package org.mewx.wenku8_flutter.legado

import android.content.Context
import io.legado.app.constant.AppConst
import io.legado.app.constant.AppLog
import io.legado.app.data.AppDatabase
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.help.book.ContentProcessorProviders
import io.legado.app.help.source.SourceHelp
import io.legado.app.help.source.exploreKinds
import io.legado.app.model.analyzeRule.AnalyzeUrlFactories
import io.legado.app.model.analyzeRule.RuleData
import io.legado.app.model.script.JsBindingInjector
import io.legado.app.model.script.JsBindings
import io.legado.app.model.script.JsEngines
import io.legado.app.model.webBook.WebBook
import io.legado.app.ui.book.search.SearchScope
import io.legado.app.utils.NetworkUtils
import io.legado.engine.LegadoEngineFacade
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import org.jsoup.Jsoup

/** One-line exception summary (class + message) for events and self-checks. */
internal fun Throwable.legadoBrief(max: Int = 400): String =
    "${javaClass.name}: ${message ?: ""}".take(max)

/**
 * Exception summary plus the first [frames] stack frames, one per line.
 * Used by the self-check's real-request stages (webBookSearch /
 * exploreBooks): a StackOverflowError's brief alone ("stack size
 * 1037KB") cannot name the looping method, but its first frames can —
 * a recursion shows up as the same frame repeated (device lesson of
 * 2026-11-03, see FIX3-stack-report.md).
 */
internal fun Throwable.legadoStack(frames: Int = 30): String {
    val head = legadoBrief(300)
    val trace = stackTrace.take(frames).joinToString("\n") { "  at $it" }
    return if (trace.isEmpty()) head else "$head\n$trace"
}

/**
 * Engine state + the bridge's business operations (sources and the
 * search-facing book chain live here and in the plugin's search sessions).
 * All state is process-wide: providers are registered once, the Room
 * database is built once, and [init] is idempotent.
 */
object LegadoEngine {

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var initialized = false

    private lateinit var dbRef: AppDatabase

    @Volatile
    private var dbFilePath: String = ""

    val isInitialized: Boolean get() = initialized

    val db: AppDatabase
        get() {
            check(initialized) { "LegadoEngine not initialized" }
            return dbRef
        }

    private val initLock = Any()

    suspend fun init(context: Context, dataDirPath: String?): Map<String, Any?> {
        if (!initialized) {
            synchronized(initLock) {
                if (!initialized) {
                    val appContext = context.applicationContext
                    val dir = if (dataDirPath.isNullOrBlank()) {
                        File(appContext.filesDir, "legado")
                    } else {
                        File(dataDirPath)
                    }
                    dir.mkdirs()
                    val database = buildLegadoDatabase(appContext, dir)
                    registerLegadoProviders(appContext, database, dir)
                    dbRef = database
                    dbFilePath = File(dir, AppDatabase.DATABASE_NAME).absolutePath
                    initialized = true
                }
            }
        }
        return mapOf(
            "ok" to true,
            "engineVersion" to LegadoEngineFacade.engineVersion(),
            "sourceCount" to dbRef.bookSourceDao.allCount()
        )
    }

    private fun requireInit() {
        if (!initialized) {
            throw LegadoBridgeException("ENGINE_NOT_INIT", "Legado engine not initialized")
        }
    }

    // ------------------------------------------------------------------
    // Error observability + self check
    // ------------------------------------------------------------------

    private val bridgeErrorLock = Any()
    private val bridgeErrors = ArrayDeque<String>()

    /**
     * Records a bridge-layer failure in a small in-memory ring so the
     * next [selfCheck] can report what actually went wrong on device
     * (engine internals deliberately swallow per-source failures, which
     * is how the 2026-11-03 "search returns nothing, no error" bug hid).
     */
    fun recordBridgeError(where: String, e: Throwable) {
        val entry = "${System.currentTimeMillis()} $where | ${e.legadoBrief(300)}"
        synchronized(bridgeErrorLock) {
            bridgeErrors.addFirst(entry)
            while (bridgeErrors.size > 12) bridgeErrors.removeLast()
        }
    }

    fun recentBridgeErrors(): List<String> =
        synchronized(bridgeErrorLock) { bridgeErrors.toList() }

    /**
     * Staged probe of the exact shared path search/explore depend on,
     * one link at a time, so a device run can say WHERE the chain
     * breaks instead of just "empty": DB counts -> SearchScope source
     * resolution (via AppDbProviders, exactly like SearchModel) -> the
     * allSources listing (every source in the DB with its switches and
     * explore/search capability — the probes below only sample the
     * first enabled source) -> JS
     * eval smoke -> ImageOps registration + decode smoke -> explore
     * kinds of the first enabled source -> AnalyzeUrl template
     * resolution ({{key}}/{{page}} JS evaluation) -> a real WebBook
     * search for 「斗破」 -> a real explore-books fetch for the first
     * kind (the exact call the Discovery page makes). Every stage is
     * isolated in runCatching; failures are reported as text, never
     * thrown.
     *
     * Post-ImageOps-fix expectations (2026-11-03): on the broken build
     * jsEval / searchUrlResolved / webBookSearch ALL failed with
     * "IllegalStateException: ImageOps 未注册" because JsBindings reads
     * the ImageOps registry for every eval; with BitmapImageOps
     * registered they must read ok, imageOps must report a successful
     * 1x1 decode, and exploreBooks must return the first kind's books.
     *
     * Post-stack-fix expectations (2026-11-03, FIX3): the ImageOps-fixed
     * build advanced to the real request and died there —
     * webBookSearch / exploreBooks both threw StackOverflowError from
     * the host's OkHttpProxyClientProvider delegating to itself
     * (unqualified name shadowed the imported top-level function).
     * With the delegation fully qualified, both stages must read ok;
     * their ERROR text carries the top 30 stack frames so any future
     * loop names its method in one screenshot.
     */
    suspend fun selfCheck(): Map<String, Any?> {
        requireInit()
        val dao = db.bookSourceDao
        val enabledList = dao.enabled(true)
        val first = enabledList.firstOrNull()
        val out = linkedMapOf<String, Any?>(
            "dbPath" to dbFilePath,
            "sourceTotal" to dao.allCount(),
            "enabledCount" to enabledList.size
        )
        out["scopeAllCount"] = runCatching {
            SearchScope("").getBookSources().size.toString()
        }.getOrElse { e ->
            recordBridgeError("selfCheck.scopeAll", e)
            "ERROR ${e.legadoBrief()}"
        }
        // Every source in the DB, one line each — the staged probes below
        // only ever look at the FIRST enabled source, so a newly imported
        // source sitting further down the list used to be invisible in
        // this report and looked "not recognised" even when it imported
        // fine. This list is the ground truth for import/switch/explore
        // and search capability per source; it changes no eligibility
        // logic anywhere.
        out["allSources"] = runCatching {
            dao.all().map { source ->
                "${source.bookSourceName} | enabled=${source.enabled} | " +
                    "enabledExplore=${source.enabledExplore} | " +
                    "type=${source.bookSourceType} | " +
                    "hasExplore=${!source.exploreUrl.isNullOrBlank()} | " +
                    "hasSearch=${!source.searchUrl.isNullOrBlank()}"
            }
        }.getOrElse { e ->
            recordBridgeError("selfCheck.allSources", e)
            listOf("ERROR ${e.legadoBrief()}")
        }
        out["jsEval"] = runCatching {
            "ok: 1+1=${JsEngines.get().eval("1+1", JsBindings())}"
        }.getOrElse { e ->
            recordBridgeError("selfCheck.jsEval", e)
            "ERROR ${e.legadoBrief()}"
        }
        out["imageOps"] = runCatching {
            val ops = JsBindingInjector.imageOpsOrNull
                ?: error("ImageOps not registered (JsBindingInjector)")
            // Mint a real 1x1 PNG with the platform codec and run it
            // through the registered implementation's decode + size:
            // exercises the impl itself, not just the registry slot.
            val png = java.io.ByteArrayOutputStream().also { outStream ->
                android.graphics.Bitmap.createBitmap(
                    1, 1, android.graphics.Bitmap.Config.ARGB_8888
                ).compress(android.graphics.Bitmap.CompressFormat.PNG, 100, outStream)
            }.toByteArray()
            val size = ops.size(ops.decode(png))
            "ok: registered (${ops.javaClass.name}), decode 1x1 png -> ${size["w"]}x${size["h"]}"
        }.getOrElse { e ->
            recordBridgeError("selfCheck.imageOps", e)
            "ERROR ${e.legadoBrief()}"
        }
        if (first == null) {
            out["firstSource"] = "(none enabled)"
        } else {
            out["firstSource"] =
                "${first.bookSourceName} <${first.bookSourceUrl}> " +
                    "enabled=${first.enabled} enabledExplore=${first.enabledExplore}"
            out["exploreKinds"] = runCatching {
                val kinds = first.exploreKinds()
                "ok: ${kinds.size} kinds [${kinds.take(6).joinToString { it.title }}]"
            }.getOrElse { e ->
                recordBridgeError("selfCheck.exploreKinds", e)
                "ERROR ${e.legadoBrief()}"
            }
            out["searchUrlResolved"] = runCatching {
                val analyzeUrl = AnalyzeUrlFactories.create(
                    rawUrl = first.searchUrl ?: "",
                    baseUrl = first.bookSourceUrl,
                    source = first,
                    ruleData = RuleData(),
                    coroutineContext = currentCoroutineContext(),
                    variables = mapOf(
                        AppConst.JsVarName.KEY to "斗破",
                        AppConst.JsVarName.PAGE to 1
                    )
                )
                "ok: ${analyzeUrl.url}"
            }.getOrElse { e ->
                recordBridgeError("selfCheck.analyzeUrl", e)
                "ERROR ${e.legadoBrief()}"
            }
            out["webBookSearch"] = runCatching {
                val page = WebBook.getBookListAwait(first, "斗破", 1)
                "ok: ${page.books.size} books, hasNext=${page.hasNextPage}"
            }.getOrElse { e ->
                recordBridgeError("selfCheck.webBookSearch", e)
                "ERROR ${e.legadoStack()}"
            }
            out["exploreBooks"] = runCatching {
                val kinds = first.exploreKinds()
                val kind = kinds.firstOrNull()
                val kindUrl = kind?.url
                if (kind == null || kindUrl.isNullOrBlank()) {
                    "skip: first source has no explore kind with a url"
                } else {
                    // The bridge's own getExploreBooks — the exact call
                    // the Discovery page makes for the selected kind.
                    val result = getExploreBooks(first.bookSourceUrl, kindUrl, 1)
                    val books = result["books"] as? List<*>
                    "ok: kind「${kind.title}」-> ${books?.size ?: 0} books, " +
                        "hasMore=${result["hasMore"]}"
                }
            }.getOrElse { e ->
                recordBridgeError("selfCheck.exploreBooks", e)
                "ERROR ${e.legadoStack()}"
            }
        }
        // Per-source deep probe (2026-11-03, for the 笔趣阁 zero-result
        // case): the staged probes above only sample the FIRST enabled
        // source, so a source that returns "no results" further down the
        // list leaves no device-side evidence at all. For each enabled
        // source (first 10, truncation noted) this reports the resolved
        // search URL — whose {{key}} encoding form (single-encoded
        // %E6%96%97…, double-encoded %25…, or raw) is decisive for
        // sources that carry the keyword in the URL path — plus one real
        // WebBook search, ok/error in the same format as above. Each
        // source is isolated: one failing source cannot mask the rest.
        // Sequential on purpose — this is a diagnostic, not a search.
        out["perSourceSearch"] = runCatching {
            val lines = enabledList.take(10).map { source ->
                "${source.bookSourceName} | searchUrlResolved: " +
                    "${probeResolvedSearchUrl(source)} | " +
                    "webBookSearch: ${probeWebBookSearch(source)}"
            }
            when {
                enabledList.isEmpty() -> listOf("(no enabled sources)")
                enabledList.size > 10 ->
                    lines + "(截断：共 ${enabledList.size} 个启用源，仅探前 10 个)"
                else -> lines
            }
        }.getOrElse { e ->
            recordBridgeError("selfCheck.perSourceSearch", e)
            listOf("ERROR ${e.legadoBrief()}")
        }
        // Image-request resolution probe (G7, P5.1): proves the two
        // mechanisms anti-hotlink sources rely on, with no network —
        // (1) a plain URL against the first enabled source picks up
        // the source-level header stack (159txt's Referer/User-Agent
        // live there); (2) a URL carrying the per-image
        // `,{headers:{...}}` option suffix 漫蛙's content rule appends
        // to every chapter image comes back with the suffix consumed
        // and the header applied. Header VALUES are never printed
        // (login headers can carry cookies) — keys only; the probe
        // URLs are synthetic constants, safe to print in full.
        out["imageResolve"] = runCatching {
            if (first == null) {
                "skip: no enabled source"
            } else {
                val probeUrl = "https://example.com/p51-probe.jpg"
                val probeSuffixed = probeUrl +
                    ",{\"headers\":{\"Referer\":\"https://probe.example/\"}}"
                val plain = resolveImageRequest(first.bookSourceUrl, probeUrl)
                val suffixed = resolveImageRequest(first.bookSourceUrl, probeSuffixed)
                "source=${first.bookSourceName} | " +
                    "plain: ${describeImageProbe(plain)} | " +
                    "suffixed: ${describeImageProbe(suffixed)}"
            }
        }.getOrElse { e ->
            recordBridgeError("selfCheck.imageResolve", e)
            "ERROR ${e.legadoBrief()}"
        }
        out["recentBridgeErrors"] = recentBridgeErrors().take(6)
        out["recentAppLog"] = AppLog.logs.take(5).map { (_, message, throwable) ->
            val head = message.lineSequence().firstOrNull() ?: ""
            if (throwable != null) "$head | ${throwable.legadoBrief(200)}" else head
        }
        return out
    }

    /** AnalyzeUrl template resolution for one source's search URL. */
    private suspend fun probeResolvedSearchUrl(source: BookSource): String =
        runCatching {
            val analyzeUrl = AnalyzeUrlFactories.create(
                rawUrl = source.searchUrl ?: "",
                baseUrl = source.bookSourceUrl,
                source = source,
                ruleData = RuleData(),
                coroutineContext = currentCoroutineContext(),
                variables = mapOf(
                    AppConst.JsVarName.KEY to "斗破",
                    AppConst.JsVarName.PAGE to 1
                )
            )
            analyzeUrl.url
        }.getOrElse { e ->
            recordBridgeError("selfCheck.analyzeUrl.perSource", e)
            "ERROR ${e.legadoBrief()}"
        }

    /** One real WebBook search for one source, self-check format. */
    private suspend fun probeWebBookSearch(source: BookSource): String =
        runCatching {
            val page = WebBook.getBookListAwait(source, "斗破", 1)
            "ok: ${page.books.size} books, hasNext=${page.hasNextPage}"
        }.getOrElse { e ->
            recordBridgeError("selfCheck.webBookSearch.perSource", e)
            "ERROR ${e.legadoStack()}"
        }

    // ------------------------------------------------------------------
    // Sources
    // ------------------------------------------------------------------

    suspend fun listSources(
        group: String?,
        enabledOnly: Boolean,
        exploreOnly: Boolean
    ): List<Map<String, Any?>> {
        requireInit()
        val dao = db.bookSourceDao
        var list = when {
            group != null -> dao.getByGroup(group)
            enabledOnly -> dao.enabled(true)
            else -> dao.all()
        }
        if (enabledOnly && group != null) list = list.filter { it.enabled }
        if (exploreOnly) list = list.filter { it.enabledExplore }
        return list.map { LegadoDto.source(it) }
    }

    suspend fun getSource(sourceUrl: String): Map<String, Any?>? {
        requireInit()
        val source = db.bookSourceDao.getBookSource(sourceUrl) ?: return null
        val kinds = runCatching { source.exploreKinds().size }.getOrNull()
        return LegadoDto.source(source, includeJson = true, exploreKindCount = kinds)
    }

    suspend fun upsertSource(sourceJson: String): Map<String, Any?> {
        requireInit()
        val source = LegadoImport.parseSingleSource(sourceJson)
        db.bookSourceDao.insert(source)
        SourceHelp.evict(source.bookSourceUrl)
        val kinds = runCatching { source.exploreKinds().size }.getOrNull()
        return LegadoDto.source(source, includeJson = true, exploreKindCount = kinds)
    }

    suspend fun importSources(payload: String, payloadKind: String): Map<String, Any?> {
        requireInit()
        val outcome = LegadoImport.importPayload(db, payload, payloadKind)
        return mapOf(
            "added" to outcome.added,
            "updated" to outcome.updated,
            "unchanged" to outcome.unchanged,
            "failed" to outcome.failed,
            "sources" to outcome.stored.map { LegadoDto.source(it) },
            "errors" to outcome.errors
        )
    }

    suspend fun deleteSources(sourceUrls: List<String>): Int {
        requireInit()
        val sources = db.bookSourceDao.getBookSources(sourceUrls)
        if (sources.isNotEmpty()) {
            SourceHelp.deleteBookSources(sources)
        }
        return sources.size
    }

    suspend fun setSourceEnabled(sourceUrl: String, enabled: Boolean) {
        requireInit()
        db.bookSourceDao.enable(sourceUrl, enabled)
        SourceHelp.evict(sourceUrl)
    }

    suspend fun setSourcesEnabled(sourceUrls: List<String>, enabled: Boolean) {
        requireInit()
        db.bookSourceDao.enableIn(sourceUrls, enabled)
        sourceUrls.forEach { SourceHelp.evict(it) }
    }

    suspend fun setSourceEnabledExplore(sourceUrl: String, enabled: Boolean) {
        requireInit()
        val source = db.bookSourceDao.getBookSource(sourceUrl)
            ?: throw LegadoBridgeException("SOURCE_NOT_FOUND", "source not found: $sourceUrl")
        source.enabledExplore = enabled
        db.bookSourceDao.update(source)
        SourceHelp.evict(sourceUrl)
    }

    suspend fun updateSourceMeta(
        sourceUrl: String,
        group: String?,
        customOrder: Int?,
        comment: String?
    ): Map<String, Any?> {
        requireInit()
        val source = db.bookSourceDao.getBookSource(sourceUrl)
            ?: throw LegadoBridgeException("SOURCE_NOT_FOUND", "source not found: $sourceUrl")
        if (group != null) source.bookSourceGroup = group
        if (customOrder != null) source.customOrder = customOrder
        if (comment != null) source.bookSourceComment = comment
        db.bookSourceDao.update(source)
        SourceHelp.evict(sourceUrl)
        return LegadoDto.source(source)
    }

    suspend fun listSourceGroups(): List<String> {
        requireInit()
        return db.bookSourceDao.allGroupsUnProcessed()
            .flatMap { it.split(",") }
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
    }

    // ------------------------------------------------------------------
    // Explore (discovery): kinds -> paged book lists
    // ------------------------------------------------------------------

    /**
     * Next-page URLs for sources whose explore rules resolve paging via a
     * parsed next-page link instead of a page number. The Dart contract
     * only carries (sourceUrl, kindUrl, page), so the bridge keeps the
     * chain per (source, kind): page 1 resets it, later pages reuse the
     * URL stored by the previous response when one was produced.
     */
    private val exploreNextPageUrls = java.util.concurrent.ConcurrentHashMap<String, String>()

    suspend fun getExploreKinds(sourceUrl: String): List<Map<String, Any?>> {
        requireInit()
        val source = sourceOrThrow(sourceUrl)
        return try {
            source.exploreKinds().map { LegadoDto.exploreKind(it) }
        } catch (e: Throwable) {
            // A failing kinds parse must stay distinguishable from
            // "this source has no kinds": record it, then let the
            // platform error reach Dart as before.
            recordBridgeError("getExploreKinds:$sourceUrl", e)
            throw e
        }
    }

    suspend fun getExploreBooks(
        sourceUrl: String,
        kindUrl: String,
        page: Int
    ): Map<String, Any?> {
        requireInit()
        val source = sourceOrThrow(sourceUrl)
        val chainKey = "$sourceUrl\n$kindUrl"
        val nextPageUrl = if (page <= 1) {
            exploreNextPageUrls.remove(chainKey)
            null
        } else {
            exploreNextPageUrls[chainKey]
        }
        val result = WebBook.getBookListAwait(
            bookSource = source,
            key = kindUrl,
            page = page,
            isSearch = false,
            nextPageUrl = nextPageUrl
        )
        // Local capture: nextPageUrl is a cross-module property, so
        // the compiler cannot smart-cast it after the null check.
        val resultNextPageUrl = result.nextPageUrl
        if (resultNextPageUrl.isNullOrBlank()) {
            exploreNextPageUrls.remove(chainKey)
        } else {
            exploreNextPageUrls[chainKey] = resultNextPageUrl
        }
        return mapOf(
            "books" to result.books.map { LegadoDto.searchBook(it) },
            "hasMore" to result.hasNextPage
        )
    }

    // ------------------------------------------------------------------
    // Book chain: info -> chapter list -> content
    // ------------------------------------------------------------------

    private suspend fun sourceOrThrow(origin: String) =
        db.bookSourceDao.getBookSource(origin)
            ?: throw LegadoBridgeException("SOURCE_NOT_FOUND", "source not found: $origin")

    private fun buildBook(
        origin: String,
        originName: String,
        bookUrl: String,
        tocUrl: String?,
        name: String?,
        author: String?,
        variable: String?
    ): Book = Book(
        bookUrl = bookUrl,
        tocUrl = tocUrl ?: "",
        origin = origin,
        originName = originName,
        name = name ?: "",
        author = author ?: "",
        variable = variable
    )

    suspend fun getBookInfo(
        origin: String,
        bookUrl: String,
        tocUrl: String?,
        name: String?,
        author: String?,
        variable: String?
    ): Map<String, Any?> {
        requireInit()
        val source = sourceOrThrow(origin)
        val book = buildBook(origin, source.bookSourceName, bookUrl, tocUrl, name, author, variable)
        val result = WebBook.getBookInfoAwait(source, book)
        return LegadoDto.book(result)
    }

    suspend fun getChapterList(
        origin: String,
        bookUrl: String,
        tocUrl: String?,
        name: String?,
        author: String?,
        variable: String?
    ): Map<String, Any?> {
        requireInit()
        val source = sourceOrThrow(origin)
        val book = buildBook(origin, source.bookSourceName, bookUrl, tocUrl, name, author, variable)
        // The engine always resolves the TOC through its own chain (which
        // also writes chapters into the engine DB as a side effect, like
        // Legado itself). forceRefresh is accepted by the contract; this
        // phase does not serve a bridge-level TOC cache.
        val chapters = WebBook.getChapterListAwait(source, book).getOrElse { throw it }
        return mapOf(
            "book" to LegadoDto.book(book),
            "chapters" to chapters.map { LegadoDto.chapter(it) }
        )
    }

    suspend fun getChapterContent(
        origin: String,
        bookUrl: String,
        tocUrl: String?,
        name: String?,
        author: String?,
        variable: String?,
        chapterUrl: String,
        chapterIndex: Int,
        chapterVariable: String?,
        nextChapterUrl: String?,
        applyReplace: Boolean
    ): Map<String, Any?> {
        requireInit()
        val source = sourceOrThrow(origin)
        val book = buildBook(origin, source.bookSourceName, bookUrl, tocUrl, name, author, variable)
        val chapter = BookChapter(
            url = chapterUrl,
            bookUrl = bookUrl,
            index = chapterIndex,
            variable = chapterVariable
        )
        var content = WebBook.getContentAwait(
            source, book, chapter, nextChapterUrl, needSave = false
        )
        if (applyReplace) {
            content = ContentProcessorProviders.get()
                .getContent(book, chapter, content, useReplace = true)
                .toString()
        }
        val isImageChapter = source.bookSourceType == 2
        val images = if (isImageChapter) {
            extractImages(content, chapter.getAbsoluteURL(book))
        } else {
            emptyList()
        }
        return mapOf(
            "content" to content,
            "images" to images,
            "isImageChapter" to isImageChapter
        )
    }

    // ------------------------------------------------------------------
    // Image requests (G7): the fork's SourceImageHeaders path
    // ------------------------------------------------------------------

    /**
     * Resolves the real fetch target for a source image (cover today,
     * manga pages when the image reader lands), mirroring the fork's
     * SourceImageHeaders.resolveSourceRequest (its :ui module is not
     * vendored): the source is looked up through [SourceHelp.getSource]
     * — the cache-first lookup the fork itself uses for cover/image
     * loads, null when the origin is unknown — an AnalyzeUrl is built
     * through the registered factory, and the engine's own
     * AnalyzeUrlCore.resolveImageRequest() applies the URL option
     * suffix (`,{headers:{...}}` / proxy / webView flags), the source
     * header, the login header and the domain cookie stack, exactly
     * like Legado itself. The synthetic "proxy" pseudo-header is
     * stripped afterwards, as the fork does.
     *
     * Never throws: an unknown origin — or a resolution failure inside
     * a broken source — returns the original URL with no headers, so
     * the Dart side falls back to the bare fetch that was the pre-G7
     * behaviour instead of losing the image outright.
     */
    suspend fun resolveImageRequest(origin: String, url: String): Map<String, Any?> {
        requireInit()
        val fallback = mapOf<String, Any?>(
            "url" to url,
            "headers" to emptyMap<String, String>()
        )
        val source = runCatching { SourceHelp.getSource(origin) }.getOrNull()
            ?: return fallback
        return runCatching {
            val analyzeUrl = AnalyzeUrlFactories.create(
                rawUrl = url,
                source = source,
                coroutineContext = currentCoroutineContext()
            )
            val (resolvedUrl, headers) = analyzeUrl.resolveImageRequest()
            val cleaned = LinkedHashMap(headers)
            cleaned.remove("proxy")
            mapOf<String, Any?>("url" to resolvedUrl, "headers" to cleaned)
        }.getOrElse { e ->
            recordBridgeError("resolveImageRequest:$origin", e)
            fallback
        }
    }

    /** One-line image-probe summary: full URL + header KEYS (never values). */
    private fun describeImageProbe(result: Map<String, Any?>): String {
        val url = result["url"] as? String ?: ""
        val host = runCatching { java.net.URI(url).host }.getOrNull() ?: "?"
        @Suppress("UNCHECKED_CAST")
        val keys = (result["headers"] as? Map<String, String>)?.keys
            ?.sorted() ?: emptyList()
        return "url=$url host=$host headers=[${keys.joinToString()}]"
    }

    /**
     * Image-chapter bodies come back from the engine as HTML with <img>
     * tags kept; pull the image URLs out in reading order (the fork does
     * this in its UI layer, so the bridge does it here per ENGINE-study
     * §1.7). Uses the engine's vendored jsoup, the only copy in the app.
     */
    private fun extractImages(html: String, baseUrl: String): List<String> {
        if (!html.contains("<img", ignoreCase = true)) return emptyList()
        return runCatching {
            val doc = Jsoup.parse(html, baseUrl)
            doc.select("img").mapNotNull { el ->
                val abs = el.attr("abs:src")
                val raw = if (abs.isNotBlank()) abs else el.attr("src")
                if (raw.isBlank()) {
                    null
                } else {
                    NetworkUtils.getAbsoluteURL(baseUrl, raw)
                }
            }
        }.getOrDefault(emptyList())
    }
}

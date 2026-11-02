package org.mewx.wenku8_flutter.legado

import android.content.Context
import io.legado.app.constant.AppConst
import io.legado.app.constant.AppLog
import io.legado.app.data.AppDatabase
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
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
     * resolution (via AppDbProviders, exactly like SearchModel) -> JS
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
        out["recentBridgeErrors"] = recentBridgeErrors().take(6)
        out["recentAppLog"] = AppLog.logs.take(5).map { (_, message, throwable) ->
            val head = message.lineSequence().firstOrNull() ?: ""
            if (throwable != null) "$head | ${throwable.legadoBrief(200)}" else head
        }
        return out
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

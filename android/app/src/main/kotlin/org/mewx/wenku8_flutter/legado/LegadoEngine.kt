package org.mewx.wenku8_flutter.legado

import android.content.Context
import io.legado.app.constant.AppConst
import io.legado.app.constant.AppLog
import io.legado.app.data.AppDatabase
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.help.book.BookHelpProviders
import io.legado.app.help.book.BookHelpShared
import io.legado.app.help.book.BookStorageProviders
import io.legado.app.help.book.ContentProcessorProviders
import io.legado.app.help.book.BookImageStorageProviders
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.model.CacheBookCallbacks
import io.legado.app.model.CacheBookShared
import io.legado.app.help.http.OkHttpClientProviders
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.source.SourceHelp
import io.legado.app.help.source.exploreKinds
import io.legado.app.model.analyzeRule.AnalyzeUrlFactories
import io.legado.app.model.analyzeRule.RuleData
import io.legado.app.model.script.JsBindingInjector
import io.legado.app.model.script.JsBindings
import io.legado.app.model.script.JsEngines
import io.legado.app.model.webBook.SearchModel
import io.legado.app.model.webBook.SourceSearchGroup
import io.legado.app.model.webBook.WebBook
import io.legado.app.ui.book.search.SearchScope
import io.legado.app.utils.NetworkUtils
import io.legado.app.utils.scan.TagScan
import io.legado.engine.LegadoEngineFacade
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

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
                    // Source login (G3): the JS showLoginDialog path
                    // needs its FlowBus consumer standing before any
                    // source JS can emit, and the login surface needs
                    // an application context for browser launches.
                    LegadoLoginHost.appContext = appContext
                    LegadoLoginEventBridge.start(scope)
                    // Rule subscriptions (G13): the engine's daily
                    // auto-update delegates its import step to the
                    // registered hook; register the host's before the
                    // first trigger, then fire one (throttled) round —
                    // the fork triggers it in the same app-start batch
                    // as its daily backup.
                    io.legado.app.help.storage.RuleSubAutoUpdateHooks
                        .register(LegadoRuleSubHook)
                    io.legado.app.help.storage.RuleSubAutoUpdate.run()
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
                    val head = "ok: kind「${kind.title}」-> ${books?.size ?: 0} books, " +
                        "hasMore=${result["hasMore"]}"
                    // Cover evidence (fix1, 2026-11-03): the Discovery
                    // page showed text covers even for a source whose
                    // list rules DO carry a cover （搬山人
                    // ruleExplore.coverUrl = img@data-src, CDN bytes
                    // verified fetchable server-side), and the host
                    // cover path audits clean end to end. The missing
                    // fact is what the engine hands back on device:
                    // append the first book's raw coverUrl, its G7
                    // resolution and one real byte fetch so a single
                    // screenshot settles "empty/odd coverUrl" vs
                    // "bytes never came back".
                    val coverUrl = (books?.firstOrNull() as? Map<*, *>)
                        ?.get("coverUrl") as? String
                    head + " | firstCover: " +
                        probeExploreCover(first.bookSourceUrl, coverUrl)
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
                // fix3: sources without a search URL (e.g. the type-5
                // RSS 源仓库 entry) only ever answered 「搜索url不能为空」
                // here, which read like a failure in the report. They
                // are not searchable by design; say so and skip the call.
                if (source.searchUrl.isNullOrBlank()) {
                    "${source.bookSourceName} | skipped: 无搜索地址（不可搜索）"
                } else {
                    "${source.bookSourceName} | searchUrlResolved: " +
                        "${probeResolvedSearchUrl(source)} | " +
                        "webBookSearch: ${probeWebBookSearch(source)}"
                }
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
        // fix3 app-path probe: perSourceSearch above calls WebBook
        // directly with NO timeout, but the App's real search goes
        // through SearchModel, which caps every page request at
        // AppConst.timeLimit (15s) — shorter than the host Cloudflare
        // solver's 30s challenge window. A shielded source can thus be
        // "ok" above and still return zero books in the App. This
        // section runs each searchable text/manga source through the
        // exact session construction (one SearchModel over a
        // single-source SearchScope, 斗破）, INCLUDING the session's
        // fix3 warm-up + retry, and reports what the App would see.
        out["appSearchProbe"] = runCatching {
            val probeSources = enabledList.filter { source ->
                (source.bookSourceType == 0 || source.bookSourceType == 2) &&
                    !source.searchUrl.isNullOrBlank()
            }
            when {
                probeSources.isEmpty() ->
                    listOf("(no searchable text/manga source)")
                else -> probeSources.take(6).map { source ->
                    probeAppSearchPath(source)
                }
            }
        }.getOrElse { e ->
            recordBridgeError("selfCheck.appSearchProbe", e)
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
        // WebView pair probes (G4/G2/G11, P5.2): the backstage probe
        // runs a REAL headless WebView round-trip — load a synthetic
        // page, evaluate the default outerHTML script, and require
        // the marker back — which is the exact machinery 得奇's
        // webJs content depends on; a registration line alone would
        // also pass on a build whose WebView creation is broken. The
        // verification probe can only check registration (popping a
        // real captcha from a self-check would be a UI ambush; the
        // dialog/browser paths are proven by the acceptance sources).
        out["backstageWebView"] = runCatching {
            val response = io.legado.app.help.http.BackstageWebViewProviders.get()
                .create(
                    html = "<html><head><title>p52</title></head>" +
                        "<body>P52_PROBE</body></html>",
                    javaScript = "document.documentElement.outerHTML",
                    delayTime = 200L
                )
                .getStrResponse()
            val body = response.body ?: ""
            if (body.contains("P52_PROBE")) {
                "ok: headless WebView round-trip returned the probe page"
            } else {
                "ERROR unexpected body: ${body.take(120)}"
            }
        }.getOrElse { e ->
            recordBridgeError("selfCheck.backstageWebView", e)
            "ERROR ${e.legadoBrief()}"
        }
        out["verificationUi"] = runCatching {
            val provider = io.legado.app.help.source.VerificationUiProviders.get()
            "ok: registered (${provider.javaClass.name})"
        }.getOrElse { e ->
            recordBridgeError("selfCheck.verificationUi", e)
            "ERROR ${e.legadoBrief()}"
        }
        out["webViewUa"] = runCatching {
            val ua = io.legado.app.help.UserAgentProviders.getWebViewUA()
            "ok: ${ua.take(110)}"
        }.getOrElse { e ->
            recordBridgeError("selfCheck.webViewUa", e)
            "ERROR ${e.legadoBrief()}"
        }
        // Source login surface (G3, P5.3): the FlowBus consumer must
        // be standing (a JS showLoginDialog with no consumer parks
        // until its 30-minute timeout), and the login-capable sources
        // are listed by name — flags and counts only, never values:
        // login info and headers carry credentials.
        out["sourceLogin"] = runCatching {
            val loginSources = dao.all().filter { it.hasLogin() }
            val states = LegadoLogin.loginStates(loginSources)
            val loggedIn = states.values.count { it }
            "ok: eventBridge=${LegadoLoginEventBridge.running}, " +
                "loginSources=${loginSources.size} " +
                "[${loginSources.take(6).joinToString { it.bookSourceName }}], " +
                "withSavedLogin=$loggedIn"
        }.getOrElse { e ->
            recordBridgeError("selfCheck.sourceLogin", e)
            "ERROR ${e.legadoBrief()}"
        }
        // Cloudflare interceptor (G5, P5.4): the provider's client
        // must be the fork-style wrapper — the solver present at
        // application-interceptor index 0 (a solved challenge's
        // re-proceed must re-run the shared client's cookie bridge
        // AFTER the solver) and its state machine the vendored
        // ChallengeInterceptorBase. Registration alone would also
        // pass if the wrapper silently regressed to the bare shared
        // client, so the built client is inspected, not the registry.
        out["cloudflare"] = runCatching {
            val client = io.legado.app.help.http.OkHttpClientProviders.get().okHttpClient
            val interceptors = client.interceptors
            val index = interceptors.indexOfFirst { it is LegadoCloudflareInterceptor }
            if (index >= 0) {
                val solver = interceptors[index]
                "ok: ${solver.javaClass.simpleName} at index $index of " +
                    "${interceptors.size} app interceptors, base=" +
                    "${solver.javaClass.superclass?.superclass?.simpleName}"
            } else {
                "ERROR solver missing: " +
                    interceptors.joinToString { it.javaClass.simpleName }
            }
        }.getOrElse { e ->
            recordBridgeError("selfCheck.cloudflare", e)
            "ERROR ${e.legadoBrief()}"
        }
        // Content pipeline probe (G9, P5.5): runs the registered
        // accessor over synthetic samples and reports OBSERVED values
        // (never hard asserts — this is a diagnostic surface): the
        // duplicate-title flag + textList shape, the t2s conversion
        // result while the converter is temporarily switched on (the
        // user's setting is restored in finally), and whether
        // re-segmentation merged a hard mid-paragraph break. Before
        // P5.5 the same probe would read sameTitleRemoved=false,
        // textList=1 and an unconverted 繁體 sample.
        out["contentProcessor"] = runCatching {
            probeContentProcessor()
        }.getOrElse { e ->
            recordBridgeError("selfCheck.contentProcessor", e)
            "ERROR ${e.legadoBrief()}"
        }
        // Management plane (P5.6): table sizes for the surfaces the
        // source manager now drives (subscriptions / replace rules),
        // counts only.
        out["manageCounts"] = runCatching {
            "ok: ruleSubs=${db.ruleSubDao.all().size}, " +
                "replaceRules=${db.replaceRuleDao.all().size}, " +
                "dictRules=${db.dictRuleDao.all().size}"
        }.getOrElse { e ->
            recordBridgeError("selfCheck.manageCounts", e)
            "ERROR ${e.legadoBrief()}"
        }
        // Converter switch (P5.5 follow-up): the value the content
        // pipeline will apply to Legado books (0 none / 1 t2s / 2 s2t).
        // The probe above temporarily flips it and restores, so this
        // reads the pipeline probe's restored end state.
        out["chineseConverterType"] = runCatching {
            "ok: type=${AppConfigProviders.get().chineseConverterType}"
        }.getOrElse { e ->
            recordBridgeError("selfCheck.chineseConverterType", e)
            "ERROR ${e.legadoBrief()}"
        }
        // Cache download plane (P5.7): the three providers CacheBook
        // needs beyond BookHelp, plus the live thread-count width.
        out["cacheProviders"] = runCatching {
            val storage = runCatching { BookStorageProviders.get(); true }
                .getOrDefault(false)
            val images = runCatching { BookImageStorageProviders.get(); true }
                .getOrDefault(false)
            val callbacks = runCatching { CacheBookCallbacks.get(); true }
                .getOrDefault(false)
            "ok: bookStorage=$storage, bookImageStorage=$images, " +
                "cacheCallbacks=$callbacks, " +
                "threadCount=${AppConfigProviders.get().threadCount}"
        }.getOrElse { e ->
            recordBridgeError("selfCheck.cacheProviders", e)
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

    /**
     * Synthetic content-pipeline probe for the self-check (P5.5).
     * Uses a throwaway book that exists only in memory (never written
     * to the DB); its read config enables the two book-level switches
     * the pipeline ANDs against, so each stage is exercised in turn by
     * the call parameters. Observed values only.
     */
    private fun probeContentProcessor(): String {
        val accessor = ContentProcessorProviders.get()
        val book = Book(
            bookUrl = "https://probe.invalid/book",
            origin = "https://probe.invalid",
            originName = "自检",
            name = "自检样本书",
            author = "自检"
        )
        book.readConfig = Book.ReadConfig(reSegment = true, useReplaceRule = true)
        val chapter = BookChapter(
            url = "https://probe.invalid/ch1",
            title = "第一章 启程",
            bookUrl = book.bookUrl,
            index = 0
        )
        // A: the body opens with a duplicate of the chapter title.
        val a = accessor.getBookContent(
            book, chapter,
            "第一章 启程\n他推开门，走了出去。",
            includeTitle = true, useReplace = true,
            chineseConvert = true, reSegment = false
        )
        // B: traditional -> simplified, converter temporarily on.
        val config = AppConfigProviders.get()
        val oldType = config.chineseConverterType
        val bText = try {
            config.chineseConverterType = 1
            accessor.getBookContent(
                book, chapter,
                "這是繁體字的測試，學習中文。",
                includeTitle = false, useReplace = true,
                chineseConvert = true, reSegment = false
            ).textList.joinToString("\n")
        } finally {
            config.chineseConverterType = oldType
        }
        // C: a hard line break mid-paragraph (no sentence end before
        // it) is merged by re-segmentation.
        val cText = accessor.getBookContent(
            book, chapter,
            "他站在窗前望着远方\n雨还在下，街上没有人。",
            includeTitle = false, useReplace = true,
            chineseConvert = false, reSegment = true
        ).textList.joinToString("\n")
        return "ok: accessor=${accessor.javaClass.simpleName} | " +
            "dedup: sameTitleRemoved=${a.sameTitleRemoved}, " +
            "textList=${a.textList.size} | " +
            "t2s: ${bText.take(12)} | " +
            "reSegmentMerged=${!cText.contains("远方\n雨")}"
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

    /**
     * fix3: one source through the App's REAL search path — a
     * SearchModel over a single-source SearchScope, built exactly like
     * the plugin session builds it, with the session's warm-up + retry
     * mirrored — reporting what the App search would actually surface
     * for 斗破： aggregate size, first book name/type, attempt count,
     * whether the warm-up ran, the cancel exception (if any) and wall
     * time. Compare against [probeWebBookSearch] (same source, direct
     * call, no 15s cap) to isolate the session layer.
     */
    private suspend fun probeAppSearchPath(source: BookSource): String {
        val startedAt = System.currentTimeMillis()
        val done = CompletableDeferred<Unit>()
        val aggregate = AtomicReference<List<SearchBook>>(emptyList())
        val cancelBrief = AtomicReference<String?>(null)
        val attempts = AtomicInteger(1)
        val warmed = AtomicBoolean(false)
        val modelRef = AtomicReference<SearchModel?>(null)
        val callback = object : SearchModel.CallBack {
            override fun getSearchScope(): SearchScope = SearchScope(source)
            override fun onSearchStart() = Unit
            override fun onSearchSuccess(searchBooks: List<SearchBook>) {
                aggregate.set(searchBooks)
            }

            override fun onSearchGroupsChanged(
                groups: List<SourceSearchGroup>
            ) = Unit

            override fun onSearchFinish(isEmpty: Boolean, hasMore: Boolean) {
                done.complete(Unit)
            }

            override fun onSearchCancel(exception: Throwable?) {
                if (exception == null) {
                    done.complete(Unit)
                    return
                }
                cancelBrief.set(exception.legadoBrief())
                if (attempts.compareAndSet(1, 2)) {
                    scope.launch {
                        runCatching {
                            OkHttpClientProviders.get().okHttpClient
                                .newCallStrResponse {
                                    url(source.bookSourceUrl)
                                }
                            warmed.set(true)
                        }
                        runCatching {
                            modelRef.get()?.restartSource(
                                source.bookSourceUrl
                            )
                        }
                    }
                } else {
                    done.complete(Unit)
                }
            }
        }
        val model = SearchModel(scope, callback)
        modelRef.set(model)
        return try {
            model.search(1L, "斗破")
            val finished = withTimeoutOrNull(120_000) { done.await() } != null
            val books = aggregate.get()
            val firstBook = books.firstOrNull()
            "${source.bookSourceName} | sessionBooks: ${books.size} | " +
                "firstType: ${firstBook?.type} | " +
                "firstName: ${firstBook?.name} | " +
                "attempts: ${attempts.get()} | warmed: ${warmed.get()} | " +
                "finished: $finished | " +
                "cancelErr: ${cancelBrief.get() ?: "none"} | " +
                "elapsedMs: ${System.currentTimeMillis() - startedAt}"
        } catch (e: Throwable) {
            "${source.bookSourceName} | ERROR ${e.legadoBrief()}"
        } finally {
            runCatching { model.close() }
        }
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
    // Source login (G3): form data, submit, button actions, web login
    // ------------------------------------------------------------------

    suspend fun getLoginData(sourceUrl: String): Map<String, Any?> {
        requireInit()
        return LegadoLogin.loginData(sourceOrThrow(sourceUrl))
    }

    suspend fun login(
        sourceUrl: String,
        data: Map<String, String>
    ): Map<String, Any?> {
        requireInit()
        return LegadoLogin.login(sourceOrThrow(sourceUrl), data)
    }

    suspend fun runLoginAction(
        sourceUrl: String,
        action: String,
        data: Map<String, String>
    ): Map<String, Any?> {
        requireInit()
        return LegadoLogin.runLoginAction(sourceOrThrow(sourceUrl), action, data)
    }

    suspend fun openSourceLogin(sourceUrl: String): Map<String, Any?> {
        requireInit()
        return LegadoLogin.openSourceLogin(sourceOrThrow(sourceUrl))
    }

    suspend fun logoutSource(sourceUrl: String) {
        requireInit()
        LegadoLogin.logout(sourceOrThrow(sourceUrl))
    }

    /** The saved login header text (the fork dialog's 查看登录头 menu). */
    suspend fun getLoginHeader(sourceUrl: String): Map<String, Any?> {
        requireInit()
        return mapOf("header" to sourceOrThrow(sourceUrl).getLoginHeader())
    }

    suspend fun removeLoginHeader(sourceUrl: String) {
        requireInit()
        sourceOrThrow(sourceUrl).removeLoginHeader()
    }

    /** Saved-login flags for a batch of sources (management list). */
    suspend fun getLoginStates(sourceUrls: List<String>): Map<String, Boolean> {
        requireInit()
        val sources = db.bookSourceDao.getBookSources(sourceUrls)
        val states = LegadoLogin.loginStates(sources)
        // Unknown URLs report false rather than vanishing, so the
        // caller can treat the answer as total over its input.
        return sourceUrls.associateWith { states[it] ?: false }
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
        chapterTitle: String?,
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
            // The TOC title (already title-rule processed by the
            // engine's chapter-list chain): the content pipeline's
            // duplicate-title removal and display-title logic key off
            // it, exactly as the fork's reader passes its TOC chapter.
            title = chapterTitle ?: "",
            bookUrl = bookUrl,
            index = chapterIndex,
            variable = chapterVariable
        )
        // Cache-first (P5.7): a chapter persisted by the cache
        // download is served from disk — the fork reader consults
        // BookHelp.getContent before the network the same way. A miss
        // falls through to the live fetch, still needSave=false:
        // online reads do not implicitly populate the offline cache;
        // only the explicit cache download (startCacheChapters) does.
        var content = BookHelpProviders.get().getContent(book, chapter)
            ?: WebBook.getContentAwait(
                source, book, chapter, nextChapterUrl, needSave = false
            )
        val isImageChapter = source.bookSourceType == 2
        // Image chapters carry an image-URL list, not prose: the fork
        // never runs the text pipeline over it (an image book's
        // getUseReplaceRule() is false unless explicitly overridden,
        // and its reader consumes the list as image refs), so the
        // pipeline below is text-chapters only.
        if (applyReplace && !isImageChapter) {
            // Full post-processing pipeline (P5.5, G9): duplicate-title
            // removal, re-segmentation, simplified/traditional
            // conversion and the replace rules, with every switch
            // resolved inside the processor exactly as the fork does
            // (chineseConvert by AppConfig.chineseConverterType,
            // reSegment by the book's own read config, replace rules
            // ANDed with Book.getUseReplaceRule()). The entry point is
            // the fork's own body-only variant — BookController's web
            // API calls getContent(includeTitle = false) for the same
            // reason: the bridge contract returns the chapter BODY and
            // the Flutter reader renders the chapter title itself, so
            // the title element of BookContent must not be prepended.
            content = ContentProcessorProviders.get()
                .getContent(
                    book, chapter, content,
                    includeTitle = false, useReplace = true
                )
                .toString()
        }
        val images = if (isImageChapter) {
            extractImages(content, chapter.getAbsoluteURL(book))
                .map { localCachedImagePath(book, it) ?: it }
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
     * P5.7: when the cache download already persisted this chapter
     * image, hand the reader its local file path instead of the remote
     * URL (the Dart side treats a leading '/' as a local file). The
     * download side stores images through BookImageDownloadShared,
     * whose extraction (TagScan) truncates a `src="URL,{...}"`
     * attribute at `URL,{`, so the lookup tries both the full src this
     * bridge extracted and that truncated key form.
     */
    private fun localCachedImagePath(book: Book, src: String): String? {
        if (!src.startsWith("http://") && !src.startsWith("https://")) return null
        val help = BookHelpProviders.get()
        val cut = src.indexOf(",{")
        val keys = if (cut >= 0) listOf(src, src.substring(0, cut + 2)) else listOf(src)
        for (key in keys) {
            if (help.isImageExist(book, key)) {
                return help.getImage(book, key).absolutePath
            }
        }
        return null
    }

    // ------------------------------------------------------------------
    // Cache download (P5.7, G15 + G8): the fork's CacheBookShared
    // ------------------------------------------------------------------

    /**
     * Runs an offline cache download for the chapter range
     * [fromIndex]..[toIndex] (engine chapter indexes, inclusive) on the
     * fork's own CacheBookShared orchestrator — per-chapter WebBook
     * fetch with needSave (chapter text persisted in the fork layout),
     * chapter images persisted through BookHelp.saveImages, three
     * strikes per chapter before it lands in the failure set.
     *
     * This function is only the bridge adapter around it:
     * - host books live in the Flutter-side registry, not the engine
     *   book table, so the model is seeded via
     *   [CacheBookShared.getOrCreate] with (source, book) before
     *   enqueueing (the bookUrl overload would miss the model map);
     * - the TOC is refreshed into the engine DB up front because
     *   CacheBook reads chapters from bookChapterDao;
     * - the engine thread count is dipped while downloading (see
     *   [LegadoConfigAccessor.acquireCacheDownloadDip]);
     * - the orchestrator's public state (CacheBookShared
     *   .successDownloadSet / errorDownloadMap) is polled into
     *   `cacheProgress` task events
     *   {taskId, done, total, failed:[chapter indexes]} — the shape
     *   the Dart CacheProgressEvent parses. A fatal error is reported
     *   as a terminal all-failed progress event. Cancelling the
     *   returned Job stops this book's model (fork stop semantics)
     *   and releases the dip.
     */
    fun startCacheChapters(
        taskId: Int,
        origin: String,
        bookUrl: String,
        tocUrl: String?,
        name: String?,
        author: String?,
        variable: String?,
        fromIndex: Int,
        toIndex: Int,
        emit: (Map<String, Any?>) -> Unit
    ): Job = scope.launch {
        fun progress(done: Int, total: Int, failed: List<Int>) {
            emit(
                mapOf(
                    "type" to "cacheProgress",
                    "taskId" to taskId,
                    "done" to done,
                    "total" to total,
                    "failed" to failed
                )
            )
        }
        var book: Book? = null
        var dipped = false
        try {
            requireInit()
            val source = sourceOrThrow(origin)
            val built = buildBook(
                origin, source.bookSourceName, bookUrl, tocUrl, name, author, variable
            )
            book = built
            WebBook.getChapterListAwait(source, built).getOrElse { throw it }
            val totalChapters = db.bookChapterDao.getChapterCount(built.bookUrl)
            if (totalChapters <= 0) {
                progress(0, 0, emptyList())
                return@launch
            }
            val from = fromIndex.coerceIn(0, totalChapters - 1)
            val to = toIndex.coerceIn(from, totalChapters - 1)
            val indexes = (from..to).toList()
            val total = indexes.size
            LegadoConfigAccessor.acquireCacheDownloadDip()
            dipped = true
            val model = CacheBookShared.getOrCreate(source, built)
            if (!CacheBookShared.enqueueDownload(built.bookUrl, from, to)) {
                progress(0, total, indexes)
                return@launch
            }
            // The fork's CacheBookService role: drive the shared
            // process loop. It winds down on its own once every model
            // drains, so this job deliberately does not join it.
            scope.launch { CacheBookShared.startProcessJob() }
            val keys = db.bookChapterDao.getChapterList(built.bookUrl)
                .associateBy { it.index }
                .let { byIndex -> indexes.map { byIndex[it]?.primaryStr() } }
            var lastDone = -1
            var lastFailed: List<Int>? = null
            while (true) {
                // The shared orchestrator keeps its success/failure
                // bookkeeping on the CacheBookShared object itself
                // (chapter keys are bookUrl+chapterUrl, so concurrent
                // books never collide).
                var succeeded = 0
                val failed = ArrayList<Int>()
                for ((offset, key) in keys.withIndex()) {
                    if (key == null) continue
                    if (CacheBookShared.successDownloadSet.contains(key)) {
                        succeeded++
                    } else if ((CacheBookShared.errorDownloadMap[key] ?: 0) >= 3) {
                        failed.add(indexes[offset])
                    }
                }
                if (succeeded != lastDone || failed != lastFailed) {
                    progress(succeeded, total, failed)
                    lastDone = succeeded
                    lastFailed = failed
                }
                val drained = CacheBookShared.cacheBookMap[built.bookUrl] == null ||
                    model.isIdle()
                if (drained || succeeded + failed.size >= total) {
                    // Terminal: everything not failed counts as done
                    // (volume chapters complete without a success
                    // entry in the model).
                    progress(total - failed.size, total, failed)
                    break
                }
                delay(400)
            }
        } catch (e: CancellationException) {
            withContext(NonCancellable) {
                runCatching {
                    book?.let {
                        CacheBookShared.cacheBookMap[it.bookUrl]?.stop()
                    }
                }
            }
            throw e
        } catch (e: Exception) {
            AppLog.put("缓存下载失败: ${e.message}", e)
            progress(0, 1, listOf(fromIndex))
        } finally {
            if (dipped) LegadoConfigAccessor.releaseCacheDownloadDip()
        }
    }

    /**
     * Engine chapter indexes whose chapter text file is present in the
     * fork-layout book cache folder (P5.7) — the bridge's view of
     * "which chapters are available offline" for one book.
     */
    suspend fun getCachedChapterIndexes(
        origin: String,
        bookUrl: String,
        tocUrl: String?,
        name: String?,
        author: String?,
        variable: String?
    ): List<Int> {
        requireInit()
        val source = sourceOrThrow(origin)
        val book = buildBook(origin, source.bookSourceName, bookUrl, tocUrl, name, author, variable)
        if (BookHelpShared.shouldSkipChapterFiles(book)) return emptyList()
        val dir = java.io.File(BookStorageProviders.get().rootPath, book.getFolderName())
        val names = dir.list() ?: return emptyList()
        return names.mapNotNull { fileName ->
            // Fork chapter files are `<index padded>-<title md5>.nb`
            // (BookChapter.getFileName); the index is the dash prefix.
            if (!fileName.endsWith(".nb")) {
                null
            } else {
                fileName.substringBefore('-').trimStart('0')
                    .ifEmpty { "0" }
                    .toIntOrNull()
            }
        }.distinct().sorted()
    }

    /** Drops one book's whole offline cache folder (text + images). */
    suspend fun clearBookCache(
        origin: String,
        bookUrl: String,
        tocUrl: String?,
        name: String?,
        author: String?,
        variable: String?
    ) {
        requireInit()
        val source = sourceOrThrow(origin)
        val book = buildBook(origin, source.bookSourceName, bookUrl, tocUrl, name, author, variable)
        BookStorageProviders.get().clearCache(book)
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

    /**
     * One-line cover evidence for the self-check's exploreBooks stage
     * (fix1, 2026-11-03): the first explore book's raw coverUrl,
     * verbatim (a source URL, not user data); the G7-resolved target
     * truncated to scheme + host + the first 40 path characters (the
     * query string, which can carry tokens, is never printed); and
     * the outcome of one real fetch with the resolved headers —
     * HTTP status + byte count, read-capped at 8MB like the Dart
     * cover loader — or the failure's brief. Resolved header values
     * are used for the request only, never printed; no image bytes
     * are reported.
     */
    private suspend fun probeExploreCover(origin: String, coverUrl: String?): String {
        if (coverUrl.isNullOrBlank()) return "coverUrl=(empty)"
        val resolved = resolveImageRequest(origin, coverUrl)
        val resolvedUrl = resolved["url"] as? String ?: coverUrl
        @Suppress("UNCHECKED_CAST")
        val headers = resolved["headers"] as? Map<String, String> ?: emptyMap()
        val uri = runCatching { java.net.URI(resolvedUrl) }.getOrNull()
        val shown = if (uri == null) {
            "(unparsable resolved url)"
        } else {
            "${uri.scheme}://${uri.host ?: "?"}${(uri.path ?: "").take(40)}"
        }
        val fetched = withContext(Dispatchers.IO) {
            runCatching {
                val client = io.legado.app.help.http.OkHttpClientProviders.get()
                    .okHttpClient.newBuilder()
                    .callTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
                    .build()
                val request = okhttp3.Request.Builder().url(resolvedUrl)
                    .apply { headers.forEach { (k, v) -> header(k, v) } }
                    .build()
                client.newCall(request).execute().use { response ->
                    var total = 0L
                    val stream = response.body?.byteStream()
                    if (stream != null) {
                        val buffer = ByteArray(16 * 1024)
                        while (total <= 8L * 1024 * 1024) {
                            val read = stream.read(buffer)
                            if (read < 0) break
                            total += read
                        }
                    }
                    "HTTP ${response.code}, $total bytes"
                }
            }.getOrElse { e -> "fetch failed: ${e.legadoBrief(200)}" }
        }
        return "coverUrl=$coverUrl | resolved=$shown | $fetched"
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
    // ------------------------------------------------------------------
    // Image-chapter payloads
    // ------------------------------------------------------------------

    // The fork BookController's imgTagRegex, verbatim: the src capture
    // tolerates one inner quote when the value continues to a closing
    // `}` — the Legado URL-option suffix form `URL,{"headers":{...}}`.
    private val imgSrcRegex = Regex(
        """<img[^>]*\ssrc=['"]([^'"]*(?:['"][^>]+\})?)['"][^>]*>""",
        RegexOption.IGNORE_CASE
    )
    private val imgDataSrcRegex = Regex(
        """<img[^>]*\sdata-src=['"]([^'"]*(?:['"][^>]+\})?)['"][^>]*>""",
        RegexOption.IGNORE_CASE
    )
    private val mdImgRegex = Regex("""!\[[^\]]*\]\(([^\s\)]+)\)""")

    /**
     * Extracts an image chapter's image URLs, in reading order, from the
     * engine's processed chapter content.
     *
     * String scanning, NOT a DOM parse — deliberately. Manga rules wrap
     * each image as `<img src="URL,{"headers":{...}}">`, and a DOM
     * parser (verified against both jsoup 1.15.3 and the app's own
     * ksoup 0.2.6) ends the double-quoted src at the JSON's first inner
     * quote, returning a truncated `URL,{` and destroying the per-image
     * headers the G7 resolver exists to recover. The fork's own reading
     * surfaces scan strings for the same reason (ChapterContentParser /
     * TagScan in :ui, BookController's regex passes for the web API);
     * this mirrors them:
     * - `<img>` tags via the BookController regex (data-src preferred,
     *   as HtmlFormatter prefers it);
     * - a TagScan.attr fallback for tag shapes the regex misses
     *   (unquoted src, odd spacing);
     * - Markdown `![alt](url)` and bare image-URL lines
     *   (BookController.isImageOrHttpLine's test).
     *
     * A candidate keeps a COMPLETE `,{...}` suffix (AnalyzeUrl consumes
     * it in resolveImageRequest). A dangling, unbalanced `,{` fragment
     * — the remnant left when the engine's HtmlFormatter re-emits a tag
     * through its DOM walk — is cut, keeping the bare URL.
     */
    private fun extractImages(content: String, baseUrl: String): List<String> {
        if (content.isBlank()) return emptyList()
        val results = LinkedHashSet<String>()
        fun addCandidate(raw: String) {
            val cleaned = cleanImageCandidate(raw) ?: return
            results.add(absolutizeImageCandidate(cleaned, baseUrl))
        }
        for (line in content.split('\n')) {
            val trimmed = line.trim().trim('　')
            if (trimmed.isEmpty()) continue
            if (trimmed.contains("<img", ignoreCase = true)) {
                // Tag by tag, so several images sharing one line all
                // survive, each with its own data-src-over-src
                // preference; TagScan covers tag shapes the regexes
                // miss (unquoted src, odd spacing — it still truncates
                // a quoted suffix at the inner quote, but the candidate
                // cleanup salvages the bare URL from that).
                val tagUrls = mutableListOf<String>()
                var searchFrom = 0
                while (true) {
                    val tagStart = trimmed.indexOf("<img", searchFrom, ignoreCase = true)
                    if (tagStart < 0) break
                    val tagEnd = trimmed.indexOf('>', tagStart)
                    if (tagEnd < 0) break
                    val tag = trimmed.substring(tagStart, tagEnd + 1)
                    val captured = imgDataSrcRegex.find(tag)?.groupValues?.get(1)
                        ?: imgSrcRegex.find(tag)?.groupValues?.get(1)
                        ?: TagScan.attr(tag, "data-src")
                        ?: TagScan.attr(tag, "src")
                    if (captured != null) tagUrls.add(captured)
                    searchFrom = tagEnd + 1
                }
                if (tagUrls.isNotEmpty()) {
                    tagUrls.forEach(::addCandidate)
                    continue
                }
            }
            val md = mdImgRegex.find(trimmed)
            if (md != null) {
                addCandidate(md.groupValues[1])
                continue
            }
            if (isImageOrHttpLine(trimmed)) addCandidate(trimmed)
        }
        return results.toList()
    }

    private fun cleanImageCandidate(raw: String): String? {
        var candidate = raw.trim().trim('　').trim()
        if (candidate.isEmpty()) return null
        val suffixAt = candidate.indexOf(",{")
        val head: String
        if (suffixAt >= 0 && !candidate.endsWith("}")) {
            // Incomplete option suffix (truncated upstream): the bare
            // URL before it is still fetchable.
            candidate = candidate.substring(0, suffixAt).trim()
            head = candidate
        } else {
            head = if (suffixAt >= 0) candidate.substring(0, suffixAt) else candidate
        }
        if (head.isEmpty()) return null
        // Only the head is held to the no-quotes rule: a complete
        // suffix is the fork's URL-option JSON — its quotes are the
        // JSON's own, and the whole string, quotes included, is what
        // AnalyzeUrl consumes downstream. Quotes, markup debris or
        // raw whitespace in the head mean this was never a URL
        // (a percent-encoded URL contains none of these).
        if (head.any { it == '"' || it == '\'' || it == '<' || it == '>' || it.isWhitespace() }) {
            return null
        }
        return candidate
    }

    private fun absolutizeImageCandidate(candidate: String, baseUrl: String): String {
        if (candidate.startsWith("data:", ignoreCase = true)) return candidate
        val suffixAt = candidate.indexOf(",{")
        val head = if (suffixAt >= 0) candidate.substring(0, suffixAt) else candidate
        val suffix = if (suffixAt >= 0) candidate.substring(suffixAt) else ""
        if (head.startsWith("http://", ignoreCase = true) ||
            head.startsWith("https://", ignoreCase = true)
        ) {
            return candidate
        }
        return NetworkUtils.getAbsoluteURL(baseUrl, head) + suffix
    }

    /** The fork BookController.isImageOrHttpLine test, verbatim logic. */
    private fun isImageOrHttpLine(line: String): Boolean {
        if (line.isBlank()) return false
        if (line.startsWith("http://", ignoreCase = true) ||
            line.startsWith("https://", ignoreCase = true) ||
            line.startsWith("//")
        ) {
            return true
        }
        val clean = line.substringBefore(",{").trim()
        return clean.endsWith(".jpg", ignoreCase = true) ||
            clean.endsWith(".jpeg", ignoreCase = true) ||
            clean.endsWith(".png", ignoreCase = true) ||
            clean.endsWith(".gif", ignoreCase = true) ||
            clean.endsWith(".webp", ignoreCase = true) ||
            clean.endsWith(".bmp", ignoreCase = true) ||
            clean.endsWith(".avif", ignoreCase = true)
    }
}

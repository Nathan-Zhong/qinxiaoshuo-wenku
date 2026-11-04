package org.mewx.wenku8_flutter.legado

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.room3.Room
import androidx.sqlite.driver.AndroidSQLiteDriver
import io.legado.app.constant.AndroidIdHolder
import io.legado.app.constant.AppLog
import io.legado.app.constant.AppLogHost
import io.legado.app.data.AppDatabase
import io.legado.app.data.AppDatabaseProvider
import io.legado.app.data.AppDatabaseProviders
import io.legado.app.data.AppDbAccessor
import io.legado.app.data.AppDbProviders
import io.legado.app.data.DatabaseMigrations
import io.legado.app.data.dao.BookChapterDao
import io.legado.app.data.dao.BookDao
import io.legado.app.data.dao.BookGroupDao
import io.legado.app.data.dao.BookSourceDao
import io.legado.app.data.dao.BookmarkDao
import io.legado.app.data.dao.CacheDao
import io.legado.app.data.dao.CookieDao
import io.legado.app.data.dao.DictRuleDao
import io.legado.app.data.dao.HttpTTSDao
import io.legado.app.data.dao.KeyboardAssistsDao
import io.legado.app.data.dao.KeywordHighlightDao
import io.legado.app.data.dao.ReadRecordDao
import io.legado.app.data.dao.ReplaceRuleDao
import io.legado.app.data.dao.RuleSubDao
import io.legado.app.data.dao.SearchKeywordDao
import io.legado.app.data.dao.ServerDao
import io.legado.app.data.dao.SourceFilterRuleDao
import io.legado.app.data.dao.TxtTocRuleDao
import io.legado.app.data.runInImmediateTransaction
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.Cookie
import io.legado.app.data.entities.ReplaceRule
import io.legado.app.help.AppCacheManager
import io.legado.app.help.CacheManager
import io.legado.app.help.FileCacheProviders
import io.legado.app.help.archive.ArchiveProviders
import io.legado.app.help.image.BitmapImageOps
import io.legado.app.help.ui.OpenUrlProviders
import io.legado.app.help.ExploreKindsCacheProvider
import io.legado.app.help.ExploreKindsCacheProviders
import io.legado.app.help.IntentData
import io.legado.app.help.IntentDataAccessor
import io.legado.app.help.IntentDataProviders
import io.legado.app.help.JsCryptoProviderJvm
import io.legado.app.help.JsCryptoProviders
import io.legado.app.help.RuleBigDataProviders
import io.legado.app.help.RuleBigDataShared
import io.legado.app.help.UserAgentProvider
import io.legado.app.help.UserAgentProviders
import android.graphics.BitmapFactory
import io.legado.app.help.book.BookContent
import io.legado.app.help.book.BookHelpAccessor
import io.legado.app.help.book.BookHelpProviders
import io.legado.app.help.book.BookHelpShared
import io.legado.app.help.book.BookImageDownloadShared
import io.legado.app.help.book.BookImageStorage
import io.legado.app.help.book.BookImageStorageProviders
import io.legado.app.help.book.BookStorage
import io.legado.app.help.book.BookStorageProviders
import io.legado.app.help.book.isCachedImageUsable
import io.legado.app.model.CacheBookCallback
import io.legado.app.model.CacheBookCallbacks
import io.legado.app.ui.book.read.page.provider.ChapterContentParserShared
import io.legado.app.utils.UrlUtil
import java.io.IOException
import io.legado.app.help.book.ContentProcessorAccessor
import io.legado.app.help.book.ContentProcessorDeps
import io.legado.app.help.book.ContentProcessorProviders
import io.legado.app.help.book.ContentProcessorShared
import io.legado.app.help.config.AppConfigAccessor
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.help.config.PreferenceProvider
import io.legado.app.help.config.SourceConfig
import io.legado.app.help.toast.Toaster
import io.legado.app.help.toast.Toasters
import io.legado.app.help.config.PreferenceProviders
import io.legado.app.help.file.registerAndroidAppFilesDir
import io.legado.app.help.http.CookieStoreBase
import io.legado.app.help.http.CookieStoreProvider
import io.legado.app.help.http.CookieStoreProviders
import io.legado.app.help.http.KmpHttpClient
import io.legado.app.help.http.OkHttpClientProvider
import io.legado.app.help.http.OkHttpClientProviders
import io.legado.app.help.http.OkHttpProxyClientProvider
import io.legado.app.help.http.OkHttpProxyClientProviders
import io.legado.app.help.http.getProxyClient
import io.legado.app.help.http.mergeCookies
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.http.okHttpClient as sharedOkHttpClient
import io.legado.app.help.http.registerSharedCookieJarBridge
import io.legado.app.help.source.SourceCacheProvider
import io.legado.app.help.source.SourceCacheProviders
import io.legado.app.help.source.SourceDebugLogger
import io.legado.app.help.source.SourceDebugLoggers
import io.legado.app.help.source.SourceHelpAccessor
import io.legado.app.help.source.SourceHelpAccessors
import io.legado.app.help.source.SourceNetworkProvider
import io.legado.app.help.source.SourceNetworkProviders
import io.legado.app.help.storage.DataStorage
import io.legado.app.help.storage.DataStorageProviders
import io.legado.app.model.Debug
import io.legado.app.model.SharedJsScope
import io.legado.app.model.analyzeRule.AnalyzeRuleCore
import io.legado.app.model.webBook.BookInfoRefreshers
import io.legado.app.model.analyzeRule.AnalyzeRuleFactories
import io.legado.app.model.analyzeRule.AnalyzeUrlFactories
import io.legado.app.model.script.JsBindingInjector
import io.legado.app.model.script.JsEngineType
import io.legado.app.model.script.JsEngines
import io.legado.app.model.script.quickjs.QuickJsJsEngine
import io.legado.app.model.script.quickjs.QuickJsSharedJsScopeBase
import io.legado.app.utils.MD5Utils
import io.legado.app.utils.NetworkUtils
import io.legado.app.utils.RegexReplacers
import io.legado.app.utils.RuleRegexes
import io.legado.app.utils.registerRuleRegexForJsonPath
import java.io.File
import kotlinx.coroutines.runBlocking

/**
 * Host-side provider implementations for the vendored Legado engine.
 *
 * The engine's shared (:data) code talks to the platform exclusively through
 * `*Providers` registries; the fork's own Android implementations live in its
 * `:app` module, which is not part of the vendored AARs. This file provides
 * the minimal-loop subset (import -> search -> info -> toc -> content) in
 * host code, following the fork's registration patterns (WebBookProvidersImpl
 * / JsEnginesAndroid / App.kt) without modifying fork code.
 *
 * Deliberately not registered (audited 2026-11-03, see
 * FIX2-imageops-report.md for reachability evidence): Cronet (OkHttp
 * fallback is the fork's own default behaviour), plugin-source
 * delegates (Manga/Video virtual sources stay inactive), BookStorage
 * (only the cache-download / bookshelf TOC-updater paths call it, not
 * the bridge's book chain), ThemeConfig, ImageController/ReadBookState
 * (web API / reader UI), Bitmap/Zip/Pdf/FileBook factories (local
 * file books, excluded by product decision).
 *
 * Registered since the 2026-11-03 ImageOps fix: JsBindingInjector
 * image ops — JsBindings reads `JsBindingInjector.image`
 * UNCONDITIONALLY for every JS eval, so leaving it unregistered killed
 * all search/explore traffic while looking like "no results" — plus
 * the FileCache / Archive / OpenUrl providers reachable through
 * CacheManager and the JS extension surface (LegadoAuxProviders.kt).
 *
 * Registered since P5.1 (2026-11-03): the Toaster + AppLog host pair
 * (G6) — JsExtensions calls `Toasters.get()` UNCONDITIONALLY for every
 * `java.toast(...)` in source JS (e.g. the first line of 西瓜书屋's
 * loginUrl), so an unregistered Toaster threw IllegalStateException
 * out of the eval; AppLog without a host kept its memory ring but
 * stamped entries with time 0 and never persisted anything.
 *
 * Registered since P5.2 (2026-11-03): the WebView pair (G4/G2/G1) —
 * BackstageWebViewProviders (headless WebView for webView/webJs
 * rules; an unregistered factory made every such request fail) and
 * VerificationUiProviders (image captcha -> Dart sheet, visible
 * browser -> LegadoBrowserActivity; unregistered it threw out of
 * SourceVerificationHelpShared the same way), plus the WebView UA
 * (G11: [LegadoWebViewUa] serves the real
 * WebSettings default UA instead of the desktop HTTP UA).
 *
 * Registered since P5.4 (2026-11-03): the Cloudflare interceptor
 * (G5) — [LegadoOkHttpProvider] no longer returns the bare shared
 * client but the fork-style wrapper with [LegadoCloudflareInterceptor]
 * at interceptor index 0 (the challenge state machine itself is the
 * vendored ChallengeInterceptorBase; see LegadoCloudflare.kt).
 */

/** Builds the engine Room database under the host's private storage. */
fun buildLegadoDatabase(context: Context, dataDir: File): AppDatabase {
    dataDir.mkdirs()
    val dbFile = File(dataDir, AppDatabase.DATABASE_NAME)
    return Room.databaseBuilder(context, AppDatabase::class.java, dbFile.absolutePath)
        .setDriver(AndroidSQLiteDriver())
        // Same stance as the fork: databases from before v80 belong to a
        // different app identity and are rebuilt destructively.
        .fallbackToDestructiveMigrationFrom(false, *(1..79).toList().toIntArray())
        .addMigrations(*DatabaseMigrations.migrations)
        .allowMainThreadQueries()
        .build()
}

/** AppDbAccessor over the host-built [AppDatabase] (fork: WebBookProvidersImpl). */
class LegadoDbAccessor(private val db: AppDatabase) : AppDbAccessor {
    override val bookDao: BookDao get() = db.bookDao
    override val bookSourceDao: BookSourceDao get() = db.bookSourceDao
    override val bookChapterDao: BookChapterDao get() = db.bookChapterDao
    override val bookGroupDao: BookGroupDao get() = db.bookGroupDao
    override val keywordHighlightDao: KeywordHighlightDao get() = db.keywordHighlightDao
    override val replaceRuleDao: ReplaceRuleDao get() = db.replaceRuleDao
    override val readRecordDao: ReadRecordDao get() = db.readRecordDao
    override val serverDao: ServerDao get() = db.serverDao
    override val txtTocRuleDao: TxtTocRuleDao get() = db.txtTocRuleDao
    override val dictRuleDao: DictRuleDao get() = db.dictRuleDao
    override val sourceFilterRuleDao: SourceFilterRuleDao get() = db.sourceFilterRuleDao
    override val httpTTSDao: HttpTTSDao get() = db.httpTTSDao
    override val cacheDao: CacheDao get() = db.cacheDao
    override val cookieDao: CookieDao get() = db.cookieDao
    override val ruleSubDao: RuleSubDao get() = db.ruleSubDao
    override val bookmarkDao: BookmarkDao get() = db.bookmarkDao
    override val searchKeywordDao: SearchKeywordDao get() = db.searchKeywordDao
    override val keyboardAssistsDao: KeyboardAssistsDao get() = db.keyboardAssistsDao

    override suspend fun <R> runInTransactionSuspending(block: suspend () -> R): R =
        db.runInImmediateTransaction { block() }
}

/**
 * AppConfigAccessor with Legado's documented defaults (interface comments /
 * fork AppConfig pref defaults). The few values the engine writes back
 * (search scope, precision, import keep-flags, toc flags, converter type,
 * tts engine, bitmap cache size) persist in a dedicated SharedPreferences
 * file; UI-only values are constants.
 */
class LegadoConfigAccessor(context: Context) : AppConfigAccessor {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("legado_engine_config", Context.MODE_PRIVATE)
    private val appContext: Context = context.applicationContext

    private fun bool(key: String, default: Boolean) = prefs.getBoolean(key, default)
    private fun int(key: String, default: Int) = prefs.getInt(key, default)
    private fun str(key: String, default: String) = prefs.getString(key, default) ?: default

    /**
     * Engine fan-out width. 16 is the fork's default; while a cache
     * download runs, the bridge dips it to [CACHE_DOWNLOAD_THREADS]
     * (reference counted via [acquireCacheDownloadDip]) so bulk chapter
     * fetching stays gentle on rate-limited sites — the fork's own
     * parallel search clamp (min(threadCount, MAX_THREAD=9)) also
     * narrows during the dip, which is deliberate device courtesy.
     */
    override val threadCount: Int
        get() = if (cacheDownloadDipHolders > 0) CACHE_DOWNLOAD_THREADS else 16

    companion object {
        private const val CACHE_DOWNLOAD_THREADS = 4

        @Volatile
        private var cacheDownloadDipHolders = 0

        @Synchronized
        fun acquireCacheDownloadDip() {
            cacheDownloadDipHolders++
        }

        @Synchronized
        fun releaseCacheDownloadDip() {
            if (cacheDownloadDipHolders > 0) cacheDownloadDipHolders--
        }
    }
    override val tocCountWords: Boolean get() = bool("tocCountWords", false)
    override fun setTocCountWords(value: Boolean) {
        prefs.edit().putBoolean("tocCountWords", value).apply()
    }
    override val tocUiUseReplace: Boolean get() = bool("tocUiUseReplace", false)
    override fun setTocUiUseReplace(value: Boolean) {
        prefs.edit().putBoolean("tocUiUseReplace", value).apply()
    }
    override var chineseConverterType: Int
        get() = int("chineseConverterType", 0)
        set(value) { prefs.edit().putInt("chineseConverterType", value).apply() }
    override val replaceEnableDefault: Boolean = true
    override val enableReadRecord: Boolean = false

    override val bookshelfSort: Int = 0
    override val bookshelfLayout: Int = 0
    override val bookshelfCoverHeight: Int = 120
    override val bookshelfGridWidth: Int = 120
    override val showUnread: Boolean = true
    override val bookshelfListShowKind: Boolean = false
    override val bookshelfListShowIntro: Boolean = false
    override val bookshelfListIntroLines: Int = 2
    override val bookshelfShowGroupCount: Boolean = true
    override val bookshelfFixedWidthMode: Boolean = false
    override val showLastUpdateTime: Boolean = false
    override val saveTabPosition: Int = 0
    override val bookExportFileName: String = ""
    override val episodeExportFileName: String = ""
    override val bookGroupStyle: Int = 0
    override val autoRefreshBook: Boolean = false
    override val preDownloadNum: Int = 10

    override var changeSourceCheckAuthor: Boolean = true
    override var changeSourceLoadInfo: Boolean = true
    override var changeSourceLoadToc: Boolean = true
    override var changeSourceLoadWordCount: Boolean = false

    override var searchScope: String
        get() = str("searchScope", "")
        set(value) { prefs.edit().putString("searchScope", value).apply() }
    override var searchGroup: String
        get() = str("searchGroup", "")
        set(value) { prefs.edit().putString("searchGroup", value).apply() }
    override val searchLayout: Int = 1
    override val precisionSearch: Boolean get() = bool("precisionSearch", false)
    override fun setPrecisionSearch(value: Boolean) {
        prefs.edit().putBoolean("precisionSearch", value).apply()
    }

    override val exportCharset: String = "UTF-8"

    override val webDavUrl: String = ""
    override val webDavAccount: String = ""
    override val webDavPassword: String = ""
    override val syncBookProgress: Boolean = true
    override val webDavDir: String = "legado"
    override val webDavDeviceName: String = ""

    override val ttsEngine: String get() = str("ttsEngine", "")
    override fun setTtsEngine(value: String?) {
        prefs.edit().putString("ttsEngine", value).apply()
    }
    override val audioPlayUseWakeLock: Boolean = false
    override val showAddToShelfAlert: Boolean = true
    override val ttsSpeechRate: Int = 5
    override val ttsTimer: Int = 0

    override val themeMode: String = "0"
    override val systemNightTheme: Boolean
        get() = (appContext.resources.configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    override val isNightTheme: Boolean get() = systemNightTheme
    override val isEInkMode: Boolean = false
    override val useDefaultCover: Boolean = false
    override val coverDrawBookName: Boolean = true
    override val coverDrawBookAuthor: Boolean = true

    override val bottomBarHeight: Int = 50
    override val bottomBarIconSize: Int = 24
    override val bottomBarLabelMode: Int = 0
    override val showHome: Boolean = true
    override val showDiscovery: Boolean = true
    override val bottomNavItemOrder: String = ""
    override val defaultHomePage: String = "bookshelf"

    override var importKeepName: Boolean
        get() = bool("importKeepName", false)
        set(value) { prefs.edit().putBoolean("importKeepName", value).apply() }
    override var importKeepGroup: Boolean
        get() = bool("importKeepGroup", false)
        set(value) { prefs.edit().putBoolean("importKeepGroup", value).apply() }
    override var importKeepEnable: Boolean
        get() = bool("importKeepEnable", false)
        set(value) { prefs.edit().putBoolean("importKeepEnable", value).apply() }
    override val localBookImportSort: Int = 0

    override val remoteServerId: Long = 0
    override val batchChangeSourceDelay: Int = 0

    override val webPort: Int = 1122
    override val bitmapCacheSize: Int get() = int("bitmapCacheSize", 50)
    override fun setBitmapCacheSize(value: Int) {
        prefs.edit().putInt("bitmapCacheSize", value).apply()
    }
    override val sourceEditMaxLine: Int = Int.MAX_VALUE
    override val welcomeShowTime: Int = 600
    override val devFeat: Boolean = false
    override val bookInfoHorizontalLayout: Boolean = false
}

/**
 * ContentProcessorAccessor backed by the fork's full pipeline (P5.5, G9).
 *
 * Mirrors the fork's Android wiring one-to-one: the fork's
 * WebBookProvidersImpl accessor delegates every call to a per-book
 * `ContentProcessor` (WeakReference cache), which in turn delegates to
 * `ContentProcessorShared` (`:core`, not vendored — replicated verbatim
 * into the host under the same FQCN, see
 * io/legado/app/help/book/ContentProcessorShared.kt). This class plays
 * both host roles: the accessor, and the per-book instance cache with
 * the fork's construction-time `upReplaceRules` + `upRemoveSameTitle`
 * (both runBlocking, as in the fork's ContentProcessor init).
 *
 * The Android deps are the host equivalents of the fork's
 * AndroidContentProcessorDeps:
 * - isAndroid8: Build.VERSION.SDK_INT in 26..27 (same expression);
 * - toastOnUi: the shared [LegadoToaster] (P5.1) — the fork uses
 *   appCtx.toastOnUi; both surface a real system Toast;
 * - getChapterFiles: the fork lists the book's download-cache folder
 *   (BookHelp.getChapterFiles, with BookHelpShared.shouldSkipChapterFiles
 *   as the guard); the host lists the same book folder inside
 *   [LegadoBookHelp]'s cache root (since P5.7 the fork's folder-name
 *   layout — see LegadoBookHelp).
 *
 * Deviations from the fork, all mechanical: the instance map is guarded
 * by a lock (bridge calls arrive on engine coroutine threads; the fork's
 * plain HashMap serves its own UI-thread-dominated call sites), and the
 * deps are an instance field instead of a file-private object because
 * the toaster / cache root are registration-time values here.
 */
class LegadoContentProcessor(
    private val toaster: LegadoToaster,
    private val bookCacheRoot: File
) : ContentProcessorAccessor {

    private val deps = object : ContentProcessorDeps {
        override val isAndroid8: Boolean =
            android.os.Build.VERSION.SDK_INT in 26..27

        override fun toastOnUi(msg: String) = toaster.toast(msg)

        override fun getChapterFiles(book: Book): Set<String> {
            if (BookHelpShared.shouldSkipChapterFiles(book)) return emptySet()
            // P5.7: the book-cache layout moved to the fork's
            // folder-name scheme (see LegadoBookHelp), so chapter
            // files now live in the folder-name directory.
            val dir = File(bookCacheRoot, book.getFolderName())
            return dir.list()?.toSet() ?: emptySet()
        }
    }

    private val processors =
        hashMapOf<String, java.lang.ref.WeakReference<ContentProcessorShared>>()

    private fun processorFor(book: Book): ContentProcessorShared {
        val key = book.name + book.origin
        synchronized(processors) {
            processors[key]?.get()?.let { return it }
            val shared = ContentProcessorShared(book.name, book.origin, deps)
            // Fork ContentProcessor init: both refreshes runBlocking
            // before the instance serves anything.
            runBlocking { shared.upReplaceRules() }
            runBlocking { shared.upRemoveSameTitle() }
            processors[key] = java.lang.ref.WeakReference(shared)
            return shared
        }
    }

    override fun getTitleReplaceRules(book: Book): List<ReplaceRule> =
        processorFor(book).getTitleReplaceRules()

    override fun getContent(
        book: Book,
        chapter: BookChapter,
        content: String,
        useReplace: Boolean
    ): CharSequence = processorFor(book).getContent(
        book, chapter, content, useReplace = useReplace
    ).toString()

    override fun getContent(
        book: Book,
        chapter: BookChapter,
        content: String,
        includeTitle: Boolean,
        useReplace: Boolean
    ): CharSequence = processorFor(book).getContent(
        book, chapter, content,
        includeTitle = includeTitle, useReplace = useReplace
    ).toString()

    override fun getBookContent(
        book: Book,
        chapter: BookChapter,
        content: String,
        includeTitle: Boolean,
        useReplace: Boolean,
        chineseConvert: Boolean,
        reSegment: Boolean
    ): BookContent = processorFor(book).getContent(
        book = book,
        chapter = chapter,
        content = content,
        includeTitle = includeTitle,
        useReplace = useReplace,
        chineseConvert = chineseConvert,
        reSegment = reSegment
    )

    override fun upReplaceRules() {
        // Fork ContentProcessor.upReplaceRules(): refresh every live
        // cached instance; books without an instance yet load fresh
        // rules at construction.
        val live = synchronized(processors) {
            processors.values.mapNotNull { it.get() }
        }
        live.forEach { shared -> runBlocking { shared.upReplaceRules() } }
    }
}

/**
 * BookHelpAccessor with the fork's on-disk layout under the engine data
 * dir (P5.7 migration): `book_cache/<Book.getFolderName()>/<chapter
 * .nb file>` for chapter text and `.../images/<md5(src)>.<suffix>` for
 * chapter images — the exact layout the fork's BookHelp/BookHelpLogic
 * use, so the engine's CacheBook orchestrator, the content processor's
 * chapter-files listing and this accessor all address the same files.
 * (The previous host layout — `MD5(bookUrl)/<index>_<MD5>.txt` — was a
 * never-exercised safety net: the bridge fetched with needSave=false,
 * so no real cache files existed under it; nothing is migrated.)
 *
 * saveContent delegates to the fork's BookHelpShared orchestration
 * (BookStorage.saveText + SAVE_CONTENT event), mirroring fork
 * BookHelp.saveContent's delegation. The image trio mirrors fork
 * BookHelpLogic semantics: downloads via the replicated
 * BookImageDownloadShared, existence = non-empty file, and
 * hasImageContent validates every extracted image by decoding it,
 * deleting corrupt files (fork parity; SVG validity is sniffed by
 * tag presence instead of fork's SvgUtils size parse — the only
 * deliberate deviation, since SvgUtils lives in the fork app module).
 */
class LegadoBookHelp(private val cacheRoot: File, private val coversDir: File) : BookHelpAccessor {
    override val cachePath: String get() = cacheRoot.absolutePath

    /** Book cache folder: `<cacheRoot>/<Book.getFolderName()>`. */
    fun bookDir(book: Book): File = File(cacheRoot, book.getFolderName())

    /** Chapter text file: `<bookDir>/<BookChapter.getFileName()>`. */
    fun chapterFile(book: Book, bookChapter: BookChapter): File =
        File(bookDir(book), bookChapter.getFileName())

    /** Chapter image file: `<bookDir>/images/<imageFileName(src)>`. */
    fun imageFile(book: Book, src: String): File =
        File(File(bookDir(book), "images"), imageFileName(src))

    override fun saveContent(
        bookSource: BookSource,
        book: Book,
        bookChapter: BookChapter,
        content: String
    ) {
        BookHelpShared.saveContent(book, bookChapter, content)
    }

    /** fork BookHelp.saveText: atomic write + word count, empty no-op. */
    fun saveText(book: Book, bookChapter: BookChapter, content: String) {
        if (content.isEmpty()) return
        val file = chapterFile(book, bookChapter)
        if (!writeTextAtomically(file, content)) {
            throw IOException("章节正文写入失败: ${file.absolutePath}")
        }
        BookHelpShared.upWordCount(book, bookChapter, content)
    }

    override fun getContent(book: Book, bookChapter: BookChapter): String? {
        val file = chapterFile(book, bookChapter)
        if (!file.isFile) return null
        return runCatching { file.readText(Charsets.UTF_8) }
            .getOrNull()
            ?.takeIf { it.isNotEmpty() }
    }

    /** fork BookHelp.hasContent: skip-guarded chapter-file existence. */
    fun hasContentFile(book: Book, bookChapter: BookChapter): Boolean =
        if (BookHelpShared.shouldSkipHasContent(book, bookChapter)) {
            true
        } else {
            chapterFile(book, bookChapter).exists()
        }

    override fun getCoverPath(bookUrl: String): String {
        coversDir.mkdirs()
        return File(coversDir, "${MD5Utils.md5Encode(bookUrl)}.jpg").absolutePath
    }

    override suspend fun saveImages(
        bookSource: BookSource,
        book: Book,
        bookChapter: BookChapter,
        content: String,
        concurrency: Int
    ) {
        BookImageDownloadShared.saveImages(bookSource, book, bookChapter, content, concurrency)
    }

    override suspend fun saveImage(
        bookSource: BookSource?,
        book: Book,
        src: String,
        chapter: BookChapter?
    ) {
        BookImageDownloadShared.saveImage(bookSource, book, src, chapter)
    }

    override fun getImage(book: Book, src: String): File = imageFile(book, src)

    override fun isImageExist(book: Book, src: String): Boolean =
        isCachedImageUsable(imageFile(book, src).absolutePath)

    override fun hasImageContent(book: Book, bookChapter: BookChapter): Boolean {
        if (!hasContentFile(book, bookChapter)) return false
        val content = getContent(book, bookChapter) ?: return false
        var allOk = true
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        for (image in ChapterContentParserShared.extractImages(content)) {
            val src = image.src
            if (src.isBlank()) continue
            val file = imageFile(book, src)
            if (!file.exists()) {
                allOk = false
                continue
            }
            BitmapFactory.decodeFile(file.absolutePath, options)
            if (options.outWidth < 1 && options.outHeight < 1 && !isSvgFile(file)) {
                allOk = false
                file.delete()
            }
        }
        return allOk
    }

    /** fork BookHelpLogic.writeImage: atomic write, throws on failure. */
    fun writeImage(book: Book, src: String, bytes: ByteArray) {
        val file = imageFile(book, src)
        if (!writeBytesAtomically(file, bytes)) {
            throw IOException("图片缓存写入失败: ${file.absolutePath}")
        }
    }

    /** fork BookHelpLogic.checkImage: decode-bounds validity (+SVG sniff). */
    fun checkImage(bytes: ByteArray): Boolean {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        return if (options.outWidth < 1 && options.outHeight < 1) {
            isSvgBytes(bytes)
        } else {
            true
        }
    }

    override suspend fun clearCacheExtra() = Unit

    companion object {
        /** fork BookHelpLogic.imageFileName: md5-16 of src + url suffix. */
        fun imageFileName(src: String): String =
            "${MD5Utils.md5Encode16(src)}.${UrlUtil.getSuffix(src, "jpg")}"

        private fun isSvgFile(file: File): Boolean =
            runCatching { isSvgBytes(file.readBytes().copyOf(2048)) }
                .getOrDefault(false)

        private fun isSvgBytes(bytes: ByteArray): Boolean =
            String(bytes, 0, minOf(bytes.size, 2048), Charsets.UTF_8)
                .contains("<svg")
    }
}

/**
 * BookStorage (P5.7): the fork's AndroidBookStorage thin shell over the
 * host BookHelp, registered so BookHelpShared.saveContent /
 * CacheBookShared can persist and probe chapter files. All paths come
 * from [LegadoBookHelp]'s fork-layout accessors.
 */
class LegadoBookStorage(private val help: LegadoBookHelp) : BookStorage {
    override val rootPath: String get() = help.cachePath

    override fun getFolderName(book: Book): String = book.getFolderName()

    override fun saveText(book: Book, chapter: BookChapter, content: String) =
        help.saveText(book, chapter, content)

    override fun getContent(book: Book, chapter: BookChapter): String? =
        help.getContent(book, chapter)

    override fun getChapterFiles(book: Book): List<String> =
        if (BookHelpShared.shouldSkipChapterFiles(book)) {
            emptyList()
        } else {
            help.bookDir(book).list()?.toList() ?: emptyList()
        }

    override fun hasCacheFile(book: Book, fileName: String): Boolean =
        File(help.bookDir(book), fileName).exists()

    override fun readCacheFile(book: Book, fileName: String): String? {
        val file = File(help.bookDir(book), fileName)
        return if (file.isFile) runCatching { file.readText(Charsets.UTF_8) }.getOrNull() else null
    }

    override fun createCacheFile(book: Book, fileName: String) {
        val file = File(help.bookDir(book), fileName)
        file.parentFile?.mkdirs()
        if (!file.exists()) file.createNewFile()
    }

    override fun deleteCacheFile(book: Book, fileName: String) {
        File(help.bookDir(book), fileName).delete()
    }

    override fun delContent(book: Book) {
        help.bookDir(book).deleteRecursively()
    }

    override fun delContent(book: Book, bookChapter: BookChapter) {
        help.chapterFile(book, bookChapter).delete()
    }

    override fun hasContent(book: Book, bookChapter: BookChapter): Boolean =
        help.hasContentFile(book, bookChapter)

    override fun clearCache() {
        File(rootPath).listFiles()?.forEach { it.deleteRecursively() }
    }

    override fun clearCache(book: Book) = delContent(book)

    override fun updateCacheFolder(old: Book, new: Book) {
        if (!BookHelpShared.shouldUpdateCacheFolder(old, new)) return
        val oldDir = help.bookDir(old)
        val newDir = help.bookDir(new)
        if (oldDir.exists() && !newDir.exists()) oldDir.renameTo(newDir)
    }

    override fun clearInvalidCache(maxSize: Long) {
        runBlocking {
            BookHelpShared.evictMangaCache(
                rootPath, BookHelpShared.cacheImageFolderName, maxSize
            )
        }
    }

    override fun clearInvalidBookFolders(
        validBookUrls: Set<String>,
        imageSubFolderName: String,
        maxChapterCacheSize: Long
    ) {
        runBlocking {
            BookHelpShared.clearInvalidBookFolders(
                rootPath, validBookUrls, imageSubFolderName, maxChapterCacheSize
            )
        }
    }
}

/**
 * BookImageStorage (P5.7): the fork's AndroidBookImageStorage thin shell
 * over the host BookHelp, registered so the replicated
 * BookImageDownloadShared can write downloaded chapter images. The
 * interface's chapter parameter is addressing context the fork's own
 * Android implementation ignores (its layout is per-book, keyed by
 * image url) — mirrored here exactly.
 */
class LegadoBookImageStorage(private val help: LegadoBookHelp) : BookImageStorage {
    override fun saveImage(
        book: Book,
        chapter: BookChapter,
        url: String,
        bytes: ByteArray
    ): String? {
        if (bytes.isEmpty()) return null
        return runCatching {
            help.writeImage(book, url, bytes)
            help.getImage(book, url).absolutePath
        }.getOrNull()
    }

    override fun getImagePath(book: Book, chapter: BookChapter, url: String): String? =
        help.getImage(book, url).takeIf { it.exists() }?.absolutePath

    override fun isImageExist(book: Book, chapter: BookChapter, url: String): Boolean =
        help.isImageExist(book, url)

    override fun hasImageContent(book: Book): Boolean {
        val imageDir = imagesDir(book)
        return imageDir.exists() && (imageDir.listFiles()?.isNotEmpty() == true)
    }

    override fun clearCache(book: Book) {
        val imageDir = imagesDir(book)
        if (imageDir.exists()) imageDir.deleteRecursively()
    }

    override fun checkImageBytes(bytes: ByteArray): Boolean = help.checkImage(bytes)

    override fun writeImageBytes(
        book: Book,
        chapter: BookChapter,
        url: String,
        bytes: ByteArray
    ) {
        help.writeImage(book, url, bytes)
    }

    /** fork AndroidBookImageStorage.imagesDir: probe-derived. */
    private fun imagesDir(book: Book): File =
        help.getImage(book, "probe").parentFile ?: File("")
}

/** Host-local atomic file write (fork `writeTextAtomically` semantics). */
internal fun writeTextAtomically(file: File, content: String): Boolean =
    writeBytesAtomically(file, content.toByteArray(Charsets.UTF_8))

/** Host-local atomic file write (fork `writeBytesAtomically` semantics). */
internal fun writeBytesAtomically(file: File, bytes: ByteArray): Boolean =
    runCatching {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, "${file.name}.part")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file)) {
            tmp.copyTo(file, overwrite = true)
            tmp.delete()
        }
        true
    }.getOrDefault(false)

/**
 * CookieStore: CookieStoreBase (engine :data) + the Android hooks the fork
 * implements in its app CookieStore/CookieManager — Room persistence via
 * CookieDao, session cookies in CacheManager memory, WebView sync.
 */
class LegadoCookieStore(private val db: AppDatabase) : CookieStoreBase() {
    override fun onInsertCookieToDb(domain: String, cookieStr: String) {
        runBlocking { db.cookieDao.insert(Cookie(domain, cookieStr)) }
    }

    override fun onDeleteCookieFromDb(domain: String) {
        runBlocking { db.cookieDao.delete(domain) }
    }

    override fun onClearOkHttpCookie() {
        runBlocking { db.cookieDao.deleteOkHttp() }
    }

    override fun onSyncCookieToWebView(baseUrl: String, cookieStr: String) {
        val cookieManager = android.webkit.CookieManager.getInstance()
        cookieStr.split(';').forEach {
            val c = it.trim()
            if (c.isNotEmpty()) cookieManager.setCookie(baseUrl, c)
        }
    }

    override fun onRemoveWebViewCookie(url: String) {
        // The platform CookieManager.removeCookie(String) no longer exists
        // at this compileSdk; the fork expires each cookie by name instead
        // (its CookieManagerExtensions), mirrored here.
        val cookieManager = android.webkit.CookieManager.getInstance()
        val baseUrl = NetworkUtils.getBaseUrl(url) ?: return
        val host = NetworkUtils.getSubDomain(url)
        val cookieGlob = cookieManager.getCookie(baseUrl) ?: return
        val directives = listOf(
            "Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/",
            "Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; Secure; SameSite=None",
            "Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; Secure; SameSite=None; Partitioned"
        )
        cookieGlob.split(";").forEach { entry ->
            if (entry.isBlank()) return@forEach
            val name = entry.substringBefore("=").trim()
            directives.forEach { directive ->
                cookieManager.setCookie(baseUrl, "$name=; $directive; Domain=.$host")
                cookieManager.setCookie(baseUrl, "$name=; $directive")
            }
        }
    }

    override fun getCookieNoSession(url: String): String {
        val domain = NetworkUtils.getSubDomain(url)
        val cacheCookie = CacheManager.getFromMemory("${domain}_cookie") as? String
        return cacheCookie ?: runBlocking { db.cookieDao.get(domain) }?.cookie ?: ""
    }

    override fun getSessionCookie(domain: String): String? =
        CacheManager.getFromMemory("${domain}_session_cookie") as? String

    /** Public accessors for the provider (the base hooks above are protected). */
    fun persistentCookie(url: String): String = getCookieNoSession(url)
    fun sessionCookie(domain: String): String? = getSessionCookie(domain)

    fun updateSessionCookie(domain: String, cookies: String) {
        val cacheKey = "${domain}_session_cookie"
        val sessionCookie = CacheManager.getFromMemory(cacheKey) as? String
        val merged = if (sessionCookie.isNullOrEmpty()) {
            cookies
        } else {
            mergeCookies(sessionCookie, cookies)
        }
        merged?.let { CacheManager.putMemory(cacheKey, it) }
    }

    override fun removeCookie(url: String, key: String) {
        val domain = NetworkUtils.getSubDomain(url)
        getSessionCookie(domain)?.let { session ->
            val map = cookieToMap(session)
            if (map.remove(key) != null) {
                mapToCookie(map)?.let { CacheManager.putMemory("${domain}_session_cookie", it) }
            }
        }
        val persistent = getCookieNoSession(url)
        if (persistent.isNotEmpty()) {
            val map = cookieToMap(persistent)
            if (map.remove(key) != null) {
                setCookie(url, mapToCookie(map))
            }
        }
    }
}

/** CookieStoreProvider delegating to [LegadoCookieStore] (fork: AndroidCookieStoreProvider). */
class LegadoCookieStoreProvider(private val store: LegadoCookieStore) : CookieStoreProvider {
    override fun setCookie(url: String, cookie: String?) = store.setCookie(url, cookie)
    override fun replaceCookie(url: String, cookie: String) = store.replaceCookie(url, cookie)
    override fun getCookie(url: String): String = store.getCookie(url)
    override fun getKey(url: String, key: String): String = store.getKey(url, key)
    override fun removeCookie(url: String) = store.removeCookie(url)
    override fun removeCookie(url: String, key: String) = store.removeCookie(url, key)
    override fun getCookieNoSession(url: String): String = store.persistentCookie(url)
    override fun getSessionCookie(domain: String): String? = store.sessionCookie(domain)
    override fun updateSessionCookie(domain: String, cookies: String) =
        store.updateSessionCookie(domain, cookies)
    override fun clear() = store.clear()
}

/** DataStorage rooted at the engine data dir (fork: AndroidDataStorage). */
class LegadoDataStorage(private val dataDir: File) : DataStorage {
    override val chapterCacheDir: String get() = File(dataDir, "book_cache").absolutePath
    override val backgroundsDir: String get() = File(dataDir, "bg").absolutePath
    override val fontsDir: String get() = File(dataDir, "font").absolutePath
    override val backupDir: String get() = File(dataDir, "backup").absolutePath
}

/** SharedPreferences-backed PreferenceProvider for shared-code pref reads. */
class LegadoPreferenceProvider(context: Context) : PreferenceProvider {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("legado_engine_prefs", Context.MODE_PRIVATE)

    override fun getString(key: String, default: String): String =
        prefs.getString(key, default) ?: default
    override fun getStringOrNull(key: String): String? = prefs.getString(key, null)
    override fun getInt(key: String, default: Int): Int = prefs.getInt(key, default)
    override fun getBoolean(key: String, default: Boolean): Boolean = prefs.getBoolean(key, default)
    override fun getLong(key: String, default: Long): Long = prefs.getLong(key, default)
    override fun getFloat(key: String, default: Float): Float = prefs.getFloat(key, default)
    override fun putString(key: String, value: String?) {
        prefs.edit().putString(key, value).apply()
    }
    override fun putInt(key: String, value: Int) { prefs.edit().putInt(key, value).apply() }
    override fun putBoolean(key: String, value: Boolean) {
        prefs.edit().putBoolean(key, value).apply()
    }
    override fun putLong(key: String, value: Long) { prefs.edit().putLong(key, value).apply() }
    override fun putFloat(key: String, value: Float) { prefs.edit().putFloat(key, value).apply() }
    override fun remove(key: String) { prefs.edit().remove(key).apply() }
    override fun contains(key: String): Boolean = prefs.contains(key)
    override fun getAll(): Map<String, *> = prefs.all
    override fun addPreferenceChangeListener(listener: (key: String) -> Unit): () -> Unit {
        val l = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key != null) listener(key)
        }
        prefs.registerOnSharedPreferenceChangeListener(l)
        return { prefs.unregisterOnSharedPreferenceChangeListener(l) }
    }
}

/**
 * OkHttpClientProvider: the engine's book-source client — the shared
 * client (`HttpHelper.okHttpClient`, vendored) wrapped exactly like
 * the fork's WebBookProvidersImpl: a NEW builder with the Cloudflare
 * interceptor (G5, P5.4; [LegadoCloudflareInterceptor]) inserted at
 * application-interceptor index 0, so a solved challenge's re-proceed
 * re-runs the shared client's own UA/cookie-bridge interceptor and
 * picks up the freshly solved cf_clearance from the CookieStore.
 * Both the wrapped client and the interceptor are single lazy
 * instances (the interceptor's per-host dedup locks must not be
 * duplicated per call, and the shared client must not be re-wrapped).
 * The proxy chain (`getProxyClient`) stays unwrapped, as in the fork.
 * Plain builder composition only — no delegation back into this
 * provider (the FIX3 self-recursion lesson does not apply, and the
 * self-check asserts the interceptor's presence and position).
 */
class LegadoOkHttpProvider(context: Context) : OkHttpClientProvider {

    private val appContext: Context = context.applicationContext

    private val cloudflareInterceptor: LegadoCloudflareInterceptor by lazy {
        LegadoCloudflareInterceptor(
            appContext,
            LegadoBookSourceChallengeCookieResolver()
        ) {
            UserAgentProviders.get()
        }
    }

    override val okHttpClient: KmpHttpClient by lazy {
        sharedOkHttpClient.newBuilder()
            .apply { interceptors().addAll(0, listOf(cloudflareInterceptor)) }
            .build()
    }
}

/** IntentDataAccessor: single-slot holder, same as the fork's. */
object LegadoIntentDataAccessor : IntentDataAccessor {
    override fun setSource(source: Any?) {
        IntentData.source = source
    }
}

/**
 * SourceHelpAccessor: the fork bridges "currently reading/audio book source"
 * lookups and SourceConfig cleanup. The host keeps its bookshelf on the Dart
 * side, so there is no reading book to look up; deletion cleanup mirrors the
 * fork's WebBookProvidersImpl verbatim: drop the source's score row
 * (SourceConfig lives in :data, caches-table backed) and clear cached
 * source variables (AppCacheManager lives in :data).
 */
object LegadoSourceHelpAccessor : SourceHelpAccessor {
    override fun getCachedReadingBookSource(key: String?): BookSource? = null
    override fun getCachedAudioBookSource(key: String?): BookSource? = null
    override fun onBookSourceDeleted(key: String) {
        SourceConfig.removeSource(key)
        AppCacheManager.clearSourceVariables()
    }
    override fun onBookSourcesDeleted(keys: List<String>) {
        SourceConfig.removeSources(keys)
        AppCacheManager.clearSourceVariables()
    }
}

/** QuickJsSharedJsScopeBase with a plain file cache (fork uses ACache; same role). */
class LegadoSharedJsScopeProvider(private val cacheDir: File) : QuickJsSharedJsScopeBase() {
    private fun fileFor(name: String): File {
        cacheDir.mkdirs()
        return File(cacheDir, "${MD5Utils.md5Encode(name)}.js")
    }

    override fun cachedJsLibContent(name: String): String? {
        val file = fileFor(name)
        return if (file.isFile) runCatching { file.readText(Charsets.UTF_8) }.getOrNull() else null
    }

    override fun storeJsLibContent(name: String, content: String) {
        runCatching { fileFor(name).writeText(content, Charsets.UTF_8) }
    }

    override fun downloadJsLibContent(url: String): String? = runBlocking {
        sharedOkHttpClient.newCallStrResponse { url(url) }.body
    }

    override fun jsLibDownloadFailedException(url: String): Exception =
        io.legado.app.exception.NoStackTraceException("下载jsLib-${url}失败")
}

/** File-backed ExploreKindsCacheProvider (fork delegates to ACache "explore"). */
class LegadoExploreKindsCache(private val cacheDir: File) : ExploreKindsCacheProvider {
    private fun fileFor(key: String): File {
        cacheDir.mkdirs()
        return File(cacheDir, "${MD5Utils.md5Encode(key)}.txt")
    }

    override fun getAsString(key: String): String? {
        val file = fileFor(key)
        return if (file.isFile) runCatching { file.readText(Charsets.UTF_8) }.getOrNull() else null
    }

    override fun put(key: String, value: String) {
        runCatching { fileFor(key).writeText(value, Charsets.UTF_8) }
    }

    override fun remove(key: String) {
        runCatching { fileFor(key).delete() }
    }
}

/**
 * [Toaster] with the fork's AndroidToaster semantics (core
 * Toaster.android.kt): a real system Toast shown on the main thread,
 * the previous one cancelled first so toasts never queue up. On top of
 * the fork behaviour the host also mirrors every message into the
 * AppLog memory ring (tag "LegadoToast") and Logcat, so a `java.toast()`
 * fired deep inside source JS leaves device-side evidence the
 * self-check can read back — the ring/Logcat floor the P5.1 spec asks
 * for, with the visible Toast being the fork's own behaviour, not a
 * new channel.
 */
class LegadoToaster(context: Context) : Toaster {
    private val appContext: Context = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var current: Toast? = null

    override fun toast(message: String) {
        record(message)
        showOnUiThread(message, Toast.LENGTH_SHORT)
    }

    override fun toastLong(message: String) {
        record(message)
        showOnUiThread(message, Toast.LENGTH_LONG)
    }

    private fun record(message: String) {
        Log.i(TAG_TOAST, message)
        // putNotSave: memory ring + DEBUG logcat only. AppLog.put with
        // toast=true would call back into this toaster via the host —
        // putNotSave(toast=false) cannot loop.
        runCatching { AppLog.putNotSave(message, null, false, TAG_TOAST) }
    }

    private fun showOnUiThread(message: String, duration: Int) {
        mainHandler.post {
            runCatching {
                current?.cancel()
                val toast = Toast.makeText(appContext, message, duration)
                current = toast
                toast.show()
            }
        }
    }

    private companion object {
        const val TAG_TOAST = "LegadoToast"
    }
}

/**
 * [AppLogHost] mirroring the fork's registerAndroidAppLogHost
 * (app AppLogAndroid.kt): wall clock + default timezone from the
 * platform, `write` persists (the fork's LogUtils.d writes a rolling
 * log file; the host appends to `logs/applog.log` under the engine
 * data dir, capped by delete-and-restart rotation, and mirrors to
 * Logcat), `toast` delegates to the shared [LegadoToaster] (the fork
 * shows it via App.toastOnUi), `debugPrint` goes to Logcat on
 * debuggable builds (the fork gates on BuildConfig.DEBUG; the host
 * reads FLAG_DEBUGGABLE, the runtime equivalent).
 *
 * `recordLog`: the fork reads its AppConfig pref (a user-facing
 * settings switch the host does not surface). The host returns true so
 * putDebug diagnostics stay available on this single-user build; the
 * memory ring the self-check reads is fed by put() either way.
 */
class LegadoAppLogHost(
    private val logFile: File,
    private val toaster: LegadoToaster,
    private val debuggable: Boolean
) : AppLogHost {

    private val writeLock = Any()

    override fun currentTimeMillis(): Long = System.currentTimeMillis()

    override fun timeZoneOffsetMillis(): Long =
        java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()).toLong()

    override val recordLog: Boolean get() = true

    override fun write(tag: String, message: String) {
        Log.d(tag, message)
        runCatching {
            synchronized(writeLock) {
                logFile.parentFile?.mkdirs()
                if (logFile.isFile && logFile.length() > MAX_LOG_BYTES) {
                    logFile.delete()
                }
                logFile.appendText(
                    "${System.currentTimeMillis()} $tag: $message\n",
                    Charsets.UTF_8
                )
            }
        }
    }

    override fun toast(message: String) {
        toaster.toast(message)
    }

    override fun debugPrint(tag: String, message: String, throwable: Throwable?) {
        if (debuggable) {
            Log.e(tag, message, throwable)
        }
    }

    private companion object {
        const val MAX_LOG_BYTES = 1_000_000L
    }
}

/**
 * Value for [AndroidIdHolder] (G20②): the system ANDROID_ID when it
 * can be read, otherwise a random UUID persisted in the engine data
 * dir so it stays stable across restarts. The fork falls back to the
 * literal string "null" (JsEnginesAndroid), which makes every
 * ANDROID_ID-less device share one id; the persisted UUID keeps the
 * fallback per-install unique instead. A system value that is blank
 * or the literal "null" (some ROMs return it as a string) counts as
 * unreadable.
 */
fun resolveHostAndroidId(context: Context, dataDir: File): String {
    val systemId = runCatching {
        Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
    }.getOrNull()
    if (!systemId.isNullOrBlank() && systemId != "null") return systemId
    val file = File(dataDir, "android_id_fallback")
    val persisted = runCatching { file.readText(Charsets.UTF_8).trim() }.getOrNull()
    if (!persisted.isNullOrBlank()) return persisted
    val generated = java.util.UUID.randomUUID().toString()
    runCatching {
        dataDir.mkdirs()
        file.writeText(generated, Charsets.UTF_8)
    }
    return generated
}

/**
 * Registers every provider the minimal loop needs, in the same relative
 * order the fork uses (JsEngines registration before WebBook providers,
 * cookie store before the shared cookie-jar bridge). Idempotent: engine
 * init calls it once per process.
 */
fun registerLegadoProviders(context: Context, db: AppDatabase, dataDir: File) {
    val appContext = context.applicationContext

    registerAndroidAppFilesDir(appContext)
    PreferenceProviders.register(LegadoPreferenceProvider(appContext))
    DataStorageProviders.register(LegadoDataStorage(dataDir))

    // Toast/AppLog hooks (G6, P5.1): registered FIRST among the
    // behaviour providers, like the fork's App.onCreate — engine
    // internals may AppLog.put from any later registration step on,
    // and any JS eval (search/explore/login scripts) may call
    // java.toast() through Toasters.get(). One shared toaster instance
    // backs both registries so AppLog.put(toast=true) and
    // java.toast() show through the same single-Toast slot.
    val legadoToaster = LegadoToaster(appContext)
    Toasters.register(legadoToaster)
    AppLog.registerHost(
        LegadoAppLogHost(
            logFile = File(dataDir, "logs/applog.log"),
            toaster = legadoToaster,
            debuggable = appContext.applicationInfo.flags and
                ApplicationInfo.FLAG_DEBUGGABLE != 0
        )
    )

    val accessor = LegadoDbAccessor(db)
    AppDbProviders.register(accessor)
    AppDatabaseProviders.register(object : AppDatabaseProvider {
        override val appDb: AppDatabase get() = db
    })
    AppConfigProviders.register(LegadoConfigAccessor(appContext))
    // ContentProcessor (P5.5): full fork pipeline via the replicated
    // ContentProcessorShared; its deps need the shared toaster and the
    // book-cache root, so the book help is built first and both
    // registrations share the one instance / folder.
    val bookCacheRoot = File(dataDir, "book_cache")
    val bookHelp = LegadoBookHelp(bookCacheRoot, File(dataDir, "covers"))
    BookHelpProviders.register(bookHelp)
    // Cache download support (P5.7): BookStorage backs
    // BookHelpShared.saveContent / CacheBookShared persistence;
    // BookImageStorage backs the replicated BookImageDownloadShared;
    // CacheBookCallbacks is the fork's reader-notification seam — the
    // Flutter reader re-reads through the bridge (cache-first), so the
    // default no-op implementation is the correct host behaviour and
    // only the registration matters (CacheBookCallbacks.get() throws
    // without one).
    BookStorageProviders.register(LegadoBookStorage(bookHelp))
    BookImageStorageProviders.register(LegadoBookImageStorage(bookHelp))
    CacheBookCallbacks.register(object : CacheBookCallback {})
    ContentProcessorProviders.register(
        LegadoContentProcessor(legadoToaster, bookCacheRoot)
    )
    IntentDataProviders.register(LegadoIntentDataAccessor)
    // The engine's own Android regex replacer (coroutine-watchdog timeout,
    // lives in :data androidMain; the JVM deadline-CharSequence variant is
    // documented broken under Android libcore and must not be used here).
    RegexReplacers.register(io.legado.app.utils.AndroidRegexReplacer)
    RuleRegexes.register(null)
    registerRuleRegexForJsonPath()
    OkHttpClientProviders.register(LegadoOkHttpProvider(appContext))
    // fix6: jsoup-compat reuses the host shared OkHttpClient, inheriting
    // its CookieJar / rate limiting / challenge-solving interceptors —
    // the fork's App.onCreate does exactly this (App.kt: "jsoup-compat
    // 复用宿主共享 OkHttpClient，继承 CookieJar/限流/Cronet 拦截器",
    // org.jsoup.Jsoup.clientFactory = { okHttpClient }). Without it,
    // JsExtensions java.get/head/post (the Jsoup path) silently fall
    // back to a BARE OkHttpClient: no cookie jar (enabledCookieJar
    // sources lose cookie sharing), no Cloudflare solver — a guarded
    // endpoint answering 403 makes Jsoup throw HttpStatusException and
    // the source's search JS dies as a bare 「JS执行出错」
    // （哔哩轻小说 search_guard handshake, device report 2026-11-04).
    org.jsoup.Jsoup.clientFactory = { OkHttpClientProviders.get().okHttpClient }
    SourceHelpAccessors.register(LegadoSourceHelpAccessor)

    // Cookie stack: store provider first, then the OkHttp cookie-jar bridge.
    val cookieStore = LegadoCookieStore(db)
    CookieStoreProviders.register(LegadoCookieStoreProvider(cookieStore))
    registerSharedCookieJarBridge()

    // JS stack. Registration order mirrors the fork's
    // registerAndroidJsEngines(): ImageOps FIRST, before any JS eval —
    // JsBindings unconditionally injects JsBindingInjector.image into
    // every bindings map, so a missing registration makes every eval
    // (even "1+1") throw IllegalStateException. The aux providers sit
    // alongside: CacheManager.delete() and the JS `cache`/`java`
    // extension surface reach FileCacheProviders / ArchiveProviders /
    // OpenUrlProviders the same unconditional way.
    JsBindingInjector.registerImageOps(BitmapImageOps)
    FileCacheProviders.impl = LegadoFileCache(dataDir)
    ArchiveProviders.register(LegadoArchiveProvider(appContext))
    OpenUrlProviders.register(LegadoOpenUrlProvider(appContext))
    JsEngines.registerProvider { type ->
        when (type) {
            JsEngineType.QUICKJS -> QuickJsJsEngine
        }
    }
    SharedJsScope.registerProviders { type ->
        when (type) {
            JsEngineType.QUICKJS -> LegadoSharedJsScopeProvider(File(dataDir, "shareJs"))
        }
    }
    RuleBigDataProviders.impl = RuleBigDataShared(
        File(dataDir, "ruleData/book").apply { mkdirs() }.absolutePath
    )
    // G20②: persisted-UUID fallback instead of the fork's literal
    // "null" when ANDROID_ID cannot be read (see resolveHostAndroidId).
    AndroidIdHolder.value = resolveHostAndroidId(appContext, dataDir)
    SourceCacheProviders.impl = object : SourceCacheProvider {
        override fun get(key: String) = CacheManager.get(key)
        override fun put(key: String, value: String) = CacheManager.put(key, value)
        override fun delete(key: String) = CacheManager.delete(key)
        override fun getFromMemory(key: String) = CacheManager.getFromMemory(key)
        override fun putMemory(key: String, value: Any) = CacheManager.putMemory(key, value)
        override fun deleteMemory(key: String) = CacheManager.deleteMemory(key)
        override fun asBinding(): Any = CacheManager
    }
    SourceNetworkProviders.impl = object : SourceNetworkProvider {
        override fun getCookie(tag: String) = cookieStore.getCookie(tag)
        override fun replaceCookie(tag: String, cookie: String) = cookieStore.replaceCookie(tag, cookie)
        override fun removeCookie(tag: String) = cookieStore.removeCookie(tag)
        override fun asBinding(): Any = cookieStore
    }
    // The fork registers its :app thin subclasses (AnalyzeRule/AnalyzeUrl).
    // For AnalyzeRule the :app twin's one addition DOES matter: the
    // refreshTocUrl() override that xiaohan-template sources call from TOC
    // pre-update JS — the shared core's hook is an empty no-op without it.
    // LegadoAnalyzeRule mirrors that override and routes through
    // BookInfoRefreshers, registered just below with the fork's own
    // delegation (WebBook.getBookInfoAwait). JS dispatch falls back to
    // reflection when no KSP table exists (the quickjs module supports
    // both paths).
    // FIX8: AnalyzeUrl now also goes through a host thin subclass
    // (LegadoAnalyzeUrl): it percent-encodes header values OkHttp would
    // reject (拷贝漫画 7789 / G社漫画 put the unencoded request URL in a
    // referer header and crashed every non-ASCII search). See FIX8-REPORT.md.
    // FIX9: the legacy AES pair FIX8 briefly exposed on both thin subclasses
    // was removed again — R8 renamed those host-only JS-called-by-name
    // methods out of the release build (the host bridge package was outside
    // the keep surface), so 6028 kept failing on device. The pair plus
    // desEncodeToBase64String now lives in the engine (JsExtensionsCommon),
    // and legado-keep.pro keeps this whole bridge package as defense in
    // depth. See FIX9-REPORT.md.
    AnalyzeRuleFactories.register { ruleData, source, preUpdateJs ->
        LegadoAnalyzeRule(ruleData, source, preUpdateJs)
    }
    BookInfoRefreshers.register(LegadoBookInfoRefresher)
    AnalyzeUrlFactories.register {
            rawUrl, baseUrl, source, ruleData, chapter, readTimeout, callTimeout,
            coroutineContext, headerMapF, hasLoginHeader, selectedOptions, variables ->
        LegadoAnalyzeUrl(
            rawUrl, baseUrl, source, ruleData, chapter, readTimeout, callTimeout,
            coroutineContext, headerMapF, hasLoginHeader, selectedOptions, variables
        )
    }
    SourceDebugLoggers.impl = object : SourceDebugLogger {
        override fun log(key: String, msg: String, print: Boolean, state: Int, showTime: Boolean) =
            Debug.log(key, msg, print = print, state = state, showTime = showTime)

        override fun log(msg: String) = Debug.log(msg)
    }
    JsCryptoProviders.register(JsCryptoProviderJvm)
    ExploreKindsCacheProviders.impl = LegadoExploreKindsCache(File(dataDir, "explore"))
    // UA pair: the HTTP UA stays the pinned desktop string; the
    // WebView UA (G11, P5.2) is the platform WebView's real default,
    // fetched lazily on the main thread — the fork's
    // AndroidUserAgentProvider splits the two the same way, and sites
    // that serve different pages per UA family otherwise hand the
    // WebView flows a desktop page their rules do not match.
    val legadoUserAgentProvider = object : UserAgentProvider {
        override fun get(): String = LegadoEngineDefaults.userAgent
        override fun getWebViewUA(): String = LegadoWebViewUa.get(appContext)
    }
    UserAgentProviders.impl = legadoUserAgentProvider
    UserAgentProviders.register(legadoUserAgentProvider)
    // WebView pair (G4/G2/G1, P5.2): headless WebView factory for
    // webView/webJs rules, and the verification UI (captcha -> Dart
    // sheet, visible browser -> LegadoBrowserActivity). Registered
    // here, inside engine init, before any engine call can reach
    // them — the registries' own contract.
    registerHostBackstageWebView(appContext)
    io.legado.app.help.source.VerificationUiProviders.register(
        LegadoVerificationUiProvider(appContext)
    )
    OkHttpProxyClientProviders.impl = object : OkHttpProxyClientProvider {
        // MUST stay fully qualified (mirrors the fork's JsEnginesAndroid
        // verbatim): inside this object the unqualified name resolves to
        // this very member, not the imported top-level function, so
        // `= getProxyClient(proxy)` compiles into infinite self-recursion
        // and every real HTTP request dies with StackOverflowError
        // (device-verified 2026-11-03, see FIX3-stack-report.md).
        override fun getProxyClient(proxy: String?): KmpHttpClient =
            io.legado.app.help.http.getProxyClient(proxy)
    }
}

/**
 * The platform WebView's default UA (G11), mirroring the fork's
 * AndroidUserAgentProvider.getWebViewUA. [android.webkit.WebSettings]
 * requires the main thread, so off-main callers hop through a Handler
 * with a bounded wait; any failure (or timeout) falls back to the
 * pinned HTTP UA rather than blocking an engine call. The value is
 * cached after the first successful read — it cannot change within a
 * process.
 */
object LegadoWebViewUa {
    @Volatile
    private var cached: String? = null

    fun get(context: Context): String {
        cached?.let { return it }
        val computed = runCatching {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                android.webkit.WebSettings.getDefaultUserAgent(context)
            } else {
                val latch = java.util.concurrent.CountDownLatch(1)
                val holder = arrayOfNulls<String>(1)
                Handler(Looper.getMainLooper()).post {
                    holder[0] = runCatching {
                        android.webkit.WebSettings.getDefaultUserAgent(context)
                    }.getOrNull()
                    latch.countDown()
                }
                if (latch.await(3, java.util.concurrent.TimeUnit.SECONDS)) {
                    holder[0]
                } else {
                    null
                }
            }
        }.getOrNull()
        val ua = computed?.takeIf { it.isNotBlank() }
            ?: LegadoEngineDefaults.userAgent
        cached = ua
        return ua
    }
}

/** Defaults shared by the provider registrations above. */
object LegadoEngineDefaults {
    /** Same shape as the fork's built-in default UA (version segment pinned). */
    const val userAgent: String =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
}

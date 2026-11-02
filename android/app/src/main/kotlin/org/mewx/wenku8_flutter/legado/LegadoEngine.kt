package org.mewx.wenku8_flutter.legado

import android.content.Context
import io.legado.app.data.AppDatabase
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.help.book.ContentProcessorProviders
import io.legado.app.help.source.SourceHelp
import io.legado.app.help.source.exploreKinds
import io.legado.app.model.webBook.WebBook
import io.legado.app.utils.NetworkUtils
import io.legado.engine.LegadoEngineFacade
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.jsoup.Jsoup

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

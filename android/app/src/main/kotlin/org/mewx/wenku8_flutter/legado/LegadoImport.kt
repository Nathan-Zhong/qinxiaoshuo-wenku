package org.mewx.wenku8_flutter.legado

import io.legado.app.constant.AppConst
import io.legado.app.data.AppDatabase
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.OldRssSource
import io.legado.app.data.entities.toBookSource
import io.legado.app.exception.NoStackTraceException
import io.legado.app.help.book.ContentProcessorProviders
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.help.http.OkHttpClientProviders
import io.legado.app.help.http.decompressed
import io.legado.app.help.http.newCallResponseBody
import io.legado.app.help.source.SourceHelp
import io.legado.app.utils.GSON
import io.legado.app.utils.isAbsUrl
import io.legado.app.utils.isJsonArray
import io.legado.app.utils.isJsonObject
import io.legado.app.utils.parseToJsonElementLenient
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/** Payload cannot be recognized as book sources at all (maps to PARSE). */
class LegadoParseException(message: String) : Exception(message)

/**
 * Book-source import, following the fork's ImportBookSourceViewModelShared
 * semantics (that class lives in `:ui`, outside the vendored AARs, so the
 * orchestration is re-implemented here on the same :data primitives):
 *
 * - payload kinds: raw JSON text / a URL to download / a local file path;
 *   a text payload that is itself an absolute URL is downloaded, and
 *   `{"sourceUrls": [...]}` bundles are expanded per address;
 * - each item is typed by its top-level keys: `bookSourceUrl` -> BookSource,
 *   `sourceUrl` -> legacy OldRssSource converted via toBookSource();
 *   an item without a usable identity key fails the whole batch;
 * - parsed sources are compared with the stored ones by lastUpdateTime:
 *   new -> added, newer -> updated, otherwise unchanged (not re-inserted);
 *   updates honor the importKeepName/Group/Enable config flags and keep
 *   the stored customOrder, exactly like the fork's importSelect with its
 *   default selection.
 */
object LegadoImport {

    data class Outcome(
        val added: Int,
        val updated: Int,
        val unchanged: Int,
        val failed: Int,
        val stored: List<BookSource>,
        val errors: List<String>
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    suspend fun importPayload(db: AppDatabase, payload: String, payloadKind: String): Outcome {
        val text = when (payloadKind) {
            "filePath" -> File(payload).readText(Charsets.UTF_8)
            "url" -> payload
            else -> payload
        }
        val parsed = arrayListOf<BookSource>()
        collect(text, parsed)
        return store(db, parsed)
    }

    /** Parses one standalone source JSON (upsertSource path). */
    fun parseSingleSource(sourceJson: String): BookSource {
        // Explicit-serializer decode: the reified fromJsonObject helper is
        // an inline function with JVM target 21 bytecode, which cannot be
        // inlined into this host (compiled for target 17).
        val source = runCatching {
            GSON.decodeFromString(BookSource.serializer(), sourceJson)
        }.getOrElse { throw LegadoParseException("不是书源") }
        if (source.bookSourceUrl.isBlank()) throw LegadoParseException("不是书源")
        return source
    }

    private suspend fun collect(text: String, acc: ArrayList<BookSource>) {
        var mText = text.trim().trim('\uFEFF')
        if (mText.startsWith("file://")) {
            mText = File(java.net.URI(mText)).readText(Charsets.UTF_8).trim()
        }
        when {
            mText.isAbsUrl() -> importFromJson(download(mText), acc)
            mText.isJsonObject() || mText.isJsonArray() -> importFromJson(mText, acc)
            else -> throw LegadoParseException("格式不对")
        }
    }

    private suspend fun download(url: String): String {
        val responseBody = OkHttpClientProviders.get().okHttpClient.newCallResponseBody {
            if (url.endsWith("#requestWithoutUA")) {
                url(url.substringBeforeLast("#requestWithoutUA"))
                header(AppConst.UA_NAME, "null")
            } else {
                url(url)
            }
        }.decompressed()
        try {
            return responseBody.bytes().decodeToString()
        } finally {
            responseBody.close()
        }
    }

    private suspend fun importFromJson(json: String, acc: ArrayList<BookSource>) {
        val element = runCatching { parseToJsonElementLenient(json) }.getOrElse {
            throw LegadoParseException("不是书源")
        }
        if (element is JsonObject) {
            val urls = (element["sourceUrls"] as? JsonArray)
                ?.takeIf { array -> array.all { it is JsonPrimitive && it.isString } }
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                ?.filter { it.isNotBlank() }
            if (!urls.isNullOrEmpty()) {
                val sizeBefore = acc.size
                try {
                    urls.forEach { importFromJson(download(it), acc) }
                } catch (e: Throwable) {
                    truncate(acc, sizeBefore)
                    throw e
                }
                return
            }
        }
        val items = if (element is JsonArray) element.toList() else listOf(element)
        if (items.isEmpty()) throw LegadoParseException("不是书源")
        val sizeBefore = acc.size
        try {
            items.forEach { item ->
                val obj = item as? JsonObject ?: throw LegadoParseException("不是书源")
                when {
                    obj.containsKey("bookSourceUrl") -> {
                        val source = runCatching {
                            GSON.decodeFromString(BookSource.serializer(), item.toString())
                        }.getOrElse {
                            throw LegadoParseException("不是书源")
                        }
                        if (source.bookSourceUrl.isBlank()) {
                            throw LegadoParseException("不是书源")
                        }
                        acc.add(source)
                    }

                    obj.containsKey("sourceUrl") -> {
                        val old = runCatching {
                            GSON.decodeFromString(OldRssSource.serializer(), item.toString())
                        }.getOrElse {
                            throw LegadoParseException("不是书源")
                        }
                        if (old.sourceUrl.isBlank()) throw LegadoParseException("不是书源")
                        acc.add(old.toBookSource())
                    }

                    else -> throw LegadoParseException("不是书源")
                }
            }
        } catch (e: Throwable) {
            truncate(acc, sizeBefore)
            throw e
        }
    }

    private fun truncate(acc: ArrayList<BookSource>, size: Int) {
        while (acc.size > size) acc.removeAt(acc.size - 1)
    }

    private suspend fun store(db: AppDatabase, parsed: List<BookSource>): Outcome {
        val dao = db.bookSourceDao
        val config = AppConfigProviders.get()
        var added = 0
        var updated = 0
        var unchanged = 0
        val toInsert = arrayListOf<BookSource>()
        for (source in parsed) {
            val existing = dao.getBookSourcePart(source.bookSourceUrl)
            when {
                existing == null -> {
                    added++
                    toInsert.add(source)
                }

                existing.lastUpdateTime < source.lastUpdateTime -> {
                    updated++
                    if (config.importKeepName) source.bookSourceName = existing.bookSourceName
                    if (config.importKeepGroup) source.bookSourceGroup = existing.bookSourceGroup
                    if (config.importKeepEnable) {
                        source.enabled = existing.enabled
                        source.enabledExplore = existing.enabledExplore
                    }
                    source.customOrder = existing.customOrder
                    toInsert.add(source)
                }

                else -> unchanged++
            }
        }
        if (toInsert.isNotEmpty()) {
            dao.insert(*toInsert.toTypedArray())
        }
        SourceHelp.evictAll()
        scope.launch { runCatching { SourceHelp.adjustSortNumber() } }
        ContentProcessorProviders.get().upReplaceRules()
        val stored = if (parsed.isEmpty()) {
            emptyList()
        } else {
            dao.getBookSources(parsed.map { it.bookSourceUrl })
        }
        return Outcome(
            added = added,
            updated = updated,
            unchanged = unchanged,
            failed = 0,
            stored = stored,
            errors = emptyList()
        )
    }
}

/** A bridge-level failure with a contract error code (ENGINE-study §4.1). */
class LegadoBridgeException(val code: String, message: String) : Exception(message)

/** Maps engine failures onto the contract error codes. */
fun legadoErrorCode(e: Throwable): String = when (e) {
    is LegadoBridgeException -> e.code
    is LegadoParseException -> "PARSE"
    is NoStackTraceException -> "PARSE"
    is java.io.IOException -> "NETWORK"
    is kotlinx.coroutines.CancellationException -> "CANCELLED"
    else -> "UNKNOWN"
}

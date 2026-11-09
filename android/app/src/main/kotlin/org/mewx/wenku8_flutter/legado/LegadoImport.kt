package org.mewx.wenku8_flutter.legado

import io.legado.app.constant.AppConst
import io.legado.app.data.AppDatabase
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.DictRule
import io.legado.app.data.entities.HttpTTS
import io.legado.app.data.entities.OldRssSource
import io.legado.app.data.entities.ReplaceRule
import io.legado.app.data.entities.RuleSub
import io.legado.app.data.entities.TxtTocRule
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
import io.legado.app.utils.systemCurrentTimeMillis
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
 * - each item is typed by its top-level keys (the fork's JsonTypeDetector
 *   key order, applied per item so composite packages — one array mixing
 *   subscriptions, sources, replace rules and dict rules, as the source
 *   warehouses ship them — land each kind in its own table):
 *   `bookSourceUrl` -> BookSource, `sourceUrl` -> legacy OldRssSource
 *   converted via toBookSource(), `pattern` -> ReplaceRule, `showRule`
 *   -> DictRule, name+type+url -> RuleSub, name+rule -> TxtTocRule,
 *   name+url -> HttpTTS. An item matching no kind counts as failed and
 *   is reported in errors; it no longer aborts the rest of the batch.
 *   A payload where NOTHING is recognised still throws, exactly as
 *   before, so garbage input keeps the old error surface;
 * - parsed sources are compared with the stored ones by lastUpdateTime:
 *   new -> added, newer -> updated, otherwise unchanged (not re-inserted);
 *   updates honor the importKeepName/Group/Enable config flags and keep
 *   the stored customOrder, exactly like the fork's importSelect with its
 *   default selection. The other kinds use their own fork comparison
 *   (see [storeTyped]): replace rules by id + the fork's field diff,
 *   dict rules by name + field diff, toc rules by id + equality,
 *   HttpTTS by id + lastUpdateTime.
 */
object LegadoImport {

    data class Outcome(
        val added: Int,
        val updated: Int,
        val unchanged: Int,
        val failed: Int,
        // Policy-skipped sources (audio/file kinds this build does
        // not adapt, A6): counted apart from failed, so the UI can
        // say "not supported" instead of "import failed".
        val skipped: Int = 0,
        val stored: List<BookSource>,
        val errors: List<String>
    )

    /** Tallies for the non-source kinds (rules / subscriptions / TTS). */
    data class Counts(
        val added: Int = 0,
        val updated: Int = 0,
        val unchanged: Int = 0,
        val failed: Int = 0,
        val errors: List<String> = emptyList(),
        // Policy-skipped items (see [Outcome.skipped]).
        val skipped: Int = 0
    ) {
        operator fun plus(other: Counts) = Counts(
            added = added + other.added,
            updated = updated + other.updated,
            unchanged = unchanged + other.unchanged,
            failed = failed + other.failed,
            errors = errors + other.errors,
            skipped = skipped + other.skipped
        )
    }

    /** Everything one payload parsed into, split by target table. */
    private class Parsed {
        val sources = arrayListOf<BookSource>()
        val replaceRules = arrayListOf<ReplaceRule>()
        val dictRules = arrayListOf<DictRule>()
        val tocRules = arrayListOf<TxtTocRule>()
        val httpTts = arrayListOf<HttpTTS>()
        val ruleSubs = arrayListOf<RuleSub>()
        var failed = 0
        val errors = arrayListOf<String>()

        fun isEmpty() = sources.isEmpty() && replaceRules.isEmpty() &&
            dictRules.isEmpty() && tocRules.isEmpty() && httpTts.isEmpty() &&
            ruleSubs.isEmpty()
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    suspend fun importPayload(db: AppDatabase, payload: String, payloadKind: String): Outcome {
        val text = when (payloadKind) {
            "filePath" -> File(payload).readText(Charsets.UTF_8)
            "url" -> payload
            else -> payload
        }
        val parsed = Parsed()
        collect(text, parsed)
        if (parsed.isEmpty()) throw LegadoParseException("不是书源")
        return store(db, parsed)
    }

    /**
     * Subscription update import (G13): [text] is the subscription
     * payload — JSON text or a URL to download — imported under the
     * subscription's declared type, following RuleSubAutoUpdateHook's
     * contract (0/1 book sources, 2 replace rules, 3 txt toc rules,
     * 4 dict rules, 5 HttpTTS). Returns the number actually stored
     * (added + updated), 0 when everything parsed was already current.
     * Unparseable payloads throw, like the fork's hook contract.
     */
    /** Hook-contract wrapper over [importByTypeOutcome] (stored count). */
    suspend fun importByType(db: AppDatabase, type: Int, text: String): Int {
        val counts = importByTypeOutcome(db, type, text)
        return counts.added + counts.updated
    }

    suspend fun importByTypeOutcome(db: AppDatabase, type: Int, text: String): Counts {
        var mText = text.trim().trim('\uFEFF')
        if (mText.startsWith("file://")) {
            mText = File(java.net.URI(mText)).readText(Charsets.UTF_8).trim()
        }
        if (mText.isAbsUrl()) mText = download(mText)
        val parsed = Parsed()
        importFromJson(mText, parsed)
        if (parsed.isEmpty()) throw LegadoParseException("格式不对")
        return when (type) {
            0, 1 -> storeSourcesOnly(db, parsed)
            2 -> storeReplaceRules(db, parsed.replaceRules)
            3 -> storeTocRules(db, parsed.tocRules)
            4 -> storeDictRules(db, parsed.dictRules)
            5 -> storeHttpTts(db, parsed.httpTts)
            else -> throw LegadoParseException("未知订阅类型: $type")
        }
    }

    /**
     * Downloads a payload by URL (the fork import chain's URL handling,
     * shared with [collect]): plain GET through the shared client,
     * `#requestWithoutUA` honoured, body decompressed.
     */
    suspend fun downloadText(url: String): String = download(url)

    /** Parses one standalone source JSON (upsertSource path). */
    fun parseSingleSource(sourceJson: String): BookSource {
        // Explicit-serializer decode: the reified fromJsonObject helper is
        // an inline function with JVM target 21 bytecode, which cannot be
        // inlined into this host (compiled for target 17). Parsed
        // leniently first (same as batch import) so a numeric
        // bookSourceType written as a string (A5) is normalised
        // before the strict entity decode runs.
        val element = runCatching { parseToJsonElementLenient(sourceJson) }
            .getOrElse { throw LegadoParseException("不是书源") }
        val obj = element as? JsonObject
            ?: throw LegadoParseException("不是书源")
        val normalized = normalizeBookSourceJson(obj)
        val source = runCatching {
            GSON.decodeFromString(BookSource.serializer(), normalized.toString())
        }.getOrElse { throw LegadoParseException("不是书源") }
        if (source.bookSourceUrl.isBlank()) throw LegadoParseException("不是书源")
        // A1: a book-source address must be a real web address. The old
        // check only rejected blanks, so "大灰狼融合VIP5.0" imported
        // "successfully" and only blew up later with an unreadable
        // OkHttp scheme error at check/search time.
        if (!isValidBookSourceUrl(source.bookSourceUrl)) {
            throw LegadoParseException(
                "书源地址不是网址：${source.bookSourceUrl.trim().take(80)}"
            )
        }
        return source
    }

    /**
     * A book-source address must be a real web address (A1). The
     * "##comment" suffix some sources carry (e.g.
     * "https://www.qidian.com##zhbyjm7783") is stripped first;
     * anything left must parse as an http(s) URL with a host.
     * Plain text ("大灰狼融合VIP5.0", "全能书源", "珍藏版") fails here
     * instead of importing "successfully" and breaking later.
     */
    internal fun isValidBookSourceUrl(raw: String): Boolean {
        val url = raw.trim().substringBefore("##").trim()
        if (url.isEmpty()) return false
        return try {
            val parsed = java.net.URL(url)
            (parsed.protocol == "http" || parsed.protocol == "https") &&
                !parsed.host.isNullOrBlank()
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Source JSONs in the wild sometimes write bookSourceType as a
     * string ("0") instead of a number (0); the strict entity decoder
     * rejects that, so the import fails with an unreadable decode
     * error (A5). Rewrite a numeric string back to a number before
     * decoding; a non-numeric string is reported plainly instead of
     * the decoder's jargon.
     */
    private fun normalizeBookSourceJson(obj: JsonObject): JsonObject {
        val type = obj["bookSourceType"] as? JsonPrimitive ?: return obj
        if (!type.isString) return obj
        val text = type.contentOrNull ?: return obj
        val number = text.trim().toIntOrNull()
        if (number != null) {
            return JsonObject(obj.toMap() + ("bookSourceType" to JsonPrimitive(number)))
        }
        throw LegadoParseException(
            "书源类型字段写成了文字「$text」，请改成数字（0=小说，2=漫画）"
        )
    }

    private suspend fun collect(text: String, acc: Parsed) {
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

    private suspend fun importFromJson(json: String, acc: Parsed) {
        val element = runCatching { parseToJsonElementLenient(json) }.getOrElse {
            throw LegadoParseException("不是书源")
        }
        if (element is JsonObject) {
            val urls = (element["sourceUrls"] as? JsonArray)
                ?.takeIf { array -> array.all { it is JsonPrimitive && it.isString } }
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                ?.filter { it.isNotBlank() }
            if (!urls.isNullOrEmpty()) {
                urls.forEach { importFromJson(download(it), acc) }
                return
            }
        }
        val items = if (element is JsonArray) element.toList() else listOf(element)
        if (items.isEmpty()) throw LegadoParseException("不是书源")
        items.forEach { item -> collectItem(item, acc) }
    }

    /**
     * Types one payload item by its keys (fork JsonTypeDetector order)
     * and appends it to the matching bucket of [acc]. Unrecognised or
     * undecodable items are tallied as failed, not thrown: a composite
     * package must not lose its good items to one bad sibling. Only a
     * payload where nothing at all is recognised throws (callers check
     * [Parsed.isEmpty]), preserving the old garbage-input error.
     */
    private fun collectItem(item: kotlinx.serialization.json.JsonElement, acc: Parsed) {
        val obj = item as? JsonObject
        if (obj == null) {
            acc.failed++
            acc.errors.add("不是书源")
            return
        }
        val text = item.toString()
        runCatching {
            when {
                obj.containsKey("bookSourceUrl") -> {
                    // A5: a string-typed bookSourceType ("0") is
                    // normalised to a number before the strict decode.
                    val normalized = normalizeBookSourceJson(obj)
                    val source = GSON.decodeFromString(
                        BookSource.serializer(), normalized.toString()
                    )
                    if (source.bookSourceUrl.isBlank()) {
                        throw LegadoParseException("不是书源")
                    }
                    // A1: refuse a non-URL address here, with the
                    // source's name attached, instead of importing it
                    // "successfully" and breaking at check/search time.
                    if (!isValidBookSourceUrl(source.bookSourceUrl)) {
                        throw LegadoParseException(
                            "书源「${source.bookSourceName}」的地址不是网址：" +
                                source.bookSourceUrl.trim().take(80)
                        )
                    }
                    acc.sources.add(source)
                }

                obj.containsKey("sourceUrl") -> {
                    val old = GSON.decodeFromString(OldRssSource.serializer(), text)
                    if (old.sourceUrl.isBlank()) throw LegadoParseException("不是书源")
                    // A1, same as above: the converted source inherits
                    // this address as its bookSourceUrl.
                    if (!isValidBookSourceUrl(old.sourceUrl)) {
                        throw LegadoParseException(
                            "书源地址不是网址：${old.sourceUrl.trim().take(80)}"
                        )
                    }
                    acc.sources.add(old.toBookSource())
                }

                obj.containsKey("pattern") -> {
                    acc.replaceRules.add(parseReplaceRule(text))
                }

                obj.containsKey("showRule") -> {
                    acc.dictRules.add(GSON.decodeFromString(DictRule.serializer(), text))
                }

                obj.containsKey("name") && obj.containsKey("type") &&
                    obj.containsKey("url") -> {
                    val sub = GSON.decodeFromString(RuleSub.serializer(), text)
                    if (sub.url.isBlank()) throw LegadoParseException("不是书源")
                    acc.ruleSubs.add(sub)
                }

                obj.containsKey("name") && obj.containsKey("rule") -> {
                    acc.tocRules.add(GSON.decodeFromString(TxtTocRule.serializer(), text))
                }

                obj.containsKey("name") && obj.containsKey("url") -> {
                    acc.httpTts.add(GSON.decodeFromString(HttpTTS.serializer(), text))
                }

                else -> throw LegadoParseException("不是书源")
            }
        }.onFailure {
            acc.failed++
            acc.errors.add(it.message ?: "不是书源")
        }
    }

    /**
     * ReplaceRule parsing with the fork ReplaceAnalyzer's compatibility
     * (that class lives in `:core`, outside the vendored AARs, so its
     * ~40 lines are mirrored here like LegadoImport mirrors the import
     * view models): strict entity decode first; when that yields no
     * usable pattern, fall back to the legacy field names (regex ->
     * pattern, replaceSummary -> name, enable -> isEnabled,
     * serialNumber -> order, useTo -> scope).
     */
    internal fun parseReplaceRule(json: String): ReplaceRule {
        val decoded = runCatching {
            GSON.decodeFromString(ReplaceRule.serializer(), json.trim())
        }.getOrNull()
        if (decoded != null && decoded.pattern.isNotEmpty()) return decoded
        val item = runCatching { parseToJsonElementLenient(json.trim()) }.getOrElse {
            throw LegadoParseException("格式不对")
        }
        val obj = item as? JsonObject ?: throw LegadoParseException("格式不对")
        fun str(key: String): String? =
            (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

        fun bool(key: String): Boolean? =
            (obj[key] as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull()

        fun long(key: String): Long? =
            (obj[key] as? JsonPrimitive)?.contentOrNull?.toLongOrNull()

        fun int(key: String): Int? =
            (obj[key] as? JsonPrimitive)?.contentOrNull?.toIntOrNull()
        val rule = ReplaceRule()
        rule.id = long("id") ?: systemCurrentTimeMillis()
        rule.pattern = str("regex") ?: ""
        if (rule.pattern.isEmpty()) throw LegadoParseException("格式不对")
        rule.isRegex = bool("isRegex") ?: false
        rule.replacement = str("replacement") ?: ""
        rule.name = str("name") ?: str("replaceSummary") ?: ""
        rule.isEnabled = bool("isEnabled") ?: bool("enable") ?: true
        rule.order = int("order") ?: int("serialNumber") ?: 0
        rule.scope = str("scope") ?: str("useTo")
        rule.group = str("group") ?: ""
        return rule
    }

    /** The fork ImportRuleDiff判据 (replace rules): any content field differs. */
    internal fun replaceRuleChanged(item: ReplaceRule, local: ReplaceRule): Boolean =
        item.name != local.name ||
            item.group != local.group ||
            item.pattern != local.pattern ||
            item.replacement != local.replacement ||
            item.scope != local.scope ||
            item.scopeTitle != local.scopeTitle ||
            item.scopeContent != local.scopeContent ||
            item.excludeScope != local.excludeScope ||
            item.isEnabled != local.isEnabled ||
            item.isRegex != local.isRegex

    /** The fork ImportRuleDiff判据 (dict rules): urlRule/showRule/enabled. */
    internal fun dictRuleChanged(item: DictRule, local: DictRule): Boolean =
        item.urlRule != local.urlRule ||
            item.showRule != local.showRule ||
            item.enabled != local.enabled

    private suspend fun store(db: AppDatabase, parsed: Parsed): Outcome {
        val sourceCounts = storeSources(db, parsed.sources)
        val typed = storeReplaceRules(db, parsed.replaceRules) +
            storeDictRules(db, parsed.dictRules) +
            storeTocRules(db, parsed.tocRules) +
            storeHttpTts(db, parsed.httpTts) +
            storeRuleSubs(db, parsed.ruleSubs)
        val stored = if (parsed.sources.isEmpty()) {
            emptyList()
        } else {
            db.bookSourceDao.getBookSources(parsed.sources.map { it.bookSourceUrl })
        }
        return Outcome(
            added = sourceCounts.added + typed.added,
            updated = sourceCounts.updated + typed.updated,
            unchanged = sourceCounts.unchanged + typed.unchanged,
            failed = parsed.failed + sourceCounts.failed,
            skipped = sourceCounts.skipped + typed.skipped,
            stored = stored,
            errors = (parsed.errors + sourceCounts.errors + typed.errors).take(8)
        )
    }

    /** Subscription-import variant: book sources only, as [Counts]. */
    private suspend fun storeSourcesOnly(db: AppDatabase, parsed: Parsed): Counts {
        val counts = storeSources(db, parsed.sources)
        return counts.copy(
            failed = parsed.failed + counts.failed,
            skipped = counts.skipped,
            errors = (parsed.errors + counts.errors).take(8)
        )
    }

    /**
     * Book-source storage with the fork importSelect semantics (see the
     * class doc): lastUpdateTime comparison, import-keep flags, stored
     * customOrder preserved, sort/source caches refreshed afterwards.
     */
    private suspend fun storeSources(db: AppDatabase, parsed: List<BookSource>): Counts {
        val dao = db.bookSourceDao
        val config = AppConfigProviders.get()
        var added = 0
        var updated = 0
        var unchanged = 0
        var rejected = 0
        val rejectedNames = arrayListOf<String>()
        val toInsert = arrayListOf<BookSource>()
        for (source in parsed) {
            // This build only adapts novel (type 0) and manga (type 2)
            // sources. Audio (1), file (3) and any unknown type are
            // refused at import time, before they reach the tables.
            if (source.bookSourceType != 0 && source.bookSourceType != 2) {
                rejected++
                if (rejectedNames.size < 3) {
                    rejectedNames.add(source.bookSourceName)
                }
                continue
            }
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
        val errors = if (rejected == 0) {
            emptyList()
        } else {
            listOf(
                "已跳过 $rejected 个非小说/漫画书源，本版只适配小说、漫画" +
                    if (rejectedNames.isEmpty()) "" else "：${rejectedNames.joinToString("、")}"
            )
        }
        // A6: policy rejections are not failures. They used to be
        // returned as failed = rejected, so the UI showed "失败 N"
        // for audio/file sources this build deliberately refuses —
        // and the user read it as "the app broke the import". They
        // now ride in skipped, with the reason kept in errors.
        return Counts(added, updated, unchanged, failed = 0, errors = errors, skipped = rejected)
    }

    /**
     * Replace-rule storage with the fork's default selection (new or
     * changed per [replaceRuleChanged]); refreshes the content
     * pipeline's live rule set afterwards, like any rule mutation.
     */
    internal suspend fun storeReplaceRules(
        db: AppDatabase,
        rules: List<ReplaceRule>
    ): Counts {
        if (rules.isEmpty()) return Counts()
        val dao = db.replaceRuleDao
        var added = 0
        var updated = 0
        var unchanged = 0
        val toInsert = arrayListOf<ReplaceRule>()
        for (rule in rules) {
            val local = dao.findById(rule.id)
            when {
                local == null -> {
                    added++
                    toInsert.add(rule)
                }

                replaceRuleChanged(rule, local) -> {
                    updated++
                    toInsert.add(rule)
                }

                else -> unchanged++
            }
        }
        if (toInsert.isNotEmpty()) {
            dao.insert(*toInsert.toTypedArray())
            ContentProcessorProviders.get().upReplaceRules()
        }
        return Counts(added, updated, unchanged)
    }

    /** Dict-rule storage: identity is the name (DictRule's primary key). */
    internal suspend fun storeDictRules(db: AppDatabase, rules: List<DictRule>): Counts {
        if (rules.isEmpty()) return Counts()
        val dao = db.dictRuleDao
        var added = 0
        var updated = 0
        var unchanged = 0
        val toInsert = arrayListOf<DictRule>()
        for (rule in rules) {
            val local = dao.getByName(rule.name)
            when {
                local == null -> {
                    added++
                    toInsert.add(rule)
                }

                dictRuleChanged(rule, local) -> {
                    updated++
                    toInsert.add(rule)
                }

                else -> unchanged++
            }
        }
        if (toInsert.isNotEmpty()) dao.insert(*toInsert.toTypedArray())
        return Counts(added, updated, unchanged)
    }

    /** Txt-toc-rule storage: by id, changed = any stored field differs. */
    internal suspend fun storeTocRules(db: AppDatabase, rules: List<TxtTocRule>): Counts {
        if (rules.isEmpty()) return Counts()
        val dao = db.txtTocRuleDao
        var added = 0
        var updated = 0
        var unchanged = 0
        val toInsert = arrayListOf<TxtTocRule>()
        for (rule in rules) {
            val local = dao.get(rule.id)
            when {
                local == null -> {
                    added++
                    toInsert.add(rule)
                }

                local.name != rule.name || local.rule != rule.rule ||
                    local.example != rule.example || local.enable != rule.enable ||
                    local.serialNumber != rule.serialNumber -> {
                    updated++
                    toInsert.add(rule)
                }

                else -> unchanged++
            }
        }
        if (toInsert.isNotEmpty()) dao.insert(*toInsert.toTypedArray())
        return Counts(added, updated, unchanged)
    }

    /** HttpTTS storage: by id, changed = newer lastUpdateTime (fork判据). */
    internal suspend fun storeHttpTts(db: AppDatabase, list: List<HttpTTS>): Counts {
        if (list.isEmpty()) return Counts()
        val dao = db.httpTTSDao
        var added = 0
        var updated = 0
        var unchanged = 0
        val toInsert = arrayListOf<HttpTTS>()
        for (tts in list) {
            val local = dao.get(tts.id)
            when {
                local == null -> {
                    added++
                    toInsert.add(tts)
                }

                local.lastUpdateTime < tts.lastUpdateTime -> {
                    updated++
                    toInsert.add(tts)
                }

                else -> unchanged++
            }
        }
        if (toInsert.isNotEmpty()) dao.insert(*toInsert.toTypedArray())
        return Counts(added, updated, unchanged)
    }

    /**
     * RuleSub storage: by id; a fresh subscription with customOrder 0
     * goes last (RuleSubViewModelShared.save semantics). Existing rows
     * count as updated only when a user-visible field actually changed.
     */
    internal suspend fun storeRuleSubs(db: AppDatabase, subs: List<RuleSub>): Counts {
        if (subs.isEmpty()) return Counts()
        val dao = db.ruleSubDao
        var added = 0
        var updated = 0
        var unchanged = 0
        val toInsert = arrayListOf<RuleSub>()
        for (sub in subs) {
            val local = dao.all().firstOrNull { it.id == sub.id }
            when {
                local == null -> {
                    added++
                    if (sub.customOrder == 0) {
                        sub.customOrder =
                            (dao.all().maxOfOrNull { it.customOrder } ?: 0) + 1
                    }
                    toInsert.add(sub)
                }

                local.name != sub.name || local.url != sub.url ||
                    local.type != sub.type || local.autoUpdate != sub.autoUpdate -> {
                    updated++
                    toInsert.add(sub)
                }

                else -> unchanged++
            }
        }
        if (toInsert.isNotEmpty()) dao.insert(*toInsert.toTypedArray())
        return Counts(added, updated, unchanged)
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

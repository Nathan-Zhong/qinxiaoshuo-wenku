package org.mewx.wenku8_flutter.legado

import io.legado.app.constant.AppConst
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.ReplaceRule
import io.legado.app.data.entities.RuleSub
import io.legado.app.help.book.ContentProcessorProviders
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.help.storage.RuleSubAutoUpdateHook
import io.legado.app.model.CheckSourceShared
import io.legado.app.model.Debug
import io.legado.app.model.webBook.WebBook
import io.legado.app.utils.isAbsUrl
import io.legado.app.utils.systemCurrentTimeMillis
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import kotlin.math.min

/**
 * Management-plane bridge operations (P5.6): source checking (G12),
 * rule subscriptions (G13), replace-rule CRUD (G14) and find-book-by-
 * URL (G16), plus the simplified/traditional converter switch the
 * content pipeline reads (P5.5 follow-up, Cassidy-ordered UI).
 *
 * Everything here is a thin orchestration over the vendored engine:
 * the per-source check itself is the engine's own
 * [CheckSourceShared.checkSource] (the same business flow the fork's
 * CheckSourceService runs), subscription payloads go through
 * [LegadoImport]'s typed import (which mirrors the fork's
 * Import*ViewModelShared family), and replace rules are plain DAO
 * work against the same tables the content pipeline reads.
 */
object LegadoManage {

    private fun requireInit() {
        if (!LegadoEngine.isInitialized) {
            throw LegadoBridgeException("ENGINE_NOT_INIT", "Legado engine not initialized")
        }
    }

    // ------------------------------------------------------------------
    // G12: checkSources
    // ------------------------------------------------------------------

    /**
     * Runs one check round over [sourceUrls] (null = every source in
     * the DB) and reports through [emit] in the task-channel contract
     * shapes: one `checkProgress` per finished source (sourceUrl,
     * state ok/fail, human message, done/total) and a final
     * `checkDone` (okCount/failCount). Returns the round's [Job] so
     * the plugin can wire cancelTask to it.
     *
     * Scheduling mirrors the fork's CheckSourceRunner (parallelism =
     * user threadCount clamped to [AppConst.MAX_THREAD], each source
     * written back to the DAO right after its check) because the
     * runner's own progress callback carries only the source NAME —
     * the bridge contract needs a per-source verdict, and the verdict
     * lives in the checked source object (its invalid groups + error
     * comment), which the runner does not hand out. The probing logic
     * itself is not re-implemented: [CheckSourceShared.checkSource]
     * runs each source through search -> info -> toc -> content and
     * records the outcome on the source exactly as in the fork.
     */
    fun checkSources(
        taskId: Int,
        sourceUrls: List<String>?,
        emit: (Map<String, Any?>) -> Unit
    ): Job {
        requireInit()
        return LegadoEngine.scope.launch {
            val dao = LegadoEngine.db.bookSourceDao
            val ids = sourceUrls ?: dao.all().map { it.bookSourceUrl }
            val total = ids.size
            var done = 0
            var okCount = 0
            var failCount = 0
            val gate = Semaphore(
                min(AppConfigProviders.get().threadCount, AppConst.MAX_THREAD)
                    .coerceAtLeast(1)
            )
            try {
                coroutineScope {
                    ids.map { url ->
                        async {
                            gate.withPermit {
                                val source = dao.getBookSource(url)
                                if (source == null) {
                                    val snapshot = synchronized(this@LegadoManage) {
                                        done++
                                        failCount++
                                        done
                                    }
                                    emit(
                                        mapOf(
                                            "type" to "checkProgress",
                                            "taskId" to taskId,
                                            "sourceUrl" to url,
                                            "state" to "fail",
                                            "message" to "书源不存在",
                                            "done" to snapshot,
                                            "total" to total
                                        )
                                    )
                                    return@withPermit
                                }
                                runCatching {
                                    CheckSourceShared.checkSource(source)
                                }.onFailure { e ->
                                    LegadoEngine.recordBridgeError("checkSource", e)
                                }
                                runCatching { dao.update(source) }
                                val invalid = source.getInvalidGroupNames()
                                val ok = invalid.isBlank()
                                val message = if (ok) {
                                    "校验成功"
                                } else {
                                    // fix9 (bug 5): the engine reports
                                    // every failure twice — once as the
                                    // invalid-group list and once as the
                                    // "// Error: " comment, which usually
                                    // just repeats those same groups —
                                    // and when it does carry a real
                                    // cause it is engine jargon. Clean
                                    // it up before showing it.
                                    checkFailureMessage(source, invalid)
                                }
                                val snapshot = synchronized(this@LegadoManage) {
                                    done++
                                    if (ok) okCount++ else failCount++
                                    done
                                }
                                emit(
                                    mapOf(
                                        "type" to "checkProgress",
                                        "taskId" to taskId,
                                        "sourceUrl" to url,
                                        "state" to if (ok) "ok" else "fail",
                                        "message" to message,
                                        "done" to snapshot,
                                        "total" to total
                                    )
                                )
                            }
                        }
                    }.awaitAll()
                }
            } finally {
                runCatching { Debug.finishChecking() }
                emit(
                    mapOf(
                        "type" to "checkDone",
                        "taskId" to taskId,
                        "okCount" to okCount,
                        "failCount" to failCount
                    )
                )
            }
        }
    }

    // ------------------------------------------------------------------
    // G12 failure text (bug 5)
    // ------------------------------------------------------------------

    /**
     * Builds the one-line failure text for a failed source check.
     *
     * What the engine hands us is two descriptions of the same
     * failure: the invalid-group list (e.g. "发现失效，失效，搜索失效")
     * and the "// Error: " comment, which usually just repeats those
     * groups ("校验失败:发现失效，搜索失效") — so the sheet showed
     * every failure twice. And when the comment does carry a real
     * cause it is engine jargon ("Expected URL scheme ... for
     * {{java..."). This cleans both up:
     *
     * - the bare "失效" group (added on any failure) is dropped when
     *   stage names exist — it says nothing beyond them;
     * - a comment that only repeats the stage names is dropped;
     * - a real cause is translated into plain language;
     * - when the engine gives no cause at all, the source's own
     *   address is probed (plain-URL sources) or compared with the
     *   address written inside its rules (script sources), so the
     *   sheet can say what is actually wrong instead of "失败".
     *
     * The verdict itself (ok/fail) still comes from the engine
     * check, unchanged — only the words change.
     */
    private suspend fun checkFailureMessage(
        source: BookSource,
        invalidRaw: String,
    ): String {
        val stages = invalidRaw.split('，', ',')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != "失效" }
        val invalid = stages.joinToString("，")
        val rawError = source.bookSourceComment
            ?.takeIf { it.startsWith("// Error: ") }
            ?.removePrefix("// Error: ")
            ?.substringBefore("\n\n")
            ?.replace(Regex("\\s*\\n\\s*"), " ")
            ?.trim()
            // FIX8: keep 1200 so a JS error's full QuickJS stack
            // survives into the note (7753's truncated stack hid
            // which eval path threw).
            ?.take(1200)
            .orEmpty()
        val cause = translateCheckError(source, rawError, stages)
            ?: probeSearchAddress(source, stages)
        val base = listOfNotNull(
            invalid.takeIf { it.isNotBlank() },
            cause,
        ).joinToString("：")
        val hints = buildList {
            hostMismatchHint(source)?.let { add(it) }
            if (source.bookSourceComment?.contains("魔法") == true) {
                add("源作者注明：使用需要魔法")
            }
        }
        return (listOf(base) + hints)
            .filter { it.isNotBlank() }
            .joinToString("；")
    }

    /**
     * Translates the engine's error comment into a human cause, or
     * null when it says nothing beyond the failed stages (pure
     * repetition, e.g. "校验失败:发现失效，搜索失效").
     *
     * A2: when the engine chokes on an address that is not a URL at
     * all, the message names the field that held it (and shows the
     * offending value) instead of the bare engine jargon — a user
     * seeing "Expected URL scheme …" could not tell whether the
     * problem was the source address, the search address or the
     * explore address.
     */
    private fun translateCheckError(
        source: BookSource,
        rawError: String,
        stages: List<String>,
    ): String? {
        var text = rawError.trim()
        // The final exception often just wraps the group list.
        while (true) {
            text = when {
                text.startsWith("校验失败:") -> text.removePrefix("校验失败:").trim()
                text.startsWith("校验失败：") -> text.removePrefix("校验失败：").trim()
                text.startsWith("失效：") -> text.removePrefix("失效：").trim()
                else -> break
            }
        }
        if (text.isBlank()) return null
        if (text.contains("Expected URL scheme")) {
            // The check fetched a {{...}} action URL as if it were a
            // web page. Those are buttons, not pages — e.g. 大灰狼聚合
            // 的发现页第一项是"登录大灰狼书源"，其地址是
            // {{java.startBrowser(...)}}；the check takes the first
            // explore kind with a URL and fetches it raw. The source
            // is not broken; the check tripped over a button. Search
            // runs before explore, so when no search stage failed,
            // search is unaffected.
            val isActionUrl = text.contains("{{java") ||
                text.contains("{[java") ||
                text.contains("java.startBrowser")
            if (isActionUrl) {
                val searchOk = stages.none { it.contains("搜索") }
                return "发现页里有个操作按钮（登录入口），校验把它当成网址打开了；这不是书源坏了" +
                    if (searchOk) "，搜索不受影响" else ""
            }
            // A2 (not an action button): name the field that held the
            // bad address. Match the offending value against the
            // source's own addresses first; when it matches nothing
            // (e.g. an address the engine built from a rule), the
            // failed stage says which address was being fetched.
            val badValue = text.substringAfter("for ", "").trim().take(80)
            val field = fieldOfBadUrl(source, badValue, stages)
            return "校验拿到的地址不是网址" +
                (field?.let { "（$it）" } ?: "") +
                (badValue.takeIf { it.isNotBlank() }?.let { "：$it" } ?: "")
        }
        if (text.contains("Unable to resolve host") ||
            text.contains("UnknownHostException")
        ) {
            return "源地址打不开（域名解析失败）"
        }
        if (text.contains("SocketTimeoutException") ||
            text.contains("ConnectException") ||
            text.contains("Failed to connect") ||
            text.contains("timeout", ignoreCase = true) ||
            text.contains("校验超时")
        ) {
            return "连接源地址超时或失败"
        }
        if (text.contains("HTTP 403")) return "源地址返回了 HTTP 403（可能被风控拦截）"
        if (text.contains("HTTP 404")) return "源地址返回了 HTTP 404"
        if (Regex("HTTP 5\\d\\d").containsMatchIn(text)) {
            return "源地址返回了服务端错误（HTTP 5xx）"
        }
        // Drop segments that only repeat the failed stages.
        val kept = text.split('，', ',', '：', ':')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .filter { segment ->
                stages.none { stage -> sameStage(segment, stage) }
            }
        if (kept.isEmpty()) return null
        return kept.joinToString("，").take(300)
    }

    /** Names the source field a bad check-time URL came from (A2):
     * the offending value is matched against the source's own
     * addresses first (a value straight out of searchUrl/exploreUrl/
     * bookSourceUrl names its field); otherwise the failed stage
     * says which address was being fetched. Null when neither says. */
    private fun fieldOfBadUrl(
        source: BookSource,
        badValue: String,
        stages: List<String>,
    ): String? {
        val probe = badValue.take(40)
        if (probe.isNotEmpty()) {
            if (!source.exploreUrl.isNullOrBlank() &&
                source.exploreUrl.contains(probe)
            ) return "发现地址"
            if (!source.searchUrl.isNullOrBlank() &&
                source.searchUrl.contains(probe)
            ) return "搜索地址"
            if (!source.bookSourceUrl.isNullOrBlank() &&
                source.bookSourceUrl.contains(probe)
            ) return "书源地址"
        }
        return when {
            stages.any { it.contains("搜索") } -> "搜索地址"
            stages.any { it.contains("发现") } -> "发现地址"
            stages.any { it.contains("目录") } -> "目录地址"
            stages.any { it.contains("正文") } -> "正文地址"
            else -> null
        }
    }

    /** Two stage spellings count as the same when they match with or
     * without the trailing "失效" (e.g. "搜索" vs "搜索失效"). */
    private fun sameStage(a: String, b: String): Boolean {
        val cleanA = a.removeSuffix("失效")
        val cleanB = b.removeSuffix("失效")
        return cleanA == cleanB || a == b
    }

    /**
     * When the engine gives no cause at all, probe the address the
     * source actually searches or explores — but only for plain-URL
     * sources, and only for reachability: any HTTP answer at all
     * (even 403/404) counts as "reachable", because a bare probe
     * without the source's headers cannot judge the API itself. The
     * bookSourceUrl is deliberately NOT a fallback: it is often a
     * different address from the one search uses (e.g. 漫蛙书源的
     * bookSourceUrl 是 manwapm.cc，搜索实际走 manwa.me)，probing it
     * would report the wrong address as reachable. The verdict is
     * untouched; this only supplies the missing reason.
     */
    private suspend fun probeSearchAddress(
        source: BookSource,
        stages: List<String>,
    ): String? {
        // Only search/explore failures are about reachability; a
        // bare toc/content failure has nothing to probe.
        if (stages.isNotEmpty() &&
            stages.none { it.contains("搜索") || it.contains("发现") }
        ) {
            return null
        }
        val plainUrl = listOfNotNull(
            source.searchUrl,
            source.exploreUrl,
        ).firstOrNull { it.isAbsUrl() && !it.startsWith("@js:") && !it.startsWith("<js>") }
            ?: return null
        val host = runCatching { URL(plainUrl).host }.getOrNull()
            ?: return null
        val origin = runCatching {
            URL(plainUrl).let { "${it.protocol}://${it.host}${if (it.port == -1) "" else ":${it.port}"}/" }
        }.getOrNull() ?: return null
        return runCatching {
            withContext(Dispatchers.IO) {
                val connection = URL(origin).openConnection() as HttpURLConnection
                try {
                    connection.connectTimeout = 5000
                    connection.readTimeout = 5000
                    connection.instanceFollowRedirects = true
                    connection.requestMethod = "GET"
                    connection.responseCode
                    "源地址能打开，可能是规则失效或源站风控"
                } finally {
                    connection.disconnect()
                }
            }
        }.getOrElse { e ->
            when (e) {
                is UnknownHostException -> "源地址 $host 打不开（域名解析失败）"
                is SocketTimeoutException -> "连接源地址 $host 超时"
                is ConnectException -> "连接源地址 $host 失败"
                else -> null
            }
        }
    }

    /**
     * Script sources (searchUrl/exploreUrl starting with @js:/<js>)
     * hide their real address inside the script, and it can go stale
     * while the source's own address stays current — e.g. 漫蛙书源的
     * 搜索/发现默认用 manwa.me，而书源地址是 manwapm.cc. Point that
     * out as a hint (not a verdict): the user can change the domain
     * in the source's login settings.
     */
    private fun hostMismatchHint(source: BookSource): String? {
        val baseHost = source.bookSourceUrl
            ?.takeIf { it.isAbsUrl() }
            ?.let { runCatching { URL(it).host }.getOrNull() }
            ?: return null
        val scriptHosts = (listOfNotNull(source.searchUrl, source.exploreUrl))
            .flatMap { text ->
                Regex("https?://([A-Za-z0-9][A-Za-z0-9.-]*)")
                    .findAll(text).map { it.groupValues[1] }
            }
            .filter { it.contains('.') && !it.equals(baseHost, ignoreCase = true) }
            .distinct()
        val other = scriptHosts.firstOrNull() ?: return null
        return "源里写的地址（$other）与书源地址（$baseHost）不一致，可能是旧域名，可在登录设置里换一个域名"
    }

    // ------------------------------------------------------------------
    // G13: subscriptions (RuleSub)
    // ------------------------------------------------------------------

    fun subscriptionMap(sub: RuleSub): Map<String, Any?> = mapOf(
        "id" to sub.id,
        "name" to sub.name,
        "url" to sub.url,
        "type" to sub.type,
        "customOrder" to sub.customOrder,
        "autoUpdate" to sub.autoUpdate,
        "lastUpdate" to sub.update
    )

    suspend fun listSubscriptions(): List<Map<String, Any?>> {
        requireInit()
        return LegadoEngine.db.ruleSubDao.all().map { subscriptionMap(it) }
    }

    /**
     * Creates (id 0) or updates a subscription row, following
     * RuleSubViewModelShared.save: a new row with customOrder 0 is
     * placed after the current maximum. Returns the stored row.
     */
    suspend fun upsertSubscription(args: Map<String, Any?>): Map<String, Any?> {
        requireInit()
        val dao = LegadoEngine.db.ruleSubDao
        val id = (args["id"] as? Number)?.toLong() ?: 0L
        val existing = if (id != 0L) dao.all().firstOrNull { it.id == id } else null
        val sub = existing ?: RuleSub(
            id = if (id != 0L) id else systemCurrentTimeMillis()
        )
        (args["name"] as? String)?.let { sub.name = it }
        (args["url"] as? String)?.let { sub.url = it }
        (args["type"] as? Number)?.let { sub.type = it.toInt() }
        (args["autoUpdate"] as? Boolean)?.let { sub.autoUpdate = it }
        (args["customOrder"] as? Number)?.let { sub.customOrder = it.toInt() }
        if (existing == null && sub.customOrder == 0) {
            sub.customOrder = (dao.all().maxOfOrNull { it.customOrder } ?: 0) + 1
        }
        dao.insert(sub)
        return subscriptionMap(sub)
    }

    suspend fun deleteSubscription(id: Long): Boolean {
        requireInit()
        val dao = LegadoEngine.db.ruleSubDao
        val sub = dao.all().firstOrNull { it.id == id } ?: return false
        dao.delete(sub)
        return true
    }

    private suspend fun subOrThrow(id: Long): RuleSub {
        return LegadoEngine.db.ruleSubDao.all().firstOrNull { it.id == id }
            ?: throw LegadoBridgeException("UNKNOWN", "订阅不存在: $id")
    }

    /**
     * Downloads one subscription and imports its payload under the
     * subscription's declared type (the same two-hop download the
     * fork's RuleSubAutoUpdate performs: a payload that is itself a
     * URL is followed once more). On success the subscription's
     * last-update stamp advances. Returns an ImportResult-shaped map.
     */
    suspend fun updateSubscription(id: Long): Map<String, Any?> {
        requireInit()
        val sub = subOrThrow(id)
        var text = LegadoImport.downloadText(sub.url).trim()
        if (text.isAbsUrl()) text = LegadoImport.downloadText(text).trim()
        val counts = LegadoImport.importByTypeOutcome(LegadoEngine.db, sub.type, text)
        sub.update = systemCurrentTimeMillis()
        LegadoEngine.db.ruleSubDao.update(sub)
        return mapOf(
            "added" to counts.added,
            "updated" to counts.updated,
            "unchanged" to counts.unchanged,
            "failed" to counts.failed,
            // A6: policy-skipped sources ride separately from failed.
            "skipped" to counts.skipped,
            "sources" to emptyList<Map<String, Any?>>(),
            "errors" to counts.errors
        )
    }

    /**
     * Batch subscription update as a task: every subscription (or,
     * with [onlyDue], only the auto-update ones whose daily stamp is
     * due — the fork's RuleSubAutoUpdate selection). Progress rides
     * the task channel as subscriptionProgress/subscriptionDone maps
     * (the Dart side parses unknown task events generically).
     */
    fun updateAllSubscriptions(
        taskId: Int,
        onlyDue: Boolean,
        emit: (Map<String, Any?>) -> Unit
    ): Job {
        requireInit()
        return LegadoEngine.scope.launch {
            val dao = LegadoEngine.db.ruleSubDao
            val now = systemCurrentTimeMillis()
            val subs = dao.all().filter { sub ->
                !onlyDue || (sub.autoUpdate && now - sub.update >= ONE_DAY_MILLIS)
            }
            var done = 0
            var okCount = 0
            var failCount = 0
            for (sub in subs) {
                val ok = runCatching { updateSubscription(sub.id) }
                    .onFailure { e ->
                        LegadoEngine.recordBridgeError("updateSubscription", e)
                    }
                    .isSuccess
                done++
                if (ok) okCount++ else failCount++
                emit(
                    mapOf(
                        "type" to "subscriptionProgress",
                        "taskId" to taskId,
                        "sourceUrl" to sub.url,
                        "state" to if (ok) "ok" else "fail",
                        "message" to sub.name,
                        "done" to done,
                        "total" to subs.size
                    )
                )
            }
            emit(
                mapOf(
                    "type" to "subscriptionDone",
                    "taskId" to taskId,
                    "okCount" to okCount,
                    "failCount" to failCount
                )
            )
        }
    }

    // ------------------------------------------------------------------
    // G14: replace rules
    // ------------------------------------------------------------------

    fun replaceRuleMap(rule: ReplaceRule): Map<String, Any?> = mapOf(
        "id" to rule.id,
        "name" to rule.name,
        "pattern" to rule.pattern,
        "replacement" to rule.replacement,
        "scope" to rule.scope,
        "isRegex" to rule.isRegex,
        "isEnabled" to rule.isEnabled,
        "order" to rule.order
    )

    suspend fun listReplaceRules(): List<Map<String, Any?>> {
        requireInit()
        return LegadoEngine.db.replaceRuleDao.all().map { replaceRuleMap(it) }
    }

    /**
     * Creates (id 0) or updates a replace rule. Fields the bridge
     * contract does not carry (group, title/content scope flags,
     * exclude scope, timeout) keep their stored values on update and
     * the entity defaults on create, so a bridge edit never silently
     * narrows a rule the fork's editor had configured.
     */
    suspend fun upsertReplaceRule(args: Map<String, Any?>): Map<String, Any?> {
        requireInit()
        val dao = LegadoEngine.db.replaceRuleDao
        val id = (args["id"] as? Number)?.toLong() ?: 0L
        val existing = if (id != 0L) dao.findById(id) else null
        val rule = existing ?: ReplaceRule(
            id = if (id != 0L) id else systemCurrentTimeMillis()
        )
        (args["name"] as? String)?.let { rule.name = it }
        (args["pattern"] as? String)?.let { rule.pattern = it }
        (args["replacement"] as? String)?.let { rule.replacement = it }
        if (args.containsKey("scope")) rule.scope = args["scope"] as? String
        (args["isRegex"] as? Boolean)?.let { rule.isRegex = it }
        (args["isEnabled"] as? Boolean)?.let { rule.isEnabled = it }
        (args["order"] as? Number)?.let { rule.order = it.toInt() }
        dao.insert(rule)
        ContentProcessorProviders.get().upReplaceRules()
        return replaceRuleMap(rule)
    }

    suspend fun deleteReplaceRule(id: Long): Boolean {
        requireInit()
        val dao = LegadoEngine.db.replaceRuleDao
        val rule = dao.findById(id) ?: return false
        dao.delete(rule)
        ContentProcessorProviders.get().upReplaceRules()
        return true
    }

    suspend fun setReplaceRuleEnabled(id: Long, enabled: Boolean) {
        requireInit()
        val dao = LegadoEngine.db.replaceRuleDao
        val rule = dao.findById(id)
            ?: throw LegadoBridgeException("UNKNOWN", "替换规则不存在: $id")
        rule.isEnabled = enabled
        dao.update(rule)
        ContentProcessorProviders.get().upReplaceRules()
    }

    // ------------------------------------------------------------------
    // G16: getBookByUrl
    // ------------------------------------------------------------------

    /**
     * Finds the book behind a detail-page URL: the engine matches the
     * URL against every source (bookUrlPattern / same-host add-book
     * sources / an explicit origin in the URL's option segment) and
     * fetches its info. Throws the engine's own human-readable
     * NoStackTraceException messages （未找到匹配书源 / 已在书架 /
     * 书籍地址格式不对） when no source claims it.
     */
    suspend fun getBookByUrl(url: String): Map<String, Any?> {
        requireInit()
        val book = WebBook.getBookInfoByUrlAwait(url)
        return mapOf(
            "origin" to book.origin,
            "book" to LegadoDto.book(book)
        )
    }

    // ------------------------------------------------------------------
    // Simplified/traditional converter switch (Cassidy-ordered)
    // ------------------------------------------------------------------

    /**
     * Reads the converter mode the content pipeline (P5.5) applies to
     * Legado books: 0 = no conversion, 1 = traditional->simplified,
     * 2 = simplified->traditional (fork AppConfig semantics). Stored
     * by the host's config accessor in SharedPreferences, so the value
     * survives restarts and is the very value the pipeline reads.
     */
    fun getChineseConverterType(): Int {
        requireInit()
        return AppConfigProviders.get().chineseConverterType
    }

    fun setChineseConverterType(type: Int) {
        requireInit()
        if (type !in 0..2) {
            throw LegadoBridgeException("UNKNOWN", "简繁转换模式不对: $type")
        }
        AppConfigProviders.get().chineseConverterType = type
    }

    private const val ONE_DAY_MILLIS = 86_400_000L
}

/**
 * The host's RuleSubAutoUpdateHook (G13): the engine's daily
 * auto-update machinery (vendored in `:data`) delegates its import
 * step to this, exactly as the fork's `:ui` hook delegates to its
 * Import*ViewModelShared family — here, to [LegadoImport]'s typed
 * import, the host's mirror of that family. Registered once at
 * engine init, before any auto-update trigger can fire.
 */
object LegadoRuleSubHook : RuleSubAutoUpdateHook {
    override suspend fun importByType(type: Int, text: String): Int {
        return LegadoImport.importByType(LegadoEngine.db, type, text)
    }
}

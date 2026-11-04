package org.mewx.wenku8_flutter.legado

import io.legado.app.constant.AppConst
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
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
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
                                    // fix6: keep the WHOLE error paragraph,
                                    // not just its first line. The engine's
                                    // addErrorComment stores "// Error: " +
                                    // e.message, and for JS failures that
                                    // message is "JS执行出错\n<real cause>" —
                                    // first-line extraction showed Cassidy
                                    // only the wrapper and dropped the cause
                                    // (device report 2026-11-04). The error
                                    // block is the comment's first paragraph
                                    // (addErrorComment prepends it ahead of a
                                    // "\n\n" separator); collapse its inner
                                    // newlines so the sheet stays one line.
                                    val errorLine = source.bookSourceComment
                                        ?.takeIf { it.startsWith("// Error: ") }
                                        ?.removePrefix("// Error: ")
                                        ?.substringBefore("\n\n")
                                        ?.replace(Regex("\\s*\\n\\s*"), " ")
                                        ?.trim()
                                        ?.take(300)
                                    listOfNotNull(
                                        invalid,
                                        errorLine?.takeIf { it.isNotBlank() }
                                    ).joinToString("：")
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

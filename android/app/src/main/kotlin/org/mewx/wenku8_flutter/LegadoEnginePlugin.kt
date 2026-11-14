package org.mewx.wenku8_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.legado.app.constant.AppConst
import io.legado.app.data.entities.SearchBook
import io.legado.app.help.http.OkHttpClientProviders
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.model.analyzeRule.AnalyzeUrlFactories
import io.legado.app.model.analyzeRule.RuleData
import io.legado.app.model.webBook.SearchModel
import io.legado.app.model.webBook.SourceSearchGroup
import io.legado.app.ui.book.search.SearchScope
import io.legado.engine.LegadoEngineFacade
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.mewx.wenku8_flutter.legado.LegadoBridgeException
import org.mewx.wenku8_flutter.legado.LegadoChallengeSignals
import org.mewx.wenku8_flutter.legado.LegadoDto
import org.mewx.wenku8_flutter.legado.LegadoEngine
import org.mewx.wenku8_flutter.legado.LegadoManage
import org.mewx.wenku8_flutter.legado.LegadoUiHost
import org.mewx.wenku8_flutter.legado.legadoBrief
import org.mewx.wenku8_flutter.legado.legadoErrorCode

/**
 * Bridge between the Dart [LegadoEngineClient] contract (ENGINE-study §4)
 * and the vendored Legado engine.
 *
 * Implemented: ping, init (real: Room DB in app-private storage +
 * provider registration), source management (list/get/upsert/import/
 * delete/enable/meta/groups), explore (getExploreKinds /
 * getExploreBooks), streaming multi-source search over the search
 * EventChannel, the book chain getBookInfo / getChapterList /
 * getChapterContent, resolveImageRequest (G7: real URL + headers
 * for source images via the engine's AnalyzeUrl), and the source
 * login surface (G3: getLoginData / login / runLoginAction /
 * openSourceLogin / logoutSource / getLoginHeader /
 * removeLoginHeader / getLoginStates — see legado/LegadoLogin.kt),
 * and the management plane (P5.6: checkSources with progress on the
 * task EventChannel, subscription CRUD + updates, replace-rule CRUD,
 * getBookByUrl, and the chinese converter switch — see
 * legado/LegadoManage.kt), and the cache download plane (P5.7:
 * cacheChapters with progress on the task EventChannel,
 * getCachedChapterIndexes, clearBookCache — see
 * legado/LegadoEngine.kt). The remaining contract method
 * (change-source candidates) returns notImplemented.
 *
 * Threading: engine work runs on [LegadoEngine.scope] (IO); channel
 * results and event sinks are always delivered on the main thread.
 *
 * The plugin is also the verification UI's bridgehead (P5.2): its
 * MethodChannel is registered in [LegadoUiHost] so the engine's
 * VerificationUiProvider can call INTO Dart (image captcha sheet),
 * and ActivityAware keeps [LegadoUiHost.activity] pointing at the
 * foreground Activity the visible browser launches from. Channels of
 * every attached engine are kept (the audio-service engine's Dart
 * isolate installs no UI handler and answers notImplemented; the
 * provider falls through to the UI engine's channel).
 */
class LegadoEnginePlugin : FlutterPlugin, ActivityAware {
    private var methodChannel: MethodChannel? = null
    private var searchEventChannel: EventChannel? = null
    private var taskEventChannel: EventChannel? = null
    private var appContext: Context? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var searchSink: EventChannel.EventSink? = null

    @Volatile
    private var taskSink: EventChannel.EventSink? = null

    private val searchSessions = ConcurrentHashMap<Int, LegadoSearchSession>()

    /** Long management tasks (source checks, batch subscription
     *  updates) by taskId, so cancelTask can stop them like searches. */
    private val taskJobs = ConcurrentHashMap<Int, kotlinx.coroutines.Job>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler { call, result -> onMethodCall(call, result) }
            LegadoUiHost.registerChannel(it)
        }
        searchEventChannel = EventChannel(binding.binaryMessenger, SEARCH_EVENTS_CHANNEL).also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    searchSink = events
                }

                override fun onCancel(arguments: Any?) {
                    searchSink = null
                }
            })
        }
        taskEventChannel = EventChannel(binding.binaryMessenger, TASK_EVENTS_CHANNEL).also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    taskSink = events
                }

                override fun onCancel(arguments: Any?) {
                    taskSink = null
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        searchSessions.values.forEach { it.shutdown() }
        searchSessions.clear()
        taskJobs.values.forEach { it.cancel() }
        taskJobs.clear()
        methodChannel?.let { LegadoUiHost.unregisterChannel(it) }
        methodChannel?.setMethodCallHandler(null)
        searchEventChannel?.setStreamHandler(null)
        taskEventChannel?.setStreamHandler(null)
        methodChannel = null
        searchEventChannel = null
        taskEventChannel = null
        searchSink = null
        taskSink = null
        appContext = null
    }

    // ------------------------------------------------------------------
    // ActivityAware: foreground Activity for the visible browser
    // ------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        LegadoUiHost.activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        LegadoUiHost.activity = null
    }

    override fun onReattachedToActivityForConfigChanges(
        binding: ActivityPluginBinding
    ) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        LegadoUiHost.activity = null
    }

    // ------------------------------------------------------------------
    // Method dispatch
    // ------------------------------------------------------------------

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ping" -> result.success(
                mapOf(
                    "engineVersion" to LegadoEngineFacade.engineVersion(),
                    "includedModules" to LegadoEngineFacade.includedModules(),
                    "upstreamCommit" to LegadoEngineFacade.upstreamCommit()
                )
            )

            "init" -> launchEngine(result) {
                val context = appContext
                    ?: throw LegadoBridgeException("ENGINE_NOT_INIT", "plugin not attached")
                LegadoEngine.init(context, call.argument<String>("dataDir"))
            }

            "engineSelfCheck" -> launchEngine(result) {
                LegadoEngine.selfCheck()
            }

            "listSources" -> launchEngine(result) {
                LegadoEngine.listSources(
                    group = call.argument<String>("group"),
                    enabledOnly = call.argument<Boolean>("enabledOnly") ?: false,
                    exploreOnly = call.argument<Boolean>("exploreOnly") ?: false
                )
            }

            "getSource" -> launchEngine(result) {
                LegadoEngine.getSource(reqString(call, "sourceUrl"))
            }

            "upsertSource" -> launchEngine(result) {
                LegadoEngine.upsertSource(reqString(call, "sourceJson"))
            }

            "importSources" -> launchEngine(result) {
                LegadoEngine.importSources(
                    payload = reqString(call, "payload"),
                    payloadKind = call.argument<String>("payloadKind") ?: "text"
                )
            }

            "deleteSources" -> launchEngine(result) {
                val urls = call.argument<List<*>>("sourceUrls")
                    ?.filterIsInstance<String>() ?: emptyList()
                mapOf("deleted" to LegadoEngine.deleteSources(urls))
            }

            "setSourceEnabled" -> launchEngine(result) {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val single = call.argument<String>("sourceUrl")
                val batch = call.argument<List<*>>("sourceUrls")?.filterIsInstance<String>()
                when {
                    single != null -> LegadoEngine.setSourceEnabled(single, enabled)
                    batch != null -> LegadoEngine.setSourcesEnabled(batch, enabled)
                    else -> throw LegadoBridgeException(
                        "UNKNOWN", "setSourceEnabled needs sourceUrl or sourceUrls"
                    )
                }
                mapOf("ok" to true)
            }

            "setSourceEnabledExplore" -> launchEngine(result) {
                LegadoEngine.setSourceEnabledExplore(
                    reqString(call, "sourceUrl"),
                    call.argument<Boolean>("enabled") ?: true
                )
                mapOf("ok" to true)
            }

            "updateSourceMeta" -> launchEngine(result) {
                LegadoEngine.updateSourceMeta(
                    sourceUrl = reqString(call, "sourceUrl"),
                    group = call.argument<String>("group"),
                    customOrder = call.argument<Int>("customOrder"),
                    comment = call.argument<String>("comment")
                )
            }

            "listSourceGroups" -> launchEngine(result) {
                LegadoEngine.listSourceGroups()
            }

            "getLoginData" -> launchEngine(result) {
                LegadoEngine.getLoginData(reqString(call, "sourceUrl"))
            }

            "login" -> launchEngine(result) {
                LegadoEngine.login(
                    sourceUrl = reqString(call, "sourceUrl"),
                    data = stringMapArg(call, "data")
                )
            }

            "runLoginAction" -> launchEngine(result) {
                LegadoEngine.runLoginAction(
                    sourceUrl = reqString(call, "sourceUrl"),
                    action = reqString(call, "action"),
                    data = stringMapArg(call, "data")
                )
            }

            "openSourceLogin" -> launchEngine(result) {
                LegadoEngine.openSourceLogin(reqString(call, "sourceUrl"))
            }

            "logoutSource" -> launchEngine(result) {
                LegadoEngine.logoutSource(reqString(call, "sourceUrl"))
                mapOf("ok" to true)
            }

            "getLoginHeader" -> launchEngine(result) {
                LegadoEngine.getLoginHeader(reqString(call, "sourceUrl"))
            }

            "removeLoginHeader" -> launchEngine(result) {
                LegadoEngine.removeLoginHeader(reqString(call, "sourceUrl"))
                mapOf("ok" to true)
            }

            "getLoginStates" -> launchEngine(result) {
                val urls = call.argument<List<*>>("sourceUrls")
                    ?.filterIsInstance<String>() ?: emptyList()
                LegadoEngine.getLoginStates(urls)
            }

            "getExploreKinds" -> launchEngine(result) {
                LegadoEngine.getExploreKinds(reqString(call, "sourceUrl"))
            }

            "getExploreBooks" -> launchEngine(result) {
                LegadoEngine.getExploreBooks(
                    sourceUrl = reqString(call, "sourceUrl"),
                    kindUrl = reqString(call, "kindUrl"),
                    page = call.argument<Int>("page") ?: 1
                )
            }

            "startSearch" -> {
                val taskId = call.argument<Int>("taskId")
                val keyword = call.argument<String>("keyword")
                if (taskId == null || keyword == null) {
                    result.error("UNKNOWN", "startSearch needs taskId and keyword", null)
                    return
                }
                val scopeArg = call.argument<Map<*, *>>("scope")
                val precision = call.argument<Boolean>("precision") ?: false
                LegadoEngine.scope.launch {
                    runCatching {
                        startSearch(taskId, keyword, scopeArg, precision)
                    }.onFailure { e ->
                        // Surface the failure BEFORE the synthetic empty
                        // finish, so Dart can tell "search broke" apart
                        // from "searched, found nothing" (the finish
                        // alone made the two indistinguishable).
                        if (e !is CancellationException) {
                            LegadoEngine.recordBridgeError("startSearch", e)
                            emitSearchEvent(
                                mapOf(
                                    "type" to "searchError",
                                    "taskId" to taskId,
                                    "sourceUrl" to null,
                                    "errorCode" to legadoErrorCode(e),
                                    "message" to e.legadoBrief()
                                )
                            )
                        }
                        emitSearchEvent(
                            mapOf(
                                "type" to "searchFinish",
                                "taskId" to taskId,
                                "isEmpty" to true,
                                "hasMore" to false
                            )
                        )
                        if (e !is CancellationException) {
                            android.util.Log.e(TAG, "startSearch failed", e)
                        }
                    }
                }
                result.success(null)
            }

            "loadMoreSearch" -> {
                val taskId = call.argument<Int>("taskId")
                if (taskId != null) {
                    searchSessions[taskId]?.loadMore()
                }
                result.success(null)
            }

            "restartSearchSource" -> {
                val taskId = call.argument<Int>("taskId")
                val sourceUrl = call.argument<String>("sourceUrl")
                if (taskId != null && sourceUrl != null) {
                    searchSessions[taskId]?.restartSource(sourceUrl)
                }
                result.success(null)
            }

            "cancelTask" -> {
                val taskId = call.argument<Int>("taskId")
                if (taskId != null) {
                    cancelSearchTask(taskId)
                    taskJobs.remove(taskId)?.cancel()
                }
                result.success(null)
            }

            "getBookInfo" -> launchEngine(result) {
                LegadoEngine.getBookInfo(
                    origin = reqString(call, "origin"),
                    bookUrl = reqString(call, "bookUrl"),
                    tocUrl = call.argument<String>("tocUrl"),
                    name = call.argument<String>("name"),
                    author = call.argument<String>("author"),
                    variable = call.argument<String>("variable")
                )
            }

            "getChapterList" -> launchEngine(result) {
                LegadoEngine.getChapterList(
                    origin = reqString(call, "origin"),
                    bookUrl = reqString(call, "bookUrl"),
                    tocUrl = call.argument<String>("tocUrl"),
                    name = call.argument<String>("name"),
                    author = call.argument<String>("author"),
                    variable = call.argument<String>("variable")
                )
            }

            "getChapterContent" -> launchEngine(result) {
                LegadoEngine.getChapterContent(
                    origin = reqString(call, "origin"),
                    bookUrl = reqString(call, "bookUrl"),
                    tocUrl = call.argument<String>("tocUrl"),
                    name = call.argument<String>("name"),
                    author = call.argument<String>("author"),
                    variable = call.argument<String>("variable"),
                    chapterUrl = reqString(call, "chapterUrl"),
                    chapterTitle = call.argument<String>("chapterTitle"),
                    chapterIndex = call.argument<Int>("chapterIndex") ?: 0,
                    chapterVariable = call.argument<String>("chapterVariable"),
                    nextChapterUrl = call.argument<String>("nextChapterUrl"),
                    applyReplace = call.argument<Boolean>("applyReplace") ?: false
                )
            }

            "resolveImageRequest" -> launchEngine(result) {
                LegadoEngine.resolveImageRequest(
                    origin = reqString(call, "origin"),
                    url = reqString(call, "url")
                )
            }

            // ---- Management plane (P5.6, legado/LegadoManage.kt) ----

            "checkSources" -> {
                val taskId = call.argument<Int>("taskId")
                if (taskId == null) {
                    result.error("UNKNOWN", "checkSources needs taskId", null)
                    return
                }
                val sourceUrls = call.argument<List<*>>("sourceUrls")
                    ?.filterIsInstance<String>()
                runCatching {
                    taskJobs[taskId] = LegadoManage.checkSources(
                        taskId, sourceUrls
                    ) { event -> emitTaskEvent(event) }
                    result.success(mapOf("taskId" to taskId))
                }.onFailure { e ->
                    result.error(legadoErrorCode(e), e.message ?: e.toString(), null)
                }
            }

            "cacheChapters" -> {
                val taskId = call.argument<Int>("taskId")
                if (taskId == null) {
                    result.error("UNKNOWN", "cacheChapters needs taskId", null)
                    return
                }
                runCatching {
                    taskJobs[taskId] = LegadoEngine.startCacheChapters(
                        taskId = taskId,
                        origin = call.argument<String>("origin") ?: "",
                        bookUrl = call.argument<String>("bookUrl") ?: "",
                        tocUrl = call.argument<String>("tocUrl"),
                        name = call.argument<String>("name"),
                        author = call.argument<String>("author"),
                        variable = call.argument<String>("variable"),
                        fromIndex = call.argument<Int>("fromIndex") ?: 0,
                        toIndex = call.argument<Int>("toIndex") ?: 0
                    ) { event -> emitTaskEvent(event) }
                    result.success(mapOf("taskId" to taskId))
                }.onFailure { e ->
                    result.error(legadoErrorCode(e), e.message ?: e.toString(), null)
                }
            }

            "getCachedChapterIndexes" -> launchEngine(result) {
                mapOf(
                    "indexes" to LegadoEngine.getCachedChapterIndexes(
                        origin = call.argument<String>("origin") ?: "",
                        bookUrl = call.argument<String>("bookUrl") ?: "",
                        tocUrl = call.argument<String>("tocUrl"),
                        name = call.argument<String>("name"),
                        author = call.argument<String>("author"),
                        variable = call.argument<String>("variable")
                    )
                )
            }

            "clearBookCache" -> launchEngine(result) {
                LegadoEngine.clearBookCache(
                    origin = call.argument<String>("origin") ?: "",
                    bookUrl = call.argument<String>("bookUrl") ?: "",
                    tocUrl = call.argument<String>("tocUrl"),
                    name = call.argument<String>("name"),
                    author = call.argument<String>("author"),
                    variable = call.argument<String>("variable")
                )
                mapOf("cleared" to true)
            }

            "listSubscriptions" -> launchEngine(result) {
                LegadoManage.listSubscriptions()
            }

            "upsertSubscription" -> launchEngine(result) {
                LegadoManage.upsertSubscription(argsMap(call))
            }

            "deleteSubscription" -> launchEngine(result) {
                val id = (call.argument<Number>("id"))?.toLong() ?: 0L
                mapOf("ok" to LegadoManage.deleteSubscription(id))
            }

            "updateSubscription" -> launchEngine(result) {
                val id = (call.argument<Number>("id"))?.toLong() ?: 0L
                LegadoManage.updateSubscription(id)
            }

            "updateAllSubscriptions" -> {
                val taskId = call.argument<Int>("taskId")
                if (taskId == null) {
                    result.error("UNKNOWN", "updateAllSubscriptions needs taskId", null)
                    return
                }
                val onlyDue = call.argument<Boolean>("onlyDue") ?: false
                runCatching {
                    taskJobs[taskId] = LegadoManage.updateAllSubscriptions(
                        taskId, onlyDue
                    ) { event -> emitTaskEvent(event) }
                    result.success(mapOf("taskId" to taskId))
                }.onFailure { e ->
                    result.error(legadoErrorCode(e), e.message ?: e.toString(), null)
                }
            }

            "listReplaceRules" -> launchEngine(result) {
                LegadoManage.listReplaceRules()
            }

            "upsertReplaceRule" -> launchEngine(result) {
                LegadoManage.upsertReplaceRule(argsMap(call))
            }

            "deleteReplaceRule" -> launchEngine(result) {
                val id = (call.argument<Number>("id"))?.toLong() ?: 0L
                mapOf("ok" to LegadoManage.deleteReplaceRule(id))
            }

            "setReplaceRuleEnabled" -> launchEngine(result) {
                val id = (call.argument<Number>("id"))?.toLong() ?: 0L
                LegadoManage.setReplaceRuleEnabled(
                    id, call.argument<Boolean>("enabled") ?: true
                )
                mapOf("ok" to true)
            }

            "getBookByUrl" -> launchEngine(result) {
                LegadoManage.getBookByUrl(reqString(call, "url"))
            }

            "getChineseConverterType" -> launchEngine(result) {
                mapOf("type" to LegadoManage.getChineseConverterType())
            }

            "setChineseConverterType" -> launchEngine(result) {
                LegadoManage.setChineseConverterType(
                    call.argument<Int>("type") ?: 0
                )
                mapOf("ok" to true)
            }

            else -> result.notImplemented()
        }
    }

    /** Runs an engine operation and delivers its result on the main thread. */
    private fun launchEngine(result: MethodChannel.Result, block: suspend () -> Any?) {
        LegadoEngine.scope.launch {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: CancellationException) {
                mainHandler.post {
                    result.error("CANCELLED", e.message ?: "cancelled", null)
                }
            } catch (e: Throwable) {
                mainHandler.post {
                    result.error(legadoErrorCode(e), e.message ?: e.toString(), null)
                }
            }
        }
    }

    private fun reqString(call: MethodCall, key: String): String =
        call.argument<String>(key)
            ?: throw LegadoBridgeException("UNKNOWN", "missing argument: $key")

    /** A string->string argument map (login form data); absent = empty. */
    private fun stringMapArg(call: MethodCall, key: String): Map<String, String> {
        val raw = call.argument<Map<*, *>>(key) ?: return emptyMap()
        return raw.entries.associate { (k, v) ->
            k.toString() to (v?.toString() ?: "")
        }
    }

    /** The whole arguments object as a string-keyed map (DTO-shaped
     *  calls like upsertSubscription send their toMap() as arguments). */
    private fun argsMap(call: MethodCall): Map<String, Any?> {
        val raw = call.arguments as? Map<*, *> ?: return emptyMap()
        return raw.entries.associate { (k, v) -> k.toString() to v }
    }

    // ------------------------------------------------------------------
    // Search sessions
    // ------------------------------------------------------------------

    private suspend fun startSearch(
        taskId: Int,
        keyword: String,
        scopeArg: Map<*, *>?,
        precision: Boolean
    ) {
        if (!LegadoEngine.isInitialized) {
            throw LegadoBridgeException("ENGINE_NOT_INIT", "Legado engine not initialized")
        }
        searchSessions.remove(taskId)?.shutdown()
        // SearchModel snapshots the precision flag from AppConfig at start.
        io.legado.app.help.config.AppConfigProviders.get().setPrecisionSearch(precision)

        val dao = LegadoEngine.db.bookSourceDao
        val group = scopeArg?.get("group") as? String
        val sourceUrls = (scopeArg?.get("sourceUrls") as? List<*>)
            ?.filterIsInstance<String>()
            ?.takeIf { it.isNotEmpty() }
        val scopes: List<SearchScope> = when {
            sourceUrls != null -> {
                // The DAO lookup is an exact-string match, so a
                // trailing slash / stray whitespace in the stored
                // URL used to silently drop an imported source from
                // every search ("imported fine, never searched").
                // Normalise before lookup, and report every URL
                // that still misses instead of dropping it quietly:
                // the Dart side already surfaces searchError events
                // per source, so "导入成功、搜索不到" becomes a
                // named failure instead of an empty result.
                val resolved = arrayListOf<SearchScope>()
                for (rawUrl in sourceUrls) {
                    val candidates = listOf(
                        rawUrl,
                        rawUrl.trim(),
                        rawUrl.trim().trimEnd('/'),
                    ).distinct()
                    val source = candidates.firstNotNullOfOrNull { candidate ->
                        runCatching { dao.getBookSource(candidate) }.getOrNull()
                    }
                    if (source != null) {
                        resolved += SearchScope(source)
                    } else {
                        emitSearchEvent(
                            mapOf(
                                "type" to "searchError",
                                "taskId" to taskId,
                                "sourceUrl" to rawUrl,
                                "errorCode" to "UNKNOWN_SOURCE",
                                "message" to "书源未在引擎库中命中，请重新导入该书源"
                            )
                        )
                    }
                }
                resolved
            }

            group != null -> listOf(SearchScope(group))
            else -> listOf(SearchScope(""))
        }

        val session = LegadoSearchSession(taskId, keyword, scopes) { event ->
            emitSearchEvent(event)
        }
        searchSessions[taskId] = session
        session.start()
    }

    private fun cancelSearchTask(taskId: Int) {
        val session = searchSessions.remove(taskId) ?: return
        session.cancelByUser()
        emitSearchEvent(
            mapOf("type" to "searchCancel", "taskId" to taskId)
        )
    }

    private fun emitSearchEvent(event: Map<String, Any?>) {
        mainHandler.post { searchSink?.success(event) }
    }

    /** Task-channel events (source checks, subscription updates). */
    private fun emitTaskEvent(event: Map<String, Any?>) {
        mainHandler.post { taskSink?.success(event) }
    }

    private companion object {
        const val TAG = "LegadoEnginePlugin"
        const val METHOD_CHANNEL = "org.mewx.wenku8/legado_engine"
        const val SEARCH_EVENTS_CHANNEL = "org.mewx.wenku8/legado_search_events"
        const val TASK_EVENTS_CHANNEL = "org.mewx.wenku8/legado_task_events"
    }
}

/** fix3: upper bound for one retried search unit (warm-up solve window
 *  plus the retried page request) before the session gives up on it. */
private const val RETRY_WATCHDOG_MS = 90_000L

/** fix4: a search unit that reports NOTHING for this long is dead,
 *  not slow. SearchModel caps every page request at
 *  AppConst.timeLimit (15s), so a live unit always calls back within
 *  that budget; 30s of total silence means its flow died without a
 *  terminal callback — which the fork's flow plumbing makes possible
 *  (see the session watchdog). */
private const val UNIT_SILENCE_MS = 30_000L
private const val WATCHDOG_TICK_MS = 5_000L

/**
 * One Dart search task, fanned out over one engine [SearchModel] per scope
 * unit (a single all/group scope, or one model per explicitly listed
 * source). Snapshots are re-emitted as the concatenation of the units'
 * latest aggregates; the Dart side performs cross-source merge/dedupe.
 * A search "round" (initial search or one load-more) finishes when every
 * unit has reported finish once; per-unit cancel (e.g. empty scope) counts
 * as finishing that unit.
 */
private class LegadoSearchSession(
    private val taskId: Int,
    private val keyword: String,
    private val scopes: List<SearchScope>,
    private val emit: (Map<String, Any?>) -> Unit
) {
    private val models = mutableListOf<SearchModel>()
    private val unitBooks = ConcurrentHashMap<Int, List<SearchBook>>()
    private val unitGroups = ConcurrentHashMap<Int, List<SourceSearchGroup>>()
    private val unitHasMore = ConcurrentHashMap<Int, Boolean>()
    private val unitFinished = ConcurrentHashMap<Int, Boolean>()

    /** Per-unit failures captured from onSearchCancel (engine semantics
     *  swallow them into a silent zero-result unit otherwise). */
    private val unitErrors = ConcurrentHashMap<Int, Map<String, Any?>>()

    /** Units that already used their one automatic retry this round
     *  (fix3 — see the retry in onSearchCancel). */
    private val unitRetried = ConcurrentHashMap<Int, Boolean>()

    /** fix4: when the current round started (wall clock); anchors the
     *  challenge-signal window and the silence math. */
    private val roundStartedAtMs = AtomicLong(0)

    /** fix4: last sign of life per unit (any model callback). A unit
     *  whose flow died silently never calls back again; the watchdog
     *  below is what notices. */
    private val unitLastActivityMs = ConcurrentHashMap<Int, Long>()
    private var watchdogJob: Job? = null
    private val finishedCount = AtomicInteger(0)
    private val roundFinishEmitted = AtomicBoolean(false)
    private val active = AtomicBoolean(true)

    fun start() {
        if (scopes.isEmpty()) {
            // No Dart-passed source URL resolved against the DB. Say so
            // explicitly instead of faking a clean empty result.
            val message = "搜索范围为空：书源未在引擎库中命中"
            LegadoEngine.recordBridgeError(
                "searchStart", IllegalStateException(message)
            )
            emit(
                mapOf(
                    "type" to "searchError",
                    "taskId" to taskId,
                    "sourceUrl" to null,
                    "errorCode" to "EMPTY_SCOPE",
                    "message" to message
                )
            )
            emit(
                mapOf(
                    "type" to "searchFinish",
                    "taskId" to taskId,
                    "isEmpty" to true,
                    "hasMore" to false
                )
            )
            return
        }
        scopes.forEachIndexed { index, scope ->
            models += SearchModel(LegadoEngine.scope, callbackFor(index, scope))
        }
        beginRound()
        LegadoEngine.scope.launch {
            models.forEach { model ->
                runCatching { model.search(taskId.toLong(), keyword) }
            }
        }
    }

    fun loadMore() {
        if (!active.get()) return
        unitFinished.clear()
        unitErrors.clear()
        unitRetried.clear()
        finishedCount.set(0)
        roundFinishEmitted.set(false)
        beginRound()
        LegadoEngine.scope.launch {
            models.forEach { model ->
                runCatching { model.search(taskId.toLong(), keyword) }
            }
        }
    }

    /** fix4: (re)arms the per-round bookkeeping and the silence
     *  watchdog. */
    private fun beginRound() {
        val now = System.currentTimeMillis()
        roundStartedAtMs.set(now)
        unitLastActivityMs.clear()
        for (unit in scopes.indices) unitLastActivityMs[unit] = now
        watchdogJob?.cancel()
        watchdogJob = LegadoEngine.scope.launch {
            while (active.get() && !roundFinishEmitted.get()) {
                delay(WATCHDOG_TICK_MS)
                checkSilentUnits()
            }
        }
    }

    private fun touchUnit(unit: Int) {
        unitLastActivityMs[unit] = System.currentTimeMillis()
    }

    /**
     * fix4 watchdog pass. Why a unit can die silently: the fork's
     * SearchModel runs each source's page request inside
     * `withTimeout(AppConst.timeLimit)` in a flow whose terminal
     * operators are `onCompletion { if (it == null) onSearchFinish }`
     * and `.catch { onSearchCancel }`. A timeout surfaces as
     * TimeoutCancellationException — a CancellationException — and a
     * flow's `.catch` never observes cancellation, while
     * `onCompletion` sees a non-null cause and stays quiet too. The
     * unit therefore fires NEITHER terminal callback: fix3's retry
     * (hung off onSearchCancel) never runs, and the round's finish
     * never emits. Multi-source searches made this likely rather
     * than rare: every source's model shares the device at once, so
     * a shielded source's request — whose Cloudflare solve alone can
     * need most of the 15s budget — is exactly the one that times
     * out; alone, with the device to itself, it squeaks through.
     *
     * A unit silent for [UNIT_SILENCE_MS] gets the treatment fix3
     * gave hard failures: one warm-up + restart for a source unit
     * (its retried attempt is then owned by warmUpAndRestart's own
     * watchdog), or an immediate finish for a scope unit that has no
     * single source to restart. User cancel still wins: the loop
     * stops with the session.
     */
    private fun checkSilentUnits() {
        if (!active.get() || roundFinishEmitted.get()) return
        val now = System.currentTimeMillis()
        for (unit in scopes.indices) {
            if (unitFinished[unit] == true) continue
            // A retry is already in flight for this unit; its own
            // post-restart watchdog (RETRY_WATCHDOG_MS) owns it.
            if (unitRetried[unit] == true) continue
            val last = unitLastActivityMs[unit] ?: roundStartedAtMs.get()
            if (now - last < UNIT_SILENCE_MS) continue
            val scope = scopes[unit]
            val sourceUrl = if (scope.isSource()) {
                scope.toString().substringAfter("::")
            } else {
                ""
            }
            if (keyword.isNotEmpty() &&
                sourceUrl.isNotEmpty() &&
                models.getOrNull(unit) != null &&
                unitRetried.put(unit, true) == null
            ) {
                LegadoEngine.recordBridgeError(
                    "searchUnitSilent",
                    IllegalStateException("源单元静默超时，预热重试: $sourceUrl")
                )
                unitErrors[unit] = mapOf(
                    "sourceUrl" to sourceUrl,
                    "errorCode" to "SilentUnitTimeout",
                    "message" to "搜索超时（无返回）"
                )
                touchUnit(unit)
                warmUpAndRestart(unit, sourceUrl)
            } else {
                markUnitFinished(unit)
            }
        }
    }

    /**
     * fix4: a unit that finished CLEANLY with zero books may never
     * have searched at all — behind a Cloudflare shield, the
     * challenge interstitial can be parsed by the source's own rules
     * as an empty book list: no exception, no books, nothing for
     * fix3's failure retry to hang on. If this unit's host was
     * actually challenged during THIS round (the host interceptor
     * records every challenge it solves — see
     * [LegadoChallengeSignals]) and the unit still came back empty,
     * give it the same one warm-up + restart a failed unit gets,
     * before its finish is allowed to close the unit.
     */
    private fun maybeRetryChallengedZero(unit: Int, scope: SearchScope): Boolean {
        if (!active.get() || keyword.isEmpty() || !scope.isSource()) {
            return false
        }
        if ((unitBooks[unit]?.size ?: 0) > 0) return false
        if (unitRetried[unit] == true) return false
        val sourceUrl = scope.toString().substringAfter("::")
        if (sourceUrl.isEmpty() || models.getOrNull(unit) == null) {
            return false
        }
        val host = runCatching { java.net.URI(sourceUrl).host }.getOrNull()
            ?: return false
        if (!LegadoChallengeSignals.challengedSince(
                host,
                roundStartedAtMs.get()
            )
        ) {
            return false
        }
        if (unitRetried.put(unit, true) != null) return false
        touchUnit(unit)
        warmUpAndRestart(unit, sourceUrl)
        return true
    }

    fun restartSource(sourceUrl: String) {
        if (!active.get()) return
        models.forEach { runCatching { it.restartSource(sourceUrl) } }
    }

    /** User-initiated cancel: stop everything; the plugin emits searchCancel. */
    fun cancelByUser() {
        active.set(false)
        watchdogJob?.cancel()
        models.forEach { runCatching { it.cancelSearch() } }
        models.forEach { runCatching { it.close() } }
    }

    fun shutdown() {
        active.set(false)
        watchdogJob?.cancel()
        models.forEach { runCatching { it.close() } }
    }

    private fun callbackFor(unit: Int, scope: SearchScope) = object : SearchModel.CallBack {
        override fun getSearchScope(): SearchScope = scope

        override fun onSearchStart() {
            touchUnit(unit)
        }

        override fun onSearchSuccess(searchBooks: List<SearchBook>) {
            if (!active.get()) return
            touchUnit(unit)
            unitBooks[unit] = searchBooks
            emitSnapshot()
        }

        override fun onSearchGroupsChanged(groups: List<SourceSearchGroup>) {
            if (!active.get()) return
            touchUnit(unit)
            unitGroups[unit] = groups
            emitSnapshot()
        }

        override fun onSearchFinish(isEmpty: Boolean, hasMore: Boolean) {
            touchUnit(unit)
            unitHasMore[unit] = hasMore
            // fix4: a clean-but-empty finish from a host that served
            // a Cloudflare challenge this round is retried once
            // (warm-up + restart) before the unit is allowed to close.
            if (maybeRetryChallengedZero(unit, scope)) return
            markUnitFinished(unit)
        }

        override fun onSearchCancel(exception: Throwable?) {
            // A unit cancelling on its own (empty scope, hard failure)
            // finishes that unit; user cancel is handled by cancelByUser.
            // The SearchModel layer reports real per-source failures
            // ONLY through this callback (its flow catch), so capture
            // the exception here — dropping it is what turned every
            // engine failure into a silent "no results" on device.
            if (!active.get()) return
            if (exception != null) {
                LegadoEngine.recordBridgeError("searchUnit", exception)
                unitErrors[unit] = mapOf(
                    "sourceUrl" to if (scope.isSource()) {
                        scope.toString().substringAfter("::")
                    } else {
                        null
                    },
                    "errorCode" to exception.javaClass.simpleName,
                    "message" to exception.legadoBrief()
                )
                // fix3: ONE automatic retry per unit per round, the way
                // a Legado user re-searches a failed source by hand —
                // but first warm the source up OUTSIDE SearchModel's
                // budget. Root cause this addresses: SearchModel caps
                // every page request at AppConst.timeLimit (15s), while
                // the host Cloudflare solver's challenge window is 30s
                // (CHALLENGE_TIMEOUT_MS). A cold cf_clearance therefore
                // reliably kills a shielded source's in-session request
                // (TimeoutCancellationException, zero books), even
                // though the very same request succeeds when the
                // timeout-free self-check path runs it — the solver
                // simply never gets to finish inside the session. The
                // warm-up below is a plain GET of the source's own URL
                // through the engine's shared client (the Cloudflare
                // interceptor sits at index 0 of it and stores the
                // solved cf_clearance in the shared cookie store), so
                // the retried page request passes without a challenge.
                // Non-shielded sources just pay one homepage GET on a
                // round that had already failed. The engine itself is
                // untouched; this is session orchestration only.
                if (keyword.isNotEmpty() &&
                    scope.isSource() &&
                    unitRetried.put(unit, true) == null
                ) {
                    val sourceUrl = scope.toString().substringAfter("::")
                    if (sourceUrl.isNotEmpty() &&
                        models.getOrNull(unit) != null
                    ) {
                        warmUpAndRestart(unit, sourceUrl)
                        return // the retried attempt finishes this unit
                    }
                }
            }
            markUnitFinished(unit)
        }
    }

    /**
     * Resolves the actual search URL for [sourceUrl] (the search-URL
     * template with {{key}} / {{page}} substituted, exactly as the
     * self-check's probe does), falling back to the source homepage
     * when the source has no search URL or the template cannot be
     * resolved. Warming up the homepage alone never solved a
     * challenge that only appears on the search path / parameterised
     * search URL, which is why shielded sources kept failing their
     * retried search even after a "successful" warm-up.
     */
    private suspend fun resolveWarmUpUrl(sourceUrl: String): String {
        return runCatching {
            val source = LegadoEngine.db.bookSourceDao.getBookSource(sourceUrl)
                ?: return@runCatching sourceUrl
            val searchUrl = source.searchUrl
            if (searchUrl.isNullOrBlank()) return@runCatching sourceUrl
            val analyzeUrl = AnalyzeUrlFactories.create(
                rawUrl = searchUrl,
                baseUrl = source.bookSourceUrl,
                source = source,
                ruleData = RuleData(),
                coroutineContext = currentCoroutineContext(),
                variables = mapOf(
                    AppConst.JsVarName.KEY to keyword,
                    AppConst.JsVarName.PAGE to 1
                )
            )
            analyzeUrl.url.takeIf { it.isNotBlank() } ?: sourceUrl
        }.getOrElse { sourceUrl }
    }

    /**
     * fix3 retry worker: warm the source through the engine's own
     * client (no SearchModel timeout — the Cloudflare interceptor gets
     * its full solve window), then restart just this unit's source for
     * page 1 through the model's own restart path. A watchdog finishes
     * the unit if the restarted attempt somehow never reports back, so
     * a round can never hang on a retried unit.
     */
    private fun warmUpAndRestart(unit: Int, sourceUrl: String) {
        LegadoEngine.scope.launch {
            val warmUrl = resolveWarmUpUrl(sourceUrl)
            runCatching {
                OkHttpClientProviders.get().okHttpClient
                    .newCallStrResponse { url(warmUrl) }
            }
            if (!active.get()) return@launch
            val model = models.getOrNull(unit) ?: run {
                markUnitFinished(unit)
                return@launch
            }
            runCatching { model.restartSource(sourceUrl) }
                .onFailure { markUnitFinished(unit) }
            launch {
                delay(RETRY_WATCHDOG_MS)
                if (active.get() && unitFinished[unit] != true) {
                    LegadoEngine.recordBridgeError(
                        "searchUnitRetry",
                        IllegalStateException("重试后仍未返回: $sourceUrl")
                    )
                    markUnitFinished(unit)
                }
            }
        }
    }

    private fun markUnitFinished(unit: Int) {
        if (!active.get()) return
        val first = unitFinished.put(unit, true) == null
        if (!first) return
        if (finishedCount.incrementAndGet() >= scopes.size &&
            roundFinishEmitted.compareAndSet(false, true)
        ) {
            val isEmpty = unitBooks.values.all { it.isEmpty() }
            val hasMore = unitHasMore.values.any { it }
            // Failures first: Dart keys its error state off receiving a
            // searchError for this round before the finish lands.
            val errors = unitErrors.values.toList()
            if (errors.isNotEmpty()) {
                val head = errors.first()
                val extra = if (errors.size > 1) {
                    "（另有 ${errors.size - 1} 个书源搜索失败）"
                } else {
                    ""
                }
                emit(
                    mapOf(
                        "type" to "searchError",
                        "taskId" to taskId,
                        "sourceUrl" to head["sourceUrl"],
                        "errorCode" to head["errorCode"],
                        "message" to "${head["message"]}$extra"
                    )
                )
            }
            emit(
                mapOf(
                    "type" to "searchFinish",
                    "taskId" to taskId,
                    "isEmpty" to isEmpty,
                    "hasMore" to hasMore
                )
            )
        }
    }

    private fun emitSnapshot() {
        val books = ArrayList<SearchBook>()
        val groups = ArrayList<Map<String, Any?>>()
        for (unit in scopes.indices) {
            unitBooks[unit]?.let { books += it }
            unitGroups[unit]?.forEach { group ->
                groups += mapOf(
                    "origin" to group.source.bookSourceUrl,
                    "originName" to group.source.bookSourceName,
                    "count" to group.books.size
                )
            }
        }
        emit(
            mapOf(
                "type" to "searchSnapshot",
                "taskId" to taskId,
                "books" to books.map { LegadoDto.searchBook(it) },
                "groups" to groups,
                "hasMore" to unitHasMore.values.any { it }
            )
        )
    }
}

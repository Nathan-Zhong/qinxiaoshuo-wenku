package org.mewx.wenku8_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.legado.app.data.entities.SearchBook
import io.legado.app.model.webBook.SearchModel
import io.legado.app.model.webBook.SourceSearchGroup
import io.legado.app.ui.book.search.SearchScope
import io.legado.engine.LegadoEngineFacade
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.mewx.wenku8_flutter.legado.LegadoBridgeException
import org.mewx.wenku8_flutter.legado.LegadoDto
import org.mewx.wenku8_flutter.legado.LegadoEngine
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
 * getChapterContent, and resolveImageRequest (G7: real URL + headers
 * for source images via the engine's AnalyzeUrl). All other contract
 * methods return notImplemented.
 *
 * Threading: engine work runs on [LegadoEngine.scope] (IO); channel
 * results and event sinks are always delivered on the main thread.
 */
class LegadoEnginePlugin : FlutterPlugin {
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

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler { call, result -> onMethodCall(call, result) }
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
            sourceUrls != null -> sourceUrls.mapNotNull { url ->
                dao.getBookSource(url)?.let { SearchScope(it) }
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

    private companion object {
        const val TAG = "LegadoEnginePlugin"
        const val METHOD_CHANNEL = "org.mewx.wenku8/legado_engine"
        const val SEARCH_EVENTS_CHANNEL = "org.mewx.wenku8/legado_search_events"
        const val TASK_EVENTS_CHANNEL = "org.mewx.wenku8/legado_task_events"
    }
}

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
        finishedCount.set(0)
        roundFinishEmitted.set(false)
        LegadoEngine.scope.launch {
            models.forEach { model ->
                runCatching { model.search(taskId.toLong(), keyword) }
            }
        }
    }

    fun restartSource(sourceUrl: String) {
        if (!active.get()) return
        models.forEach { runCatching { it.restartSource(sourceUrl) } }
    }

    /** User-initiated cancel: stop everything; the plugin emits searchCancel. */
    fun cancelByUser() {
        active.set(false)
        models.forEach { runCatching { it.cancelSearch() } }
        models.forEach { runCatching { it.close() } }
    }

    fun shutdown() {
        active.set(false)
        models.forEach { runCatching { it.close() } }
    }

    private fun callbackFor(unit: Int, scope: SearchScope) = object : SearchModel.CallBack {
        override fun getSearchScope(): SearchScope = scope

        override fun onSearchStart() = Unit

        override fun onSearchSuccess(searchBooks: List<SearchBook>) {
            if (!active.get()) return
            unitBooks[unit] = searchBooks
            emitSnapshot()
        }

        override fun onSearchGroupsChanged(groups: List<SourceSearchGroup>) {
            if (!active.get()) return
            unitGroups[unit] = groups
            emitSnapshot()
        }

        override fun onSearchFinish(isEmpty: Boolean, hasMore: Boolean) {
            unitHasMore[unit] = hasMore
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
            }
            markUnitFinished(unit)
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

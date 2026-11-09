package org.mewx.wenku8_flutter.legado

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import io.legado.app.constant.AppLog
import io.legado.app.constant.EventBus
import io.legado.app.data.entities.BaseSource
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SourceUiRequest
import io.legado.app.data.entities.rule.RowUi
import io.legado.app.help.source.SourceVerificationHelpShared
import io.legado.app.help.source.WebViewLoadSpec
import io.legado.app.help.source.deriveWebViewLoadSpec
import io.legado.app.model.script.runScriptWithContext
import io.legado.app.utils.FlowBus
import io.legado.app.utils.GSON
import io.legado.app.utils.isAbsUrl
import io.legado.app.utils.toJson
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Host endpoints for source login (G3, P5.3).
 *
 * Everything semantic lives in the vendored `:data` engine, exactly as
 * in the fork: the login form definition is `BaseSource.loginUi()`
 * (RowUi rows), saved credentials are `putLoginInfo`/`getLoginInfoMap`
 * (AES-encrypted into the engine's source cache), the login header is
 * `putLoginHeader`/`getLoginHeader`, and submitting runs
 * `BaseSource.login()` (eval the source's loginUrl JS and call its
 * `login()`). This file is only the bridge surface over those calls —
 * shaped field-for-field after the fork's SourceLoginDialog
 * (rebuild/getLoginData/login/button handling) — plus the two host
 * duties the fork's `:ui` layer performed:
 *
 * - the JS-triggered path: `BaseSource.showLoginDialog()` emits
 *   `SourceUiRequest.Login` on the FlowBus and parks the JS thread in
 *   `SourceVerificationHelpShared.awaitLoginFinished` (up to 30 min).
 *   [LegadoLoginEventBridge] is the host's SourceUiEventBridgeHost: it
 *   consumes the event, dispatches like the fork's showSourceLogin
 *   (form -> Dart sheet, URL -> login WebView, JS-only -> login()),
 *   and calls `notifyLoginFinished` when the login UI closes — the
 *   fork signals exactly there (the overlay's onDispose).
 * - the web-login window: the fork opens a full-screen WebView with
 *   isLogin semantics (toolbar confirm = sync cookies + reload, close
 *   = login finished). Ours is the P5.2 [LegadoBrowserActivity] with
 *   `resultMode = "login"` (see LegadoBrowserRequest).
 *
 * Credentials only ever travel Dart -> this bridge -> the engine's
 * own encrypted store. Nothing here logs them; the self-check reports
 * counts and flags only.
 */

/** Process-wide host state for the login surface (set at engine init). */
object LegadoLoginHost {
    @Volatile
    var appContext: Context? = null
}

object LegadoLogin {

    // ------------------------------------------------------------------
    // Form definition + saved values (fork SourceLoginDialog.rebuild)
    // ------------------------------------------------------------------

    /**
     * The login form for one source: parsed RowUi rows, the values the
     * fork's dialog would prefill from the saved login info, and the
     * login kind — `form` (rows exist), `web` (loginUrl is a page to
     * open), `js` (loginUrl is a script with no form), or `none`.
     * The web URL is the only loginUrl form ever sent to Dart; JS
     * login text never leaves the engine.
     */
    fun loginData(source: BookSource): Map<String, Any?> {
        val rows = runCatching { source.loginUi() }.getOrElse { e ->
            LegadoEngine.recordBridgeError("loginUi:${source.bookSourceUrl}", e)
            null
        }.orEmpty()
        val info = source.getLoginInfoMap()
        // Fork rebuild(): text/password prefilled from saved info,
        // select snapped to the saved option (default first), toggle
        // to the saved "true"/"false".
        val values = LinkedHashMap<String, String>()
        for (row in rows) {
            when (row.type) {
                RowUi.Type.text, RowUi.Type.password ->
                    values[row.name] = info?.get(row.name) ?: ""

                RowUi.Type.select -> {
                    val chars = row.chars ?: emptyList()
                    val idx = chars.indexOf(info?.get(row.name)).coerceAtLeast(0)
                    values[row.name] = chars.getOrElse(idx) { "" }
                }

                RowUi.Type.toggle ->
                    values[row.name] = (info?.get(row.name) == "true").toString()
            }
        }
        val loginUrl = source.loginUrl
        val kind = when {
            rows.isNotEmpty() -> "form"
            loginUrl.isNullOrBlank() -> "none"
            loginUrl.isAbsUrl() -> "web"
            else -> "js"
        }
        return mapOf(
            "sourceUrl" to source.bookSourceUrl,
            "sourceName" to source.bookSourceName,
            "kind" to kind,
            "loginUrl" to if (kind == "web") loginUrl else null,
            "rows" to rows.map { row ->
                mapOf(
                    "name" to row.name,
                    "type" to row.type,
                    "action" to row.action,
                    "chars" to (row.chars ?: emptyList()),
                    "flexBasisPercent" to
                        (row.style?.layout_flexBasisPercent?.toDouble() ?: 0.0)
                )
            },
            "values" to values,
            "hasLoginInfo" to (info != null),
            "hasLoginHeader" to (source.getLoginHeader() != null)
        )
    }

    /** Batch login-state probe for the management list (flags only). */
    fun loginStates(sources: List<BookSource>): Map<String, Boolean> =
        sources.associate { source ->
            source.bookSourceUrl to
                (source.getLoginInfoMap() != null ||
                    source.getLoginHeader() != null)
        }

    // ------------------------------------------------------------------
    // Submit / button / logout (fork SourceLoginDialog handlers)
    // ------------------------------------------------------------------

    /**
     * Fork confirm semantics, one-to-one: an empty data map removes
     * the saved login info and runs nothing; otherwise the info is
     * saved first and `login()` runs after — a save failure aborts
     * before any JS, and a login() failure propagates (the Dart sheet
     * stays open and shows the message, as the fork dialog does).
     */
    suspend fun login(
        source: BookSource,
        data: Map<String, String>
    ): Map<String, Any?> {
        if (data.isEmpty()) {
            source.removeLoginInfo()
            return mapOf("ok" to true, "removed" to true)
        }
        if (!source.putLoginInfo(GSON.toJson(data))) {
            throw LegadoBridgeException("UNKNOWN", "保存登录信息失败")
        }
        runScriptWithContext { source.login() }
        return mapOf("ok" to true, "removed" to false)
    }

    /**
     * Fork button-row semantics: an absolute-URL action opens a
     * browser (the fork hands it to the platform — ACTION_VIEW here,
     * the internal browser as fallback); any other action is JS,
     * evaluated as `loginJs + action` with the dialog's bindings —
     * `result` = a supplier of the CURRENT form data (evaluated when
     * the script reads it, i.e. the values as of this click, which is
     * what the Dart side just sent), `book`/`chapter` null (the
     * management surface has no reading context; the fork fills them
     * only when a book/chapter opened the dialog). Select/toggle
     * changes run through this same path in the fork.
     */
    suspend fun runLoginAction(
        source: BookSource,
        action: String,
        data: Map<String, String>
    ): Map<String, Any?> {
        if (action.isAbsUrl()) {
            openActionUrl(source, action)
            return mapOf("ok" to true, "opened" to "browser")
        }
        val loginJs = source.getLoginJs() ?: ""
        runScriptWithContext {
            source.evalJS("$loginJs\n$action") {
                put("result", { HashMap(data) })
                put("book", null)
                put("chapter", null)
            }
        }
        return mapOf("ok" to true)
    }

    /**
     * Logout = the fork's two removal paths composed (its dialog
     * removes the info on empty submit and the header from its menu):
     * saved credentials AND the login header (with its cookies) go.
     */
    fun logout(source: BookSource) {
        source.removeLoginInfo()
        source.removeLoginHeader()
    }

    // ------------------------------------------------------------------
    // Opening login (fork showSourceLogin dispatch)
    // ------------------------------------------------------------------

    /**
     * The Dart-initiated entry from the management page. Form sources
     * are answered `form` — the Dart side opens the login sheet itself
     * (it already holds the client); web sources open the login
     * WebView here; JS-only sources run `login()` here (its script
     * drives any browser/captcha through the P5.2 channels).
     */
    suspend fun openSourceLogin(source: BookSource): Map<String, Any?> {
        val rows = runCatching { source.loginUi() }.getOrNull()
        val loginUrl = source.loginUrl
        return when {
            !rows.isNullOrEmpty() -> mapOf("kind" to "form")
            loginUrl.isNullOrBlank() -> mapOf("kind" to "none")
            loginUrl.isAbsUrl() -> {
                openLoginWebView(source)
                mapOf("kind" to "web")
            }

            else -> {
                runScriptWithContext { source.login() }
                mapOf("kind" to "js")
            }
        }
    }

    /**
     * Opens the login WebView for [source] (fork openLoginWebView):
     * load spec derived with isLogin = true, cookies synced both ways
     * by the Activity, close signals login-finished (resultMode
     * "login"). Returns false when the Activity could not be started
     * at all — the caller then owns waking any login waiter itself.
     */
    suspend fun openLoginWebView(source: BaseSource): Boolean {
        val url = source.loginUrl?.takeIf { it.isAbsUrl() } ?: return false
        val spec = runCatching {
            deriveWebViewLoadSpec(
                url = url,
                isLogin = true,
                sourceKey = source.getKey(),
                sourceType = source.getSourceType(),
                coroutineContext = currentCoroutineContext(),
            )
        }.getOrElse { e ->
            LegadoEngine.recordBridgeError("loginWeb.spec", e)
            WebViewLoadSpec(
                baseUrl = url,
                headerMap = runCatching { source.getHeaderMap(true) }
                    .getOrElse { emptyMap() },
                html = null,
            )
        }
        val token = LegadoBrowserHost.stash(
            LegadoBrowserRequest(
                sourceKey = source.getKey(),
                sourceName = source.getTag(),
                sourceType = source.getSourceType(),
                url = url,
                title = "登录",
                saveResult = false,
                refetchAfterSuccess = false,
                asBottomSheet = false,
                spec = spec,
                resultMode = LegadoBrowserRequest.RESULT_LOGIN,
            )
        )
        return startBrowserActivity(token)
    }

    /** A button row's URL action: system browser, internal fallback. */
    private suspend fun openActionUrl(source: BookSource, url: String) {
        val activity = LegadoUiHost.activity
        val context = activity ?: LegadoLoginHost.appContext ?: return
        val launched = runCatching {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                if (activity == null) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            true
        }.getOrElse { false }
        if (!launched) {
            // No system browser took it: fall back to the internal
            // browser with NO result hand-back (an auxiliary page —
            // closing it must not touch verification or login waits).
            val spec = runCatching {
                deriveWebViewLoadSpec(
                    url = url,
                    isLogin = false,
                    sourceKey = source.getKey(),
                    sourceType = source.getSourceType(),
                    coroutineContext = currentCoroutineContext(),
                )
            }.getOrElse {
                WebViewLoadSpec(
                    baseUrl = url,
                    headerMap = runCatching { source.getHeaderMap(true) }
                        .getOrElse { emptyMap() },
                    html = null,
                )
            }
            val token = LegadoBrowserHost.stash(
                LegadoBrowserRequest(
                    sourceKey = source.getKey(),
                    sourceName = source.getTag(),
                    sourceType = source.getSourceType(),
                    url = url,
                    title = source.getTag(),
                    saveResult = false,
                    refetchAfterSuccess = false,
                    asBottomSheet = false,
                    spec = spec,
                    resultMode = LegadoBrowserRequest.RESULT_NONE,
                )
            )
            startBrowserActivity(token)
        }
    }

    /**
     * Starts [LegadoBrowserActivity] for a stashed request token and
     * reports whether the launch actually happened (runOnMain posts
     * when off the main thread, so the result is delivered through a
     * continuation rather than read back synchronously).
     */
    internal suspend fun startBrowserActivity(token: String): Boolean =
        suspendCancellableCoroutine { continuation ->
            LegadoBackstageWebView.runOnMain {
                val activity = LegadoUiHost.activity
                val context = activity ?: LegadoLoginHost.appContext
                val launched = if (context == null) {
                    LegadoBrowserHost.discard(token)
                    false
                } else {
                    val intent = Intent(
                        context, LegadoBrowserActivity::class.java
                    ).apply {
                        putExtra(LegadoBrowserActivity.EXTRA_TOKEN, token)
                        if (activity == null) {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                    }
                    runCatching {
                        context.startActivity(intent)
                        true
                    }.getOrElse { e ->
                        LegadoBrowserHost.discard(token)
                        LegadoEngine.recordBridgeError("loginWeb.launch", e)
                        false
                    }
                }
                if (continuation.isActive) continuation.resume(launched)
            }
        }
}

/**
 * The fork's SourceUiEventBridgeHost, host edition: a standing
 * collector of the FlowBus SOURCE_UI_REQUEST channel. Only
 * [SourceUiRequest.Login] is consumed here (verification codes arrive
 * through the VerificationUiProvider instead, and source-variable
 * dialogs have no Dart surface yet). Each request is handled in its
 * own coroutine so the collector keeps draining while a login sheet
 * is open.
 */
object LegadoLoginEventBridge {
    private val started = AtomicBoolean(false)

    @Volatile
    var running: Boolean = false
        private set

    fun start(scope: CoroutineScope) {
        if (!started.compareAndSet(false, true)) return
        running = true
        scope.launch {
            FlowBus.with(EventBus.SOURCE_UI_REQUEST).collect { event ->
                if (event is SourceUiRequest.Login) {
                    // The collect block has no scope receiver; child
                    // work goes on the engine scope explicitly.
                    scope.launch { handleLoginRequest(event.source) }
                }
            }
        }
    }

    /**
     * Dispatches one JS-requested login like the fork's
     * showSourceLogin, then wakes the parked JS thread — the fork
     * wakes it from the login UI's dispose, which is why the web
     * branch defers the wake to the browser Activity (it owns the
     * login-finished signal in resultMode "login") and every other
     * branch wakes here, including failures: a JS thread must never
     * park for the full 30 minutes because a dialog could not open.
     */
    private suspend fun handleLoginRequest(source: BaseSource) {
        val key = source.getKey()
        var browserOwnsWake = false
        try {
            val bookSource = source as? BookSource
            val rows = runCatching { source.loginUi() }.getOrNull()
            val loginUrl = source.loginUrl
            when {
                bookSource != null && !rows.isNullOrEmpty() ->
                    showLoginFormViaDart(bookSource)

                !loginUrl.isNullOrBlank() && loginUrl.isAbsUrl() ->
                    browserOwnsWake = LegadoLogin.openLoginWebView(source)

                bookSource != null && !loginUrl.isNullOrBlank() ->
                    runScriptWithContext { bookSource.login() }

                else -> Unit // no login surface for this source kind
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            LegadoEngine.recordBridgeError("sourceLoginUi", e)
            AppLog.put("弹出书源登录界面失败\n${e.message}", e)
        } finally {
            if (!browserOwnsWake) {
                SourceVerificationHelpShared.notifyLoginFinished(key)
            }
        }
    }

    /**
     * Asks Dart to show the login sheet and suspends until it closes
     * (any outcome — submit, dismiss, or no UI at all — counts as
     * closed; the fork's waiter only needs the close signal). Channel
     * iteration mirrors the captcha path: a channel whose Dart side
     * has no handler answers notImplemented and the next is tried.
     */
    private suspend fun showLoginFormViaDart(source: BookSource) {
        val args = mapOf(
            "sourceKey" to source.getKey(),
            "sourceName" to source.getTag(),
            "sourceType" to source.getSourceType(),
            "origin" to source.bookSourceUrl,
        )
        suspendCancellableCoroutine { continuation ->
            Handler(Looper.getMainLooper()).post {
                invokeLoginOnChannel(
                    LegadoUiHost.channelSnapshot(), 0, args
                ) { if (continuation.isActive) continuation.resume(Unit) }
            }
        }
    }

    private fun invokeLoginOnChannel(
        channels: List<MethodChannel>,
        index: Int,
        args: Map<String, Any?>,
        done: () -> Unit,
    ) {
        if (index >= channels.size) {
            done()
            return
        }
        channels[index].invokeMethod(
            "showSourceLogin",
            args,
            object : MethodChannel.Result {
                override fun success(result: Any?) = done()

                override fun error(code: String, message: String?, details: Any?) {
                    LegadoEngine.recordBridgeError(
                        "sourceLoginUi",
                        IllegalStateException("Dart login UI error $code: $message")
                    )
                    done()
                }

                override fun notImplemented() {
                    invokeLoginOnChannel(channels, index + 1, args, done)
                }
            },
        )
    }
}

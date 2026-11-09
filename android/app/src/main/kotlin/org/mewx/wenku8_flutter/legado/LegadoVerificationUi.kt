package org.mewx.wenku8_flutter.legado

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import io.legado.app.constant.AppLog
import io.legado.app.data.entities.BaseSource
import io.legado.app.data.entities.BookSource
import io.legado.app.help.source.SourceVerificationHelpShared
import io.legado.app.help.source.VerificationUiProvider
import io.legado.app.help.source.WebViewLoadSpec
import io.legado.app.help.source.deriveWebViewLoadSpec
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch

/**
 * Host endpoints for the engine's verification UI (G1/G2, P5.2).
 *
 * The vendored `:data` engine drives every verification flow through
 * [SourceVerificationHelpShared] and calls OUT to a platform
 * [VerificationUiProvider] only for the two moments a human is needed:
 * showing an image captcha and opening a visible browser. The fork's
 * provider lives in its `:app`/`:ui` modules (not vendored); this file
 * is the host equivalent:
 *
 * - image captcha -> forwarded over the bridge MethodChannel to Dart,
 *   which renders the Wenku-styled jelly sheet (see
 *   lib/legado/legado_verification_ui.dart); the entered code comes
 *   back as the invokeMethod result and is fed into
 *   [SourceVerificationHelpShared.setResult] + `notifyResultArrived`,
 *   byte-for-byte the fork's SourceUiEventBridgeHost confirm path.
 *   Dismissal — or any failure to reach a Dart UI at all — follows the
 *   fork's `checkResult` semantics (fill an empty result and wake the
 *   waiter), so a JS thread can never park forever on a dialog that
 *   could not be shown.
 * - visible browser -> [LegadoBrowserActivity] (native Wenku-styled
 *   shell + system WebView), launched with a load spec derived by the
 *   engine's own [deriveWebViewLoadSpec]; the Activity itself performs
 *   the fork's result hand-back on close.
 *
 * The waiting protocol (locking, result cache, wakeups) all stays in
 * `:data`; nothing here re-implements it.
 */

/**
 * Bridges to the Flutter side: the method channels of every attached
 * engine (the app runs a second engine for the audio service whose
 * Dart isolate installs no UI handler — its channel answers
 * notImplemented and the provider falls through to the next one), and
 * the current foreground Activity for launching the browser.
 */
object LegadoUiHost {
    private val channels = CopyOnWriteArrayList<MethodChannel>()

    /** The current foreground Activity, set by the plugin (ActivityAware). */
    @Volatile
    var activity: Activity? = null

    fun registerChannel(channel: MethodChannel) {
        if (!channels.contains(channel)) channels.add(channel)
    }

    fun unregisterChannel(channel: MethodChannel) {
        channels.remove(channel)
    }

    fun channelSnapshot(): List<MethodChannel> = channels.toList()
}

/** One pending browser launch, handed to [LegadoBrowserActivity] by token. */
class LegadoBrowserRequest(
    val sourceKey: String,
    val sourceName: String,
    val sourceType: Int,
    val url: String,
    val title: String,
    val saveResult: Boolean,
    val refetchAfterSuccess: Boolean,
    val asBottomSheet: Boolean,
    val spec: WebViewLoadSpec,
    /**
     * What closing the browser hands back (P5.3 added the two
     * non-verification modes): [RESULT_VERIFICATION] is the P5.2
     * behaviour — fill/wake the verification result; [RESULT_LOGIN]
     * is the fork's login window — closing signals login-finished
     * (cookies were already synced on every page finish) and never
     * touches the verification slot; [RESULT_NONE] is an auxiliary
     * page (a login form's URL action) that hands back nothing.
     */
    val resultMode: String = RESULT_VERIFICATION,
    val stashedAt: Long = System.currentTimeMillis(),
) {
    companion object {
        const val RESULT_VERIFICATION = "verification"
        const val RESULT_LOGIN = "login"
        const val RESULT_NONE = "none"
    }
}

/**
 * In-memory hand-off for browser requests: the load spec can carry a
 * whole pre-fetched page body, far beyond Intent extra limits, so the
 * Intent only carries a one-shot token (the fork passes its spec
 * through in-memory navigation state the same way).
 */
object LegadoBrowserHost {
    private val pending = ConcurrentHashMap<String, LegadoBrowserRequest>()

    fun stash(request: LegadoBrowserRequest): String {
        // Opportunistic cleanup so an abandoned launch (engine went
        // away before the Activity started) cannot accumulate.
        val cutoff = System.currentTimeMillis() - STALE_MS
        pending.entries.removeIf { it.value.stashedAt < cutoff }
        val token = UUID.randomUUID().toString()
        pending[token] = request
        return token
    }

    fun take(token: String?): LegadoBrowserRequest? =
        if (token == null) null else pending.remove(token)

    fun discard(token: String) {
        pending.remove(token)
    }

    // Last browser-launch failure per source, for the login sheet
    // (bug 4): a browser that never opened wakes a waiting script
    // with the same empty result as a browser the user closed
    // without confirming, so without this the sheet cannot tell
    // "never opened" from "closed unfinished" — and the user sees
    // neither, because the launch happens in a background coroutine.
    private val launchFailures = ConcurrentHashMap<String, Long>()

    fun noteLaunchFailure(sourceKey: String) {
        launchFailures[sourceKey] = System.currentTimeMillis()
    }

    /** True when a launch failure was recorded for this source recently. */
    fun consumeLaunchFailure(
        sourceKey: String,
        withinMs: Long = 120_000,
    ): Boolean {
        val at = launchFailures.remove(sourceKey) ?: return false
        return System.currentTimeMillis() - at <= withinMs
    }

    private const val STALE_MS = 30 * 60 * 1000L
}

/** [VerificationUiProvider] host implementation (see file KDoc). */
class LegadoVerificationUiProvider(
    context: Context,
) : VerificationUiProvider {

    private val appContext: Context = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun showVerificationCodeDialog(url: String, source: BaseSource) {
        val sourceKey = source.getKey()
        AppLog.put("请求图片验证码: ${source.getTag()}")
        val args = mapOf(
            "sourceKey" to sourceKey,
            "sourceName" to source.getTag(),
            "sourceType" to source.getSourceType(),
            "origin" to (source as? BookSource)?.bookSourceUrl.orEmpty(),
            "url" to url,
        )
        mainHandler.post {
            invokeCaptchaOnChannel(LegadoUiHost.channelSnapshot(), 0, args, sourceKey)
        }
    }

    /**
     * Tries each attached engine's channel in registration order; a
     * channel whose Dart side has no handler installed answers
     * notImplemented and the next one is tried. A real error (handler
     * present but the sheet failed) is terminal.
     */
    private fun invokeCaptchaOnChannel(
        channels: List<MethodChannel>,
        index: Int,
        args: Map<String, Any?>,
        sourceKey: String,
    ) {
        if (index >= channels.size) {
            cancelVerification(sourceKey, "no Dart UI channel available")
            return
        }
        channels[index].invokeMethod(
            "showVerificationCode",
            args,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val code = result as? String
                    if (code != null) {
                        SourceVerificationHelpShared.setResult(sourceKey, code)
                        SourceVerificationHelpShared.notifyResultArrived(sourceKey)
                    } else {
                        cancelVerification(sourceKey, null)
                    }
                }

                override fun error(code: String, message: String?, details: Any?) {
                    cancelVerification(sourceKey, "Dart UI error $code: $message")
                }

                override fun notImplemented() {
                    invokeCaptchaOnChannel(channels, index + 1, args, sourceKey)
                }
            },
        )
    }

    /**
     * Fork `checkResult` semantics for a dialog that was dismissed or
     * could not be shown: fill an empty result (unless one is already
     * there) and wake the waiting thread, which then fails with
     * "验证结果为空" instead of parking forever.
     */
    private fun cancelVerification(sourceKey: String, why: String?) {
        if (why != null) {
            LegadoEngine.recordBridgeError(
                "verificationCode", IllegalStateException(why)
            )
        }
        SourceVerificationHelpShared.getResult(sourceKey)
            ?: SourceVerificationHelpShared.setResult(sourceKey, "")
        SourceVerificationHelpShared.notifyResultArrived(sourceKey)
    }

    /**
     * Tells Dart a fire-and-forget browser never opened (bug 4).
     * Best-effort: a channel whose Dart side has no handler answers
     * notImplemented and is skipped, exactly like the captcha path.
     */
    private fun notifyBrowserLaunchFailed(source: BaseSource) {
        invokeOnChannel(
            LegadoUiHost.channelSnapshot(),
            0,
            "browserLaunchFailed",
            mapOf(
                "sourceName" to source.getTag(),
                "sourceKey" to source.getKey(),
            ),
        )
    }

    private fun invokeOnChannel(
        channels: List<MethodChannel>,
        index: Int,
        method: String,
        args: Map<String, Any?>,
    ) {
        if (index >= channels.size) return
        channels[index].invokeMethod(
            method,
            args,
            object : MethodChannel.Result {
                override fun success(result: Any?) = Unit
                override fun error(
                    code: String,
                    message: String?,
                    details: Any?,
                ) = Unit

                override fun notImplemented() {
                    invokeOnChannel(channels, index + 1, method, args)
                }
            },
        )
    }

    override fun startBrowser(
        source: BaseSource,
        url: String,
        title: String,
        saveResult: Boolean?,
        refetchAfterSuccess: Boolean?,
        asBottomSheet: Boolean,
    ) {
        val sourceKey = source.getKey()
        AppLog.put("打开内置浏览器: ${source.getTag()} $url")
        LegadoEngine.scope.launch {
            // Same derivation the fork's WebViewScreen performs before
            // first paint (source headerMap, POST body prefetch, data:
            // unpack, raw-HTML detection). A derivation failure falls
            // back to a plain load of the URL with the source's own
            // header map — the browser stays usable.
            val spec = runCatching {
                deriveWebViewLoadSpec(
                    url = url,
                    isLogin = false,
                    sourceKey = sourceKey,
                    sourceType = source.getSourceType(),
                    coroutineContext = currentCoroutineContext(),
                )
            }.getOrElse { e ->
                LegadoEngine.recordBridgeError("startBrowser.spec", e)
                WebViewLoadSpec(
                    baseUrl = url,
                    headerMap = runCatching { source.getHeaderMap(true) }
                        .getOrElse { emptyMap() },
                    html = null,
                )
            }
            val token = LegadoBrowserHost.stash(
                LegadoBrowserRequest(
                    sourceKey = sourceKey,
                    sourceName = source.getTag(),
                    sourceType = source.getSourceType(),
                    url = url,
                    title = title,
                    saveResult = saveResult ?: false,
                    refetchAfterSuccess = refetchAfterSuccess ?: true,
                    asBottomSheet = asBottomSheet,
                    spec = spec,
                    // The engine calls this entry for two different
                    // things: getVerificationResult (saveResult=true,
                    // a JS thread is parked on the result) and plain
                    // java.startBrowser (saveResult=false, nobody
                    // waits — e.g. 漫蛙书源的登录按钮). A fire-and-
                    // forget browser must not use the verification
                    // mode: closing it would otherwise fill "" into
                    // the verification slot (RESULT_NONE exists
                    // exactly for pages that hand back nothing).
                    resultMode = if (saveResult == true)
                        LegadoBrowserRequest.RESULT_VERIFICATION
                    else
                        LegadoBrowserRequest.RESULT_NONE,
                )
            )
            LegadoBackstageWebView.runOnMain {
                val activity = LegadoUiHost.activity
                val intent = Intent(
                    activity ?: appContext,
                    LegadoBrowserActivity::class.java,
                ).apply {
                    putExtra(LegadoBrowserActivity.EXTRA_TOKEN, token)
                    if (activity == null) {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                }
                runCatching {
                    (activity ?: appContext).startActivity(intent)
                }.onFailure { e ->
                    LegadoBrowserHost.discard(token)
                    LegadoEngine.recordBridgeError("startBrowser.launch", e)
                    LegadoBrowserHost.noteLaunchFailure(sourceKey)
                    // A fire-and-forget browser (saveResult != true,
                    // e.g. 漫蛙书源的发布页/登录页面) has no waiting
                    // script to report through: tell Dart directly,
                    // or the tap looks dead (bug 4). An awaiting
                    // browser reports through its waiter instead —
                    // the recorded failure is what lets
                    // LegadoLogin tell the two apart — so this
                    // notification must not fire for it.
                    if (saveResult != true) {
                        notifyBrowserLaunchFailed(source)
                    }
                    // A browser that could not open must not leave a
                    // getVerificationResult waiter parked: same empty
                    // fill as a browser closed with no result.
                    SourceVerificationHelpShared.getResult(sourceKey)
                        ?: SourceVerificationHelpShared.setResult(sourceKey, "")
                    SourceVerificationHelpShared.notifyResultArrived(sourceKey)
                }
            }
        }
    }
}

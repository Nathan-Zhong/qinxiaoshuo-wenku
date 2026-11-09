package org.mewx.wenku8_flutter.legado

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.content.ContextCompat
import androidx.webkit.UserAgentMetadata
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import eu.kanade.tachiyomi.network.AndroidCookieJar
import eu.kanade.tachiyomi.network.interceptor.CHALLENGE_TIMEOUT_MS
import eu.kanade.tachiyomi.network.interceptor.COOKIE_CLEARANCE
import eu.kanade.tachiyomi.network.interceptor.ChallengeCookieResolver
import eu.kanade.tachiyomi.network.interceptor.ChallengeInterceptorBase
import eu.kanade.tachiyomi.network.interceptor.CloudflareBypassException
import io.legado.app.constant.AppLog
import io.legado.app.help.http.CookieStoreProviders
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.CookieJar
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request

/**
 * Cloudflare challenge solving for the book-source HTTP stack, G5 / P5.4.
 *
 * A same-semantics replication of the fork's `:app` network layer
 * (eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor +
 * WebViewInterceptor, and the private BookSourceChallengeCookieResolver
 * from WebBookProvidersImpl), re-hosted here because `:app` is not part
 * of the vendored AARs — the FIX2 / P5.2 replication precedent. The
 * challenge STATE MACHINE is not replicated at all: trigger detection
 * (`cf-mitigated: challenge` + `Server` header, Cloudflare's official
 * signal), the per-host dedup lock, the solve window and the
 * re-proceed-after-solve loop are the vendored `:data`
 * [ChallengeInterceptorBase] itself, so trigger/dedup/retry behaviour
 * is the fork's own binary code. This file only supplies the Android
 * solve channel the base class delegates to:
 *
 * - a throwaway headless WebView loads the challenged URL (the fork
 *   never shows a browser for this path; interactive challenges post
 *   an `interactiveBegin` message and are abandoned immediately);
 * - solved when webkit's CookieManager gains a cf_clearance whose
 *   value differs from the pre-solve one;
 * - on success the webkit cookies are merged into the engine
 *   CookieStore, and the base class re-proceeds the original request,
 *   whose CookieJar bridge then carries the new clearance — no user
 *   retry, and later requests to the same host pass silently.
 *
 * Host adaptations, behaviour-preserving:
 * - the fork's `App.instance` becomes the injected application context;
 * - the fork's `:app` `CookieStore` object (not vendored) becomes
 *   [CookieStoreProviders] (the host cookie store is registered there);
 * - the fork's `:app` WebViewUtil helpers (supportsWebView /
 *   isOutdated / setDefaultSettings / setUserAgent, incl. the
 *   Sec-CH-UA client-hints sync via androidx.webkit — declared by the
 *   host at the fork catalog's version, 1.16.0) are replicated at the
 *   bottom of this file; `LogUtils.e` becomes android.util.Log;
 * - the default UA provider is wired by [LegadoOkHttpProvider] to
 *   `UserAgentProviders.get()` exactly like the fork's
 *   WebBookProvidersImpl, so the solving WebView presents the same UA
 *   the HTTP requests carry (Cloudflare binds clearance to the UA;
 *   the fork deliberately passes the HTTP UA here, not the G11
 *   WebView UA, which serves the visible/headless content WebViews).
 */

/**
 * WebView solve channel for [ChallengeInterceptorBase] (fork:
 * eu.kanade.tachiyomi.network.interceptor.WebViewInterceptor).
 */
abstract class LegadoWebViewInterceptor(
    private val context: Context,
    private val defaultUserAgentProvider: () -> String,
) : ChallengeInterceptorBase() {

    // Preheat the WebView (the first WebSettings.getDefaultUserAgent is
    // slow; move it off the first challenged request); MIUI / Samsung
    // (API 31) preheat can crash (chromium#1279562) — skip there, only
    // the first challenge is slower. Verbatim from the fork (the
    // primary device for this app is Xiaomi, so the skip applies).
    private val initWebView by lazy {
        val manufacturer = Build.MANUFACTURER
        if (manufacturer.equals("Xiaomi", true) ||
            (Build.VERSION.SDK_INT == Build.VERSION_CODES.S && manufacturer.equals("Samsung", true))
        ) {
            return@lazy
        }

        try {
            WebSettings.getDefaultUserAgent(context)
        } catch (_: Exception) {
            // WebView/Chrome may be mid-update and throw; ignore.
        }
    }

    override fun isEngineAvailable(): Boolean = supportsWebView(context)

    override fun onEngineUnavailable() {
        AppLog.put("WebView 不可用, 无法通过 Cloudflare 挑战")
    }

    override fun prepareEngine() {
        initWebView
    }

    fun parseHeaders(headers: Headers): Map<String, String> {
        return headers
            // Unsafe headers make WebView throw net::ERR_INVALID_ARGUMENT.
            .filter { (name, value) ->
                isRequestHeaderSafe(name, value)
            }
            .groupBy(keySelector = { (name, _) -> name }) { (_, value) -> value }
            .mapValues { it.value.getOrNull(0).orEmpty() }
    }

    fun CountDownLatch.awaitChallengeWindow() {
        await(CHALLENGE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
    }

    fun createWebView(request: Request): WebView {
        return WebView(context).apply {
            setDefaultSettings()
            // An empty UA makes Chromium WebView reset to its default.
            setUserAgent(request.header("User-Agent") ?: defaultUserAgentProvider())
        }
    }
}

// Based on [IsRequestHeaderSafe] in
// https://source.chromium.org/chromium/chromium/src/+/main:services/network/public/cpp/header_util.cc
// (verbatim from the fork's WebViewInterceptor).
private fun isRequestHeaderSafe(_name: String, _value: String): Boolean {
    val name = _name.lowercase(Locale.ENGLISH)
    val value = _value.lowercase(Locale.ENGLISH)
    if (name in unsafeHeaderNames || name.startsWith("proxy-")) return false
    if (name == "connection" && value == "upgrade") return false
    return true
}

private val unsafeHeaderNames = listOf(
    "content-length", "host", "trailer", "te", "upgrade", "cookie2", "keep-alive", "transfer-encoding", "set-cookie",
)

/**
 * The Cloudflare solver (fork: eu.kanade...CloudflareInterceptor,
 * itself ported from mihon). See the file header for the two
 * deliberate deviations from upstream mihon that the fork documents
 * and this replication keeps: no early give-up based on guessing
 * whether the first loaded document "looks like" a challenge, and
 * non-GET requests solve against the site root page.
 */
class LegadoCloudflareInterceptor(
    private val context: Context,
    private val cookieResolver: ChallengeCookieResolver,
    defaultUserAgentProvider: () -> String,
) : LegadoWebViewInterceptor(context, defaultUserAgentProvider) {

    private val executor = ContextCompat.getMainExecutor(context)

    /**
     * Whether solved cookies can ride the re-sent request. When the
     * resolver is itself an OkHttp [CookieJar], OkHttp merges webkit's
     * new cf_clearance on its own; the book-source resolver is not a
     * CookieJar, so the base rule applies (the request must carry the
     * CookieJar pseudo-header for the cookie bridge to merge the
     * store's cookies in). Fork override, verbatim.
     */
    override fun canCarrySolvedCookies(request: Request): Boolean =
        cookieResolver is CookieJar || super.canCarrySolvedCookies(request)

    override fun oldClearance(request: Request): String? =
        cookieResolver.get(request.url)
            .firstOrNull { it.name == COOKIE_CLEARANCE }
            ?.value

    override fun clearClearance(request: Request) {
        cookieResolver.remove(request.url, COOKIE_NAMES, 0)
    }

    override fun solve(request: Request, oldClearance: String?) {
        // fix4: remember that this host served a Cloudflare challenge
        // just now. A search request can come back from a challenged
        // host as a cleanly-parsed EMPTY result (the interstitial
        // parsed by the source's rules) or die silently inside
        // SearchModel's 15s timeout — neither leaves an exception for
        // the search session to retry on. This timestamp is the signal
        // the session consults (see LegadoSearchSession).
        LegadoChallengeSignals.record(request.url.host)
        resolveWithWebView(request, oldClearance)
        syncCookiesToHostStore(request.url)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun resolveWithWebView(originalRequest: Request, oldClearance: String?) {
        // OkHttp has no async interceptors: park this thread until the
        // WebView solves the challenge.
        val latch = CountDownLatch(1)

        var webview: WebView? = null

        var cloudflareBypassed = false
        var isWebViewOutdated = false

        val origRequestUrl = originalRequest.url.toString()
        // WebView can only GET: non-GET requests fetch the clearance
        // from the site root page instead (the clearance covers the
        // whole site).
        val challengeUrl = if (originalRequest.method == "GET") {
            origRequestUrl
        } else {
            originalRequest.url.newBuilder().encodedPath("/").query(null).fragment(null).build().toString()
        }
        val headers = parseHeaders(originalRequest.headers)

        executor.execute {
            webview = createWebView(originalRequest)

            webview.addJavascriptInterface(
                object {
                    @Suppress("unused")
                    @JavascriptInterface
                    fun interactiveDetected() {
                        // The challenge needs human interaction and
                        // cannot be passed silently; give up at once.
                        latch.countDown()
                    }
                },
                "mihon",
            )

            webview.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    fun isCloudFlareBypassed(): Boolean {
                        return cookieResolver.get(origRequestUrl.toHttpUrl())
                            .firstOrNull { it.name == COOKIE_CLEARANCE }
                            .let { it != null && it.value != oldClearance }
                    }

                    if (isCloudFlareBypassed()) {
                        cloudflareBypassed = true
                        latch.countDown()
                        return
                    }
                    // Watch for the interactiveBegin event (an
                    // interactive challenge will never solve silently;
                    // abandon immediately instead of eating the whole
                    // solve window).
                    view.evaluateJavascript(
                        """
                            addEventListener("message", ({data}) => {
                                if (data?.source === "cloudflare-challenge" && data?.event === "interactiveBegin") {
                                    mihon.interactiveDetected();
                                }
                            })
                        """.trimIndent(),
                        null,
                    )
                }

                override fun onReceivedHttpError(
                    view: WebView?,
                    request: WebResourceRequest?,
                    errorResponse: WebResourceResponse?,
                ) {
                    // A challenge page returns 200 and never lands here;
                    // only a non-challenge main-frame error means there
                    // is nothing to wait for.
                    if (request?.isForMainFrame == true &&
                        errorResponse?.responseHeaders?.get("cf-mitigated") != "challenge"
                    ) {
                        AppLog.put(
                            "挑战求解放弃: 主文档返回非挑战错误 ${errorResponse?.statusCode}\n$challengeUrl"
                        )
                        latch.countDown()
                    }
                }
            }

            webview.loadUrl(challengeUrl, headers)
        }

        latch.awaitChallengeWindow()

        executor.execute {
            if (!cloudflareBypassed) {
                isWebViewOutdated = webview?.isOutdated() == true
            }

            webview?.run {
                stopLoading()
                destroy()
            }
        }

        // Cloudflare was not bypassed.
        if (!cloudflareBypassed) {
            if (isWebViewOutdated) {
                // Upstream shows an information_webview_outdated toast;
                // the host has no moko resources — log only (fork's
                // own stance).
                AppLog.put("系统 WebView 版本过低, 可能无法通过 Cloudflare 挑战")
            } else {
                AppLog.put("挑战求解放弃: ${CHALLENGE_TIMEOUT_MS / 1000} 秒求解窗耗尽\n$challengeUrl")
            }

            throw CloudflareBypassException()
        }
    }

    /**
     * After a successful solve, merge webkit CookieManager's cookies
     * (cf_clearance included) into the host CookieStore:
     * replaceCookie merges (same-name overwrite), so source cookies
     * are kept; both HTTP stacks read the store from there. (Fork:
     * `CookieStore.replaceCookie` on its :app singleton; host:
     * [CookieStoreProviders].)
     */
    private fun syncCookiesToHostStore(url: HttpUrl) {
        try {
            val cookieStr = CookieManager.getInstance().getCookie(url.toString()) ?: return
            CookieStoreProviders.get()?.replaceCookie(url.toString(), cookieStr)
            CookieManager.getInstance().flush()
        } catch (_: Exception) {
            // A persistence failure must not spoil this re-send; the
            // compat stack still holds the cookies in memory.
        }
    }
}

private val COOKIE_NAMES = listOf("cf_clearance")

/**
 * Book-source stack [ChallengeCookieResolver] (fork: the private
 * BookSourceChallengeCookieResolver in WebBookProvidersImpl): reads
 * and expires go through webkit's [AndroidCookieJar] (vendored), and
 * removal additionally drops the name from the engine CookieStore so
 * a stale clearance cannot be re-merged by the cookie bridge.
 */
class LegadoBookSourceChallengeCookieResolver : ChallengeCookieResolver {

    private val webkitCookieJar = AndroidCookieJar()

    override fun get(url: HttpUrl): List<okhttp3.Cookie> = webkitCookieJar.get(url)

    override fun remove(url: HttpUrl, cookieNames: List<String>?, maxAge: Int): Int {
        val removed = webkitCookieJar.remove(url, cookieNames, maxAge)
        cookieNames?.forEach {
            runCatching { CookieStoreProviders.get()?.removeCookie(url.toString(), it) }
        }
        return removed
    }
}

// ---------------------------------------------------------------------------
// WebView helpers, replicated from the fork's `:app` WebViewUtil.kt
// (itself ported from mihon; only the parts the challenge path needs).
// ---------------------------------------------------------------------------

/** Below this WebView version a JS challenge cannot solve itself. */
private const val MINIMUM_WEBVIEW_VERSION = 118

private fun supportsWebView(context: Context): Boolean {
    try {
        // No WebView installed can throw WebViewFactory$MissingWebViewPackageException.
        CookieManager.getInstance()
    } catch (_: Throwable) {
        return false
    }

    return context.packageManager.hasSystemFeature(PackageManager.FEATURE_WEBVIEW)
}

private fun WebView.isOutdated(): Boolean {
    return getWebViewMajorVersion() < MINIMUM_WEBVIEW_VERSION
}

@SuppressLint("SetJavaScriptEnabled")
private fun WebView.setDefaultSettings() {
    with(settings) {
        javaScriptEnabled = true
        domStorageEnabled = true
        useWideViewPort = true
        loadWithOverviewMode = true
        cacheMode = WebSettings.LOAD_DEFAULT

        // Challenge iframes/popups must share the main page's session.
        setSupportMultipleWindows(true)

        setSupportZoom(true)
        builtInZoomControls = true
        displayZoomControls = false
    }

    CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
}

/**
 * Sets the UA and syncs the Sec-CH-UA client hints with it; otherwise
 * the hints keep exposing the real WebView version and Cloudflare may
 * flag the environment as inconsistent when they contradict the UA.
 */
private fun WebView.setUserAgent(userAgent: String) {
    settings.userAgentString = userAgent

    if (!WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) return

    val versionMatch = CHROME_VERSION_REGEX.find(userAgent) ?: return
    val majorVersion = versionMatch.groupValues[1]
    val fullVersion = majorVersion + versionMatch.groupValues[2].ifEmpty { ".0.0.0" }

    try {
        val metadata = WebSettingsCompat.getUserAgentMetadata(settings)
        val brandVersionList = metadata.brandVersionList.map { brandVersion ->
            val brand = when (brandVersion.brand) {
                WEBVIEW_BRAND -> CHROME_BRAND
                CHROMIUM_BRAND -> CHROMIUM_BRAND
                else -> return@map brandVersion
            }

            UserAgentMetadata.BrandVersion.Builder()
                .setBrand(brand)
                .setMajorVersion(majorVersion)
                .setFullVersion(fullVersion)
                .build()
        }

        WebSettingsCompat.setUserAgentMetadata(
            settings,
            UserAgentMetadata.Builder(metadata)
                .setBrandVersionList(brandVersionList)
                .setFullVersion(fullVersion)
                .build(),
        )
    } catch (e: Exception) {
        Log.e(TAG, "setUserAgentMetadata failed: $e")
    }
}

/**
 * fix4: last-challenge timestamps per host, written by
 * [LegadoCloudflareInterceptor.solve] — which the fork's challenge
 * state machine only calls after a response actually carried
 * Cloudflare's challenge markers, so a record here means "this host
 * challenged us at this time", never a guess. Read by the search
 * session (LegadoEnginePlugin) to decide whether a zero-result or
 * silently-dead search unit deserves the warm-up + retry that fix3
 * wired to hard failures only. Process-lifetime, in-memory only.
 */
object LegadoChallengeSignals {
    private val lastChallengeAtMs = ConcurrentHashMap<String, Long>()

    fun record(host: String) {
        if (host.isNotEmpty()) {
            lastChallengeAtMs[host] = System.currentTimeMillis()
        }
    }

    /** True when [host] was challenged at or after [sinceMs]. */
    fun challengedSince(host: String, sinceMs: Long): Boolean =
        (lastChallengeAtMs[host] ?: 0L) >= sinceMs
}

private const val TAG = "WebViewUtil"
private const val WEBVIEW_BRAND = "Android WebView"
private const val CHROMIUM_BRAND = "Chromium"
private const val CHROME_BRAND = "Google Chrome"
private val CHROME_VERSION_REGEX = """Chrome/(\d+)(\.[\d.]+)?""".toRegex()

private fun WebView.getWebViewMajorVersion(): Int {
    val uaRegexMatch = """.*Chrome/(\d+)\..*""".toRegex().matchEntire(getDefaultUserAgentString())
    return if (uaRegexMatch != null && uaRegexMatch.groupValues.size > 1) {
        uaRegexMatch.groupValues[1].toInt()
    } else {
        0
    }
}

// Based on https://stackoverflow.com/a/29218966
private fun WebView.getDefaultUserAgentString(): String {
    val originalUA: String = settings.userAgentString

    // Emptying it makes the next read return the system default UA.
    settings.userAgentString = null
    val defaultUserAgentString = settings.userAgentString

    // Restore the original UA.
    settings.userAgentString = originalUA

    return defaultUserAgentString
}

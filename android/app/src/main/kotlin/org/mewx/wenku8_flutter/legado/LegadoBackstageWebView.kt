package org.mewx.wenku8_flutter.legado

import android.annotation.SuppressLint
import android.content.Context
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.util.AndroidRuntimeException
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.legado.app.constant.AppConst.timeLimit
import io.legado.app.exception.NoStackTraceException
import io.legado.app.exception.RegexTimeoutException
import io.legado.app.help.getUserAgent
import io.legado.app.help.http.BackstageWebViewFactory
import io.legado.app.help.http.BackstageWebViewHandle
import io.legado.app.help.http.BackstageWebViewProviders
import io.legado.app.help.http.CookieStoreProviders
import io.legado.app.help.http.StrResponse
import io.legado.app.utils.EscapeUtils
import io.legado.app.utils.RuleRegexes
import java.lang.ref.WeakReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeout
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Background (headless) WebView for the engine, G4 / P5.2.
 *
 * A same-semantics replication of the fork's `:app`
 * `io.legado.app.help.http.BackstageWebView` + `BackstageWebViewFactoryImpl`
 * (that module is not part of the vendored AARs, so — exactly like the
 * FIX2 BitmapImageOps precedent — the implementation is re-hosted here
 * against the vendored `:data` factory interface; engine code itself is
 * untouched). Callers are the engine's own: `AnalyzeUrlCore` webView /
 * webJs requests (e.g. 得奇's `{"webView":true}` chapter URLs and its
 * page-context XHR webJs) and the JS `webView / webViewGetSource /
 * webViewGetOverrideUrl` extensions (media sniffing included: a
 * [sourceRegex] hit or an [overrideUrlRegex] navigation hit resolves
 * the response with the sniffed URL).
 *
 * Host adaptations, behaviour-preserving:
 * - the fork's `App.instance` becomes the injected application context;
 * - `AppConfig.userAgent` becomes the [io.legado.app.help.getUserAgent]
 *   default fallback ([io.legado.app.help.UserAgentProviders.get], the
 *   host-registered UA);
 * - the fork's `CookieStore.setCookie` app singleton becomes
 *   [CookieStoreProviders] (the host cookie store is registered there);
 * - `runOnUI` / `Coroutine.async(IO)` become a main-thread Handler and
 *   this file's IO scope.
 *
 * Lifecycle: the WebView is created on the main thread, never attached
 * to a window, and destroyed on result / error / cancellation. The
 * factory caps concurrent live WebViews (see
 * [LegadoBackstageWebViewFactory]) so a parallel search cannot spawn
 * unbounded Chromium instances.
 */
class LegadoBackstageWebView(
    private val appContext: Context,
    private val url: String? = null,
    private val html: String? = null,
    private val encode: String? = null,
    private val tag: String? = null,
    private val headerMap: Map<String, String>? = null,
    private val sourceRegex: String? = null,
    private val overrideUrlRegex: String? = null,
    private val javaScript: String? = null,
    private val delayTime: Long = 1000L,
) : BackstageWebViewHandle {

    private val mHandler = Handler(Looper.getMainLooper())
    private var callback: Callback? = null
    private var mWebView: WebView? = null

    override suspend fun getStrResponse(): StrResponse = withTimeout(timeLimit) {
        suspendCancellableCoroutine { block ->
            block.invokeOnCancellation {
                runOnMain {
                    destroy()
                }
            }
            callback = object : Callback() {
                override fun onResult(response: StrResponse) {
                    if (!block.isCompleted) {
                        block.resume(response)
                    }
                }

                override fun onError(error: Throwable) {
                    if (!block.isCompleted)
                        block.resumeWithException(error)
                }
            }
            runOnMain {
                try {
                    load()
                } catch (error: Throwable) {
                    block.resumeWithException(error)
                }
            }
        }
    }

    private fun getEncoding(): String {
        return encode ?: "utf-8"
    }

    @Throws(AndroidRuntimeException::class)
    private fun load() {
        val webView = createWebView()
        mWebView = webView
        try {
            when {
                !html.isNullOrEmpty() -> if (url.isNullOrEmpty()) {
                    webView.loadData(html, "text/html", getEncoding())
                } else {
                    webView.loadDataWithBaseURL(url, html, "text/html", getEncoding(), url)
                }

                else -> if (headerMap == null) {
                    webView.loadUrl(url!!)
                } else {
                    webView.loadUrl(url!!, headerMap)
                }
            }
        } catch (e: Exception) {
            callback?.onError(e)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createWebView(): WebView {
        val webView = WebView(appContext)
        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.blockNetworkImage = true
        settings.userAgentString = headerMap.getUserAgent()
        settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
        // File access stays off (host hardening; the fork leaves the
        // platform default, which is also off since API 30, and no
        // engine path loads file:// pages through this WebView).
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        if (sourceRegex.isNullOrBlank() && overrideUrlRegex.isNullOrBlank()) {
            webView.webViewClient = HtmlWebViewClient()
        } else {
            webView.webViewClient = SnifferWebClient()
        }
        return webView
    }

    private fun destroy() {
        mWebView?.destroy()
        mWebView = null
    }

    private fun getJs(): String {
        javaScript?.let {
            if (it.isNotEmpty()) {
                return it
            }
        }
        return JS
    }

    private fun setCookie(url: String) {
        tag?.let {
            ioScope.launch {
                val cookie = CookieManager.getInstance().getCookie(url)
                CookieStoreProviders.get()?.setCookie(it, cookie)
            }
        }
    }

    private inner class HtmlWebViewClient : WebViewClient() {

        private var runnable: EvalJsRunnable? = null
        private var isRedirect = false

        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest
        ): Boolean {
            isRedirect = isRedirect || request.isRedirect
            return super.shouldOverrideUrlLoading(view, request)
        }

        override fun onPageStarted(
            view: WebView,
            url: String,
            favicon: android.graphics.Bitmap?
        ) {
            super.onPageStarted(view, url, favicon)
            if (runnable == null) {
                runnable = EvalJsRunnable(view, url, getJs())
            }
            mHandler.removeCallbacks(runnable!!)
            mHandler.postDelayed(runnable!!, delayTime)
        }

        override fun onPageFinished(view: WebView, url: String) {
            super.onPageFinished(view, url)
            setCookie(url)
        }

        @SuppressLint("WebViewClientOnReceivedSslError")
        override fun onReceivedSslError(
            view: WebView?,
            handler: SslErrorHandler?,
            error: SslError?
        ) {
            handler?.proceed()
        }

        private inner class EvalJsRunnable(
            webView: WebView,
            private val url: String,
            private val mJavaScript: String
        ) : Runnable {
            var retry = 0
            private val mWebView: WeakReference<WebView> = WeakReference(webView)
            override fun run() {
                mWebView.get()?.evaluateJavascript(mJavaScript) {
                    handleResult(it)
                }
            }

            private fun handleResult(result: String) {
                ioScope.launch {
                    if (result.isNotEmpty() && result != "null") {
                        val content = EscapeUtils.unescapeJson(result)
                            .replace(quoteRegex, "")
                        try {
                            val response = buildStrResponse(content)
                            callback?.onResult(response)
                        } catch (e: Exception) {
                            callback?.onError(e)
                        }
                        mHandler.post {
                            destroy()
                        }
                        return@launch
                    }
                    if (retry > 30) {
                        callback?.onError(NoStackTraceException("js执行超时"))
                        mHandler.post {
                            destroy()
                        }
                        return@launch
                    }
                    retry++
                    mHandler.postDelayed(this@EvalJsRunnable, 1000)
                }
            }

            private fun buildStrResponse(content: String): StrResponse {
                if (!isRedirect) {
                    return StrResponse(url, content)
                }
                val originUrl = this@LegadoBackstageWebView.url ?: url
                val originResponse = Response.Builder()
                    .code(302)
                    .request(Request.Builder().url(originUrl).build())
                    .protocol(Protocol.HTTP_1_1)
                    .message("Found")
                    .build()
                val response = Response.Builder()
                    .code(200)
                    .request(Request.Builder().url(url).build())
                    .protocol(Protocol.HTTP_1_1)
                    .message("OK")
                    .priorResponse(originResponse)
                    .build()
                return StrResponse(response, content)
            }
        }
    }

    /**
     * Full-match sniff test, routed through [RuleRegexes] with a time
     * budget exactly like the fork: source-supplied regexes are
     * untrusted and can be pathological.
     */
    private fun matchesEntire(text: String, pattern: String): Boolean = try {
        RuleRegexes.get()
            .matchesEntire(text, pattern, multiline = false, timeout = SNIFF_REGEX_TIMEOUT)
    } catch (_: RegexTimeoutException) {
        false
    }

    private inner class SnifferWebClient : WebViewClient() {

        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest
        ): Boolean {
            if (shouldOverrideUrlLoading(request.url.toString())) {
                return true
            }
            return super.shouldOverrideUrlLoading(view, request)
        }

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION", "KotlinRedundantDiagnosticSuppress")
        override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
            if (shouldOverrideUrlLoading(url)) {
                return true
            }
            return super.shouldOverrideUrlLoading(view, url)
        }

        private fun shouldOverrideUrlLoading(requestUrl: String): Boolean {
            overrideUrlRegex?.let {
                if (matchesEntire(requestUrl, it)) {
                    try {
                        val response = StrResponse(url!!, requestUrl)
                        callback?.onResult(response)
                    } catch (e: Exception) {
                        callback?.onError(e)
                    }
                    destroy()
                    return true
                }
            }
            return false
        }

        override fun onLoadResource(view: WebView, resUrl: String) {
            sourceRegex?.let {
                if (matchesEntire(resUrl, it)) {
                    try {
                        val response = StrResponse(url!!, resUrl)
                        callback?.onResult(response)
                    } catch (e: Exception) {
                        callback?.onError(e)
                    }
                    destroy()
                }
            }
        }

        override fun onPageStarted(
            webView: WebView,
            url: String,
            favicon: android.graphics.Bitmap?
        ) {
            super.onPageStarted(webView, url, favicon)
            if (!javaScript.isNullOrEmpty()) {
                val runnable = LoadJsRunnable(webView, javaScript)
                mHandler.postDelayed(runnable, delayTime)
            }
        }

        override fun onPageFinished(webView: WebView, url: String) {
            super.onPageFinished(webView, url)
            setCookie(url)
        }

        @SuppressLint("WebViewClientOnReceivedSslError")
        override fun onReceivedSslError(
            view: WebView?,
            handler: SslErrorHandler?,
            error: SslError?
        ) {
            handler?.proceed()
        }

        private inner class LoadJsRunnable(
            webView: WebView,
            private val mJavaScript: String?
        ) : Runnable {
            private val mWebView: WeakReference<WebView> = WeakReference(webView)
            override fun run() {
                mWebView.get()?.loadUrl("javascript:${mJavaScript}")
            }
        }
    }

    companion object {
        const val JS = "document.documentElement.outerHTML"
        private val quoteRegex = "^\"|\"$".toRegex()

        /** Per-match sniff budget (ms), same value as the fork. */
        private const val SNIFF_REGEX_TIMEOUT = 1000L

        private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        /** Fork `runOnUI`: inline when already on the main thread. */
        fun runOnMain(block: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                block()
            } else {
                Handler(Looper.getMainLooper()).post(block)
            }
        }
    }

    abstract class Callback {
        abstract fun onResult(response: StrResponse)
        abstract fun onError(error: Throwable)
    }
}

/**
 * [BackstageWebViewFactory] host implementation (fork:
 * BackstageWebViewFactoryImpl): creates [LegadoBackstageWebView]
 * instances and serialises access to a small pool of live WebViews —
 * the fork relies on caller discipline, the host adds a hard cap so a
 * multi-source search burst cannot spin up unbounded Chromium
 * instances. Waiting for a pool slot is bounded by an overall timeout
 * so a stuck page cannot starve later callers forever.
 */
class LegadoBackstageWebViewFactory(context: Context) : BackstageWebViewFactory {

    private val appContext: Context = context.applicationContext
    private val pool = Semaphore(MAX_CONCURRENT_WEBVIEWS)

    override fun create(
        url: String?,
        html: String?,
        encode: String?,
        tag: String?,
        headerMap: Map<String, String>?,
        sourceRegex: String?,
        overrideUrlRegex: String?,
        javaScript: String?,
        delayTime: Long,
    ): BackstageWebViewHandle {
        val delegate = LegadoBackstageWebView(
            appContext = appContext,
            url = url,
            html = html,
            encode = encode,
            tag = tag,
            headerMap = headerMap,
            sourceRegex = sourceRegex,
            overrideUrlRegex = overrideUrlRegex,
            javaScript = javaScript,
            delayTime = delayTime,
        )
        return object : BackstageWebViewHandle {
            override suspend fun getStrResponse(): StrResponse =
                withTimeout(POOL_WAIT_TIMEOUT_MS) {
                    pool.withPermit { delegate.getStrResponse() }
                }
        }
    }

    private companion object {
        const val MAX_CONCURRENT_WEBVIEWS = 3
        const val POOL_WAIT_TIMEOUT_MS = 60_000L
    }
}

/** Registers the host backstage WebView factory (engine init only). */
fun registerHostBackstageWebView(context: Context) {
    BackstageWebViewProviders.register(LegadoBackstageWebViewFactory(context))
}

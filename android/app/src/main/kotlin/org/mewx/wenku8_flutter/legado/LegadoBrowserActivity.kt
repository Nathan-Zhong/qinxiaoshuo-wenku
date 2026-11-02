package org.mewx.wenku8_flutter.legado

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.net.http.SslError
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import io.legado.app.help.getUserAgent
import io.legado.app.help.http.CookieStoreProviders
import io.legado.app.help.source.SourceHelp
import io.legado.app.help.source.SourceVerificationHelpShared
import io.legado.app.model.analyzeRule.AnalyzeUrlCore
import io.legado.app.utils.EscapeUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The visible in-app browser (G2, P5.2): a native full-screen page
 * whose chrome follows the Wenku design vocabulary (56dp bar, Archive
 * palette — surface #FDFCFA / ink #181818 / muted #646B62 in light
 * mode, #242424 / #F2F2F2 / #B7B7B7 in dark, values taken from
 * app_ui.dart / archive_design.dart) around a plain system WebView.
 * It exists only to serve engine verification flows (source JS
 * `java.startBrowser(...)` / `startBrowserAwait(...)`); it is launched
 * exclusively by [LegadoVerificationUiProvider] with a request stashed
 * in [LegadoBrowserHost].
 *
 * Behaviour mirrors the fork's WebViewScreen + AndroidWebView
 * semantics item by item:
 * - load spec pre-derived by the engine ([LegadoBrowserRequest.spec]):
 *   POST bodies and data: URLs arrive as HTML, raw HTML is rendered
 *   directly, everything else loads with the source header map;
 * - cookies flow both ways through [CookieStoreProviders]: engine
 *   cookies are injected before the load, WebView cookies are written
 *   back on every page finish;
 * - the 确定 action (shown when the engine waits for a result) performs
 *   the fork's saveVerificationResult: refetch through AnalyzeUrl
 *   (refetchAfterSuccess) or take the rendered DOM, hand it to
 *   [SourceVerificationHelpShared.setResult] and close — a failed
 *   refetch toasts and keeps the page open for a retry, like the fork;
 * - a Cloudflare challenge that appears and then clears triggers the
 *   same save automatically (the fork's onPageFinished `_cf_chl_opt`
 *   check);
 * - closing by any path fills an empty result and wakes the waiter
 *   (the fork's onDispose checkResult), so nothing can park forever;
 * - non-http(s) navigations are intercepted: legado/yuedu links are
 *   swallowed (the host has no deep-link importer), anything else asks
 *   for confirmation before being handed to the system;
 * - system back walks the fork's chain: video fullscreen first, then
 *   WebView history (with the fork's `history size > 1` guard), then
 *   close. The top-bar back arrow closes directly, like the fork.
 *
 * `asBottomSheet` requests render the same page as a 65%-height
 * bottom window over the app (the fork's overlay sheet), the only
 * presentation difference.
 */
class LegadoBrowserActivity : Activity() {

    private lateinit var request: LegadoBrowserRequest
    private lateinit var webView: WebView
    private lateinit var titleView: TextView
    private lateinit var subtitleView: TextView
    private lateinit var chromeBar: LinearLayout
    private lateinit var progressBar: ProgressBar
    private lateinit var container: FrameLayout

    private var initialTitle: String = ""
    private var resultSaved = false
    private var cloudflareChallenge = false
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null

    private val isNight: Boolean
        get() = (resources.configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private val colorSurface: Int get() = if (isNight) 0xFF242424.toInt() else 0xFFFDFCFA.toInt()
    private val colorBackground: Int get() = if (isNight) 0xFF191919.toInt() else 0xFFF4F3EF.toInt()
    private val colorInk: Int get() = if (isNight) 0xFFF2F2F2.toInt() else 0xFF181818.toInt()
    private val colorMuted: Int get() = if (isNight) 0xFFB7B7B7.toInt() else 0xFF646B62.toInt()
    private val colorHairline: Int get() = if (isNight) 0xFF3C3C3C.toInt() else 0xFFD8DBD5.toInt()

    private fun dp(value: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, value.toFloat(), resources.displayMetrics
    ).toInt()

    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else 0
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val req = LegadoBrowserHost.take(intent.getStringExtra(EXTRA_TOKEN))
        if (req == null) {
            finish()
            return
        }
        request = req
        initialTitle = req.title

        buildChrome()
        configureWindow()
        configureWebView()
        loadRequest()
    }

    // ------------------------------------------------------------------
    // Chrome (Wenku-styled shell)
    // ------------------------------------------------------------------

    private fun buildChrome() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(colorBackground)
        }
        chromeBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(colorSurface)
            setPadding(dp(4), statusBarHeight(), dp(8), 0)
        }
        val backButton = TextView(this).apply {
            text = "‹"
            setTextColor(colorInk)
            textSize = 30f
            gravity = Gravity.CENTER
            setPadding(dp(10), dp(2), dp(12), dp(6))
            setOnClickListener { closeBrowser() }
        }
        chromeBar.addView(
            backButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, dp(56)
            ),
        )
        val titles = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(2), 0, dp(8), 0)
        }
        titleView = TextView(this).apply {
            text = initialTitle
            setTextColor(colorInk)
            textSize = 15f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        subtitleView = TextView(this).apply {
            text = request.sourceName
            setTextColor(colorMuted)
            textSize = 11f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        titles.addView(titleView)
        titles.addView(subtitleView)
        chromeBar.addView(
            titles,
            LinearLayout.LayoutParams(0, dp(56), 1f),
        )
        val refreshButton = TextView(this).apply {
            text = "↻"
            setTextColor(colorInk)
            textSize = 20f
            gravity = Gravity.CENTER
            setPadding(dp(10), dp(4), dp(10), dp(4))
            setOnClickListener {
                progressBar.visibility = View.VISIBLE
                progressBar.progress = 0
                webView.reload()
            }
        }
        chromeBar.addView(
            refreshButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, dp(56)
            ),
        )
        if (request.saveResult ||
            request.resultMode == LegadoBrowserRequest.RESULT_LOGIN
        ) {
            val okButton = TextView(this).apply {
                text = "确定"
                setTextColor(colorInk)
                textSize = 15f
                typeface = android.graphics.Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                setPadding(dp(12), dp(4), dp(6), dp(4))
                setOnClickListener {
                    // Verification windows save their result; the
                    // login window's confirm is the fork's isLogin
                    // semantic — sync cookies, reload, stay open.
                    if (request.resultMode ==
                        LegadoBrowserRequest.RESULT_LOGIN
                    ) {
                        confirmLoginCookies()
                    } else {
                        saveVerificationResult()
                    }
                }
            }
            chromeBar.addView(
                okButton,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, dp(56)
                ),
            )
        }
        root.addView(chromeBar)
        val divider = View(this).apply { setBackgroundColor(colorHairline) }
        root.addView(
            divider,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1),
        )
        progressBar = ProgressBar(
            this, null, android.R.attr.progressBarStyleHorizontal
        ).apply {
            max = 100
            progress = 0
        }
        root.addView(
            progressBar,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(2)),
        )
        container = FrameLayout(this).apply { setBackgroundColor(colorSurface) }
        root.addView(
            container,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f
            ),
        )
        if (request.asBottomSheet) {
            // Rounded top corners for the sheet presentation.
            val sheetBg = GradientDrawable().apply {
                setColor(colorBackground)
                cornerRadii = floatArrayOf(
                    dp(12).toFloat(), dp(12).toFloat(),
                    dp(12).toFloat(), dp(12).toFloat(),
                    0f, 0f, 0f, 0f,
                )
            }
            root.background = sheetBg
        }
        setContentView(root)

        webView = WebView(this)
        container.addView(
            webView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    private fun configureWindow() {
        if (request.asBottomSheet) {
            val height = (resources.displayMetrics.heightPixels * 0.65f).toInt()
            window.setLayout(
                WindowManager.LayoutParams.MATCH_PARENT, height
            )
            window.setGravity(Gravity.BOTTOM)
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            window.attributes = window.attributes.apply { dimAmount = 0.45f }
            window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        } else {
            window.setBackgroundDrawable(ColorDrawable(colorBackground))
        }
        // Status-bar icon tone follows the Wenku light/dark palette.
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = if (isNight) {
            0
        } else {
            View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or
                View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        }
    }

    // ------------------------------------------------------------------
    // WebView (fork AndroidWebView semantics)
    // ------------------------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView() {
        val spec = request.spec
        webView.setBackgroundColor(colorSurface)
        with(webView.settings) {
            javaScriptEnabled = true
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            domStorageEnabled = true
            allowContentAccess = true
            allowFileAccess = false
            builtInZoomControls = true
            displayZoomControls = false
            useWideViewPort = true
            loadWithOverviewMode = true
            userAgentString = spec.headerMap.getUserAgent()
        }
        webView.webViewClient = BrowserClient()
        webView.webChromeClient = object : WebChromeClient() {
            override fun onReceivedTitle(view: WebView?, title: String?) {
                super.onReceivedTitle(view, title)
                // Fork: adopt the page title only when it is a real
                // title (non-blank, not the URL itself); otherwise
                // fall back to the passed-in title.
                val current = view?.url
                titleView.text =
                    if (!title.isNullOrBlank() && title != current) {
                        title
                    } else {
                        initialTitle
                    }
            }

            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                super.onProgressChanged(view, newProgress)
                if (newProgress >= 100) {
                    progressBar.visibility = View.GONE
                } else {
                    progressBar.visibility = View.VISIBLE
                    progressBar.progress = newProgress
                }
            }

            override fun onShowCustomView(
                view: View?,
                callback: CustomViewCallback?,
            ) {
                if (view == null) return
                customView = view
                customViewCallback = callback
                container.addView(
                    view,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    ),
                )
                chromeBar.visibility = View.GONE
                progressBar.visibility = View.GONE
            }

            override fun onHideCustomView() {
                customView?.let { container.removeView(it) }
                customView = null
                customViewCallback = null
                chromeBar.visibility = View.VISIBLE
            }

            override fun onCloseWindow(window: WebView?) {
                if (request.saveResult) {
                    saveVerificationResult()
                } else {
                    closeBrowser()
                }
            }
        }
    }

    private fun loadRequest() {
        val spec = request.spec
        val baseUrl = spec.baseUrl.ifEmpty { request.url }
        applyCookiesToWebView(baseUrl)
        val html = spec.html
        if (html.isNullOrEmpty()) {
            webView.loadUrl(spec.baseUrl, HashMap(spec.headerMap))
        } else {
            webView.loadDataWithBaseURL(
                spec.baseUrl, html, "text/html", "utf-8", spec.baseUrl
            )
        }
    }

    /** Engine cookies -> WebView before the load (fork applyToWebView). */
    private fun applyCookiesToWebView(url: String) {
        val glob = runCatching { CookieStoreProviders.get()?.getCookie(url) }
            .getOrNull() ?: return
        val baseUrl = io.legado.app.utils.NetworkUtils.getBaseUrl(url) ?: return
        val manager = CookieManager.getInstance()
        glob.split(';')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .forEach { manager.setCookie(baseUrl, it) }
        manager.flush()
    }

    private inner class BrowserClient : WebViewClient() {

        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest,
        ): Boolean = interceptUrl(request.url.toString())

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION", "KotlinRedundantDiagnosticSuppress")
        override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean =
            interceptUrl(url)

        @SuppressLint("WebViewClientOnReceivedSslError")
        override fun onReceivedSslError(
            view: WebView?,
            handler: SslErrorHandler?,
            error: SslError?,
        ) {
            handler?.proceed()
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            super.onPageFinished(view, url)
            if (url != null) {
                // WebView cookies are authoritative after a load:
                // write them back into the engine cookie store (fork
                // onPageFinished semantics).
                val webCookie = CookieManager.getInstance().getCookie(url)
                runCatching {
                    CookieStoreProviders.get()?.setCookie(url, webCookie)
                }
            }
            if (request.saveResult) {
                // Fork Cloudflare probe: challenge present -> remember;
                // challenge gone after being present -> auto-save.
                view?.evaluateJavascript("!!window._cf_chl_opt") { raw ->
                    if (raw == "true") {
                        cloudflareChallenge = true
                    } else if (cloudflareChallenge) {
                        cloudflareChallenge = false
                        saveVerificationResult()
                    }
                }
            }
        }
    }

    /**
     * Fork `WebViewUtil.shouldOverrideUrl`: http/https stay in the
     * WebView; legado/yuedu deep links are swallowed (no importer
     * behind them in this host); any other scheme asks first, then is
     * handed to the system.
     */
    private fun interceptUrl(url: String): Boolean {
        val scheme = url.substringBefore(':').lowercase()
        return when (scheme) {
            "http", "https" -> false
            "legado", "yuedu" -> true
            else -> {
                AlertDialog.Builder(this)
                    .setTitle("打开外部链接")
                    .setMessage(url)
                    .setPositiveButton("打开") { _, _ ->
                        runCatching {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            )
                        }
                    }
                    .setNegativeButton("取消", null)
                    .show()
                true
            }
        }
    }

    // ------------------------------------------------------------------
    // Result hand-back (fork saveVerificationResult / checkResult)
    // ------------------------------------------------------------------

    private fun saveVerificationResult() {
        if (!request.saveResult) {
            closeBrowser()
            return
        }
        if (request.refetchAfterSuccess) {
            val req = request
            LegadoEngine.scope.launch {
                val body = runCatching {
                    val source = SourceHelp.getSource(req.sourceKey, req.sourceType)
                    AnalyzeUrlCore(
                        req.url,
                        headerMapF = req.spec.headerMap,
                        source = source,
                        coroutineContext = currentCoroutineContext(),
                    ).getStrResponseAwait(allowWebView = false).body
                }
                body.onSuccess { text ->
                    SourceVerificationHelpShared.setResult(
                        req.sourceKey, text ?: ""
                    )
                    resultSaved = true
                    withContext(Dispatchers.Main) { closeBrowser() }
                }.onFailure { e ->
                    // Fork: a failed refetch toasts and STAYS on the
                    // page so the user can retry or back out.
                    withContext(Dispatchers.Main) {
                        Toast.makeText(
                            this@LegadoBrowserActivity,
                            "获取验证结果失败：${e.message ?: ""}",
                            Toast.LENGTH_SHORT,
                        ).show()
                    }
                }
            }
        } else {
            webView.evaluateJavascript("document.documentElement.outerHTML") { raw ->
                // Platform values arrive JSON-escaped; the fork
                // normalises with unescapeJson + quote trim.
                val text = if (raw == null) {
                    ""
                } else {
                    EscapeUtils.unescapeJson(raw).trim('"')
                }
                SourceVerificationHelpShared.setResult(request.sourceKey, text)
                resultSaved = true
                closeBrowser()
            }
        }
    }

    /**
     * Fork checkResult on dispose: whatever path closed the browser,
     * a waiter must find SOME result (empty when nothing was saved)
     * and be woken.
     */
    private fun ensureResultFilled() {
        val key = request.sourceKey
        SourceVerificationHelpShared.getResult(key)
            ?: SourceVerificationHelpShared.setResult(key, "")
        SourceVerificationHelpShared.notifyResultArrived(key)
    }

    /**
     * The fork's login-window confirm (WebViewActivity isLogin):
     * push the WebView's cookies into the engine store for the
     * current page, then reload so the page itself renders in the
     * logged-in state for the user to see before closing. The window
     * stays open — finishing is the close path's job, not confirm's.
     */
    private fun confirmLoginCookies() {
        val url = webView.url ?: request.url
        val webCookie = CookieManager.getInstance().getCookie(url)
        runCatching {
            CookieStoreProviders.get()?.setCookie(url, webCookie)
        }
        webView.reload()
    }

    /**
     * Close hand-back by request mode: verification windows fill/wake
     * the verification result (fork checkResult); login windows wake
     * the parked login JS (fork overlay onDispose ->
     * notifyLoginFinished) and never touch the verification slot —
     * a login in progress may itself be waiting on a captcha result
     * under the same source key; auxiliary pages hand back nothing.
     * Safe to call twice (close + onDestroy backstop): both engine
     * signals are idempotent fills/markers.
     */
    private fun handBackOnClose() {
        when (request.resultMode) {
            LegadoBrowserRequest.RESULT_LOGIN ->
                SourceVerificationHelpShared.notifyLoginFinished(
                    request.sourceKey
                )

            LegadoBrowserRequest.RESULT_NONE -> Unit
            else -> ensureResultFilled()
        }
    }

    private fun closeBrowser() {
        handBackOnClose()
        finish()
    }

    override fun onBackPressed() {
        when {
            customView != null -> customViewCallback?.onCustomViewHidden()
            // Fork guard: canGoBack alone is not enough (invisible
            // history entries would eat the first back press).
            webView.canGoBack() &&
                webView.copyBackForwardList().size > 1 -> webView.goBack()

            else -> closeBrowser()
        }
    }

    override fun onDestroy() {
        // Backstop for every exit path (including system teardown):
        // the fork fills the result from onDispose the same way.
        if (::request.isInitialized) {
            runCatching { handBackOnClose() }
        }
        if (::webView.isInitialized) {
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.destroy()
        }
        super.onDestroy()
    }

    companion object {
        const val EXTRA_TOKEN = "org.mewx.wenku8.legado.browser_token"
    }
}

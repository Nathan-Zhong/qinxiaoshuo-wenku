package org.mewx.wenku8_flutter.legado

import io.legado.app.constant.AppConst
import io.legado.app.data.entities.BaseSource
import io.legado.app.data.entities.BookChapterLike
import io.legado.app.model.analyzeRule.AnalyzeUrlCore
import io.legado.app.model.analyzeRule.RuleDataInterface
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/**
 * Host-side thin subclass of the shared [AnalyzeUrlCore], registered in
 * [AnalyzeUrlFactories] in place of the bare core (FIX8). Two additions,
 * both documented in FIX8-REPORT.md:
 *
 * 1. Header-value hardening (deliberate deviation): the core populates
 *    [headerMap] from the source's header rule — e.g. 拷贝漫画 7789's
 *    `"referer": baseUrl`, where baseUrl is the request URL with the raw,
 *    unencoded keyword substituted in. OkHttp throws
 *    IllegalArgumentException on such values while the request is being
 *    built, killing the whole search/check for that source. Values are
 *    percent-encoded here — once for the caller-supplied [headerMapF]
 *    (sanitized copy passed to super, which is also the map the request
 *    path falls back to) and once for the core-built [headerMap] after
 *    construction — via [sanitizeHeaderMap], which leaves already-legal
 *    values byte-identical.
 *
 * 2. The legacy AES pair (see [LegadoLegacyCrypto]) for URL/header JS
 *    contexts, where `java` binds to this object.
 */
class LegadoAnalyzeUrl(
    rawUrl: String,
    baseUrl: String = "",
    source: BaseSource? = null,
    ruleData: RuleDataInterface? = null,
    chapter: BookChapterLike? = null,
    readTimeout: Long? = null,
    callTimeout: Long? = null,
    coroutineContext: CoroutineContext = EmptyCoroutineContext,
    headerMapF: Map<String, String>? = null,
    hasLoginHeader: Boolean = true,
    selectedOptions: Map<String, String>? = null,
    variables: Map<AppConst.JsVarName, Any>? = null,
) : AnalyzeUrlCore(
    rawUrl, baseUrl, source, ruleData, chapter, readTimeout, callTimeout,
    coroutineContext, sanitizeHeaderMap(headerMapF), hasLoginHeader,
    selectedOptions, variables,
) {

    init {
        // The core's init has fully populated headerMap by now (from the
        // source's header rule or from headerMapF); clean any illegal
        // values in place so the request builders downstream never see
        // a value OkHttp would reject.
        val cleaned = sanitizeHeaderMap(headerMap)
        if (cleaned !== headerMap) {
            headerMap.clear()
            headerMap.putAll(cleaned!!)
        }
    }

    @JvmOverloads
    fun aesBase64DecodeToString(
        str: String,
        key: String,
        transformation: String = "AES/ECB/PKCS7Padding",
        iv: String = "",
    ): String? = LegadoLegacyCrypto.aesBase64DecodeToString(str, key, transformation, iv)

    @JvmOverloads
    fun aesEncodeToBase64String(
        str: String,
        key: String,
        transformation: String = "AES/ECB/PKCS7Padding",
        iv: String = "",
    ): String? = LegadoLegacyCrypto.aesEncodeToBase64String(str, key, transformation, iv)
}

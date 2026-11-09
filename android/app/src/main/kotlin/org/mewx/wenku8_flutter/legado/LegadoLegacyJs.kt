package org.mewx.wenku8_flutter.legado

/**
 * OkHttp header-value hardening (FIX8, device-verified in 1.0.8).
 *
 * OkHttp rejects header values containing characters outside TAB /
 * 0x20..0x7E, throwing IllegalArgumentException while the engine builds
 * the request. Sources that put the (unencoded) request URL into a
 * `referer` header — 拷贝漫画 7789, G社漫画 — crash every search / check
 * whose keyword contains non-ASCII characters. [sanitizeHeaderValue]
 * percent-encodes exactly the characters OkHttp would reject (UTF-8
 * bytes, `%XX`), and returns already-legal values byte-identical, so
 * encoded values are never double-encoded and plain ASCII headers
 * (Authorization, Cookie, UA, …) are untouched. This is a deliberate
 * host-side deviation: the fork (and upstream) crash the same way; the
 * archived FIX2 plan (b) proposed the same encoding inside the engine's
 * addHeaders, which as vendored AAR code was not host-editable, and
 * OkHttp interceptors cannot help because the throw happens while the
 * request is being built, before any client/interceptor sees it.
 *
 * History: this file also carried FIX8's host-side AES pair
 * (LegadoLegacyCrypto). FIX9 removed it — on the release build R8
 * renamed the host-only, JS-called-by-name methods away (the host bridge
 * package sat outside the keep surface), so they never reached JS. The
 * functions now live in the engine itself (JsExtensionsCommon, restored
 * with upstream semantics); see FIX9-REPORT.md.
 */

private val HEX_DIGITS = "0123456789ABCDEF".toCharArray()

/** Percent-encode only the characters OkHttp would reject (see file doc). */
internal fun sanitizeHeaderValue(value: String): String {
    var needsEncoding = false
    for (ch in value) {
        if (!(ch == '\t' || ch in ' '..'~')) {
            needsEncoding = true
            break
        }
    }
    if (!needsEncoding) return value
    val out = StringBuilder(value.length + 16)
    var i = 0
    while (i < value.length) {
        val cp = Character.codePointAt(value, i)
        if (cp == 0x09 || cp in 0x20..0x7E) {
            out.append(cp.toChar())
        } else {
            for (b in String(Character.toChars(cp)).toByteArray(Charsets.UTF_8)) {
                val v = b.toInt() and 0xFF
                out.append('%').append(HEX_DIGITS[v shr 4]).append(HEX_DIGITS[v and 0x0F])
            }
        }
        i += Character.charCount(cp)
    }
    return out.toString()
}

/** A sanitized copy of [headers] (order preserved), or null in → null out. */
internal fun sanitizeHeaderMap(headers: Map<String, String>?): Map<String, String>? {
    if (headers == null) return null
    var changed = false
    val out = LinkedHashMap<String, String>(headers.size)
    for ((name, value) in headers) {
        val clean = sanitizeHeaderValue(value)
        if (clean != value) changed = true
        out[name] = clean
    }
    return if (changed) out else headers
}

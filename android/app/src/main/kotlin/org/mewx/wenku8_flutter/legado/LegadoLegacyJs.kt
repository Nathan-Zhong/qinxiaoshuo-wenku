package org.mewx.wenku8_flutter.legado

import android.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Host supplements for two gaps between the vendored fork engine and the
 * wider Legado source ecosystem (see FIX8-REPORT.md for the full evidence):
 *
 * 1. The legacy `java.aesBase64DecodeToString` / `java.aesEncodeToBase64String`
 *    pair. Upstream Legado exposes these on the JS `java` object; the fork
 *    dropped them (its replacement is `createSymmetricCrypto`), and the
 *    xiaohan template family (漫画柜 6028, Komiic, 拷贝 variants, …) bootstraps
 *    itself by AES-decrypting `source.variableComment` through the decode
 *    function — without it every rule script of those sources dies with
 *    `TypeError: not a function`. The implementations below mirror the
 *    upstream semantics exactly (transformation string passed through to
 *    [Cipher.getInstance], key/iv as raw UTF-8 bytes, base64 payload,
 *    null on any failure).
 *
 * 2. OkHttp header-value hardening. OkHttp rejects header values containing
 *    characters outside TAB / 0x20..0x7E, throwing IllegalArgumentException
 *    while the engine builds the request. Sources that put the (unencoded)
 *    request URL into a `referer` header — 拷贝漫画 7789, G社漫画 — crash
 *    every search / check whose keyword contains non-ASCII characters.
 *    [sanitizeHeaderValue] percent-encodes exactly the characters OkHttp
 *    would reject (UTF-8 bytes, `%XX`), and returns already-legal values
 *    byte-identical, so encoded values are never double-encoded and plain
 *    ASCII headers (Authorization, Cookie, UA, …) are untouched. This is a
 *    deliberate host-side deviation: the fork (and upstream) crash the same
 *    way; the archived FIX2 plan (b) proposed the same encoding inside the
 *    engine's addHeaders, which as vendored AAR code is not host-editable,
 *    and OkHttp interceptors cannot help because the throw happens while
 *    the request is being built, before any client/interceptor sees it.
 */
internal object LegadoLegacyCrypto {

    @JvmStatic
    fun aesBase64DecodeToString(
        str: String,
        key: String,
        transformation: String,
        iv: String,
    ): String? = try {
        val cipher = cipherFor(transformation, Cipher.DECRYPT_MODE, key, iv) ?: return null
        val plain = cipher.doFinal(Base64.decode(str, Base64.DEFAULT))
        String(plain, Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }

    @JvmStatic
    fun aesEncodeToBase64String(
        str: String,
        key: String,
        transformation: String,
        iv: String,
    ): String? = try {
        val cipher = cipherFor(transformation, Cipher.ENCRYPT_MODE, key, iv) ?: return null
        val encrypted = cipher.doFinal(str.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(encrypted, Base64.NO_WRAP)
    } catch (_: Exception) {
        null
    }

    private fun cipherFor(
        transformation: String,
        mode: Int,
        key: String,
        iv: String,
    ): Cipher? {
        val secretKey = SecretKeySpec(key.toByteArray(Charsets.UTF_8), "AES")
        // "PKCS7Padding" is the spelling the sources carry; some providers
        // only register "PKCS5Padding" (identical scheme for AES's 16-byte
        // blocks), so retry with the alias before giving up.
        val names = listOf(
            transformation,
            transformation.replace("PKCS7Padding", "PKCS5Padding"),
        ).distinct()
        for (name in names) {
            try {
                val cipher = Cipher.getInstance(name)
                if (iv.isEmpty() || name.contains("ECB")) {
                    cipher.init(mode, secretKey)
                } else {
                    cipher.init(mode, secretKey, IvParameterSpec(iv.toByteArray(Charsets.UTF_8)))
                }
                return cipher
            } catch (_: Exception) {
                // try the alias spelling
            }
        }
        return null
    }
}

private val HEX_DIGITS = "0123456789ABCDEF".toCharArray()

/** See [LegadoLegacyCrypto] doc: percent-encode only OkHttp-illegal chars. */
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

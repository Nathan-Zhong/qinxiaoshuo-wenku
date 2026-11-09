package org.mewx.wenku8_flutter.legado

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import io.legado.app.constant.AppPattern
import io.legado.app.help.FileCacheProvider
import io.legado.app.help.archive.ArchiveProvider
import io.legado.app.help.ui.OpenUrlProvider
import io.legado.app.utils.MD5Utils
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream

/**
 * Host implementations for the engine's secondary provider registries
 * that the search / explore / info / toc / content chains can reach
 * indirectly. Audited 2026-11-03 after the ImageOps outage (see
 * FIX2-imageops-report.md for the full sibling-guard inventory):
 *
 * - [LegadoFileCache]: `CacheManager.delete()` calls
 *   `FileCacheProviders.get().remove()` UNCONDITIONALLY, and the
 *   ByteArray / putFile / getFile members of the JS-visible `cache`
 *   object route here too. The fork delegates to ACache; this is a
 *   plain file-backed equivalent with the same expiry semantics
 *   (saveTime in seconds, 0 = never expires).
 * - [LegadoArchiveProvider]: the JS archive helpers
 *   (`java.getZipByteArrayContent`, `unArchiveFile`, ...) call
 *   `ArchiveProviders.get()`. The fork delegates to libarchive
 *   (zip/rar/7z/...); this host version covers ZIP with
 *   java.util.zip — the format those helpers overwhelmingly carry —
 *   and fails rar/7z with the interface's own conventions (null from
 *   getByteArrayContent, empty list from getFilesName, a clear
 *   exception from deCompress). Entry-listing semantics mirror the
 *   fork exactly: null filter -> empty list; unsupported suffix ->
 *   IllegalArgumentException("Unexpected file suffix"); unreadable
 *   archive -> empty list.
 * - [LegadoOpenUrlProvider]: `java.openUrl()` in source JS calls
 *   `OpenUrlProviders.get()`. The fork pops a confirmation dialog
 *   (its own UI layer, not vendored); the host equivalent fires an
 *   ACTION_VIEW intent — same functional outcome, no dialog.
 */

class LegadoFileCache(private val baseDir: File) : FileCacheProvider {

    private fun root(persistent: Boolean): File =
        File(baseDir, if (persistent) "file_cache_persistent" else "file_cache")

    private fun entryFile(key: String, persistent: Boolean): File {
        val dir = root(persistent).apply { mkdirs() }
        return File(dir, "${MD5Utils.md5Encode(key)}.entry")
    }

    private fun write(key: String, payload: ByteArray, saveTime: Int, persistent: Boolean) {
        val deadline = if (saveTime == 0) 0L else System.currentTimeMillis() + saveTime * 1000L
        val out = ByteArrayOutputStream()
        // 8-byte big-endian deadline header, then the raw payload.
        for (shift in 56 downTo 0 step 8) {
            out.write((deadline shr shift).toInt())
        }
        out.write(payload)
        runCatching { entryFile(key, persistent).writeBytes(out.toByteArray()) }
    }

    private fun read(key: String, persistent: Boolean): ByteArray? {
        val file = entryFile(key, persistent)
        if (!file.isFile) return null
        val bytes = runCatching { file.readBytes() }.getOrNull() ?: return null
        if (bytes.size < 8) {
            file.delete()
            return null
        }
        var deadline = 0L
        for (i in 0 until 8) {
            deadline = (deadline shl 8) or (bytes[i].toLong() and 0xFF)
        }
        if (deadline != 0L && System.currentTimeMillis() > deadline) {
            file.delete()
            return null
        }
        return bytes.copyOfRange(8, bytes.size)
    }

    override fun put(key: String, value: String, saveTime: Int, persistent: Boolean) {
        write(key, value.toByteArray(Charsets.UTF_8), saveTime, persistent)
    }

    override fun getAsString(key: String, persistent: Boolean): String? =
        read(key, persistent)?.toString(Charsets.UTF_8)

    override fun put(key: String, value: ByteArray, saveTime: Int, persistent: Boolean) {
        write(key, value, saveTime, persistent)
    }

    override fun getAsBinary(key: String, persistent: Boolean): ByteArray? =
        read(key, persistent)

    override fun remove(key: String, persistent: Boolean) {
        runCatching { entryFile(key, persistent).delete() }
    }
}

class LegadoArchiveProvider(context: Context) : ArchiveProvider {

    private val appContext: Context = context.applicationContext

    override val tempFolderName: String = "ArchiveTemp"

    private fun tempRoot(): File =
        File(appContext.externalCacheDir ?: appContext.cacheDir, tempFolderName)

    private fun checkArchive(name: String) {
        if (!AppPattern.archiveFileRegex.matches(name)) {
            throw IllegalArgumentException("Unexpected file suffix")
        }
    }

    private fun requireZip(bytes: ByteArray, what: String) {
        val isZip = bytes.size >= 2 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte()
        if (!isZip) {
            throw IllegalStateException(
                "$what: 宿主 ArchiveProvider 仅支持 zip 格式 (fork 的 libarchive 全格式实现未 vendored)"
            )
        }
    }

    override fun deCompress(archivePath: String): List<String> {
        val archive = File(archivePath)
        if (archive.isDirectory) throw IllegalArgumentException("Unexpected Folder input")
        checkArchive(archive.name)
        val bytes = archive.readBytes()
        requireZip(bytes, "deCompress")
        val workDir = File(tempRoot(), MD5Utils.md5Encode16(archive.name)).apply { mkdirs() }
        val extracted = mutableListOf<String>()
        ZipInputStream(ByteArrayInputStream(bytes)).use { zis ->
            var entry: ZipEntry? = zis.nextEntry
            while (entry != null) {
                if (!entry.isDirectory) {
                    val target = File(workDir, entry.name)
                    // Zip-slip guard: entries must stay inside the work dir.
                    require(
                        target.canonicalPath.startsWith(workDir.canonicalPath + File.separator)
                    ) { "archive entry escapes target dir: ${entry.name}" }
                    target.parentFile?.mkdirs()
                    target.outputStream().use { zis.copyTo(it) }
                    extracted.add(target.absolutePath)
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
        return extracted
    }

    override fun getFilesName(archivePath: String, filter: ((String) -> Boolean)?): List<String> {
        checkArchive(File(archivePath).name)
        if (filter == null) return emptyList()
        return try {
            ZipFile(File(archivePath)).use { zip ->
                val names = mutableListOf<String>()
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    if (!entry.isDirectory && filter(entry.name)) {
                        names.add(entry.name)
                    }
                }
                names
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    override fun getByteArrayContent(bytes: ByteArray, path: String): ByteArray? {
        val isZip = bytes.size >= 2 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte()
        if (!isZip) return null
        return try {
            var result: ByteArray? = null
            ZipInputStream(ByteArrayInputStream(bytes)).use { zis ->
                var entry: ZipEntry? = zis.nextEntry
                while (entry != null) {
                    if (!entry.isDirectory && entry.name == path) {
                        result = zis.readBytes()
                        break
                    }
                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
            result
        } catch (e: Exception) {
            null
        }
    }
}

class LegadoOpenUrlProvider(context: Context) : OpenUrlProvider {

    private val appContext: Context = context.applicationContext

    override fun openUrl(
        url: String,
        mimeType: String?,
        sourceKey: String?,
        sourceTag: String?,
        sourceType: Int
    ) {
        runCatching {
            val uri = Uri.parse(url)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                if (!mimeType.isNullOrBlank()) {
                    setDataAndType(uri, mimeType)
                } else {
                    data = uri
                }
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(intent)
        }.onFailure { e ->
            Log.w("LegadoOpenUrl", "openUrl failed for $url: ${e.message}")
        }
    }
}

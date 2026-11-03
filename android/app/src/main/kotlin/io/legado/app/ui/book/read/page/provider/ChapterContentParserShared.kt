package io.legado.app.ui.book.read.page.provider

/**
 * 宿主复刻说明 (P5.7): 本文件是 fork `:ui` 同名文件的逐字复刻
 * (huajideshutiao/legado @ d31c0a2, ui/src/commonMain/.../ChapterContentParserShared.kt),
 * 同包同名, 因为 `:ui` 未 vendored、而图片下载编排 (BookImageDownloadShared
 * 的 flowImages) 与 BookHelp.hasImageContent 的图片提取都以本类的
 * extractImages 为唯一口径, 必须与 fork 一致。唯一偏差: TagScan.forEachTag
 * 是 JVM 21 目标的 inline 函数无法 inline 进宿主 (JVM 17), 两处调用改走
 * 文件末尾逐字等价的非 inline 复刻 forEachTagLocal; 其余与 fork 原文
 * 零差异。其依赖 (TagScan / EscapeUtils / BookContent) 均已在 vendored
 * AAR 中。
 */

import io.legado.app.help.book.BookContent
import io.legado.app.utils.EscapeUtils
import io.legado.app.utils.scan.TagScan

/**
 * 章节正文轻量解析器的共享实现。
 *
 * 从 app 端 `ChapterContentParser` 原样下沉：逐项消费 [BookContent.textList]，把 `<img>`
 * 替换为 [srcReplaceChar]，保留 src/style/onclick 顺序，把 `<br>` 转换为换行，并对文本
 * 做 HTML entity 解码。Android 端解析器改为委托本实现，确保下沉前后行为一致。
 */
object ChapterContentParserShared {

    const val srcReplaceChar = "▩"

    fun parse(bookContent: BookContent): List<ParsedParagraph> {
        return bookContent.textList.map { content ->
            if (content.isEmpty()) return@map ParsedParagraph("", emptyList())
            if (content.indexOf('<') == -1) {
                return@map ParsedParagraph(decodeHtml(content), emptyList())
            }

            val images = mutableListOf<ImgData>()
            val textBuilder = StringBuilder(content.length)
            var cursor = 0
            //发现规则与 [extractImages] 共用 TagScan.forEachTag：旧实现本函数另写一遍
            //indexOf('<')/indexOf('>') 发现循环，两端口径会分叉（引号内的 `>`、`<a<img ...>`）
            forEachTagLocal(content) { tagStart, tagEnd, name ->
                if (tagStart > cursor) {
                    textBuilder.append(content, cursor, tagStart)
                }
                val tagContent = content.substring(tagStart + 1, tagEnd)
                if (TagScan.isImgTag(name)) {
                    //标签整名比对：`<image>`/`<imgx>` 不再是图片标签（旧版用 startsWith("img") 会误吃原文）
                    val fullTag = content.substring(tagStart, tagEnd + 1)
                    // 取不到 src 就整个丢弃, 不写占位符: 兜成空串只会在阅读页留一个永远
                    // 加载不出的 ▩, 且与 extractImages / 缓存侧口径不一致
                    val src = TagScan.attr(fullTag, "src")
                    if (src != null) {
                        images.add(
                            ImgData(
                                src = src,
                                style = TagScan.attr(fullTag, "style") ?: "",
                                onclick = TagScan.attr(fullTag, "onclick") ?: "",
                            )
                        )
                        textBuilder.append(srcReplaceChar)
                    }
                } else if (
                    tagContent.equals("br", ignoreCase = true) ||
                    tagContent.equals("br/", ignoreCase = true)
                ) {
                    textBuilder.append('\n')
                }
                cursor = tagEnd + 1
            }
            //最后一个标签之后的正文、以及回调不到的残缺标签 (无闭合 `>`) 都要原样保留:
            //forEachTag 正常扫完返回串长、遇残缺标签返回那个 `<`, 两种情况都从 cursor 补到串尾
            if (cursor < content.length) {
                textBuilder.append(content, cursor, content.length)
            }

            ParsedParagraph(decodeHtml(textBuilder.toString()), images)
        }
    }

    fun extractImages(content: String): List<ImgData> {
        if (!content.contains("<img", ignoreCase = true)) return emptyList()
        val images = mutableListOf<ImgData>()
        //发现规则与 parse 共用 TagScan.forEachTag：旧版本函数直接搜 `<img` 子串，
        //遇到 `<a<img src="b.jpg">` 会取到阅读页根本不显示的图，两端口径不一致
        forEachTagLocal(content) { tagStart, tagEnd, name ->
            if (!TagScan.isImgTag(name)) return@forEachTagLocal
            val fullTag = content.substring(tagStart, tagEnd + 1)
            val src = TagScan.attr(fullTag, "src")
            if (src != null) {
                images.add(
                    ImgData(
                        src = src,
                        style = TagScan.attr(fullTag, "style") ?: "",
                        onclick = TagScan.attr(fullTag, "onclick") ?: "",
                    )
                )
            }
        }
        return images
    }

    private fun decodeHtml(html: String): String {
        return if (html.contains('&')) EscapeUtils.unescapeHtml(html) else html
    }
}

/**
 * 宿主偏差 (P5.7): 与 `TagScan.forEachTag` 逐字等价的非 inline 实现。
 * 原函数是 inline 函数, 其 AAR 字节码以 JVM 21 目标编译, 无法 inline
 * 进本宿主模块 (JVM 17 目标), 故在此按原文复刻扫描循环 (标签名仍取
 * TagScan.tagName, 引号外 `>` 判定与原文一致)。除此函数与两处调用点
 * 改名外, 本文件与 fork 原文零差异。
 */
private fun forEachTagLocal(
    text: String,
    onTag: (tagStart: Int, tagEnd: Int, name: String) -> Unit
): Int {
    var index = 0
    while (index < text.length) {
        val tagStart = text.indexOf('<', index)
        if (tagStart == -1) return text.length
        var i = tagStart + 1
        var quote: Char? = null
        var tagEnd = -1
        while (i < text.length) {
            val c = text[i]
            if (quote == null) {
                if (c == '"' || c == '\'') quote = c
                else if (c == '>') {
                    tagEnd = i
                    break
                }
            } else if (c == quote) {
                quote = null
            }
            i++
        }
        if (tagEnd == -1) return tagStart
        onTag(tagStart, tagEnd, TagScan.tagName(text, tagStart))
        index = tagEnd + 1
    }
    return text.length
}

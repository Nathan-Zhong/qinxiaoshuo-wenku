package io.legado.app.ui.book.read.page.provider

/**
 * 宿主复刻说明 (P5.7): 本类是 fork `:ui` 的
 * `SimpleChapterLayout.kt` 中 [ParsedParagraph] 数据类的逐字复刻
 * (huajideshutiao/legado @ d31c0a2), 同包同名, 因为 `:ui` 未 vendored、
 * 而宿主复刻的 ChapterContentParserShared 以其为返回类型。原文件其余
 * 排版代码与本项目无关, 不复刻。除本说明外与 fork 原文零差异。
 */
data class ParsedParagraph(
    val text: String,
    val images: List<ImgData> = emptyList(),
)

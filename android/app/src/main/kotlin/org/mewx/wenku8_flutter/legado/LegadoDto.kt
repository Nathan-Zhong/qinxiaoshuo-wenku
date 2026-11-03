package org.mewx.wenku8_flutter.legado

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.data.entities.rule.ExploreKind
import io.legado.app.data.entities.rule.FlexChildStyle
import io.legado.app.utils.GSON
import kotlin.math.roundToInt

/**
 * Entity -> channel map conversions, field-for-field per ENGINE-study
 * §4.3 tables A-D. Values stay StandardMessageCodec types; Longs are
 * passed as-is (codec maps them to Dart int).
 */
object LegadoDto {

    /** Table A. [includeJson] only for single-source reads (getSource/upsert). */
    fun source(
        source: BookSource,
        includeJson: Boolean = false,
        exploreKindCount: Int? = null
    ): Map<String, Any?> {
        return mapOf(
            "sourceUrl" to source.bookSourceUrl,
            "sourceName" to source.bookSourceName,
            "group" to source.bookSourceGroup,
            "type" to source.bookSourceType,
            "enabled" to source.enabled,
            "enabledExplore" to source.enabledExplore,
            "customOrder" to source.customOrder,
            "weight" to source.weight,
            "respondTimeMs" to source.respondTime,
            "lastUpdateTime" to source.lastUpdateTime,
            "hasLogin" to source.hasLogin(),
            // fix3: lets the Dart search scope exclude sources that can
            // never search (blank searchUrl — e.g. RSS-type entries in
            // the book-source table), mirroring the capability check
            // the engine self-check makes per source.
            "hasSearch" to !source.searchUrl.isNullOrBlank(),
            "comment" to source.bookSourceComment,
            "icon" to source.bookSourceIcon,
            "exploreKindCount" to exploreKindCount,
            "sourceJson" to if (includeJson) {
                runCatching {
                    GSON.encodeToString(BookSource.serializer(), source)
                }.getOrNull()
            } else {
                null
            }
        )
    }

    /** Table B. */
    fun searchBook(book: SearchBook): Map<String, Any?> {
        return mapOf(
            "name" to book.name,
            "author" to book.author,
            "bookUrl" to book.bookUrl,
            "tocUrl" to book.tocUrl,
            "origin" to book.origin,
            "originName" to book.originName,
            "origins" to book.origins.toList(),
            "type" to book.type,
            "kind" to book.kind,
            "coverUrl" to book.coverUrl,
            "intro" to book.intro,
            "wordCount" to book.wordCount,
            "latestChapterTitle" to book.latestChapterTitle,
            "chapterWordCount" to if (book.chapterWordCount < 0) 0 else book.chapterWordCount,
            "variable" to book.variable
        )
    }

    /** Table C (Table B fields + book-only fields). */
    fun book(book: Book): Map<String, Any?> {
        return mapOf(
            "name" to book.name,
            "author" to book.author,
            "bookUrl" to book.bookUrl,
            "tocUrl" to book.tocUrl,
            "origin" to book.origin,
            "originName" to book.originName,
            "origins" to listOf(book.origin),
            "type" to book.type,
            "kind" to book.kind,
            "coverUrl" to (book.customCoverUrl ?: book.coverUrl),
            "intro" to (book.customIntro ?: book.intro),
            "wordCount" to book.wordCount,
            "latestChapterTitle" to book.latestChapterTitle,
            "chapterWordCount" to 0,
            "variable" to book.variable,
            "charset" to book.charset,
            "totalChapterNum" to book.totalChapterNum,
            "latestChapterTime" to book.latestChapterTime,
            "lastCheckCount" to book.lastCheckCount,
            "canUpdate" to book.canUpdate
        )
    }

    /**
     * Table F. The fork entity is `ExploreKind{title, type, url, style}`
     * (no `viewName`; `style` is a [FlexChildStyle] object, not an Int),
     * so the bridge maps it onto the drafted shape: `type` -> `viewName`
     * (RowUi.Type strings such as text/title/button), and `style` -> the
     * effective column count of the style (1-4, defaulting to
     * [FlexChildStyle.DEFAULT_COLS]; the legacy basis-percent field is
     * folded back into a column count when `cols` is absent).
     */
    fun exploreKind(kind: ExploreKind): Map<String, Any?> {
        val style = kind.style()
        val cols = style.cols?.coerceIn(1, FlexChildStyle.MAX_COLS)
            ?: if (style.layout_flexBasisPercent > 0f) {
                (100f / style.layout_flexBasisPercent).roundToInt()
                    .coerceIn(1, FlexChildStyle.MAX_COLS)
            } else {
                FlexChildStyle.DEFAULT_COLS
            }
        return mapOf(
            "title" to kind.title,
            "url" to kind.url,
            "viewName" to kind.type,
            "style" to cols
        )
    }

    /** Table D. */
    fun chapter(chapter: BookChapter): Map<String, Any?> {
        return mapOf(
            "url" to chapter.url,
            "title" to chapter.title,
            "index" to chapter.index,
            "isVolume" to chapter.isVolume,
            "isVip" to chapter.isVip,
            "isPay" to chapter.isPay,
            "resourceUrl" to chapter.resourceUrl,
            "tag" to chapter.tag,
            "wordCount" to chapter.wordCount,
            "variable" to chapter.variable
        )
    }
}

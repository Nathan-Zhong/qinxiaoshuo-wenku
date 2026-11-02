package org.mewx.wenku8_flutter.legado

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.utils.GSON

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

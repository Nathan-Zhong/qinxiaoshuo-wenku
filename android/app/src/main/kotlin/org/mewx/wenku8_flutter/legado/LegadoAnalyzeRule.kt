package org.mewx.wenku8_flutter.legado

import io.legado.app.data.entities.BaseSource
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRuleCore
import io.legado.app.model.analyzeRule.RuleDataInterface
import io.legado.app.model.webBook.BookInfoRefresher
import io.legado.app.model.webBook.BookInfoRefreshers
import io.legado.app.model.webBook.WebBook
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * Host-side thin subclass of the shared [AnalyzeRuleCore], mirroring the
 * fork's :app `io.legado.app.model.analyzeRule.AnalyzeRule` (and its desktop
 * twin `DesktopAnalyzeRule`): the core's `refreshTocUrl()` is an empty open
 * hook by design ("app 端 AnalyzeRule 实现"), and xiaohan-template sources
 * (漫画柜 6028, Komiic, 拷贝 variants, …) call `java.refreshTocUrl()` from
 * their TOC pre-update JS when a book's site moves — with the bare core
 * registered that call silently did nothing.
 *
 * The override below is the fork's body verbatim: it routes through the
 * [BookInfoRefreshers] provider, which [LegadoHostProviders] registers with
 * [LegadoBookInfoRefresher]. Engine code is untouched; JS dispatch reaches
 * this override through the same reflective fallback as every other core
 * method in this host.
 */
class LegadoAnalyzeRule(
    ruleData: RuleDataInterface? = null,
    source: BaseSource? = null,
    preUpdateJs: Boolean = false,
) : AnalyzeRuleCore(ruleData, source, preUpdateJs) {

    // Note (FIX9): the legacy AES pair that FIX8 temporarily delegated here
    // (aesBase64DecodeToString / aesEncodeToBase64String) was removed again:
    // on the 1.0.8 device build those host-only method names were renamed
    // away by R8 (the host bridge package was outside the keep surface), so
    // JS never saw them. The pair — plus desEncodeToBase64String — now lives
    // in the engine itself (JsExtensionsCommon), restored with upstream
    // semantics; see FIX9-REPORT.md. Do not re-add JS-visible methods to
    // host subclasses: names here are not R8-stable.

    override fun refreshTocUrl() {
        val bookSource = getSource() as? BookSource
        val book = ruleData as? Book
        if (bookSource == null || book == null) return
        val refresher = BookInfoRefreshers.getOrNull() ?: return
        runBlocking(coroutineContext) {
            withTimeout(1800000) {
                refresher.refreshBookInfo(bookSource, book, false)
            }
        }
    }
}

/**
 * Mirror of the fork :app `BookInfoRefresherImpl`: delegates the refresh to
 * the shared [WebBook.getBookInfoAwait], exactly like the fork.
 */
object LegadoBookInfoRefresher : BookInfoRefresher {
    override suspend fun refreshBookInfo(bookSource: BaseSource, book: Any, canReName: Boolean) {
        WebBook.getBookInfoAwait(
            bookSource as BookSource,
            book as Book,
            canReName,
        )
    }
}

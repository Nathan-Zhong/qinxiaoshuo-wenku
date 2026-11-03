import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;

import '../book_search.dart';
import '../catalog.dart';
import '../tag_catalogue.dart';
import 'legado_book_registry.dart';
import 'legado_dto.dart';
import 'legado_engine_client.dart';
import 'legado_image_urls.dart';
import 'search_merge.dart';

/// Body served in place of an image (manga) chapter for STRING
/// content callers (TTS, illustration repair, exports): those flows
/// keep a readable placeholder, while the reader itself renders image
/// chapters from the structured [ChapterImageList] payload instead.
const String legadoImageChapterNotice = '本章节为图片章节，漫画阅读将在后续版本提供。';

/// The image bit of the engine's BookType bitmask
/// (`BookType.image = 1 shl 6` in the fork): a book whose record
/// carries it came from an image (manga) source and every one of its
/// chapters is an image chapter — the same test the native bridge
/// applies via `source.bookSourceType == 2`.
const int legadoImageBookTypeBit = 1 << 6;

/// Whether a registry record's [LegadoBookRecord.type] bitmask marks
/// an image (manga) book.
bool isLegadoImageBookType(int type) => type & legadoImageBookTypeBit != 0;

/// Structured payload of one image chapter for the manga reader: the
/// book's source ([origin], the key every image resolution needs) and
/// the chapter's image URLs in reading order. [urls] may be empty when
/// the engine marked the chapter as an image chapter but no image
/// could be extracted — the reader shows its empty/failed state with a
/// retry instead of prose.
class ChapterImageList {
  const ChapterImageList({required this.origin, required this.urls});

  final String origin;
  final List<String> urls;

  @override
  bool operator ==(Object other) =>
      other is ChapterImageList &&
      other.origin == origin &&
      listEquals(other.urls, urls);

  @override
  int get hashCode => Object.hash(origin, Object.hashAll(urls));
}

/// Adapts the Legado engine bridge onto the host's [NovelRepository]
/// contract, so the unmodified detail page, directory, reader, shelf
/// and bookmark flows work on engine books. All identity translation
/// goes through [LegadoBookRegistry]; this class only talks to the
/// engine and maps DTOs.
class LegadoNovelRepository extends NovelRepository {
  LegadoNovelRepository({required this.client, required this.registry});

  final LegadoEngineClient client;
  final LegadoBookRegistry registry;

  Future<void>? _initFuture;
  bool _engineReady = false;

  /// The bridge requires an explicit init (Room DB + providers). It is
  /// idempotent on the native side; here it is also memoised, with the
  /// memo dropped on failure so a later call can retry. Once init has
  /// succeeded the answer is the [_engineReady] flag, not the memo
  /// future, so later callers never depend on that future's zone.
  Future<void> ensureEngineReady() {
    if (_engineReady) return Future<void>.value();
    return _initFuture ??= client
        .init()
        .then<void>((_) {
          _engineReady = true;
        })
        .catchError((Object error) {
          _initFuture = null;
          throw error;
        });
  }

  /// Sources eligible for searching/browsing under PLAN item 5: enabled
  /// text-novel (0) and manga (2) sources only.
  ///
  /// fix3: sources without a search URL are excluded as well. They can
  /// never return results (the engine answers 「搜索url不能为空」), and
  /// inside a shared search round that junk unit only ever produced a
  /// spurious per-source failure — the same reason the engine self-check
  /// probes skip them. Explore browsing is unaffected: [exploreOnly]
  /// callers keep every enabled text/manga source.
  Future<List<BookSourceSummary>> eligibleSources({
    bool exploreOnly = false,
  }) async {
    await ensureEngineReady();
    final sources = await client.listSources(
      enabledOnly: true,
      exploreOnly: exploreOnly,
    );
    return sources
        .where(
          (source) =>
              (source.type == 0 || source.type == 2) &&
              (exploreOnly || source.hasSearch),
        )
        .toList(growable: false);
  }

  Future<LegadoBookRecord> _recordFor(int id) async {
    final record = await registry.recordByIdAsync(id);
    if (record == null) {
      throw const FormatException('书籍来源记录不存在，请重新搜索后再试');
    }
    return record;
  }

  @override
  Future<List<Novel>> list() async {
    await registry.ready;
    return <Novel>[for (final record in registry.allRecords) record.toNovel()];
  }

  @override
  Future<Novel?> find(int id) async {
    await registry.ready;
    return registry.novelById(id);
  }

  /// One-shot search (collects the streaming search until it finishes):
  /// used by the repository contract's auxiliary callers (author pages
  /// and the like). The search page itself uses the streaming
  /// controller instead.
  @override
  Future<List<Novel>> search(String query) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final sources = await eligibleSources();
    if (sources.isEmpty) return const [];
    final handle = client.startSearch(
      keyword: term,
      sourceUrls: [for (final source in sources) source.sourceUrl],
    );
    var latest = const <SearchBook>[];
    var finished = false;
    final subscription = handle.events.listen((event) {
      if (event is SearchSnapshotEvent) latest = event.books;
      if (event is SearchFinishEvent || event is SearchCancelEvent) {
        finished = true;
      }
    });
    try {
      // Engine searches fan out over many slow sources; cap the wait
      // and keep whatever has arrived, like Legado's own stop button.
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (!finished && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!finished) await handle.cancel();
    } finally {
      await subscription.cancel();
    }
    final merged = mergeSearchBooks(latest);
    return <Novel>[
      for (final book in merged)
        (await registry.registerMerged(book)).first.toNovel(),
    ];
  }

  @override
  Future<Novel> detail(Novel novel) async {
    final record = await _recordFor(novel.id);
    await ensureEngineReady();
    final info = await client.getBookInfo(
      origin: record.origin,
      bookUrl: record.bookUrl,
      tocUrl: record.tocUrl.isEmpty ? null : record.tocUrl,
      variable: record.variable,
      name: record.name,
      author: record.author,
    );
    registry.absorbBookInfo(info);
    return registry.novelById(novel.id) ?? record.toNovel();
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    final record = await _recordFor(id);
    try {
      await ensureEngineReady();
      final result = await client.getChapterList(book: record.toBookInfo());
      registry.absorbBookInfo(result.book);
      await registry.saveToc(id, result.chapters);
      return legadoNovelChapters(result.chapters);
    } catch (_) {
      // A persisted directory (from an earlier successful fetch) keeps
      // the book readable when the source or network is unavailable.
      final persisted = await registry.tocOf(id);
      if (persisted != null && persisted.isNotEmpty) {
        return legadoNovelChapters(persisted);
      }
      rethrow;
    }
  }

  /// The engine fetch behind both [chapterContent] and
  /// [chapterImages]: resolves the chapter DTO, then runs the full
  /// content chain (post-processing included).
  Future<ChapterContent> _fetchChapter(
    LegadoBookRecord record,
    NovelChapter chapter,
  ) async {
    var dto = await registry.dtoChapter(record.id, chapter.id);
    if (dto == null) {
      // The reader can outlive the in-memory TOC (process restart with
      // a restored directory snapshot): refetch the directory once.
      await chapters(record.id);
      dto = await registry.dtoChapter(record.id, chapter.id);
    }
    if (dto == null || dto.isVolume) {
      throw const FormatException('章节不存在或已被来源移除');
    }
    await ensureEngineReady();
    final toc = await registry.tocOf(record.id) ?? const <Chapter>[];
    final position = toc.indexOf(dto);
    String? nextChapterUrl;
    if (position >= 0) {
      for (var i = position + 1; i < toc.length; i++) {
        if (!toc[i].isVolume) {
          nextChapterUrl = toc[i].url;
          break;
        }
      }
    }
    return client.getChapterContent(
      book: record.toBookInfo(),
      chapter: dto,
      nextChapterUrl: nextChapterUrl,
      // Reading a Legado book runs the engine's full content
      // post-processing (duplicate-title removal, re-segmentation,
      // simplified/traditional conversion, replace rules — switches
      // resolved inside the engine exactly as in Legado itself),
      // mirroring how the fork's reader always processes content.
      // Wenku books never reach this repository (see the dispatch
      // below), so their content path is untouched.
      applyReplace: true,
    );
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    final record = await _recordFor(novelId);
    final result = await _fetchChapter(record, chapter);
    if (result.isImageChapter) return legadoImageChapterNotice;
    return result.content;
  }

  /// The structured image-chapter payload for the manga reader, or
  /// null when the book is not an image book (the overwhelmingly
  /// common case — answered from the registry record's type bitmask
  /// without any engine call, so text reading pays nothing).
  ///
  /// For an image book the chapter is fetched once through the same
  /// chain as [chapterContent]. The bridge's own extracted list is
  /// preferred; when it comes back empty the chapter body is parsed
  /// again on this side ([parseLegadoImageUrls], the bridge
  /// extractor's twin) so one missed shape cannot blank a chapter.
  /// The engine's own isImageChapter verdict wins over the record: a
  /// mismatch stays on the text path rather than rendering an empty
  /// image list.
  Future<ChapterImageList?> chapterImages(
    int novelId,
    NovelChapter chapter,
  ) async {
    final record = await _recordFor(novelId);
    if (!isLegadoImageBookType(record.type)) return null;
    final result = await _fetchChapter(record, chapter);
    if (!result.isImageChapter) return null;
    final dto = await registry.dtoChapter(novelId, chapter.id);
    // The chapter's absolute URL — the base the native side resolves
    // against (`chapter.getAbsoluteURL(book)`): the DTO url resolved
    // against the book's toc/book URL when it is itself relative.
    final bookBase = record.tocUrl.isNotEmpty
        ? record.tocUrl
        : record.bookUrl;
    var baseUrl = bookBase;
    final dtoUrl = dto?.url ?? '';
    if (dtoUrl.isNotEmpty) {
      final parsed = Uri.tryParse(dtoUrl);
      if (parsed != null && parsed.hasScheme) {
        baseUrl = dtoUrl;
      } else {
        final base = Uri.tryParse(bookBase);
        if (base != null && base.hasScheme) {
          try {
            baseUrl = base.resolve(dtoUrl).toString();
          } catch (_) {
            baseUrl = dtoUrl;
          }
        } else {
          baseUrl = dtoUrl;
        }
      }
    }
    var urls = legadoChapterImageUrls(result.images, baseUrl: baseUrl);
    if (urls.isEmpty && result.content.trim().isNotEmpty) {
      urls = parseLegadoImageUrls(result.content, baseUrl: baseUrl);
    }
    return ChapterImageList(origin: record.origin, urls: urls);
  }

  // ------------------------------------------------------------------
  // Offline cache download (P5.7)
  // ------------------------------------------------------------------

  /// Starts the engine-side cache download for the inclusive engine
  /// chapter-index range; progress arrives via [cacheTaskEvents].
  /// Returns the bridge task id (for [cancelCacheTask]).
  Future<int> startCacheDownload(
    int novelId, {
    required int fromIndex,
    required int toIndex,
  }) async {
    final record = await _recordFor(novelId);
    return client.cacheChapters(
      book: record.toBookInfo(),
      fromIndex: fromIndex,
      toIndex: toIndex,
    );
  }

  /// Cache-progress events for one bridge task.
  Stream<CacheProgressEvent> cacheTaskEvents(int taskId) => client.taskEvents
      .where((event) => event is CacheProgressEvent && event.taskId == taskId)
      .cast<CacheProgressEvent>();

  /// Engine chapter indexes present in the book's offline cache.
  Future<List<int>> cachedChapterIndexes(int novelId) async {
    final record = await _recordFor(novelId);
    return client.getCachedChapterIndexes(book: record.toBookInfo());
  }

  /// Drops the book's whole engine-side offline cache.
  Future<void> clearBookCache(int novelId) async {
    final record = await _recordFor(novelId);
    await client.clearBookCache(book: record.toBookInfo());
  }

  /// Cancels a running cache task (best effort, like the bridge's
  /// other task cancels).
  Future<void> cancelCacheTask(int taskId) => client.cancelTask(taskId);
}

/// The reader-facing URL list for an image chapter: remote entries go
/// through [sanitizeLegadoImageUrls] one by one (resolve + validate);
/// entries starting with '/' are local cache files substituted by the
/// bridge (P5.7) and pass through verbatim — resolving an absolute
/// file path against the chapter URL would mangle it into a bogus
/// https URL. Order is preserved; duplicates collapse.
List<String> legadoChapterImageUrls(
  List<String> raw, {
  required String baseUrl,
}) {
  final seen = <String>{};
  final out = <String>[];
  for (final entry in raw) {
    final String? url;
    if (entry.startsWith('/')) {
      url = entry;
    } else {
      final cleaned = sanitizeLegadoImageUrls([entry], baseUrl: baseUrl);
      url = cleaned.isEmpty ? null : cleaned.first;
    }
    if (url != null && url.isNotEmpty && seen.add(url)) out.add(url);
  }
  return out;
}

/// Routes host repository calls by book identity: Legado ids go to the
/// engine repository, everything else keeps flowing to the original
/// (wenku) repository untouched. Installed as the `remote` of the
/// host's offline repository in `main.dart`, which makes every existing
/// surface (search results, shelf, bookmarks, detail, reader, TTS)
/// reach engine books without knowing about the split.
class LegadoDispatchRepository extends NovelRepository
    implements ProgressiveTagCatalogue {
  LegadoDispatchRepository({required this.legacy, required this.legado});

  final NovelRepository legacy;
  final LegadoNovelRepository legado;

  @override
  Future<List<Novel>> list() => legacy.list();

  @override
  Future<Novel?> find(int id) =>
      isLegadoBookId(id) ? legado.find(id) : legacy.find(id);

  @override
  Future<List<Novel>> search(String query) => legacy.search(query);

  @override
  Future<Novel> detail(Novel novel) =>
      isLegadoBookId(novel.id) ? legado.detail(novel) : legacy.detail(novel);

  @override
  Future<List<NovelChapter>> chapters(int id) =>
      isLegadoBookId(id) ? legado.chapters(id) : legacy.chapters(id);

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) =>
      isLegadoBookId(novelId)
      ? legado.chapterContent(novelId, chapter)
      : legacy.chapterContent(novelId, chapter);

  /// Image-chapter payloads exist only for engine books; Wenku books
  /// answer null without touching the legacy repository.
  Future<ChapterImageList?> chapterImages(
    int novelId,
    NovelChapter chapter,
  ) => isLegadoBookId(novelId)
      ? legado.chapterImages(novelId, chapter)
      : Future<ChapterImageList?>.value(null);

  // Offline cache download (P5.7): engine books only; the legacy side
  // keeps using the Flutter-side chapter cache in OfflineNovelRepository.

  Future<int> startCacheDownload(
    int novelId, {
    required int fromIndex,
    required int toIndex,
  }) => legado.startCacheDownload(
    novelId,
    fromIndex: fromIndex,
    toIndex: toIndex,
  );

  Stream<CacheProgressEvent> cacheTaskEvents(int taskId) =>
      legado.cacheTaskEvents(taskId);

  Future<List<int>> cachedChapterIndexes(int novelId) async =>
      isLegadoBookId(novelId)
      ? legado.cachedChapterIndexes(novelId)
      : const <int>[];

  Future<void> clearBookCache(int novelId) async {
    if (isLegadoBookId(novelId)) await legado.clearBookCache(novelId);
  }

  Future<void> cancelCacheTask(int taskId) => legado.cancelCacheTask(taskId);

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => legacy.browse(sort: sort, page: page, refresh: refresh);

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) => legacy.searchPage(query, page: page, refresh: refresh);

  @override
  Future<NovelPage> authorPage(
    String author, {
    int page = 1,
    bool refresh = false,
  }) => legacy.authorPage(author, page: page, refresh: refresh);

  @override
  Future<NovelPage> searchFilteredPage(
    String query, {
    BookSearchField field = BookSearchField.all,
    int page = 1,
    bool refresh = false,
  }) => legacy.searchFilteredPage(
    query,
    field: field,
    page: page,
    refresh: refresh,
  );

  @override
  Future<NovelPage> tagPage(
    String tag, {
    int page = 1,
    bool refresh = false,
    bool Function()? current,
  }) {
    final target = legacy;
    if (target is ProgressiveTagCatalogue) {
      return (target as ProgressiveTagCatalogue).tagPage(
        tag,
        page: page,
        refresh: refresh,
        current: current,
      );
    }
    return legacy.searchFilteredPage(
      tag,
      field: BookSearchField.tags,
      page: page,
      refresh: refresh,
    );
  }
}

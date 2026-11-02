import 'dart:async';

import '../book_search.dart';
import '../catalog.dart';
import '../tag_catalogue.dart';
import 'legado_book_registry.dart';
import 'legado_dto.dart';
import 'legado_engine_client.dart';
import 'search_merge.dart';

/// Body served in place of an image (manga) chapter in this phase: the
/// reader renders it as an ordinary chapter page, in the reader's own
/// typography, instead of failing. Manga image reading lands in the
/// next phase.
const String legadoImageChapterNotice = '本章节为图片章节，漫画阅读将在后续版本提供。';

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
  Future<List<BookSourceSummary>> eligibleSources({
    bool exploreOnly = false,
  }) async {
    await ensureEngineReady();
    final sources = await client.listSources(
      enabledOnly: true,
      exploreOnly: exploreOnly,
    );
    return sources
        .where((source) => source.type == 0 || source.type == 2)
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

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    final record = await _recordFor(novelId);
    var dto = await registry.dtoChapter(novelId, chapter.id);
    if (dto == null) {
      // The reader can outlive the in-memory TOC (process restart with
      // a restored directory snapshot): refetch the directory once.
      await chapters(novelId);
      dto = await registry.dtoChapter(novelId, chapter.id);
    }
    if (dto == null || dto.isVolume) {
      throw const FormatException('章节不存在或已被来源移除');
    }
    await ensureEngineReady();
    final toc = await registry.tocOf(novelId) ?? const <Chapter>[];
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
    final result = await client.getChapterContent(
      book: record.toBookInfo(),
      chapter: dto,
      nextChapterUrl: nextChapterUrl,
    );
    if (result.isImageChapter) return legadoImageChapterNotice;
    return result.content;
  }
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

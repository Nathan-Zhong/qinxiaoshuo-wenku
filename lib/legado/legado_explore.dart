import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_ui.dart';
import '../catalog.dart';
import '../glass_choices.dart';
import '../library_state.dart';
import '../novel_feed_controller.dart';
import '../pages.dart' show DiscoverPage;
import 'legado_book_registry.dart';
import 'legado_dto.dart';
import 'search_merge.dart';
import 'legado_novel_repository.dart';

/// Discovery selection state (PLAN item 10): one chosen source, one
/// chosen explore kind of that source, both remembered across launches.
///
/// A source is browsable when it is enabled, has its explore switch on,
/// is a text/manga source, and actually returns at least one browsable
/// kind. Kind lists are fetched lazily per source and cached for the
/// process; group-heading kinds (no url) structure Legado's own UI but
/// have no counterpart in the host discovery layout, so the picker
/// offers only browsable kinds.
class LegadoExploreSelection extends ChangeNotifier {
  LegadoExploreSelection({
    required this.repository,
    Future<SharedPreferences>? preferences,
  }) : _prefsFuture = preferences ?? SharedPreferences.getInstance();

  final LegadoNovelRepository repository;
  final Future<SharedPreferences> _prefsFuture;

  static const String _sourceKey = 'legado_explore_source';
  static const String _kindKey = 'legado_explore_kind';

  bool _loaded = false;
  bool _loading = false;
  Object? _loadError;
  List<BookSourceSummary> _sources = const [];
  final Map<String, List<ExploreSection>> _kindsBySource = {};

  String? _sourceUrl;
  String? _kindUrl;

  bool get loaded => _loaded;
  Object? get loadError => _loadError;
  List<BookSourceSummary> get sources => _sources;

  BookSourceSummary? get source {
    for (final source in _sources) {
      if (source.sourceUrl == _sourceUrl) return source;
    }
    return null;
  }

  String? get sourceUrl => _sourceUrl;
  String? get kindUrl => _kindUrl;

  List<ExploreSection> kindsOf(String sourceUrl) =>
      _kindsBySource[sourceUrl] ?? const [];

  List<ExploreSection> get kinds =>
      _sourceUrl == null ? const [] : kindsOf(_sourceUrl!);

  /// Browsable kinds of the selected source (headings excluded).
  List<ExploreSection> get browsableKinds =>
      kinds.where((kind) => !kind.isGroupHeading).toList(growable: false);

  ExploreSection? get kind {
    for (final kind in browsableKinds) {
      if (kind.url == _kindUrl) return kind;
    }
    return null;
  }

  /// (Re)loads the eligible source list and resolves the selection.
  ///
  /// The source list is re-queried on EVERY call: this tab is the
  /// app's landing page, so a load-once latch here meant a source
  /// imported after the first bootstrap stayed invisible to the
  /// picker (and to [LegadoExploreRepository.browse]) until the
  /// process restarted — the discovery side of the 2026-11-03
  /// "imported but nothing shows" bug. Selection resolution only
  /// re-runs when there is no still-valid selection, so paging the
  /// feed does not re-fetch kind lists.
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    try {
      final prefs = await _prefsFuture;
      final sources = await repository.eligibleSources(exploreOnly: true);
      _sources = sources;
      _kindsBySource.removeWhere(
        (url, _) => !sources.any((source) => source.sourceUrl == url),
      );
      final selectionValid =
          _sourceUrl != null &&
          sources.any((source) => source.sourceUrl == _sourceUrl);
      if (!selectionValid) {
        _sourceUrl = null;
        _kindUrl = null;
        final rememberedSource = prefs.getString(_sourceKey);
        final rememberedKind = prefs.getString(_kindKey);
        final candidates = <String>[
          ?rememberedSource,
          for (final source in sources) source.sourceUrl,
        ];
        for (final candidate in candidates) {
          final kinds = await _kinds(candidate);
          final browsable = kinds
              .where((kind) => !kind.isGroupHeading)
              .toList(growable: false);
          if (browsable.isEmpty) continue;
          _sourceUrl = candidate;
          _kindUrl = browsable.any((kind) => kind.url == rememberedKind)
              ? rememberedKind
              : browsable.first.url;
          break;
        }
      }
      _loaded = true;
      _loadError = null;
    } catch (error) {
      // Surfaced through the feed as the discovery page's usual load
      // error (with retry), not swallowed.
      _loadError = error;
      rethrow;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<List<ExploreSection>> _kinds(String sourceUrl) async {
    final cached = _kindsBySource[sourceUrl];
    if (cached != null) return cached;
    final kinds = await repository.client.getExploreKinds(sourceUrl);
    _kindsBySource[sourceUrl] = kinds;
    return kinds;
  }

  /// Picker support: kinds of an arbitrary (eligible) source.
  Future<List<ExploreSection>> kindsFor(String sourceUrl) => _kinds(sourceUrl);

  Future<void> select({
    required String sourceUrl,
    required String kindUrl,
  }) async {
    _sourceUrl = sourceUrl;
    _kindUrl = kindUrl;
    notifyListeners();
    try {
      final prefs = await _prefsFuture;
      await prefs.setString(_sourceKey, sourceUrl);
      await prefs.setString(_kindKey, kindUrl);
    } catch (_) {
      // Remembering the choice is best-effort.
    }
  }
}

/// Serves the selected source's explore lists through the repository
/// contract the discovery feed consumes. Pagination follows the
/// engine's own hasMore signal; selections are read live from
/// [selection], and the tab refreshes the feed after a change.
class LegadoExploreRepository extends NovelRepository {
  LegadoExploreRepository({required this.selection, required this.engine});

  final LegadoExploreSelection selection;
  final LegadoNovelRepository engine;

  /// Discovery cover prefetch (fix1, 2026-11-03 — a Cassidy-ordered
  /// enhancement, not a bug fix): sources whose LIST rules carry no
  /// cover rule (only ruleBookInfo has one) show text covers in
  /// explore lists, exactly as in Legado itself. For those books this
  /// repository quietly fetches the detail info in the background
  /// once a page has landed, and reports each filled book through
  /// [onCoverFilled] so the tab can swap the list item's cover in
  /// place. No UI is added and list rendering never waits for it.
  ///
  /// Deliberately conservative: at most [_coverPrefetchConcurrency]
  /// fetches in flight; one attempt per book for the repository's
  /// lifetime (the attempted set doubles as the negative cache, so a
  /// failed or coverless detail fetch is never retried — no request
  /// loops against shielded sites); every failure is silent and the
  /// text cover simply stays. Books whose registry record already
  /// has a cover (e.g. fetched earlier for the shelf) are never
  /// queued. Explore results only — search results are out of scope.
  void Function(Novel novel)? onCoverFilled;

  /// fix3 (performance): lowered from 3 to 2 — each prefetch is a full
  /// detail fetch whose completion swaps a feed row and starts a cover
  /// download/decode; two in flight still fill a page promptly while
  /// leaving more headroom for scrolling and page transitions. The
  /// prefetch itself (Cassidy's fix1 request) is unchanged.
  static const int _coverPrefetchConcurrency = 2;
  final Set<String> _coverPrefetchAttempted = <String>{};
  final List<LegadoBookRecord> _coverPrefetchQueue = <LegadoBookRecord>[];
  int _coverPrefetchActive = 0;

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    await selection.load();
    final sourceUrl = selection.sourceUrl;
    final kindUrl = selection.kindUrl;
    if (sourceUrl == null || kindUrl == null) {
      return NovelPage(items: const [], page: page, totalPages: page);
    }
    final result = await engine.client.getExploreBooks(
      sourceUrl: sourceUrl,
      kindUrl: kindUrl,
      page: page,
    );
    final novels = <Novel>[];
    final records = <LegadoBookRecord>[];
    final damagedNameKeys = <String>{};
    for (final book in result.books) {
      // fix2: remember which hits arrived with font-obfuscated titles
      // (invisible codepoints) so the background prefetch below can
      // repair them from the detail page, like it already does for
      // missing covers.
      if (legadoHasInvisibleChars(book.name)) {
        damagedNameKeys.add('${book.origin}\n${book.bookUrl}');
      }
      final record = await engine.registry.registerSearchBook(book);
      records.add(record);
      novels.add(record.toNovel());
    }
    _scheduleCoverPrefetch(records, damagedNameKeys: damagedNameKeys);
    return NovelPage(
      items: novels,
      page: page,
      totalPages: result.hasMore ? page + 1 : page,
      totalItems: novels.length,
    );
  }

  /// Book keys queued for a title repair (fix2): their list hits
  /// carried invisible codepoints, so a detail fetch should replace
  /// the stripped title with the real one even when the book already
  /// has a cover.
  final Set<String> _nameRepairKeys = <String>{};

  void _scheduleCoverPrefetch(
    List<LegadoBookRecord> records, {
    Set<String> damagedNameKeys = const <String>{},
  }) {
    for (final record in records) {
      final needsNameRepair = damagedNameKeys.contains(record.bookKey);
      if (needsNameRepair) _nameRepairKeys.add(record.bookKey);
      final cover = record.coverUrl;
      if (!needsNameRepair && cover != null && cover.isNotEmpty) continue;
      if (!_coverPrefetchAttempted.add(record.bookKey)) continue;
      _coverPrefetchQueue.add(record);
    }
    _pumpCoverPrefetch();
  }

  void _pumpCoverPrefetch() {
    while (_coverPrefetchActive < _coverPrefetchConcurrency &&
        _coverPrefetchQueue.isNotEmpty) {
      final record = _coverPrefetchQueue.removeAt(0);
      _coverPrefetchActive++;
      unawaited(
        _fetchCover(record).whenComplete(() {
          _coverPrefetchActive--;
          _pumpCoverPrefetch();
        }),
      );
    }
  }

  Future<void> _fetchCover(LegadoBookRecord record) async {
    try {
      // The record may have gained its cover through another path
      // (detail page, shelf) while it waited in the queue.
      final nameBefore = record.name;
      final needsFetch =
          (record.coverUrl == null || record.coverUrl!.isEmpty) ||
          _nameRepairKeys.contains(record.bookKey);
      if (needsFetch) {
        await engine.ensureEngineReady();
        final info = await engine.client.getBookInfo(
          origin: record.origin,
          bookUrl: record.bookUrl,
          tocUrl: record.tocUrl.isEmpty ? null : record.tocUrl,
          variable: record.variable,
          name: record.name,
          author: record.author,
        );
        engine.registry.absorbBookInfo(info);
      }
      _nameRepairKeys.remove(record.bookKey);
      final cover = record.coverUrl;
      if ((cover != null && cover.isNotEmpty) ||
          record.name != nameBefore) {
        onCoverFilled?.call(record.toNovel());
      }
    } catch (_) {
      // Silent by design (see [onCoverFilled]): the attempted set
      // keeps this book out of the queue for the rest of the session.
    }
  }

  @override
  Future<List<Novel>> list() => engine.list();

  @override
  Future<Novel?> find(int id) => engine.find(id);

  @override
  Future<List<Novel>> search(String query) => engine.search(query);

  @override
  Future<Novel> detail(Novel novel) => engine.detail(novel);

  @override
  Future<List<NovelChapter>> chapters(int id) => engine.chapters(id);

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) =>
      engine.chapterContent(novelId, chapter);
}

/// The discovery tab: the host's own [DiscoverPage], fed by the
/// selected source's explore lists. The source/kind picker sits behind
/// the page's existing category button (same slot, same icon) and is
/// built from the same sheet/choice components as the original sort
/// picker.
class LegadoDiscoverTab extends StatefulWidget {
  const LegadoDiscoverTab({
    super.key,
    required this.state,
    required this.repository,
    required this.engine,
    required this.onSearch,
    this.showHeader = true,
  });

  final LibraryState state;
  final NovelRepository repository;
  final LegadoNovelRepository engine;
  final VoidCallback onSearch;
  final bool showHeader;

  /// Mirrors [DiscoverPage.buildHeader] so the shell's pinned header
  /// keeps coming from the page itself.
  Widget buildHeader(BuildContext context) => DiscoverPage(
    books: const [],
    state: state,
    repository: repository,
    onSearch: onSearch,
  ).buildHeader(context);

  @override
  State<LegadoDiscoverTab> createState() => _LegadoDiscoverTabState();
}

class _LegadoDiscoverTabState extends State<LegadoDiscoverTab> {
  late final LegadoExploreSelection _selection = LegadoExploreSelection(
    repository: widget.engine,
  );
  late final LegadoExploreRepository _exploreRepository =
      LegadoExploreRepository(selection: _selection, engine: widget.engine);
  late final NovelFeedController _feed = NovelFeedController(
    _exploreRepository,
    initialItems: 20,
  );

  @override
  void initState() {
    super.initState();
    _selection.addListener(_selectionChanged);
    // Cover prefetch results swap the matching feed item in place;
    // the feed ignores them once it has been disposed, and this tab
    // drops them after unmount.
    _exploreRepository.onCoverFilled = (novel) {
      if (!mounted) return;
      _feed.replaceItems([novel]);
    };
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      await _selection.load();
    } catch (_) {
      // browse() re-runs load and surfaces the failure through the
      // feed's error state; the bootstrap only needs the feed started.
    }
    if (!mounted) return;
    await _feed.loadInitial();
  }

  void _selectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _exploreRepository.onCoverFilled = null;
    _selection.removeListener(_selectionChanged);
    _selection.dispose();
    _feed.dispose();
    super.dispose();
  }

  /// Null while nothing is selected so the discovery header keeps the
  /// catalogue's original sort-label fallback instead of duplicating
  /// the tab name.
  String? get _categoryTitle {
    final kind = _selection.kind;
    if (kind != null) return kind.title;
    final source = _selection.source;
    if (source != null) return source.sourceName;
    return null;
  }

  Future<void> _chooseSource(BuildContext context) async {
    final reduceMotion = widget.state.reduceMotion;
    final picked = await showJellySheet<({String sourceUrl, String kindUrl})>(
      context: context,
      reduceMotion: reduceMotion,
      heightFactor: .75,
      builder: (_) => LegadoExplorePicker(selection: _selection),
    );
    if (!context.mounted || picked == null) return;
    await _selection.select(
      sourceUrl: picked.sourceUrl,
      kindUrl: picked.kindUrl,
    );
    await _feed.refresh();
  }

  @override
  Widget build(BuildContext context) => DiscoverPage(
    books: const [],
    feed: _feed,
    state: widget.state,
    repository: widget.repository,
    showHeader: widget.showHeader,
    onSearch: widget.onSearch,
    categoryTitle: _categoryTitle,
    onChooseCategory: _chooseSource,
  );
}

/// Source + kind chooser shown from the discovery category button,
/// composed from the same pieces as [DiscoveryFilters]: an
/// [ArchiveSection] head, [GlassChoiceGroup] option rows and the
/// sheet's own scroll padding.
class LegadoExplorePicker extends StatefulWidget {
  const LegadoExplorePicker({super.key, required this.selection});

  final LegadoExploreSelection selection;

  @override
  State<LegadoExplorePicker> createState() => _LegadoExplorePickerState();
}

class _LegadoExplorePickerState extends State<LegadoExplorePicker> {
  late String? _sourceUrl = widget.selection.sourceUrl;
  List<ExploreSection>? _kinds;
  bool _loadingKinds = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (_sourceUrl != null) unawaited(_loadKinds(_sourceUrl!));
    if (widget.selection.sources.isEmpty) {
      unawaited(_loadSources());
    }
  }

  Future<void> _loadSources() async {
    try {
      await widget.selection.load();
      if (!mounted) return;
      setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _loadKinds(String sourceUrl) async {
    setState(() {
      _loadingKinds = true;
      _kinds = null;
      _error = null;
    });
    try {
      final kinds = await widget.selection.kindsFor(sourceUrl);
      if (!mounted || _sourceUrl != sourceUrl) return;
      setState(() {
        _kinds = kinds;
        _loadingKinds = false;
      });
    } catch (error) {
      if (!mounted || _sourceUrl != sourceUrl) return;
      setState(() {
        _error = error;
        _loadingKinds = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.selection.sources;
    final browsable = <ExploreSection>[
      for (final kind in _kinds ?? const <ExploreSection>[])
        if (!kind.isGroupHeading) kind,
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ArchiveSection(title: '选择书源', code: 'DISCOVER / SOURCES'),
          const SizedBox(height: 16),
          if (_error != null && sources.isEmpty)
            const AppText('书源加载失败，请稍后重试')
          else if (sources.isEmpty)
            const AppText('暂无带发现内容的书源，请先到「我的 → 书源管理」导入书源，或使用搜索找书')
          else ...[
            GlassChoiceGroup<String>(
              name: 'explore-source',
              label: '书源',
              value: _sourceUrl ?? '',
              options: {
                for (final source in sources)
                  source.sourceUrl: source.sourceName,
              },
              optionName: (url) => url,
              onChanged: (url) {
                setState(() => _sourceUrl = url);
                unawaited(_loadKinds(url));
              },
            ),
            const SizedBox(height: 12),
            if (_loadingKinds)
              // Bounded height: the sheet scrolls, so the skeleton
              // cannot expand freely like it does in page bodies.
              const SizedBox(
                height: 96,
                child: LoadingSkeleton(layout: SkeletonLayout.actions),
              )
            else if (_error != null)
              const AppText('分类加载失败，请稍后重试')
            else if (_sourceUrl != null && _kinds != null && browsable.isEmpty)
              const AppText('该书源暂无发现内容，可使用搜索找书')
            else if (browsable.isNotEmpty)
              GlassChoiceGroup<String>(
                name: 'explore-kind',
                label: '分类',
                value: widget.selection.kindUrl ?? '',
                options: {for (final kind in browsable) kind.url!: kind.title},
                optionName: (url) => url,
                onChanged: (url) => Navigator.pop(context, (
                  sourceUrl: _sourceUrl!,
                  kindUrl: url,
                )),
              ),
          ],
        ],
      ),
    );
  }
}

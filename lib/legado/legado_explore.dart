import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_ui.dart';
import '../catalog.dart';
import '../glass_choices.dart';
import '../library_state.dart';
import '../novel_feed_controller.dart';
import '../pages.dart' show DiscoverPage;
import 'legado_dto.dart';
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

  /// Loads (once) the eligible source list and restores the remembered
  /// selection, falling back to the first browsable source/kind.
  Future<void> load() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final prefs = await _prefsFuture;
      final sources = await repository.eligibleSources(exploreOnly: true);
      _sources = sources;
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
      _loaded = true;
      _loadError = null;
    } catch (error) {
      // Surfaced through the feed as the discovery page's usual load
      // error (with retry), not swallowed. `_loaded` stays false so a
      // retry re-runs the load instead of serving the failure forever.
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
    for (final book in result.books) {
      final record = await engine.registry.registerSearchBook(book);
      novels.add(record.toNovel());
    }
    return NovelPage(
      items: novels,
      page: page,
      totalPages: result.hasMore ? page + 1 : page,
      totalItems: novels.length,
    );
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
  late final NovelFeedController _feed = NovelFeedController(
    LegadoExploreRepository(selection: _selection, engine: widget.engine),
    initialItems: 20,
  );

  @override
  void initState() {
    super.initState();
    _selection.addListener(_selectionChanged);
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

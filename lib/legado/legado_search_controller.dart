import 'dart:async';

import '../book_search.dart';
import '../catalog.dart';
import '../novel_feed_controller.dart';
import 'legado_book_registry.dart';
import 'legado_engine_client.dart';
import 'legado_novel_repository.dart';
import 'search_merge.dart';

/// Placeholder repository for the superclass: every loading entry point
/// of [NovelFeedController] is overridden below, so this repository is
/// never actually queried; it exists only to satisfy the constructor.
class _InertRepository extends NovelRepository {
  const _InertRepository();

  @override
  Future<List<Novel>> list() async => const [];

  @override
  Future<Novel?> find(int id) async => null;

  @override
  Future<List<Novel>> search(String query) async => const [];

  @override
  Future<Novel> detail(Novel novel) async => novel;

  @override
  Future<List<NovelChapter>> chapters(int id) async => const [];

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async => '';
}

/// User-facing text for a search round that failed with no results.
///
/// Raw engine messages pass through unchanged, with one translation:
/// the Cloudflare solver's failure (G5) reaches Dart as the fork's
/// English IOException text ("Failed to bypass Cloudflare challenge",
/// possibly wrapped in the exception brief), which says nothing to a
/// reader — it becomes a plain explanation in the app's own wording.
/// The automatic solve is silent and self-retrying inside the request
/// (see LegadoCloudflare.kt), so by the time this text shows, the
/// shield genuinely needs a human pass (the source's own verification
/// entry, when it has one) or a later retry.
String legadoSearchRoundErrorText(SearchErrorEvent error) {
  final message = error.message;
  if (message.isEmpty) {
    return '书源搜索失败（${error.errorCode}）';
  }
  if (message.contains('Failed to bypass Cloudflare')) {
    return '该网站的人机验证（Cloudflare）未能自动通过，请稍后重试';
  }
  return message;
}

/// The home shell's global search feed, backed by the Legado engine's
/// streaming search instead of a one-shot repository query.
///
/// It keeps the exact public surface the shell and the inline search
/// results consume from [NovelFeedController] (items / loading / error /
/// hasMore / page / query / searchField / resultRevision /
/// resultStartIndex / loadInitial / refresh / retry / searchFor /
/// scheduleSearch / cancelScheduledSearch / loadMore /
/// selectSearchField), while underneath:
///
/// - a search fans out to every enabled text/manga source at once
///   (PLAN item 6), results are published snapshot by snapshot as they
///   arrive, and starting a new search (or cancelling) stops the old
///   one through the bridge's `cancelTask`;
/// - every full snapshot is re-merged with the定版 merge function
///   (item 7), so one book with several sources stays one row;
/// - the field filter （全部/书名/作者/标签/ID) is applied locally on the
///   merged list, mirroring `NovelRepository.searchFilteredPage`.
class LegadoSearchFeedController extends NovelFeedController {
  LegadoSearchFeedController({
    required this.engineRepository,
    this.onNoSourcesHint,
  }) : super(const _InertRepository(), search: true);

  /// Owns the engine client (init memoisation, source eligibility) and
  /// the book registry this controller reads through. (Named to not
  /// shadow the superclass's inert [repository] field.)
  final LegadoNovelRepository engineRepository;

  LegadoEngineClient get client => engineRepository.client;
  LegadoBookRegistry get registry => engineRepository.registry;

  /// Called (at most once per search opening) when a search cannot run
  /// because no eligible source is enabled, so the shell can point the
  /// user at 「我的 → 书源管理」 with the app's usual feedback.
  void Function()? onNoSourcesHint;

  // Own state (the superclass's fields stay unused; its loading entry
  // points are all overridden).
  List<Novel> _items = const [];
  List<Novel> _rawItems = const [];
  bool _loadingValue = false;
  Object? _errorValue;
  bool _hasMoreValue = false;
  int _pageValue = 0;
  int? _totalItemsValue;
  bool _refreshingValue = false;
  bool _refreshFailedValue = false;
  int _resultRevisionValue = 0;
  int _resultStartIndexValue = 0;
  String _queryValue = '';
  BookSearchField _searchFieldValue = BookSearchField.all;

  Timer? _debounce;
  LegadoSearchHandle? _handle;
  StreamSubscription<LegadoSearchEvent>? _subscription;
  int _generation = 0;
  int _roundStartIndex = 0;
  bool _hintShown = false;
  bool _disposed = false;

  /// First bridge-reported failure of the current search round. The
  /// engine swallows per-source failures into a zero-result finish;
  /// the bridge re-emits them as [SearchErrorEvent]s, and a round that
  /// ends empty WITH a recorded failure is an error, not "no results".
  SearchErrorEvent? _roundError;

  // -------------------------------------------------------------------
  // NovelFeedController surface
  // -------------------------------------------------------------------

  @override
  List<Novel> get items => _items;

  @override
  int get resultRevision => _resultRevisionValue;

  @override
  int get resultStartIndex => _resultStartIndexValue;

  @override
  bool get loading => _loadingValue;
  @override
  set loading(bool value) => _loadingValue = value;

  @override
  Object? get error => _errorValue;
  @override
  set error(Object? value) => _errorValue = value;

  @override
  bool get hasMore => _hasMoreValue;
  @override
  set hasMore(bool value) => _hasMoreValue = value;

  @override
  int get page => _pageValue;
  @override
  set page(int value) => _pageValue = value;

  @override
  int? get totalItems => _totalItemsValue;
  @override
  set totalItems(int? value) => _totalItemsValue = value;

  @override
  bool get refreshing => _refreshingValue;
  @override
  set refreshing(bool value) => _refreshingValue = value;

  @override
  bool get refreshFailed => _refreshFailedValue;
  @override
  set refreshFailed(bool value) => _refreshFailedValue = value;

  @override
  String get query => _queryValue;
  @override
  set query(String value) => _queryValue = value;

  @override
  BookSearchField get searchField => _searchFieldValue;
  @override
  set searchField(BookSearchField value) => _searchFieldValue = value;

  @override
  Future<void> loadInitial() async {
    // No recommendation feed exists in this app (PLAN item 11): an
    // empty query stays idle. Still warm the source list so the
    // no-sources hint can fire as soon as the search opens.
    if (_queryValue.trim().isNotEmpty) {
      await searchFor(_queryValue);
      return;
    }
    await _warmSources();
  }

  @override
  Future<void> refresh() {
    _debounce?.cancel();
    _debounce = null;
    if (_queryValue.trim().isEmpty) return loadInitial();
    return searchFor(_queryValue);
  }

  @override
  Future<void> retry() {
    if (_queryValue.trim().isEmpty) return loadInitial();
    return searchFor(_queryValue);
  }

  @override
  Future<void> searchFor(String value) async {
    if (_disposed) return;
    final term = value.trim();
    if (_queryValue == term &&
        ((_loadingValue && _debounce == null) ||
            (_pageValue > 0 && _errorValue == null))) {
      return;
    }
    _debounce?.cancel();
    _debounce = null;
    _queryValue = term;
    _resetResults();
    await _runSearch(term);
  }

  @override
  void scheduleSearch(
    String value, {
    Duration delay = const Duration(milliseconds: 280),
  }) {
    if (_disposed) return;
    final term = value.trim();
    if (_queryValue == term &&
        (_debounce != null ||
            _loadingValue ||
            (_pageValue > 0 && _errorValue == null))) {
      return;
    }
    _debounce?.cancel();
    _queryValue = term;
    _resetResults();
    _loadingValue = true;
    notifyListeners();
    _debounce = Timer(delay, () {
      _debounce = null;
      unawaited(_runSearch(term));
    });
  }

  /// Closing the search (or abandoning the typed query) stops any
  /// pending debounce and any in-flight engine search — the stop
  /// affordance PLAN item 6 asks for.
  @override
  void cancelScheduledSearch() {
    final hadDebounce = _debounce != null;
    _debounce?.cancel();
    _debounce = null;
    if (hadDebounce) {
      _loadingValue = false;
      _refreshingValue = false;
      notifyListeners();
    }
    if (_handle != null) {
      _generation++;
      unawaited(_cancelHandle());
      if (_loadingValue) {
        _loadingValue = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> loadMore() async {
    final handle = _handle;
    if (_disposed || handle == null || _loadingValue || !_hasMoreValue) {
      return;
    }
    if (_errorValue != null) return;
    _loadingValue = true;
    _roundError = null;
    _roundStartIndex = _rawItems.length;
    notifyListeners();
    try {
      await handle.loadMore();
    } catch (_) {
      if (_disposed) return;
      _loadingValue = false;
      notifyListeners();
    }
  }

  @override
  Future<void> selectSearchField(BookSearchField value) async {
    if (_disposed || _searchFieldValue == value) return;
    _searchFieldValue = value;
    _applyFilter();
    notifyListeners();
  }

  // -------------------------------------------------------------------
  // Engine search plumbing
  // -------------------------------------------------------------------

  void _resetResults() {
    _generation++;
    _cancelHandleSync();
    _items = const [];
    _rawItems = const [];
    _pageValue = 0;
    _totalItemsValue = null;
    _hasMoreValue = false;
    _errorValue = null;
    _refreshFailedValue = false;
    _loadingValue = false;
    _refreshingValue = false;
    _resultStartIndexValue = 0;
    _roundError = null;
  }

  Future<void> _warmSources() async {
    try {
      final sources = await _eligibleSourceUrls();
      if (sources.isEmpty) _showHintOnce();
    } catch (_) {
      // Warming is best-effort; a real search surfaces errors itself.
    }
  }

  Future<List<String>> _eligibleSourceUrls() async {
    await registry.ready;
    final sources = await engineRepository.eligibleSources();
    return <String>[for (final source in sources) source.sourceUrl];
  }

  void _showHintOnce() {
    if (_hintShown) return;
    _hintShown = true;
    onNoSourcesHint?.call();
  }

  /// The hint may fire again on the next search opening.
  void resetHint() => _hintShown = false;

  Future<void> _runSearch(String term) async {
    if (_disposed) return;
    final generation = ++_generation;
    _cancelHandleSync();
    if (term.isEmpty) {
      _loadingValue = false;
      notifyListeners();
      return;
    }
    _loadingValue = true;
    _errorValue = null;
    _refreshFailedValue = false;
    _roundStartIndex = 0;
    _roundError = null;
    notifyListeners();
    try {
      final sourceUrls = await _eligibleSourceUrls();
      if (_disposed || generation != _generation) return;
      if (sourceUrls.isEmpty) {
        _loadingValue = false;
        _hasMoreValue = false;
        _pageValue = 1;
        _showHintOnce();
        notifyListeners();
        return;
      }
      final handle = client.startSearch(keyword: term, sourceUrls: sourceUrls);
      _handle = handle;
      _subscription = handle.events.listen(
        (event) => _onSearchEvent(generation, event),
        onError: (Object error) {
          if (_disposed || generation != _generation) return;
          _loadingValue = false;
          if (_items.isEmpty) _errorValue = error;
          notifyListeners();
        },
      );
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _loadingValue = false;
      _errorValue = error;
      notifyListeners();
    }
  }

  Future<void> _onSearchEvent(int generation, LegadoSearchEvent event) async {
    if (_disposed || generation != _generation) return;
    switch (event) {
      case SearchSnapshotEvent():
        final merged = mergeSearchBooks(event.books);
        final novels = <Novel>[];
        for (final book in merged) {
          final records = await registry.registerMerged(book);
          if (records.isNotEmpty) novels.add(records.first.toNovel());
        }
        if (_disposed || generation != _generation) return;
        final previousIds = [for (final novel in _items) novel.id];
        _rawItems = List.unmodifiable(novels);
        _hasMoreValue = event.hasMore;
        if (_pageValue == 0) _pageValue = 1;
        _applyFilter();
        final nextIds = [for (final novel in _items) novel.id];
        if (!_listEquals(previousIds, nextIds)) {
          _resultStartIndexValue = _roundStartIndex.clamp(0, _items.length);
          _resultRevisionValue++;
        }
        notifyListeners();
      case SearchErrorEvent():
        // Recorded, not yet surfaced: the round's finish decides
        // whether this was a hard failure (still no items) or a
        // partial success (items from other sources stay usable).
        _roundError ??= event;
      case SearchFinishEvent():
        _loadingValue = false;
        _hasMoreValue = event.hasMore;
        if (_pageValue == 0) _pageValue = 1;
        final roundError = _roundError;
        if (_items.isEmpty && roundError != null) {
          _errorValue = FormatException(legadoSearchRoundErrorText(roundError));
        }
        _totalItemsValue = _items.length;
        notifyListeners();
      case SearchCancelEvent():
        _loadingValue = false;
        _handle = null;
        notifyListeners();
      case UnknownSearchEvent():
        break;
    }
  }

  void _applyFilter() {
    if (_searchFieldValue == BookSearchField.all) {
      _items = _rawItems;
    } else {
      final pattern = BookSearch(_queryValue, field: _searchFieldValue);
      _items = List.unmodifiable(
        _rawItems.where(
          (book) => pattern.matches(
            title: book.title,
            author: book.author,
            tags: book.genre,
            summary: book.summary,
            id: '${book.id}',
          ),
        ),
      );
    }
    _totalItemsValue = _items.length;
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _cancelHandleSync() {
    final handle = _handle;
    _handle = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (handle != null) unawaited(handle.cancel().catchError((Object _) {}));
  }

  Future<void> _cancelHandle() async {
    final handle = _handle;
    _handle = null;
    await _subscription?.cancel();
    _subscription = null;
    if (handle != null) {
      try {
        await handle.cancel();
      } catch (_) {
        // The native side treats cancelling an unknown task as a no-op;
        // a channel failure here must not escape into the UI.
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _generation++;
    _cancelHandleSync();
    super.dispose();
  }
}

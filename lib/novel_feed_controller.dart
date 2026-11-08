import 'dart:async';

import 'package:flutter/foundation.dart';

import 'catalog.dart';
import 'blocked_tags.dart';
import 'book_search.dart';
import 'publication_catalog.dart';
import 'tag_catalogue.dart';

/// Owns page cursors, stale-result isolation and explicit recovery. A failed
/// page never advances the cursor or loops automatically against the service.
class NovelFeedController extends ChangeNotifier {
  NovelFeedController(
    this.repository, {
    this.search = false,
    this.initialItems = 0,
  }) : assert(initialItems >= 0);
  final NovelRepository repository;
  final bool search;

  /// Discovery can warm a useful list below the ten featured files. Service
  /// page sizes/cursors stay unchanged; search remains one page at a time.
  final int initialItems;
  List<Novel> _items = const [];
  BlockedTags _blockedTags = BlockedTags.empty;
  List<Novel>? _visibleItems;
  int _visibleResultStartIndex = 0;
  int _blockedItemCount = 0;
  PublicationLibrary? _publication;
  PublicationCatalog? _publicationCatalog;

  /// An explicit publication category replaces, rather than combines with,
  /// ranking and tag requests because its service has its own ordered cursor.
  PublicationLibrary? get publication => _publication;

  NovelSort sort = NovelSort.lastUpdate;
  String query = '';
  BookSearchField searchField = BookSearchField.all;
  List<String> tags = const [];
  final _tagSuggestions = <String>{};
  Set<String> get tagSuggestions => Set.unmodifiable(_tagSuggestions);
  int page = 0;
  int? totalItems;
  bool hasMore = true;
  bool loading = false;
  TagSearchProgress? _tagProgress;
  String? get tagProgressLabel {
    final progress = _tagProgress;
    if (!loading || progress == null) return null;
    final total = progress.totalPages;
    return total == null
        ? '正在筛选标签 · 已检查 ${progress.scannedPages} 页'
        : '正在筛选标签 · 已检查 ${progress.scannedPages} / $total 页';
  }

  Object? error;
  bool refreshFailed = false;
  int _generation = 0;
  // Accepted data batches, not request attempts. Failed/stale requests must not
  // restart presentation, and appended pages must leave the old rows alone.
  int _resultRevision = 0;
  int _resultStartIndex = 0;
  bool refreshing = false;
  bool _disposed = false;
  Timer? _searchDelay;

  List<Novel> get allItems => _items;
  List<Novel> get items {
    if (_blockedTags.isEmpty) return _items;
    _projectVisibleItems();
    return _visibleItems!;
  }

  bool get hasBlockedTags => _blockedTags.isNotEmpty;
  int get blockedItemCount {
    if (_blockedTags.isEmpty) return 0;
    _projectVisibleItems();
    return _blockedItemCount;
  }

  bool get hasLoaded => page > 0;
  int get resultRevision => _resultRevision;
  int get resultStartIndex {
    if (_blockedTags.isEmpty) return _resultStartIndex;
    _projectVisibleItems();
    return _visibleResultStartIndex;
  }

  void _projectVisibleItems() {
    if (_visibleItems != null) return;
    final visible = <Novel>[];
    var first = 0;
    for (var index = 0; index < _items.length; index++) {
      final book = _items[index];
      if (_blockedTags.blocks(book)) continue;
      visible.add(book);
      if (index < _resultStartIndex) first++;
    }
    _visibleItems = List.unmodifiable(visible);
    _visibleResultStartIndex = first;
    _blockedItemCount = _items.length - visible.length;
  }

  /// Filter the already accepted pages, without touching service cursors or
  /// starting a request. Clearing a rule restores the retained original rows.
  void setBlockedTags(Iterable<String> values) {
    if (_disposed) return;
    final next = BlockedTags(values);
    if (_blockedTags.sameAs(next)) return;
    _blockedTags = next;
    _visibleItems = null;
    _resultStartIndex = 0;
    _resultRevision++;
    notifyListeners();
  }

  Future<void> refresh() {
    _searchDelay?.cancel();
    _searchDelay = null;
    return _load(replace: true, force: true);
  }

  /// Swaps already-loaded items for fresher snapshots of the same
  /// books (matched by id) when the replacement brings a cover the
  /// loaded item lacks, or a repaired title (fix2: the discovery
  /// prefetch also replaces font-obfuscated list titles with the
  /// detail page's real title). Pagination, the result revision and
  /// the entrance sequence are deliberately untouched: the discovery
  /// cover prefetch (fix1) uses this to trade a text cover for the
  /// real one a background detail fetch brought back, in place.
  /// Unknown ids and unchanged snapshots are ignored.
  void replaceItems(Iterable<Novel> replacements) {
    if (_disposed) return;
    final byId = <int, Novel>{
      for (final novel in replacements) novel.id: novel,
    };
    if (byId.isEmpty || _items.isEmpty) return;
    var changed = false;
    final next = List<Novel>.of(_items);
    for (var i = 0; i < next.length; i++) {
      final fresh = byId[next[i].id];
      if (fresh != null &&
          ((fresh.coverUrl != null && fresh.coverUrl != next[i].coverUrl) ||
              fresh.title != next[i].title)) {
        next[i] = fresh;
        changed = true;
      }
    }
    if (!changed) return;
    _items = List.unmodifiable(next);
    _visibleItems = null;
    notifyListeners();
  }

  Future<void> loadInitial() => _load(replace: true);
  Future<void> loadMore() async {
    if (loading || !hasMore || error != null) return;
    await _load(replace: false);
  }

  Future<void> retry() => loading
      ? Future.value()
      : _load(replace: page == 0 || refreshFailed, force: true);

  Future<void> selectSort(NovelSort value) async {
    if (sort == value && tags.isEmpty && _publication == null) return;
    sort = value;
    tags = const [];
    _publication = null;
    _publicationCatalog = null;
    _reset();
    await _load(replace: true);
  }

  Future<void> selectTags(Iterable<String> values) async {
    final next =
        values.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList()
          ..sort();
    if (listEquals(tags, next) && _publication == null) return;
    tags = List.unmodifiable(next);
    _publication = null;
    _publicationCatalog = null;
    _reset();
    await _load(replace: true);
  }

  /// Browse a publication through the same paging, refresh and stale-response
  /// isolation as discovery. The caller restores the existing account first.
  Future<void> selectPublication(
    PublicationLibrary value, {
    required PublicationCatalog catalog,
    bool force = false,
  }) async {
    if (_disposed || search) return;
    if (!force &&
        _publication?.id == value.id &&
        identical(_publicationCatalog, catalog)) {
      return;
    }
    _publication = value;
    _publicationCatalog = catalog;
    tags = const [];
    _reset();
    await _load(replace: true, force: force);
  }

  /// A changed identity must not retain another account's visible book list.
  /// A refreshed connection for the same identity preserves resolved content.
  Future<void> refreshPublicationSession({required bool retain}) async {
    if (_disposed || _publication == null) return;
    if (!retain) _reset();
    await _load(replace: true, force: true);
  }

  Future<void> searchFor(String value) async {
    if (_disposed) return;
    final term = value.trim();
    if (query == term &&
        ((loading && _searchDelay == null) || (page > 0 && error == null))) {
      return;
    }
    _searchDelay?.cancel();
    _searchDelay = null;
    query = term;
    _reset();
    await _load(replace: true);
  }

  Future<void> selectSearchField(BookSearchField value) async {
    if (_disposed || searchField == value) return;
    _searchDelay?.cancel();
    _searchDelay = null;
    searchField = value;
    _reset();
    await _load(replace: true);
  }

  /// Invalidate old results immediately, but request only the final input after
  /// a short quiet period. Pagination cannot start during the debounce window.
  void scheduleSearch(
    String value, {
    Duration delay = const Duration(milliseconds: 280),
  }) {
    if (_disposed || !search) return;
    final term = value.trim();
    if (query == term &&
        (_searchDelay != null || loading || (page > 0 && error == null))) {
      return;
    }
    _searchDelay?.cancel();
    query = term;
    _reset();
    loading = true;
    notifyListeners();
    _searchDelay = Timer(delay, () {
      _searchDelay = null;
      unawaited(_load(replace: true));
    });
  }

  /// A closed search keeps its last result/query, without launching a request
  /// which the user can no longer see. Reopening can explicitly resume it.
  void cancelScheduledSearch() {
    if (_searchDelay == null) return;
    _searchDelay!.cancel();
    _searchDelay = null;
    loading = false;
    refreshing = false;
    notifyListeners();
  }

  void _reset() {
    _generation++;
    _items = const [];
    _visibleItems = null;
    page = 0;
    totalItems = null;
    hasMore = true;
    error = null;
    refreshFailed = false;
    loading = false;
    refreshing = false;
    _tagProgress = null;
  }

  Future<void> _load({required bool replace, bool force = false}) async {
    if (_disposed) return;
    if (!replace && loading) return;
    final generation = replace ? ++_generation : _generation;
    var requestedPage = replace ? 1 : page + 1;
    var replacing = replace;
    final requestedSort = sort;
    final requestedPublication = _publication;
    final publicationCatalog = _publicationCatalog;
    final filteringTags = !search && tags.isNotEmpty;
    final requestedQuery = filteringTags ? tags.join(' ') : query;
    final requestedField = filteringTags ? BookSearchField.tags : searchField;
    final hadItems = _items.isNotEmpty;
    final retaining = replace && hadItems;
    loading = true;
    _tagProgress = null;
    refreshing = replace && _items.isNotEmpty;
    error = null;
    refreshFailed = false;
    notifyListeners();
    try {
      while (true) {
        void acceptTagProgress(TagSearchProgress progress) {
          if (_disposed || generation != _generation) return;
          _tagProgress = progress;
          if (!retaining && progress.items.isNotEmpty) {
            final oldCount = _items.length;
            final merged = <int, Novel>{
              if (!replacing)
                for (final item in _items) item.id: item,
              for (final item in progress.items) item.id: item,
            };
            _items = List.unmodifiable(merged.values);
            _visibleItems = null;
            _resultStartIndex = replacing ? 0 : oldCount;
            replacing = false;
            _tagSuggestions.addAll(_items.expand((book) => book.tags));
            if (_resultStartIndex < _items.length) _resultRevision++;
          }
          notifyListeners();
        }

        final tagOnly =
            requestedField == BookSearchField.tags ||
            requestedField == BookSearchField.all &&
                requestedQuery.trim().startsWith('#');
        final result =
            requestedPublication != null && publicationCatalog != null
            ? await publicationCatalog.browsePublication(
                requestedPublication.id,
                page: requestedPage,
                refresh: force,
              )
            : (search || filteringTags) &&
                tagOnly &&
                repository is ProgressiveTagCatalogue
            ? await (repository as ProgressiveTagCatalogue).tagPage(
                requestedQuery,
                page: requestedPage,
                refresh: force,
                current: () => !_disposed && generation == _generation,
                onProgress: acceptTagProgress,
              )
            : search || filteringTags
            ? await repository.searchFilteredPage(
                requestedQuery,
                field: requestedField,
                page: requestedPage,
                refresh: force,
              )
            : await repository.browse(
                sort: requestedSort,
                page: requestedPage,
                refresh: force,
              );
        if (_disposed || generation != _generation) return;
        if (result.page != requestedPage) {
          throw const FormatException('分页游标不匹配');
        }
        final oldCount = _items.length;
        final merged = <int, Novel>{
          if (!replacing)
            for (final item in _items) item.id: item,
          for (final item in result.items) item.id: item,
        };
        _resultStartIndex = replacing ? 0 : oldCount;
        _items = List.unmodifiable(merged.values);
        _visibleItems = null;
        _tagSuggestions.addAll(result.items.expand((book) => book.tags));
        if (_resultStartIndex < _items.length) _resultRevision++;
        page = requestedPage;
        hasMore = result.hasMore;
        totalItems = result.totalItems;
        replacing = false;
        refreshing = false;
        // At most the first three ordinary API pages, sequentially. Publish
        // page one immediately, stop on duplicates/errors/end or a new sort.
        if (search ||
            filteringTags ||
            _items.length >= initialItems ||
            page >= 3 ||
            !hasMore ||
            result.items.isEmpty ||
            _items.length <= _resultStartIndex) {
          break;
        }
        notifyListeners();
        if (_disposed || generation != _generation) return;
        requestedPage = page + 1;
      }
    } catch (failure) {
      if (_disposed || generation != _generation) return;
      error = failure;
      refreshFailed = replacing && hadItems;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        refreshing = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _searchDelay?.cancel();
    _generation++;
    super.dispose();
  }
}

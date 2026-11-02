import 'dart:async';

import 'package:flutter/services.dart';

import 'legado_dto.dart';

/// Dart-side client for the Legado engine bridge.
///
/// Mirrors the channel contract drafted in ENGINE-study.md §4: one
/// MethodChannel for request/response calls, an EventChannel streaming
/// full search snapshots, and a second EventChannel for long-running
/// task events (source checks, subscription batch updates, change-source
/// candidates, cache downloads). The native side is not implemented yet;
/// this client is written and unit-tested against that contract alone.
///
/// Long tasks are addressed by a caller-visible `taskId` (see
/// [newTaskId]); [cancelTask] cancels any of them, searches included.
class LegadoEngineClient {
  LegadoEngineClient({
    MethodChannel? methodChannel,
    EventChannel? searchEventChannel,
    EventChannel? taskEventChannel,
  }) : _methodChannel = methodChannel ?? const MethodChannel(methodChannelName),
       _searchEventChannel =
           searchEventChannel ?? const EventChannel(searchEventChannelName),
       _taskEventChannel =
           taskEventChannel ?? const EventChannel(taskEventChannelName);

  static const String methodChannelName = 'org.mewx.wenku8/legado_engine';
  static const String searchEventChannelName =
      'org.mewx.wenku8/legado_search_events';
  static const String taskEventChannelName =
      'org.mewx.wenku8/legado_task_events';

  final MethodChannel _methodChannel;
  final EventChannel _searchEventChannel;
  final EventChannel _taskEventChannel;

  int _taskIdCounter = 0;

  /// Registers the handler for platform-initiated calls on the bridge
  /// channel (P5.2: the engine's verification UI asks Dart to show the
  /// image-captcha sheet and awaits the entered code as the call
  /// result). One handler per client; passing null detaches. Ordinary
  /// Dart -> native calls are unaffected.
  void setPlatformCallHandler(
    Future<Object?> Function(MethodCall call)? handler,
  ) {
    _methodChannel.setMethodCallHandler(
      handler == null ? null : (call) => handler(call),
    );
  }

  /// Allocates the next task id. Ids are monotonic per client instance;
  /// pass one explicitly to task-starting methods when the caller needs
  /// to know it before the native side answers.
  int newTaskId() => ++_taskIdCounter;

  Future<Map<Object?, Object?>?> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) {
    return _methodChannel.invokeMapMethod<Object?, Object?>(method, arguments);
  }

  Future<List<T>> _invokeList<T>(
    String method,
    T Function(Map<Object?, Object?>) decode, [
    Map<String, Object?>? arguments,
  ]) async {
    final result = await _methodChannel.invokeListMethod<Object?>(
      method,
      arguments,
    );
    if (result == null) return <T>[];
    return <T>[
      for (final item in result)
        if (item is Map) decode(item.cast<Object?, Object?>()),
    ];
  }

  // ---------------------------------------------------------------------
  // Init & source management
  // ---------------------------------------------------------------------

  /// Spike-level liveness probe: the native side answers straight from
  /// the engine facade (`LegadoEngineFacade`), proving the vendored AARs
  /// are linked and readable by the host toolchain. No engine state is
  /// touched, so this is safe to call before [init].
  Future<LegadoPingResult> ping() async {
    final result = await _invokeMap('ping');
    return LegadoPingResult.fromMap(result ?? const {});
  }

  Future<LegadoEngineInfo> init({String? dataDir}) async {
    final result = await _invokeMap('init', <String, Object?>{
      'dataDir': ?dataDir,
    });
    return LegadoEngineInfo.fromMap(result ?? const {});
  }

  /// Staged on-device probe of the shared search/explore path (DB
  /// counts, scope resolution, JS eval, explore kinds, AnalyzeUrl
  /// template resolution, one real WebBook search). Returns the raw
  /// report map; values are scalars or string lists, formatted for
  /// display by the caller. Requires [init] to have run.
  Future<Map<String, Object?>> engineSelfCheck() async {
    final result = await _invokeMap('engineSelfCheck');
    return <String, Object?>{
      for (final entry in (result ?? const {}).entries)
        entry.key.toString(): entry.value,
    };
  }

  Future<List<BookSourceSummary>> listSources({
    String? group,
    bool enabledOnly = false,
    bool exploreOnly = false,
  }) {
    return _invokeList('listSources', BookSourceSummary.fromMap, {
      'group': ?group,
      'enabledOnly': enabledOnly,
      'exploreOnly': exploreOnly,
    });
  }

  Future<BookSourceSummary?> getSource(String sourceUrl) async {
    final result = await _invokeMap('getSource', {'sourceUrl': sourceUrl});
    return result == null ? null : BookSourceSummary.fromMap(result);
  }

  /// Saves one source from its full JSON text (editor save path).
  Future<BookSourceSummary> upsertSource(String sourceJson) async {
    final result = await _invokeMap('upsertSource', {'sourceJson': sourceJson});
    return BookSourceSummary.fromMap(result ?? const {});
  }

  /// Returns how many sources were actually deleted.
  Future<int> deleteSources(List<String> sourceUrls) async {
    final result = await _invokeMap('deleteSources', {
      'sourceUrls': sourceUrls,
    });
    final deleted = result?['deleted'];
    return deleted is num ? deleted.toInt() : 0;
  }

  Future<void> setSourceEnabled(String sourceUrl, bool enabled) {
    return _methodChannel.invokeMethod<void>('setSourceEnabled', {
      'sourceUrl': sourceUrl,
      'enabled': enabled,
    });
  }

  Future<void> setSourcesEnabled(List<String> sourceUrls, bool enabled) {
    return _methodChannel.invokeMethod<void>('setSourceEnabled', {
      'sourceUrls': sourceUrls,
      'enabled': enabled,
    });
  }

  Future<void> setSourceEnabledExplore(String sourceUrl, bool enabled) {
    return _methodChannel.invokeMethod<void>('setSourceEnabledExplore', {
      'sourceUrl': sourceUrl,
      'enabled': enabled,
    });
  }

  Future<BookSourceSummary> updateSourceMeta({
    required String sourceUrl,
    String? group,
    int? customOrder,
    String? comment,
  }) async {
    final result = await _invokeMap('updateSourceMeta', <String, Object?>{
      'sourceUrl': sourceUrl,
      'group': ?group,
      'customOrder': ?customOrder,
      'comment': ?comment,
    });
    return BookSourceSummary.fromMap(result ?? const {});
  }

  Future<List<String>> listSourceGroups() async {
    final result = await _methodChannel.invokeListMethod<String>(
      'listSourceGroups',
    );
    return result ?? <String>[];
  }

  // ---------------------------------------------------------------------
  // Import (Legado semantics: a payload is JSON text, a URL to download,
  // or a local file path; absolute URLs inside text payloads are followed
  // by the engine, `sourceUrls` bundles are expanded, legacy subscription
  // sources are converted)
  // ---------------------------------------------------------------------

  Future<ImportResult> importSources({
    required String payload,
    required LegadoImportPayloadKind payloadKind,
  }) async {
    final result = await _invokeMap('importSources', {
      'payload': payload,
      'payloadKind': payloadKind.wireName,
    });
    return ImportResult.fromMap(result ?? const {});
  }

  Future<ImportResult> importFromJsonText(String jsonText) => importSources(
    payload: jsonText,
    payloadKind: LegadoImportPayloadKind.text,
  );

  Future<ImportResult> importFromUrl(String url) =>
      importSources(payload: url, payloadKind: LegadoImportPayloadKind.url);

  Future<ImportResult> importFromFilePath(String filePath) => importSources(
    payload: filePath,
    payloadKind: LegadoImportPayloadKind.filePath,
  );

  /// Starts a source check; progress arrives on [taskEvents]. Returns the
  /// task id (allocated here unless [taskId] is given).
  Future<int> checkSources({List<String>? sourceUrls, int? taskId}) async {
    final id = taskId ?? newTaskId();
    final result = await _invokeMap('checkSources', <String, Object?>{
      'taskId': id,
      'sourceUrls': ?sourceUrls,
    });
    final nativeId = result?['taskId'];
    return nativeId is num ? nativeId.toInt() : id;
  }

  // ---------------------------------------------------------------------
  // Explore (discovery)
  // ---------------------------------------------------------------------

  Future<List<ExploreSection>> getExploreKinds(String sourceUrl) {
    return _invokeList('getExploreKinds', ExploreSection.fromMap, {
      'sourceUrl': sourceUrl,
    });
  }

  Future<ExploreBookPage> getExploreBooks({
    required String sourceUrl,
    required String kindUrl,
    int page = 1,
  }) async {
    final result = await _invokeMap('getExploreBooks', {
      'sourceUrl': sourceUrl,
      'kindUrl': kindUrl,
      'page': page,
    });
    return ExploreBookPage.fromMap(result ?? const {});
  }

  // ---------------------------------------------------------------------
  // Subscriptions
  // ---------------------------------------------------------------------

  Future<List<LegadoSubscription>> listSubscriptions() {
    return _invokeList('listSubscriptions', LegadoSubscription.fromMap);
  }

  Future<LegadoSubscription> upsertSubscription(
    LegadoSubscription subscription,
  ) async {
    final result = await _invokeMap('upsertSubscription', subscription.toMap());
    return LegadoSubscription.fromMap(result ?? const {});
  }

  Future<bool> deleteSubscription(int id) async {
    final result = await _invokeMap('deleteSubscription', {'id': id});
    final ok = result?['ok'];
    return ok is bool ? ok : false;
  }

  Future<ImportResult> updateSubscription(int id) async {
    final result = await _invokeMap('updateSubscription', {'id': id});
    return ImportResult.fromMap(result ?? const {});
  }

  /// Starts a batch subscription update; progress arrives on [taskEvents].
  Future<int> updateAllSubscriptions({
    bool onlyDue = false,
    int? taskId,
  }) async {
    final id = taskId ?? newTaskId();
    final result = await _invokeMap('updateAllSubscriptions', {
      'taskId': id,
      'onlyDue': onlyDue,
    });
    final nativeId = result?['taskId'];
    return nativeId is num ? nativeId.toInt() : id;
  }

  // ---------------------------------------------------------------------
  // Search (streaming, full snapshots)
  // ---------------------------------------------------------------------

  /// Starts a search across the given scope and returns its handle.
  ///
  /// The handle's stream emits a full snapshot every time the native
  /// aggregate changes (matching the engine SearchModel callback), then a
  /// single finish/cancel event. Call [LegadoSearchHandle.loadMore],
  /// [LegadoSearchHandle.restartSource] and [LegadoSearchHandle.cancel]
  /// to steer it.
  LegadoSearchHandle startSearch({
    required String keyword,
    String? group,
    List<String>? sourceUrls,
    bool precision = false,
    int? taskId,
  }) {
    final id = taskId ?? newTaskId();
    final handle = LegadoSearchHandle._(this, id);
    unawaited(
      _methodChannel
          .invokeMethod<void>('startSearch', <String, Object?>{
            'taskId': id,
            'keyword': keyword,
            'scope': <String, Object?>{
              'group': ?group,
              'sourceUrls': ?sourceUrls,
            },
            'precision': precision,
          })
          .catchError((Object _) {}),
    );
    return handle;
  }

  Future<void> loadMoreSearch(int taskId) {
    return _methodChannel.invokeMethod<void>('loadMoreSearch', {
      'taskId': taskId,
    });
  }

  Future<void> restartSearchSource(int taskId, String sourceUrl) {
    return _methodChannel.invokeMethod<void>('restartSearchSource', {
      'taskId': taskId,
      'sourceUrl': sourceUrl,
    });
  }

  /// Cancels any native task (search, check, subscription batch, cache).
  Future<void> cancelTask(int taskId) {
    return _methodChannel.invokeMethod<void>('cancelTask', {'taskId': taskId});
  }

  Stream<LegadoSearchEvent> _searchEventsFor(int taskId) {
    return _searchEventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map && event['taskId'] == taskId)
        .map((event) => LegadoSearchEvent.fromMap(event as Map));
  }

  // ---------------------------------------------------------------------
  // Book main chain
  // ---------------------------------------------------------------------

  Future<BookInfo> getBookInfo({
    required String origin,
    required String bookUrl,
    String? tocUrl,
    String? variable,
    String? name,
    String? author,
  }) async {
    final result = await _invokeMap('getBookInfo', <String, Object?>{
      'origin': origin,
      'bookUrl': bookUrl,
      'tocUrl': ?tocUrl,
      'variable': ?variable,
      'name': ?name,
      'author': ?author,
    });
    return BookInfo.fromMap(result ?? const {});
  }

  Future<ChapterListResult> getChapterList({
    required BookInfo book,
    bool forceRefresh = false,
  }) async {
    final result = await _invokeMap('getChapterList', <String, Object?>{
      ...book.toEngineBookArgs(),
      'forceRefresh': forceRefresh,
    });
    return ChapterListResult.fromMap(result ?? const {});
  }

  Future<ChapterContent> getChapterContent({
    required BookInfo book,
    required Chapter chapter,
    String? nextChapterUrl,
    bool applyReplace = false,
  }) async {
    final chapterVariable = chapter.variable;
    final result = await _invokeMap('getChapterContent', <String, Object?>{
      ...book.toEngineBookArgs(),
      'chapterUrl': chapter.url,
      'chapterIndex': chapter.index,
      'chapterVariable': ?chapterVariable,
      'nextChapterUrl': ?nextChapterUrl,
      'applyReplace': applyReplace,
    });
    return ChapterContent.fromMap(result ?? const {});
  }

  /// Resolves the real URL + required headers for a cover/manga image.
  Future<ImageRequest> resolveImageRequest({
    required String origin,
    required String url,
  }) async {
    final result = await _invokeMap('resolveImageRequest', {
      'origin': origin,
      'url': url,
    });
    return ImageRequest.fromMap(result ?? const {});
  }

  Future<BookByUrlResult?> getBookByUrl(String url) async {
    final result = await _invokeMap('getBookByUrl', {'url': url});
    return result == null ? null : BookByUrlResult.fromMap(result);
  }

  /// Starts a change-source candidate search; snapshots arrive through
  /// the returned handle's stream (task event channel).
  LegadoChangeSourceHandle changeSourceCandidates({
    required String name,
    String author = '',
    String? excludeOrigin,
    int? taskId,
  }) {
    final id = taskId ?? newTaskId();
    unawaited(
      _methodChannel
          .invokeMethod<void>('changeSourceCandidates', <String, Object?>{
            'taskId': id,
            'name': name,
            'author': author,
            'excludeOrigin': ?excludeOrigin,
          })
          .catchError((Object _) {}),
    );
    return LegadoChangeSourceHandle._(this, id);
  }

  Future<ChangeSourceResult> applyChangeSource({
    required String oldBookKey,
    required String newOrigin,
    required String newBookUrl,
    required int durChapterIndex,
    String? durChapterTitle,
  }) async {
    final result = await _invokeMap('applyChangeSource', <String, Object?>{
      'oldBookKey': oldBookKey,
      'newOrigin': newOrigin,
      'newBookUrl': newBookUrl,
      'durChapterIndex': durChapterIndex,
      'durChapterTitle': ?durChapterTitle,
    });
    return ChangeSourceResult.fromMap(result ?? const {});
  }

  // ---------------------------------------------------------------------
  // Replace rules & cache download (draft API)
  // ---------------------------------------------------------------------

  Future<List<LegadoReplaceRule>> listReplaceRules() {
    return _invokeList('listReplaceRules', LegadoReplaceRule.fromMap);
  }

  Future<LegadoReplaceRule> upsertReplaceRule(LegadoReplaceRule rule) async {
    final result = await _invokeMap('upsertReplaceRule', rule.toMap());
    return LegadoReplaceRule.fromMap(result ?? const {});
  }

  Future<bool> deleteReplaceRule(int id) async {
    final result = await _invokeMap('deleteReplaceRule', {'id': id});
    final ok = result?['ok'];
    return ok is bool ? ok : false;
  }

  Future<void> setReplaceRuleEnabled(int id, bool enabled) {
    return _methodChannel.invokeMethod<void>('setReplaceRuleEnabled', {
      'id': id,
      'enabled': enabled,
    });
  }

  /// Starts a chapter cache download; progress arrives on [taskEvents].
  Future<int> cacheChapters({
    required BookInfo book,
    required int fromIndex,
    required int toIndex,
    int? taskId,
  }) async {
    final id = taskId ?? newTaskId();
    final result = await _invokeMap('cacheChapters', <String, Object?>{
      'taskId': id,
      ...book.toEngineBookArgs(),
      'fromIndex': fromIndex,
      'toIndex': toIndex,
    });
    final nativeId = result?['taskId'];
    return nativeId is num ? nativeId.toInt() : id;
  }

  // ---------------------------------------------------------------------
  // Task events
  // ---------------------------------------------------------------------

  /// Broadcast stream of long-task events (checks, subscription batch
  /// updates, change-source candidates, cache progress). Filter by
  /// `taskId` on the event objects.
  Stream<LegadoTaskEvent> get taskEvents {
    return _taskEventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => LegadoTaskEvent.fromMap(event as Map));
  }
}

/// Payload kinds for `importSources`, wire values per ENGINE-study §4.2.
enum LegadoImportPayloadKind {
  text('text'),
  url('url'),
  filePath('filePath');

  const LegadoImportPayloadKind(this.wireName);
  final String wireName;
}

/// Handle for one running search. See [LegadoEngineClient.startSearch].
class LegadoSearchHandle {
  LegadoSearchHandle._(this._client, this.taskId);

  final LegadoEngineClient _client;

  final int taskId;

  /// Full-snapshot events for this search only.
  Stream<LegadoSearchEvent> get events => _client._searchEventsFor(taskId);

  Future<void> loadMore() => _client.loadMoreSearch(taskId);

  Future<void> restartSource(String sourceUrl) =>
      _client.restartSearchSource(taskId, sourceUrl);

  Future<void> cancel() => _client.cancelTask(taskId);
}

/// Handle for one change-source candidate search.
class LegadoChangeSourceHandle {
  LegadoChangeSourceHandle._(this._client, this.taskId);

  final LegadoEngineClient _client;

  final int taskId;

  /// Candidate snapshots for this task only.
  Stream<List<SearchBook>> get candidates {
    return _client.taskEvents
        .where(
          (event) => event is ChangeCandidatesEvent && event.taskId == taskId,
        )
        .map((event) => (event as ChangeCandidatesEvent).books);
  }

  Future<void> cancel() => _client.cancelTask(taskId);
}

/// Events pushed on the search event channel.
sealed class LegadoSearchEvent {
  const LegadoSearchEvent(this.taskId);

  final int taskId;

  factory LegadoSearchEvent.fromMap(Map<Object?, Object?> map) {
    final m = <String, Object?>{
      for (final entry in map.entries) entry.key.toString(): entry.value,
    };
    final taskId = m['taskId'] is num ? (m['taskId'] as num).toInt() : 0;
    switch (m['type']) {
      case 'searchSnapshot':
        final booksRaw = m['books'];
        final groupsRaw = m['groups'];
        return SearchSnapshotEvent(
          taskId,
          books: <SearchBook>[
            if (booksRaw is List)
              for (final item in booksRaw)
                if (item is Map)
                  SearchBook.fromMap(item.cast<Object?, Object?>()),
          ],
          groups: <SearchGroupCount>[
            if (groupsRaw is List)
              for (final item in groupsRaw)
                if (item is Map)
                  SearchGroupCount.fromMap(item.cast<Object?, Object?>()),
          ],
          hasMore: m['hasMore'] == true,
        );
      case 'searchFinish':
        return SearchFinishEvent(
          taskId,
          isEmpty: m['isEmpty'] == true,
          hasMore: m['hasMore'] == true,
        );
      case 'searchError':
        return SearchErrorEvent(
          taskId,
          sourceUrl: m['sourceUrl']?.toString(),
          errorCode: m['errorCode']?.toString() ?? 'UNKNOWN',
          message: m['message']?.toString() ?? '',
        );
      case 'searchCancel':
        return SearchCancelEvent(taskId);
      default:
        return UnknownSearchEvent(taskId, m);
    }
  }
}

class SearchSnapshotEvent extends LegadoSearchEvent {
  const SearchSnapshotEvent(
    super.taskId, {
    required this.books,
    this.groups = const <SearchGroupCount>[],
    this.hasMore = false,
  });

  /// The full aggregated result list (replace, don't append).
  final List<SearchBook> books;
  final List<SearchGroupCount> groups;
  final bool hasMore;
}

class SearchFinishEvent extends LegadoSearchEvent {
  const SearchFinishEvent(
    super.taskId, {
    required this.isEmpty,
    required this.hasMore,
  });

  final bool isEmpty;
  final bool hasMore;
}

class SearchCancelEvent extends LegadoSearchEvent {
  const SearchCancelEvent(super.taskId);
}

/// A per-source (or whole-task) search failure. The engine's own
/// semantics swallow these into a silent zero-result finish; the
/// bridge re-emits them as events (always before the round's finish)
/// so "search broke" stays distinguishable from "found nothing".
class SearchErrorEvent extends LegadoSearchEvent {
  const SearchErrorEvent(
    super.taskId, {
    this.sourceUrl,
    required this.errorCode,
    required this.message,
  });

  /// The failing source, when the failure is source-scoped.
  final String? sourceUrl;
  final String errorCode;
  final String message;
}

class UnknownSearchEvent extends LegadoSearchEvent {
  const UnknownSearchEvent(super.taskId, this.raw);

  final Map<String, Object?> raw;
}

/// Events pushed on the task event channel.
sealed class LegadoTaskEvent {
  const LegadoTaskEvent(this.taskId);

  final int taskId;

  factory LegadoTaskEvent.fromMap(Map<Object?, Object?> map) {
    final m = <String, Object?>{
      for (final entry in map.entries) entry.key.toString(): entry.value,
    };
    final taskId = m['taskId'] is num ? (m['taskId'] as num).toInt() : 0;
    int asInt(String key) => m[key] is num ? (m[key] as num).toInt() : 0;
    switch (m['type']) {
      case 'checkProgress':
        return CheckProgressEvent(
          taskId,
          sourceUrl: m['sourceUrl']?.toString() ?? '',
          ok: m['state'] == 'ok',
          message: m['message']?.toString(),
          done: asInt('done'),
          total: asInt('total'),
        );
      case 'checkDone':
        return CheckDoneEvent(
          taskId,
          okCount: asInt('okCount'),
          failCount: asInt('failCount'),
        );
      case 'changeCandidates':
        final booksRaw = m['books'];
        return ChangeCandidatesEvent(taskId, <SearchBook>[
          if (booksRaw is List)
            for (final item in booksRaw)
              if (item is Map)
                SearchBook.fromMap(item.cast<Object?, Object?>()),
        ]);
      case 'cacheProgress':
        final failedRaw = m['failed'];
        return CacheProgressEvent(
          taskId,
          done: asInt('done'),
          total: asInt('total'),
          failed: <int>[
            if (failedRaw is List)
              for (final item in failedRaw)
                if (item is num) item.toInt(),
          ],
        );
      default:
        return UnknownTaskEvent(taskId, m);
    }
  }
}

class CheckProgressEvent extends LegadoTaskEvent {
  const CheckProgressEvent(
    super.taskId, {
    required this.sourceUrl,
    required this.ok,
    this.message,
    this.done = 0,
    this.total = 0,
  });

  final String sourceUrl;
  final bool ok;
  final String? message;
  final int done;
  final int total;
}

class CheckDoneEvent extends LegadoTaskEvent {
  const CheckDoneEvent(
    super.taskId, {
    required this.okCount,
    required this.failCount,
  });

  final int okCount;
  final int failCount;
}

class ChangeCandidatesEvent extends LegadoTaskEvent {
  const ChangeCandidatesEvent(super.taskId, this.books);

  final List<SearchBook> books;
}

class CacheProgressEvent extends LegadoTaskEvent {
  const CacheProgressEvent(
    super.taskId, {
    required this.done,
    required this.total,
    this.failed = const <int>[],
  });

  final int done;
  final int total;
  final List<int> failed;
}

class UnknownTaskEvent extends LegadoTaskEvent {
  const UnknownTaskEvent(super.taskId, this.raw);

  final Map<String, Object?> raw;
}

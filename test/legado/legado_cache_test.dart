// Cache download (P5.7): the bridge client surface for the engine's
// CacheBook orchestrator, the repository/dispatch routing, the
// OfflineNovelRepository job wiring (a Legado download must drive the
// engine task, not the Flutter chapter cache), the detail-page status
// count, local-path passthrough for cached manga pages, and reading a
// cached page from disk.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legado/legado.dart';
import 'package:wenku8_flutter/legado/legado_manga_reader.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/offline_widgets.dart';

const _methodChannel = MethodChannel('org.mewx.wenku8/legado_engine');
const _taskChannel = EventChannel('org.mewx.wenku8/legado_task_events');
const _sourceUrl = 'https://banshan.example.com';
const _bookUrl = 'https://banshan.example.com/book/1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late LegadoBookRegistry registry;
  late LegadoNovelRepository repository;
  late LegadoDispatchRepository dispatch;
  late List<MethodCall> calls;
  MockStreamHandlerEventSink? taskSink;
  // When true the mock engine emits only the first progress event and
  // then goes silent (a long-running download the test can cancel).
  var hangAfterFirstProgress = false;

  Map<String, Object?> bookMap({required int type}) => {
    'bookUrl': _bookUrl,
    'tocUrl': _bookUrl,
    'name': '搬山人',
    'author': '作者甲',
    'type': type,
    'origin': _sourceUrl,
    'originName': '搬山人源',
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    calls = [];
    taskSink = null;
    hangAfterFirstProgress = false;
    messenger.setMockStreamHandler(
      _taskChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          taskSink = events;
        },
        onCancel: (arguments) {
          taskSink = null;
        },
      ),
    );
    messenger.setMockMethodCallHandler(_methodChannel, (call) async {
      calls.add(call);
      final args = call.arguments is Map
          ? (call.arguments as Map).cast<String, Object?>()
          : const <String, Object?>{};
      switch (call.method) {
        case 'init':
          return {'ok': true, 'engineVersion': 'test', 'sourceCount': 0};
        case 'getBookInfo':
          return bookMap(type: 8);
        case 'getChapterList':
          return {
            'book': bookMap(type: 8),
            'chapters': [
              for (var i = 0; i < 5; i++)
                {
                  'title': '第${i + 1}章',
                  'url': 'https://banshan.example.com/ch/${i + 1}',
                  'index': i,
                },
            ],
          };
        case 'getChapterContent':
          return {
            'content': '正文内容',
            'images': const <String>[],
            'isImageChapter': false,
          };
        case 'cacheChapters':
          final taskId = args['taskId'] as int;
          Future<void>.delayed(const Duration(milliseconds: 50), () {
            taskSink?.success(<String, Object?>{
              'type': 'cacheProgress',
              'taskId': taskId,
              'done': 2,
              'total': 5,
              'failed': <int>[],
            });
            if (hangAfterFirstProgress) return;
            Future<void>.delayed(const Duration(milliseconds: 50), () {
              taskSink?.success(<String, Object?>{
                'type': 'cacheProgress',
                'taskId': taskId,
                'done': 5,
                'total': 5,
                'failed': <int>[],
              });
            });
          });
          return {'taskId': taskId};
        case 'getCachedChapterIndexes':
          return {
            'indexes': [0, 1, 2],
          };
        case 'clearBookCache':
          return {'cleared': true};
        case 'cancelTask':
          return null;
      }
      return null;
    });
    final client = LegadoEngineClient(methodChannel: _methodChannel);
    registry = LegadoBookRegistry(
      preferences: SharedPreferences.getInstance(),
    );
    await registry.ready;
    repository = LegadoNovelRepository(client: client, registry: registry);
    dispatch = LegadoDispatchRepository(
      legacy: const DemoNovelRepository(),
      legado: repository,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_methodChannel, null);
    messenger.setMockStreamHandler(_taskChannel, null);
  });

  Future<LegadoBookRecord> seed() => registry.registerSearchBook(
    SearchBook(
      name: '搬山人',
      author: '作者甲',
      bookUrl: _bookUrl,
      origin: _sourceUrl,
      originName: '搬山人源',
      type: 8,
    ),
  );

  List<MethodCall> callsTo(String method) =>
      calls.where((call) => call.method == method).toList();

  group('client cache surface', () {
    test('cacheChapters forwards range and book args', () async {
      final record = await seed();
      final taskId = await repository.startCacheDownload(
        record.id,
        fromIndex: 1,
        toIndex: 3,
      );
      final call = callsTo('cacheChapters').single;
      final args = (call.arguments as Map).cast<String, Object?>();
      expect(args['taskId'], taskId);
      expect(args['fromIndex'], 1);
      expect(args['toIndex'], 3);
      expect(args['origin'], _sourceUrl);
      expect(args['bookUrl'], _bookUrl);
    });

    test('cachedChapterIndexes parses the bridge list', () async {
      final record = await seed();
      expect(await repository.cachedChapterIndexes(record.id), [0, 1, 2]);
      expect(callsTo('getCachedChapterIndexes'), hasLength(1));
    });

    test('dispatch answers empty / no-ops for non-Legado ids', () async {
      expect(await dispatch.cachedChapterIndexes(42), isEmpty);
      await dispatch.clearBookCache(42);
      expect(callsTo('getCachedChapterIndexes'), isEmpty);
      expect(callsTo('clearBookCache'), isEmpty);
    });
  });

  group('cached manga page paths', () {
    test('legadoChapterImageUrls keeps local paths verbatim', () {
      expect(
        legadoChapterImageUrls(
          [
            '/data/book_cache/x/images/a.jpg',
            'https://img.example.com/p2.jpg,{',
            'https://img.example.com/p2.jpg',
            '/data/book_cache/x/images/a.jpg',
          ],
          baseUrl: 'https://manwa.example.com/ch/1',
        ),
        [
          '/data/book_cache/x/images/a.jpg',
          'https://img.example.com/p2.jpg',
        ],
      );
    });

    test('loadLegadoMangaImageBytes reads a local file', () async {
      final dir = await Directory.systemTemp.createTemp('manga-local-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/page.jpg');
      await file.writeAsBytes([1, 2, 3, 4]);
      expect(
        await loadLegadoMangaImageBytes(origin: '', url: file.path),
        [1, 2, 3, 4],
      );
      await expectLater(
        loadLegadoMangaImageBytes(origin: '', url: '${dir.path}/gone.jpg'),
        throwsA(anything),
      );
    });
  });

  group('offline repository wiring', () {
    late Directory root;
    late OfflineCacheStore store;
    late OfflineNovelRepository offline;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('legado-cache-');
      store = OfflineCacheStore(Directory('${root.path}/cache'));
      offline = OfflineNovelRepository(remote: dispatch, cache: store);
    });

    tearDown(() async {
      offline.dispose();
      store.dispose();
      await root.delete(recursive: true);
    });

    Future<Novel> seededNovel() async {
      final record = await seed();
      final chapters = await repository.chapters(record.id);
      return record.toNovel().withChapters(chapters);
    }

    Future<void> waitForPhase(int id, DownloadPhase phase) async {
      for (var i = 0; i < 200; i++) {
        if (offline.jobFor(id)?.phase == phase) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('job never reached $phase (now ${offline.jobFor(id)?.phase})');
    }

    test('download drives the engine task and completes the job', () async {
      final novel = await seededNovel();
      offline.download(novel);
      await waitForPhase(novel.id, DownloadPhase.completed);
      final job = offline.jobFor(novel.id)!;
      expect(job.completed, 5);
      expect(job.total, 5);
      final call = callsTo('cacheChapters').single;
      final args = (call.arguments as Map).cast<String, Object?>();
      expect(args['fromIndex'], 0);
      expect(args['toIndex'], 4);
      expect(offline.legadoCachedCount(novel), 5);
      expect(offline.availableOffline(novel.id), isTrue);
      // The Flutter chapter cache must NOT hold prose bodies for the
      // engine book (the engine folder is the offline store).
      expect(store.book(novel.id)?.cachedCount ?? 0, 0);
    });

    test('a chapter subset downloads as one engine range', () async {
      final novel = await seededNovel();
      offline.download(novel, chapterIds: {2, 3, 4});
      await waitForPhase(novel.id, DownloadPhase.completed);
      final args =
          (callsTo('cacheChapters').single.arguments as Map)
              .cast<String, Object?>();
      expect(args['fromIndex'], 1);
      expect(args['toIndex'], 3);
    });

    test('cancel forwards to the bridge task', () async {
      hangAfterFirstProgress = true;
      final novel = await seededNovel();
      offline.download(novel);
      await waitForPhase(novel.id, DownloadPhase.downloading);
      offline.cancel(novel.id);
      expect(offline.jobFor(novel.id)?.phase, DownloadPhase.cancelled);
      final cancel = callsTo('cancelTask').single;
      final args = (cancel.arguments as Map).cast<String, Object?>();
      final cacheArgs =
          (callsTo('cacheChapters').single.arguments as Map)
              .cast<String, Object?>();
      expect(args['taskId'], cacheArgs['taskId']);
    });

    test('removeCachedBook clears the engine cache too', () async {
      final novel = await seededNovel();
      offline.download(novel);
      await waitForPhase(novel.id, DownloadPhase.completed);
      await offline.removeCachedBook(novel.id);
      // The engine-side clear is fire-and-forget inside removeCachedBook.
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(callsTo('clearBookCache'), hasLength(1));
      expect(offline.legadoCachedCount(novel), 0);
      expect(offline.availableOffline(novel.id), isFalse);
    });

    test('refreshLegadoCacheState restores counts after restart', () async {
      final novel = await seededNovel();
      expect(offline.legadoCachedCount(novel), 0);
      await offline.refreshLegadoCacheState(novel);
      expect(offline.legadoCachedCount(novel), 3);
    });

    testWidgets('status line shows the engine-side count', (tester) async {
      final novel = await seededNovel();
      await tester.runAsync(() async {
        offline.download(novel);
        await waitForPhase(novel.id, DownloadPhase.completed);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfflineBookStatus(repository: offline, novel: novel),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('缓存 5 / 5 章'), findsOneWidget);
      // Flush the repository's frame-coalescing timer before the
      // binding checks for pending timers.
      await tester.pump(const Duration(seconds: 1));
    });
  });
}

// Manga (image chapter) reading path: extracting the ordered page
// URL list out of the engine's chapter payload, the repository's
// per-book/per-chapter gating, the bounded page-image cache, and the
// reader shell rendering image chapters as a vertical image column
// while text chapters stay on the prose path.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legado/legado.dart';
import 'package:wenku8_flutter/legado/legado_manga_reader.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/listening/widgets.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';

import '../support/listening_fixture.dart';
import '../reader_modes_test.dart' show settleReader;

const _sourceUrl = 'https://manwa.example.com';

/// The classic 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('legado image URL parsing', () {
    test('manwa-style suffixed img tags survive in order', () {
      const content =
          '<img src="https://img.example.com/p1.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}">\n'
          '<img src="https://img.example.com/p2.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}">';
      expect(parseLegadoImageUrls(content, baseUrl: ''), [
        'https://img.example.com/p1.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}',
        'https://img.example.com/p2.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}',
      ]);
    });

    test('a suffix truncated by DOM formatting degrades to the bare URL', () {
      // What the string looks like after HtmlFormatter.formatKeepImg +
      // a DOM round-trip: the src was cut at the quote after `,{`.
      const content = '<img src="https://img.example.com/p1.jpg,{">';
      expect(parseLegadoImageUrls(content, baseUrl: ''), [
        'https://img.example.com/p1.jpg',
      ]);
      expect(
        sanitizeLegadoImageUrls([
          'https://img.example.com/p1.jpg,{',
        ], baseUrl: ''),
        ['https://img.example.com/p1.jpg'],
      );
    });

    test('tags sharing one line, single quotes, data-src and md forms', () {
      // Two tags share a line; the markdown form gets its own line,
      // as the engine's formatter emits one image per line.
      const content =
          "<img src='https://img.example.com/a.jpg'>"
          '<img data-src="https://img.example.com/b.jpg">\n'
          '![x](https://img.example.com/c.jpg)';
      expect(parseLegadoImageUrls(content, baseUrl: ''), [
        'https://img.example.com/a.jpg',
        'https://img.example.com/b.jpg',
        'https://img.example.com/c.jpg',
      ]);
    });

    test('bare URL lines are taken, prose lines are not, repeats dedupe', () {
      const content =
          '　　https://img.example.com/a.jpg\n'
          '这一行是正文，不是图片 https://img.example.com/skip.jpg 也不是\n'
          'https://img.example.com/a.jpg\n'
          'https://img.example.com/b.png,{"headers":{"Referer":"https://x/"}}';
      expect(parseLegadoImageUrls(content, baseUrl: ''), [
        'https://img.example.com/a.jpg',
        'https://img.example.com/b.png,{"headers":{"Referer":"https://x/"}}',
      ]);
    });

    test('relative page URLs resolve against the chapter address', () {
      const content = '<img src="/img/p1.jpg"><img src="p2.jpg">';
      expect(
        parseLegadoImageUrls(
          content,
          baseUrl: 'https://manwa.example.com/ch/9',
        ),
        [
          'https://manwa.example.com/img/p1.jpg',
          'https://manwa.example.com/ch/p2.jpg',
        ],
      );
    });

    test('cleanLegadoImageUrl keeps complete suffixes, cuts broken ones', () {
      expect(
        cleanLegadoImageUrl(
          'https://img.example.com/a.jpg,{"headers":{"Referer":"https://x/"}}',
        ),
        'https://img.example.com/a.jpg,{"headers":{"Referer":"https://x/"}}',
      );
      expect(
        cleanLegadoImageUrl('https://img.example.com/a.jpg,{'),
        'https://img.example.com/a.jpg',
      );
      expect(
        cleanLegadoImageUrl('https://img.example.com/a.jpg,{"headers"'),
        'https://img.example.com/a.jpg',
      );
      expect(cleanLegadoImageUrl('not a url'), isNull);
      expect(cleanLegadoImageUrl(''), isNull);
    });
  });

  group('MangaImageCache', () {
    test('concurrent loads share one fetch; later loads hit the cache', () async {
      var calls = 0;
      final cache = MangaImageCache(
        loader: ({required origin, required url, String? bookUrl}) async {
          calls++;
          return _png;
        },
      );
      final a = cache.load(_sourceUrl, 'https://i/1.jpg');
      final b = cache.load(_sourceUrl, 'https://i/1.jpg');
      final results = await Future.wait([a, b]);
      expect(calls, 1);
      expect(results.first.size, const Size(1, 1));
      await cache.load(_sourceUrl, 'https://i/1.jpg');
      expect(calls, 1);
      expect(cache.cachedEntries, 1);
      expect(cache.peek('https://i/1.jpg')?.bytes, _png);
    });

    test('entry budget evicts least-recently-used pages', () async {
      final cache = MangaImageCache(
        maxEntries: 2,
        loader: ({required origin, required url, String? bookUrl}) async => _png,
      );
      await cache.load(_sourceUrl, 'https://i/1.jpg');
      await cache.load(_sourceUrl, 'https://i/2.jpg');
      await cache.load(_sourceUrl, 'https://i/3.jpg');
      expect(cache.peek('https://i/1.jpg'), isNull);
      expect(cache.peek('https://i/3.jpg'), isNotNull);
    });

    test('a failure is remembered briefly, then evict allows a retry', () async {
      var calls = 0;
      final cache = MangaImageCache(
        loader: ({required origin, required url, String? bookUrl}) async {
          calls++;
          throw StateError('boom');
        },
      );
      await expectLater(
        cache.load(_sourceUrl, 'https://i/x.jpg'),
        throwsStateError,
      );
      await expectLater(
        cache.load(_sourceUrl, 'https://i/x.jpg'),
        throwsStateError,
      );
      expect(calls, 1, reason: 'the failure window suppresses refetching');
      cache.evict('https://i/x.jpg');
      await expectLater(
        cache.load(_sourceUrl, 'https://i/x.jpg'),
        throwsStateError,
      );
      expect(calls, 2);
    });
  });

  group('repository chapterImages', () {
    const methodChannel = MethodChannel('org.mewx.wenku8/legado_engine');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late LegadoBookRegistry registry;
    late LegadoNovelRepository repository;
    var contentCalls = 0;
    var mockBookType = legadoImageBookTypeBit;
    var isImageChapter = true;
    var nativeImages = <String>['https://img.example.com/p1.jpg,{'];
    var contentBody =
        '<img src="https://img.example.com/p2.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}">';

    setUp(() async {
      SharedPreferences.setMockInitialValues(const {});
      contentCalls = 0;
      mockBookType = legadoImageBookTypeBit;
      isImageChapter = true;
      nativeImages = ['https://img.example.com/p1.jpg,{'];
      contentBody =
          '<img src="https://img.example.com/p2.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}">';
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'init':
            return {'ok': true, 'engineVersion': 'test', 'sourceCount': 0};
          case 'getBookInfo':
            return {
              'bookUrl': 'https://manwa.example.com/book/1',
              'tocUrl': 'https://manwa.example.com/book/1',
              'name': '测试漫画',
              'author': '佚名',
              'type': mockBookType,
              'origin': _sourceUrl,
              'originName': '漫蛙',
            };
          case 'getChapterList':
            return {
              'book': {
                'bookUrl': 'https://manwa.example.com/book/1',
                'tocUrl': 'https://manwa.example.com/book/1',
                'name': '测试漫画',
                'author': '佚名',
                'type': mockBookType,
                'origin': _sourceUrl,
                'originName': '漫蛙',
              },
              'chapters': [
                {
                  'title': '第1话',
                  'url': 'https://manwa.example.com/ch/1',
                  'index': 0,
                },
                {
                  'title': '第2话',
                  'url': 'https://manwa.example.com/ch/2',
                  'index': 1,
                },
              ],
            };
          case 'getChapterContent':
            contentCalls++;
            return {
              'content': contentBody,
              'images': nativeImages,
              'isImageChapter': isImageChapter,
            };
        }
        return null;
      });
      final client = LegadoEngineClient(methodChannel: methodChannel);
      registry = LegadoBookRegistry(
        preferences: SharedPreferences.getInstance(),
      );
      await registry.ready;
      repository = LegadoNovelRepository(client: client, registry: registry);
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(methodChannel, null);
    });

    Future<LegadoBookRecord> seed({required int type}) =>
        registry.registerSearchBook(
          SearchBook(
            name: '测试漫画',
            author: '佚名',
            bookUrl: 'https://manwa.example.com/book/1',
            origin: _sourceUrl,
            originName: '漫蛙',
            type: type,
          ),
        );

    test('image book: native images are sanitized and returned in order', () async {
      final record = await seed(type: legadoImageBookTypeBit);
      final chapters = await repository.chapters(record.id);
      nativeImages = [
        'https://img.example.com/p1.jpg,{',
        'https://img.example.com/p2.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}',
      ];
      final images = await repository.chapterImages(record.id, chapters.first);
      expect(images, isNotNull);
      expect(images!.origin, _sourceUrl);
      expect(images.urls, [
        'https://img.example.com/p1.jpg',
        'https://img.example.com/p2.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}',
      ]);
    });

    test('image book: empty native list falls back to parsing content', () async {
      final record = await seed(type: legadoImageBookTypeBit);
      final chapters = await repository.chapters(record.id);
      nativeImages = const [];
      final images = await repository.chapterImages(record.id, chapters.first);
      expect(images?.urls, [
        'https://img.example.com/p2.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}',
      ]);
    });

    test('text book: null without any engine content call', () async {
      mockBookType = 8;
      final record = await seed(type: 8);
      final chapters = await repository.chapters(record.id);
      expect(await repository.chapterImages(record.id, chapters.first), isNull);
      expect(contentCalls, 0);
    });

    test('image book but prose chapter: the engine verdict wins (null)', () async {
      final record = await seed(type: legadoImageBookTypeBit);
      final chapters = await repository.chapters(record.id);
      isImageChapter = false;
      contentBody = '这一章是文字。';
      nativeImages = const [];
      expect(await repository.chapterImages(record.id, chapters.first), isNull);
      expect(contentCalls, 1);
    });

    test('chapterContent still returns the notice for image chapters', () async {
      final record = await seed(type: legadoImageBookTypeBit);
      final chapters = await repository.chapters(record.id);
      expect(
        await repository.chapterContent(record.id, chapters.first),
        legadoImageChapterNotice,
      );
    });

    test('dispatch answers null for non-Legado ids and delegates Legado ids', () async {
      final dispatch = LegadoDispatchRepository(
        legacy: const DemoNovelRepository(),
        legado: repository,
      );
      const chapter = NovelChapter('第1话', '', id: 1);
      expect(await dispatch.chapterImages(42, chapter), isNull);
      final record = await seed(type: legadoImageBookTypeBit);
      await repository.chapters(record.id);
      final images = await dispatch.chapterImages(record.id, chapter);
      expect(images?.urls, isNotEmpty);
    });
  });

  group('MangaChapterImage widget', () {
    testWidgets('shows the image once loaded', (tester) async {
      final cache = MangaImageCache(
        loader: ({required origin, required url, String? bookUrl}) async => _png,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MangaChapterImage(
              origin: _sourceUrl,
              url: 'https://img.example.com/ok.jpg',
              cache: cache,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('图片加载失败'), findsNothing);
    });

    testWidgets('failure shows the retry panel; tapping retry reloads', (
      tester,
    ) async {
      var fail = true;
      final cache = MangaImageCache(
        loader: ({required origin, required url, String? bookUrl}) async {
          if (fail) throw StateError('boom');
          return _png;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MangaChapterImage(
              origin: _sourceUrl,
              url: 'https://img.example.com/flaky.jpg',
              cache: cache,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('图片加载失败'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('重试图片'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('图片加载失败'), findsNothing);
    });
  });

  group('reader shell with Legado books', () {
    const methodChannel = MethodChannel('org.mewx.wenku8/legado_engine');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('manga_reader_test');
      MangaImageDebug.loaderOverride = ({required origin, required url, String? bookUrl}) async =>
          _png;
    });

    tearDown(() {
      MangaImageDebug.loaderOverride = null;
      messenger.setMockMethodCallHandler(methodChannel, null);
      tempDir.deleteSync(recursive: true);
    });

    /// The offline repository reads/writes real files; drain that IO
    /// on the real event loop between fake-async pumps until [until]
    /// holds, the same way the offline/listening UI suites settle
    /// their readers with a condition loop.
    Future<void> drainReaderIo(
      WidgetTester tester, {
      bool Function()? until,
    }) async {
      for (var i = 0; i < 60; i++) {
        if (until != null && until()) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<Widget> buildReader({
      required int bookType,
      required bool imageChapter,
      Map<String, Object> prefs = const {},
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'init':
            return {'ok': true, 'engineVersion': 'test', 'sourceCount': 0};
          case 'getBookInfo':
            return {
              'bookUrl': 'https://manwa.example.com/book/1',
              'tocUrl': 'https://manwa.example.com/book/1',
              'name': '测试漫画',
              'author': '佚名',
              'type': bookType,
              'origin': _sourceUrl,
              'originName': '漫蛙',
            };
          case 'getChapterList':
            return {
              'book': {
                'bookUrl': 'https://manwa.example.com/book/1',
                'tocUrl': 'https://manwa.example.com/book/1',
                'name': '测试漫画',
                'author': '佚名',
                'type': bookType,
                'origin': _sourceUrl,
                'originName': '漫蛙',
              },
              'chapters': [
                {
                  'title': '第1话',
                  'url': 'https://manwa.example.com/ch/1',
                  'index': 0,
                },
                {
                  'title': '第2话',
                  'url': 'https://manwa.example.com/ch/2',
                  'index': 1,
                },
              ],
            };
          case 'getChapterContent':
            return imageChapter
                ? {
                    'content':
                        '<img src="https://img.example.com/p1.jpg,{"headers":{"Referer":"https://manwa.example.com/"}}">',
                    'images': ['https://img.example.com/p1.jpg,{'],
                    'isImageChapter': true,
                  }
                : {
                    'content': '这一章是文字正文。\n第二段正文继续。',
                    'images': <String>[],
                    'isImageChapter': false,
                  };
        }
        return null;
      });
      final client = LegadoEngineClient(methodChannel: methodChannel);
      final registry = LegadoBookRegistry(
        preferences: SharedPreferences.getInstance(),
      );
      await registry.ready;
      final legado = LegadoNovelRepository(client: client, registry: registry);
      final dispatch = LegadoDispatchRepository(
        legacy: const DemoNovelRepository(),
        legado: legado,
      );
      final record = await registry.registerSearchBook(
        SearchBook(
          name: '测试漫画',
          author: '佚名',
          bookUrl: 'https://manwa.example.com/book/1',
          origin: _sourceUrl,
          originName: '漫蛙',
          type: bookType,
        ),
      );
      final detailed = await dispatch.detail(record.toNovel());
      final novel = detailed.withChapters(
        await dispatch.chapters(record.id),
      );
      final offline = OfflineNovelRepository(
        remote: dispatch,
        cache: OfflineCacheStore(tempDir),
      );
      final state = await LibraryState.load();
      final listening = ListeningController(
        repository: const DemoNovelRepository(),
        audio: FakeSpeechAudio(),
        store: ListeningStore(await SharedPreferences.getInstance()),
        outputFactory: (_) async => FakeListeningOutput(),
      );
      return MaterialApp(
        theme: novelTheme(Brightness.light),
        builder: (context, child) =>
            ListeningScope(controller: listening, child: child!),
        home: ReaderPage(
          state: state,
          novel: novel,
          repository: offline,
          initialChapter: 0,
        ),
      );
    }

    testWidgets('image chapter renders as a vertical image column', (
      tester,
    ) async {
      await tester.pumpWidget(
        await buildReader(bookType: legadoImageBookTypeBit, imageChapter: true),
      );
      await drainReaderIo(tester);
      await settleReader(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MangaChapterImage), findsWidgets);
      expect(find.textContaining('CH.001 / IMAGE'), findsOneWidget);
      expect(find.textContaining('本章节为图片章节'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('image chapter stays scrollable in paged reader mode', (
      tester,
    ) async {
      await tester.pumpWidget(
        await buildReader(
          bookType: legadoImageBookTypeBit,
          imageChapter: true,
          prefs: {'readerPreferences': jsonEncode({'mode': 'paged'})},
        ),
      );
      await drainReaderIo(tester);
      await settleReader(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MangaChapterImage), findsWidgets);
      expect(find.byType(ReaderPagedView), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('text chapter of a Legado book renders prose, unchanged', (
      tester,
    ) async {
      await tester.pumpWidget(
        await buildReader(bookType: 8, imageChapter: false),
      );
      await drainReaderIo(
        tester,
        until: () =>
            find.textContaining('这一章是文字正文').evaluate().isNotEmpty,
      );
      await settleReader(tester);
      expect(find.byType(MangaChapterImage), findsNothing);
      expect(find.textContaining('这一章是文字正文'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}

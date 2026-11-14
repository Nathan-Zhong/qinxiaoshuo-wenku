// fix7: text-type sources whose chapters are entirely images
// (copymanga 7789 shape: bookSourceType 0, ruleContent
// imageStyle=FULL, body = one <img> per page) must open in the manga
// image view, while prose — including prose with illustrations —
// stays on the text path untouched.
//
// Layers covered: the pure all-image sniff, the repository routing
// (registry imageStyle gate + engine fetch + sniff verdict), the
// registry absorbing/persisting the style, and the reader shell
// rendering the routed chapter as a vertical image column.

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

import '../support/listening_fixture.dart';
import '../reader_modes_test.dart' show settleReader;

const _copyUrl = 'https://www.mangacopy.com/';

/// The classic 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
);

/// 7789's real payload shape (chapter 1 of 鬼滅之刃， trimmed): the
/// content rule emits one bare `<img>` line per page, nothing else.
const _copyChapterBody =
    '<img src="https://sg.mangafunb.fun/g/guimiezhiren/1c39f/1647262528900001.jpg.c1500x.jpg">\n'
    '<img src="https://sg.mangafunb.fun/g/guimiezhiren/1c39f/1647262528900002.jpg.c1500x.jpg">\n'
    '<img src="https://sg.mangafunb.fun/g/guimiezhiren/1c39f/1647262528900003.jpg.c1500x.jpg">';

const _copyChapterUrls = [
  'https://sg.mangafunb.fun/g/guimiezhiren/1c39f/1647262528900001.jpg.c1500x.jpg',
  'https://sg.mangafunb.fun/g/guimiezhiren/1c39f/1647262528900002.jpg.c1500x.jpg',
  'https://sg.mangafunb.fun/g/guimiezhiren/1c39f/1647262528900003.jpg.c1500x.jpg',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('legadoContentIsImageChapter (the sniff)', () {
    test('copymanga payload: img-tag lines only -> image chapter', () {
      expect(legadoContentIsImageChapter(_copyChapterBody), isTrue);
    });

    test('bare image-URL lines only -> image chapter', () {
      expect(
        legadoContentIsImageChapter(
          'https://img.example.com/1.jpg\nhttps://img.example.com/2.jpg',
        ),
        isTrue,
      );
    });

    test('markdown images only -> image chapter', () {
      expect(
        legadoContentIsImageChapter(
          '![](https://img.example.com/1.jpg)\n![](https://img.example.com/2.jpg)',
        ),
        isTrue,
      );
    });

    test('a single image with an otherwise empty body -> image', () {
      expect(
        legadoContentIsImageChapter('<img src="https://img.example.com/1.jpg">'),
        isTrue,
      );
    });

    test('plain prose -> not an image chapter', () {
      expect(
        legadoContentIsImageChapter('第一章 开始\n这是正文段落。\n又一段正文继续着。'),
        isFalse,
      );
    });

    test('prose with illustrations stays prose', () {
      const body =
          '正文第一段，讲述了很长的一个故事。\n'
          '<img src="https://img.example.com/ill1.jpg">\n'
          '正文第二段，故事还在继续。\n'
          '<img src="https://img.example.com/ill2.jpg">\n'
          '正文第三段，故事结束了。';
      expect(legadoContentIsImageChapter(body), isFalse);
    });

    test('images plus a textual tail note stay prose', () {
      const body =
          '<img src="https://img.example.com/1.jpg">\n'
          '<img src="https://img.example.com/2.jpg">\n'
          '（第1话 完）';
      expect(legadoContentIsImageChapter(body), isFalse);
    });

    test('a single image plus a caption stays prose', () {
      const body =
          '<img src="https://img.example.com/1.jpg">\n'
          '图：主角登场';
      expect(legadoContentIsImageChapter(body), isFalse);
    });

    test('images plus separator-only residue -> image chapter', () {
      const body =
          '<img src="https://img.example.com/1.jpg">\n'
          '***\n'
          '<img src="https://img.example.com/2.jpg">';
      expect(legadoContentIsImageChapter(body), isTrue);
    });

    test('empty body -> not an image chapter', () {
      expect(legadoContentIsImageChapter(''), isFalse);
      expect(legadoContentIsImageChapter('  \n \n'), isFalse);
    });
  });

  group('registry imageStyle', () {
    late LegadoBookRegistry registry;

    setUp(() async {
      SharedPreferences.setMockInitialValues(const {});
      registry = LegadoBookRegistry(
        preferences: SharedPreferences.getInstance(),
      );
      await registry.ready;
    });

    test('absorbed from a book snapshot, sticky, and persisted', () async {
      final record = await registry.registerSearchBook(
        const SearchBook(
          name: '拷贝漫画',
          author: '佚名',
          bookUrl: 'https://api.mangacopy.com/api/v3/comic2/guimiezhiren',
          origin: _copyUrl,
          type: 8,
        ),
      );
      expect(record.imageStyle, isNull);
      registry.absorbBookInfo(
        BookInfo.fromSearchBook(record.toSearchBook()).copyWithStyle('FULL'),
      );
      expect(record.imageStyle, 'FULL');
      // A later absorb that does not carry the style must not clear it.
      registry.absorbBookInfo(
        BookInfo.fromSearchBook(record.toSearchBook()).copyWithStyle(null),
      );
      expect(record.imageStyle, 'FULL');
      // Persisted round-trip.
      await registry.flush();
      final reloaded = LegadoBookRegistry(
        preferences: SharedPreferences.getInstance(),
      );
      await reloaded.ready;
      expect(reloaded.recordById(record.id)?.imageStyle, 'FULL');
      expect(reloaded.recordById(record.id)?.type, 8);
    });
  });

  group('repository routing for imageStyle-gated text books', () {
    const methodChannel = MethodChannel('org.mewx.wenku8/legado_engine');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late LegadoBookRegistry registry;
    late LegadoNovelRepository repository;
    var contentCalls = 0;
    var contentBody = _copyChapterBody;
    var nativeImages = <String>[];
    String? bookImageStyle = 'FULL';

    Map<String, Object?> bookMap() => {
      'bookUrl': 'https://api.mangacopy.com/api/v3/comic2/guimiezhiren',
      'tocUrl': 'https://api.mangacopy.com/api/v3/comic/guimiezhiren',
      'name': '鬼滅之刃',
      'author': '佚名',
      'type': 8,
      'origin': _copyUrl,
      'originName': '拷贝漫画',
      'imageStyle': bookImageStyle,
    };

    setUp(() async {
      SharedPreferences.setMockInitialValues(const {});
      contentCalls = 0;
      contentBody = _copyChapterBody;
      nativeImages = <String>[];
      bookImageStyle = 'FULL';
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'init':
            return {'ok': true, 'engineVersion': 'test', 'sourceCount': 0};
          case 'getBookInfo':
            return bookMap();
          case 'getChapterList':
            return {
              'book': bookMap(),
              'chapters': [
                {
                  'title': '第1话',
                  'url':
                      'https://api.mangacopy.com/api/v3/comic/guimiezhiren/chapter2/uuid-1',
                  'index': 0,
                },
                {
                  'title': '第2话',
                  'url':
                      'https://api.mangacopy.com/api/v3/comic/guimiezhiren/chapter2/uuid-2',
                  'index': 1,
                },
              ],
            };
          case 'getChapterContent':
            contentCalls++;
            return {
              'content': contentBody,
              'images': nativeImages,
              // The engine verdict is type-based: a type-0 source
              // never reports an image chapter.
              'isImageChapter': false,
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

    Future<LegadoBookRecord> seed() => registry.registerSearchBook(
      const SearchBook(
        name: '鬼滅之刃',
        author: '佚名',
        bookUrl: 'https://api.mangacopy.com/api/v3/comic2/guimiezhiren',
        origin: _copyUrl,
        originName: '拷贝漫画',
        type: 8,
      ),
    );

    test('copymanga fixture routes to images parsed from the body', () async {
      final record = await seed();
      final chapters = await repository.chapters(record.id);
      final images = await repository.chapterImages(record.id, chapters.first);
      expect(images, isNotNull);
      expect(images!.origin, _copyUrl);
      expect(images.urls, _copyChapterUrls);
      expect(contentCalls, 1);
    });

    test('the bridge-extracted list is preferred when present', () async {
      final record = await seed();
      final chapters = await repository.chapters(record.id);
      nativeImages = const ['https://img.example.com/native1.jpg'];
      final images = await repository.chapterImages(record.id, chapters.first);
      expect(images?.urls, ['https://img.example.com/native1.jpg']);
    });

    test('chapterContent serves the notice for an all-image chapter', () async {
      final record = await seed();
      final chapters = await repository.chapters(record.id);
      expect(
        await repository.chapterContent(record.id, chapters.first),
        legadoImageChapterNotice,
      );
    });

    test('prose chapter of a gated book stays prose, then probing '
        'retires for the process', () async {
      final record = await seed();
      final chapters = await repository.chapters(record.id);
      contentBody =
          '正文第一段。\n<img src="https://img.example.com/ill.jpg">\n正文第二段。';
      expect(await repository.chapterImages(record.id, chapters.first), isNull);
      expect(contentCalls, 1);
      expect(
        await repository.chapterContent(record.id, chapters.first),
        contentBody,
      );
      expect(contentCalls, 2, reason: 'chapterContent fetches its own copy');
      // Second chapter: the recorded prose verdict answers without
      // another engine fetch.
      expect(await repository.chapterImages(record.id, chapters[1]), isNull);
      expect(contentCalls, 2);
    });

    test('a text book without the style signal never probes', () async {
      bookImageStyle = null;
      final record = await seed();
      final chapters = await repository.chapters(record.id);
      expect(record.imageStyle, isNull);
      expect(await repository.chapterImages(record.id, chapters.first), isNull);
      expect(contentCalls, 0);
    });
  });

  group('reader shell with a copymanga-shaped book', () {
    const methodChannel = MethodChannel('org.mewx.wenku8/legado_engine');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('imgstyle_reader_test');
      MangaImageDebug.loaderOverride = ({required origin, required url, String? bookUrl}) async =>
          _png;
    });

    tearDown(() {
      MangaImageDebug.loaderOverride = null;
      messenger.setMockMethodCallHandler(methodChannel, null);
      tempDir.deleteSync(recursive: true);
    });

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

    Future<Widget> buildReader({required bool allImageChapter}) async {
      SharedPreferences.setMockInitialValues(const {});
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'init':
            return {'ok': true, 'engineVersion': 'test', 'sourceCount': 0};
          case 'getBookInfo':
          case 'getChapterList':
            final book = {
              'bookUrl':
                  'https://api.mangacopy.com/api/v3/comic2/guimiezhiren',
              'tocUrl': 'https://api.mangacopy.com/api/v3/comic/guimiezhiren',
              'name': '鬼滅之刃',
              'author': '佚名',
              'type': 8,
              'origin': _copyUrl,
              'originName': '拷贝漫画',
              'imageStyle': 'FULL',
            };
            if (call.method == 'getBookInfo') return book;
            return {
              'book': book,
              'chapters': [
                {
                  'title': '第1话',
                  'url':
                      'https://api.mangacopy.com/api/v3/comic/guimiezhiren/chapter2/uuid-1',
                  'index': 0,
                },
                {
                  'title': '第2话',
                  'url':
                      'https://api.mangacopy.com/api/v3/comic/guimiezhiren/chapter2/uuid-2',
                  'index': 1,
                },
              ],
            };
          case 'getChapterContent':
            return {
              'content': allImageChapter
                  ? _copyChapterBody
                  : '这一章是文字正文。\n<img src="https://img.example.com/ill.jpg">\n第二段正文继续。',
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
        const SearchBook(
          name: '鬼滅之刃',
          author: '佚名',
          bookUrl: 'https://api.mangacopy.com/api/v3/comic2/guimiezhiren',
          origin: _copyUrl,
          originName: '拷贝漫画',
          type: 8,
        ),
      );
      final detailed = await dispatch.detail(record.toNovel());
      final novel = detailed.withChapters(await dispatch.chapters(record.id));
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

    testWidgets('all-image chapter of a text-type book renders as a '
        'vertical image column', (tester) async {
      await tester.pumpWidget(await buildReader(allImageChapter: true));
      await drainReaderIo(tester);
      await settleReader(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MangaChapterImage), findsWidgets);
      expect(find.textContaining('CH.001 / IMAGE'), findsOneWidget);
      expect(find.textContaining('本章节为图片章节'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('prose chapter of the same book renders prose, unchanged', (
      tester,
    ) async {
      await tester.pumpWidget(await buildReader(allImageChapter: false));
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

/// Test-local helper: a BookInfo identical to the receiver's search
/// view but carrying an image style, as the bridge stamps it.
extension on BookInfo {
  BookInfo copyWithStyle(String? style) => BookInfo(
    name: name,
    author: author,
    bookUrl: bookUrl,
    tocUrl: tocUrl,
    origin: origin,
    originName: originName,
    origins: origins,
    type: type,
    kind: kind,
    coverUrl: coverUrl,
    intro: intro,
    wordCount: wordCount,
    latestChapterTitle: latestChapterTitle,
    chapterWordCount: chapterWordCount,
    variable: variable,
    charset: charset,
    totalChapterNum: totalChapterNum,
    latestChapterTime: latestChapterTime,
    lastCheckCount: lastCheckCount,
    canUpdate: canUpdate,
    imageStyle: style,
  );
}

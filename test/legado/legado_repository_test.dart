import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legado/legado_book_registry.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';
import 'package:wenku8_flutter/legado/legado_engine_client.dart';
import 'package:wenku8_flutter/legado/legado_explore.dart';
import 'package:wenku8_flutter/legado/legado_novel_repository.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';

const _sourceUrl = 'https://src.example';

Map<String, Object?> _sourceMap({int type = 0, bool enabledExplore = true}) => {
  'sourceUrl': _sourceUrl,
  'sourceName': '示例源',
  'group': '',
  'type': type,
  'enabled': true,
  'enabledExplore': enabledExplore,
  'customOrder': 0,
  'weight': 0,
  'respondTimeMs': 100,
  'lastUpdateTime': 0,
  'hasLogin': false,
  'comment': null,
  'icon': null,
  'exploreKindCount': null,
  'sourceJson': null,
};

Map<String, Object?> _bookMap() => {
  'name': '斗破苍穹',
  'author': '天蚕土豆',
  'bookUrl': 'https://src.example/book/1',
  'tocUrl': 'https://src.example/book/1/toc',
  'origin': _sourceUrl,
  'originName': '示例源',
  'origins': [_sourceUrl],
  'type': 0,
  'kind': '玄幻',
  'coverUrl': 'https://img.example/c.jpg',
  'intro': '三十年河东',
  'wordCount': '500万字',
  'latestChapterTitle': '第100章',
  'chapterWordCount': 0,
  'variable': null,
  'charset': 'utf-8',
  'totalChapterNum': 2,
  'latestChapterTime': 0,
  'lastCheckCount': 0,
  'canUpdate': true,
};

Map<String, Object?> _chapterMap(String url, String title, int index) => {
  'url': url,
  'title': title,
  'index': index,
  'isVolume': false,
  'isVip': false,
  'isPay': false,
  'resourceUrl': null,
  'tag': null,
  'wordCount': null,
  'variable': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(LegadoEngineClient.methodChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late LegadoEngineClient client;
  late LegadoBookRegistry registry;
  late LegadoNovelRepository repository;
  Object? Function(MethodCall call)? responder;
  var imageChapter = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    imageChapter = false;
    responder = (call) {
      switch (call.method) {
        case 'init':
          return {'ok': true, 'engineVersion': 'test', 'sourceCount': 1};
        case 'listSources':
          return [_sourceMap()];
        case 'getBookInfo':
          return _bookMap();
        case 'getChapterList':
          return {
            'book': _bookMap(),
            'chapters': [
              _chapterMap('https://src.example/c1', '第一章', 0),
              _chapterMap('https://src.example/c2', '第二章', 1),
            ],
          };
        case 'getChapterContent':
          return {
            'content': imageChapter ? '<img src="x">' : '正文内容',
            'images': imageChapter ? ['https://img.example/1.jpg'] : <String>[],
            'isImageChapter': imageChapter,
          };
        case 'getExploreKinds':
          return [
            {'title': '分组', 'url': null, 'viewName': 'title', 'style': 3},
            {'title': '玄幻', 'url': 'kind/xh', 'viewName': 'text', 'style': 3},
            {'title': '都市', 'url': 'kind/ds', 'viewName': 'text', 'style': 3},
          ];
        case 'getExploreBooks':
          final args = (call.arguments as Map).cast<String, Object?>();
          final page = args['page'] as int? ?? 1;
          return {
            'books': [
              {
                ..._bookMap(),
                'name': '发现书$page',
                'bookUrl': 'https://src.example/book/e$page',
              },
            ],
            'hasMore': page < 2,
          };
      }
      return null;
    };
    client = LegadoEngineClient(methodChannel: methodChannel);
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      return responder?.call(call);
    });
    registry = LegadoBookRegistry(preferences: SharedPreferences.getInstance());
    await registry.ready;
    repository = LegadoNovelRepository(client: client, registry: registry);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  Future<LegadoBookRecord> seedBook() => registry.registerSearchBook(
    const SearchBook(
      name: '斗破苍穹',
      author: '天蚕土豆',
      bookUrl: 'https://src.example/book/1',
      origin: _sourceUrl,
      originName: '示例源',
    ),
  );

  group('LegadoNovelRepository', () {
    test(
      'detail maps engine info onto the novel and refreshes the record',
      () async {
        final record = await seedBook();
        final novel = await repository.detail(record.toNovel());
        expect(novel.id, record.id);
        expect(novel.title, '斗破苍穹');
        expect(novel.summary, '三十年河东');
        expect(novel.genre, '玄幻');
        expect(novel.coverUrl, 'https://img.example/c.jpg');
        expect(
          registry.recordById(record.id)?.tocUrl,
          'https://src.example/book/1/toc',
        );
      },
    );

    test('chapters come from the engine and persist as fallback', () async {
      final record = await seedBook();
      final chapters = await repository.chapters(record.id);
      expect(chapters, hasLength(2));
      expect(chapters.first.title, '第一章');
      expect(chapters.first.id, 1);
      // Engine failure afterwards: the persisted TOC serves instead.
      responder = (call) {
        if (call.method == 'getChapterList') {
          throw PlatformException(code: 'NET', message: 'down');
        }
        return null;
      };
      final cached = await repository.chapters(record.id);
      expect(cached.map((c) => c.title), ['第一章', '第二章']);
    });

    test(
      'chapter content returns text; image chapters return the notice',
      () async {
        final record = await seedBook();
        await repository.chapters(record.id);
        const chapter = NovelChapter('第一章', '', id: 1);
        expect(await repository.chapterContent(record.id, chapter), '正文内容');
        imageChapter = true;
        expect(
          await repository.chapterContent(record.id, chapter),
          legadoImageChapterNotice,
        );
      },
    );

    test(
      'chapter content asks the engine to run its content pipeline',
      () async {
        // P5.5: reading a Legado book must request the full
        // post-processing (applyReplace: true) with the TOC chapter
        // title, like the fork's reader always processing content.
        Map<String, Object?>? contentArgs;
        final base = responder;
        responder = (call) {
          if (call.method == 'getChapterContent') {
            contentArgs = (call.arguments as Map).cast<String, Object?>();
          }
          return base?.call(call);
        };
        final record = await seedBook();
        await repository.chapters(record.id);
        const chapter = NovelChapter('第一章', '', id: 1);
        await repository.chapterContent(record.id, chapter);
        expect(contentArgs?['applyReplace'], isTrue);
        expect(contentArgs?['chapterTitle'], '第一章');
      },
    );

    test('find resolves from the registry without the engine', () async {
      final record = await seedBook();
      responder = null;
      final novel = await repository.find(record.id);
      expect(novel?.title, '斗破苍穹');
      expect(await repository.find(record.id + 500), isNull);
    });

    test('eligible sources exclude audio/video source types', () async {
      responder = (call) {
        if (call.method == 'listSources') {
          return [
            _sourceMap(type: 0),
            {..._sourceMap(type: 1), 'sourceUrl': 'https://audio.example'},
            {..._sourceMap(type: 2), 'sourceUrl': 'https://manga.example'},
          ];
        }
        return {'ok': true, 'engineVersion': 't', 'sourceCount': 3};
      };
      final sources = await repository.eligibleSources();
      expect(sources.map((s) => s.sourceUrl), [
        _sourceUrl,
        'https://manga.example',
      ]);
    });
  });

  group('LegadoDispatchRepository', () {
    test('routes by id range and leaves the rest to the legacy repo', () async {
      final legacy = _RecordingLegacy();
      final dispatch = LegadoDispatchRepository(
        legacy: legacy,
        legado: repository,
      );
      final record = await seedBook();

      final wenkuNovel = Novel(
        id: 42,
        title: '文库书',
        author: '作者',
        genre: '',
        summary: '',
        colors: record.toNovel().colors,
      );
      await dispatch.detail(wenkuNovel);
      expect(legacy.detailCalls, [42]);
      final detail = await dispatch.detail(record.toNovel());
      expect(detail.title, '斗破苍穹');
      expect(legacy.detailCalls, [42]);

      final chapters = await dispatch.chapters(record.id);
      expect(chapters, hasLength(2));
      expect(legacy.chapterCalls, isEmpty);
      await dispatch.chapters(42);
      expect(legacy.chapterCalls, [42]);

      expect(await dispatch.chapterContent(record.id, chapters.first), '正文内容');
      expect(await dispatch.find(42), isNull);
      expect((await dispatch.find(record.id))?.title, '斗破苍穹');
    });
  });

  group('LegadoExploreSelection + repository', () {
    test(
      'load picks the first browsable kind; browse pages follow hasMore',
      () async {
        final selection = LegadoExploreSelection(
          repository: repository,
          preferences: SharedPreferences.getInstance(),
        );
        await selection.load();
        expect(selection.sourceUrl, _sourceUrl);
        expect(selection.kindUrl, 'kind/xh');
        expect(selection.browsableKinds.map((k) => k.title), ['玄幻', '都市']);

        final explore = LegadoExploreRepository(
          selection: selection,
          engine: repository,
        );
        final page1 = await explore.browse(page: 1);
        expect(page1.items.single.title, '发现书1');
        expect(page1.hasMore, isTrue);
        expect(isLegadoBookId(page1.items.single.id), isTrue);
        final page2 = await explore.browse(page: 2);
        expect(page2.items.single.title, '发现书2');
        expect(page2.hasMore, isFalse);
      },
    );

    test('load picks up a source imported after the first load', () async {
      // Regression (2026-11-03): the discovery tab bootstraps before
      // any source exists; load() must re-query instead of latching
      // the empty list for the rest of the process.
      final base = responder;
      var imported = false;
      responder = (call) {
        if (call.method == 'listSources') {
          return imported ? [_sourceMap()] : <Object?>[];
        }
        return base?.call(call);
      };
      final selection = LegadoExploreSelection(
        repository: repository,
        preferences: SharedPreferences.getInstance(),
      );
      await selection.load();
      expect(selection.sources, isEmpty);
      expect(selection.sourceUrl, isNull);
      imported = true;
      await selection.load();
      expect(selection.sources, hasLength(1));
      expect(selection.sourceUrl, _sourceUrl);
      expect(selection.kindUrl, 'kind/xh');
    });

    test('selection is remembered across instances', () async {
      final first = LegadoExploreSelection(
        repository: repository,
        preferences: SharedPreferences.getInstance(),
      );
      await first.load();
      await first.select(sourceUrl: _sourceUrl, kindUrl: 'kind/ds');
      final second = LegadoExploreSelection(
        repository: repository,
        preferences: SharedPreferences.getInstance(),
      );
      await second.load();
      expect(second.kindUrl, 'kind/ds');
    });
  });

  group('explore cover prefetch (fix1)', () {
    Future<void> drainUntil(bool Function() done) async {
      for (var i = 0; i < 500 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    Object? Function(MethodCall) exploreResponder({
      required List<Map<String, Object?>> books,
      required Object? Function(MethodCall) onInfo,
    }) {
      return (call) {
        switch (call.method) {
          case 'init':
            return {'ok': true, 'engineVersion': 'test', 'sourceCount': 1};
          case 'listSources':
            return [_sourceMap()];
          case 'getExploreKinds':
            return [
              {'title': '玄幻', 'url': 'kind/xh', 'viewName': 'text', 'style': 3},
            ];
          case 'getExploreBooks':
            return {'books': books, 'hasMore': false};
          case 'getBookInfo':
            return onInfo(call);
        }
        return null;
      };
    }

    Future<LegadoExploreRepository> coverExplore() async {
      final selection = LegadoExploreSelection(
        repository: repository,
        preferences: SharedPreferences.getInstance(),
      );
      await selection.load();
      return LegadoExploreRepository(selection: selection, engine: repository);
    }

    test('a coverless explore book is filled from detail info, once', () async {
      var infoCalls = 0;
      responder = exploreResponder(
        books: [
          {..._bookMap(), 'coverUrl': null},
        ],
        onInfo: (call) {
          infoCalls++;
          return _bookMap();
        },
      );
      final explore = await coverExplore();
      final filled = <Novel>[];
      explore.onCoverFilled = filled.add;
      final page = await explore.browse(page: 1);
      // The page lands immediately with the text cover; the fill is
      // a background follow-up, never a browse-time wait.
      expect(page.items.single.coverUrl, isNull);
      await drainUntil(() => filled.isNotEmpty);
      expect(infoCalls, 1);
      expect(filled.single.coverUrl, 'https://img.example/c.jpg');
      expect(
        registry.recordById(page.items.single.id)?.coverUrl,
        'https://img.example/c.jpg',
      );
      // Browsing the same page again fetches nothing: the record
      // carries the cover now (and the session cache is warm anyway).
      await explore.browse(page: 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(infoCalls, 1);
    });

    test(
      'a failed detail fetch is silent and never retried this session',
      () async {
        var infoCalls = 0;
        responder = exploreResponder(
          books: [
            {..._bookMap(), 'coverUrl': null},
          ],
          onInfo: (call) {
            infoCalls++;
            throw PlatformException(code: 'NET', message: 'down');
          },
        );
        final explore = await coverExplore();
        final filled = <Novel>[];
        explore.onCoverFilled = filled.add;
        final page = await explore.browse(page: 1);
        expect(page.items.single.coverUrl, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(infoCalls, 1);
        expect(filled, isEmpty);
        // Negative cache: a later browse of the same book does not
        // re-queue it (no retry loop against a shielded site).
        await explore.browse(page: 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(infoCalls, 1);
        expect(filled, isEmpty);
      },
    );

    test('books that already carry a cover are never prefetched', () async {
      var infoCalls = 0;
      var fills = 0;
      responder = exploreResponder(
        books: [_bookMap()],
        onInfo: (call) {
          infoCalls++;
          return _bookMap();
        },
      );
      final explore = await coverExplore();
      explore.onCoverFilled = (_) => fills++;
      final page = await explore.browse(page: 1);
      expect(page.items.single.coverUrl, 'https://img.example/c.jpg');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(infoCalls, 0);
      expect(fills, 0);
    });

    test('prefetch runs at most three detail fetches at a time', () async {
      var infoCalls = 0;
      var active = 0;
      var maxActive = 0;
      responder = exploreResponder(
        books: [
          for (var i = 0; i < 6; i++)
            {
              ..._bookMap(),
              'name': '书$i',
              'bookUrl': 'https://src.example/book/x$i',
              'coverUrl': null,
            },
        ],
        onInfo: (call) async {
          infoCalls++;
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          active--;
          final args = (call.arguments as Map).cast<String, Object?>();
          return {
            ..._bookMap(),
            'bookUrl': args['bookUrl'],
            'name': args['name'],
          };
        },
      );
      final explore = await coverExplore();
      final filled = <Novel>[];
      explore.onCoverFilled = filled.add;
      final page = await explore.browse(page: 1);
      expect(page.items, hasLength(6));
      await drainUntil(() => filled.length >= 6);
      expect(infoCalls, 6);
      expect(filled, hasLength(6));
      expect(maxActive, lessThanOrEqualTo(3));
      expect(maxActive, greaterThan(1));
    });

    test(
      'a font-obfuscated explore title is repaired from detail info',
      () async {
        // fix2 regression (real device): a source whose list pages use
        // font anti-scraping served the title with a private-use-area
        // char in it ('斗\uE000破苍穹'); the discovery shelf rendered
        // phantom gaps. The detail page serves the real title.
        var infoCalls = 0;
        responder = exploreResponder(
          books: [
            {..._bookMap(), 'name': '斗\uE000破苍穹'},
          ],
          onInfo: (call) {
            infoCalls++;
            return _bookMap();
          },
        );
        final explore = await coverExplore();
        final filled = <Novel>[];
        explore.onCoverFilled = filled.add;
        final page = await explore.browse(page: 1);
        // The stored title is already stripped of the invisible char.
        expect(page.items.single.title, '斗破苍穹');
        // Even though the book already has a cover, the damaged title
        // queues exactly one background detail fetch to repair it.
        await drainUntil(() => filled.isNotEmpty);
        expect(infoCalls, 1);
        expect(filled.single.title, '斗破苍穹');
        expect(
          registry.recordById(page.items.single.id)?.name,
          '斗破苍穹',
        );
        // Browsing again (the source still serves the obfuscated
        // title) must neither clobber the repaired title nor refetch.
        await explore.browse(page: 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(infoCalls, 1);
        expect(
          registry.recordById(page.items.single.id)?.name,
          '斗破苍穹',
        );
      },
    );

    test('feed replaceItems swaps in a filled cover only', () async {
      responder = exploreResponder(
        books: [
          {..._bookMap(), 'coverUrl': null},
        ],
        onInfo: (call) => _bookMap(),
      );
      final explore = await coverExplore();
      final feed = NovelFeedController(explore);
      await feed.loadInitial();
      final item = feed.items.single;
      expect(item.coverUrl, isNull);
      final revision = feed.resultRevision;
      var notifications = 0;
      feed.addListener(() => notifications++);
      // A coverless replacement changes nothing and stays silent.
      feed.replaceItems([item]);
      expect(notifications, 0);
      // Once the background prefetch has filled the registry record,
      // its fresh snapshot swaps the cover in place — pagination and
      // the result revision are untouched.
      await drainUntil(() => registry.recordById(item.id)?.coverUrl != null);
      feed.replaceItems([registry.novelById(item.id)!]);
      expect(feed.items.single.coverUrl, 'https://img.example/c.jpg');
      expect(feed.resultRevision, revision);
      expect(feed.page, 1);
      expect(notifications, 1);
      feed.dispose();
    });
  });
}

class _RecordingLegacy extends DemoNovelRepository {
  final detailCalls = <int>[];
  final chapterCalls = <int>[];

  @override
  Future<Novel> detail(Novel novel) async {
    detailCalls.add(novel.id);
    return novel;
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    chapterCalls.add(id);
    return const [];
  }
}

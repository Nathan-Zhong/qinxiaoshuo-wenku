import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legado/legado_book_registry.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';
import 'package:wenku8_flutter/legado/legado_engine_client.dart';
import 'package:wenku8_flutter/legado/legado_explore.dart';
import 'package:wenku8_flutter/legado/legado_novel_repository.dart';

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

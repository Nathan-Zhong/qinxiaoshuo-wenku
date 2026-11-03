import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legado/legado_book_registry.dart';
import 'package:wenku8_flutter/legado/legado_engine_client.dart';
import 'package:wenku8_flutter/legado/legado_novel_repository.dart';
import 'package:wenku8_flutter/legado/legado_search_controller.dart';

/// fix3 end-to-end chain contract (Cassidy's acceptance wording):
/// after importing sources, discovery search must surface BOTH novels
/// and manga; a manga result must open detail → chapters → a real
/// image chapter; a novel result must open detail → chapters → real
/// text content. The whole chain is exercised here at the repository
/// level over a mocked bridge: search snapshot → registered Novel →
/// detail() → chapters() → chapterImages()/chapterContent(), with the
/// bridge calls asserted at each hop.
const _txtOrigin = 'https://txt.example';
const _kalaOrigin = 'https://www.kalamanhua.com';
const _mangaBookUrl = 'https://www.kalamanhua.com/comic/32034.html';
const _textBookUrl = 'https://txt.example/book/doupo';

Map<String, Object?> _searchBook({
  required String origin,
  required String originName,
  required String bookUrl,
  required String name,
  required int type,
}) => {
  'name': name,
  'author': '天蚕土豆',
  'bookUrl': bookUrl,
  'tocUrl': '',
  'origin': origin,
  'originName': originName,
  'origins': [origin],
  'type': type,
  'kind': null,
  'coverUrl': null,
  'intro': null,
  'wordCount': null,
  'latestChapterTitle': null,
  'chapterWordCount': 0,
  'variable': null,
};

Map<String, Object?> _source(String url, String name, int type) => {
  'sourceUrl': url,
  'sourceName': name,
  'group': '',
  'type': type,
  'enabled': true,
  'enabledExplore': true,
  'customOrder': 0,
  'weight': 0,
  'respondTimeMs': 1,
  'lastUpdateTime': 0,
  'hasLogin': false,
  'hasSearch': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(LegadoEngineClient.methodChannelName);
  const searchChannel = EventChannel(LegadoEngineClient.searchEventChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late LegadoBookRegistry registry;
  late LegadoNovelRepository repository;
  late LegadoSearchFeedController controller;
  late List<MethodCall> calls;
  MockStreamHandlerEventSink? sink;

  Map<String, Object?> bookInfoFor(String origin) => {
    'bookUrl': origin == _kalaOrigin ? _mangaBookUrl : _textBookUrl,
    'tocUrl': origin == _kalaOrigin ? _mangaBookUrl : _textBookUrl,
    'name': '斗破苍穹',
    'author': '天蚕土豆',
    'type': origin == _kalaOrigin ? 64 : 8,
    'origin': origin,
    'originName': origin == _kalaOrigin ? '卡拉漫画' : '文字源',
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls = <MethodCall>[];
    sink = null;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      switch (call.method) {
        case 'init':
          return {'ok': true, 'engineVersion': 't', 'sourceCount': 2};
        case 'listSources':
          return [
            _source(_txtOrigin, '文字源', 0),
            _source(_kalaOrigin, '卡拉漫画', 2),
          ];
        case 'getBookInfo':
          return bookInfoFor(args['origin'] as String);
        case 'getChapterList':
          final origin = args['origin'] as String;
          return {
            'book': bookInfoFor(origin),
            'chapters': [
              {
                'title': origin == _kalaOrigin ? '第1话' : '第一章',
                'url': origin == _kalaOrigin
                    ? 'https://www.kalamanhua.com/comic/32034/1.html'
                    : 'https://txt.example/book/doupo/1',
                'index': 0,
              },
              {
                'title': origin == _kalaOrigin ? '第2话' : '第二章',
                'url': origin == _kalaOrigin
                    ? 'https://www.kalamanhua.com/comic/32034/2.html'
                    : 'https://txt.example/book/doupo/2',
                'index': 1,
              },
            ],
          };
        case 'getChapterContent':
          if (args['origin'] == _kalaOrigin) {
            return {
              'content': '',
              'images': [
                'https://image.kalaimg.top/p/1.jpg',
                'https://image.kalaimg.top/p/2.jpg',
              ],
              'isImageChapter': true,
            };
          }
          return {
            'content': '第一章正文，斗气大陆。',
            'images': <String>[],
            'isImageChapter': false,
          };
      }
      return null;
    });
    messenger.setMockStreamHandler(
      searchChannel,
      MockStreamHandler.inline(
        onListen: (args, events) => sink = events,
        onCancel: (args) => sink = null,
      ),
    );
    final client = LegadoEngineClient(
      methodChannel: methodChannel,
      searchEventChannel: searchChannel,
    );
    registry = LegadoBookRegistry(preferences: SharedPreferences.getInstance());
    await registry.ready;
    repository = LegadoNovelRepository(client: client, registry: registry);
    controller = LegadoSearchFeedController(engineRepository: repository);
    addTearDown(controller.dispose);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(searchChannel, null);
  });

  Future<void> settle() async {
    await pumpEventQueue();
    await pumpEventQueue();
  }

  /// Runs one App search for 斗破 and returns the visible items after
  /// the native session's snapshot lands.
  Future<List<Novel>> searchDoupo() async {
    await controller.searchFor('斗破');
    await settle();
    final call = calls.singleWhere((c) => c.method == 'startSearch');
    final taskId = (call.arguments as Map)['taskId'] as int;
    sink!.success({
      'type': 'searchSnapshot',
      'taskId': taskId,
      'books': [
        _searchBook(
          origin: _txtOrigin,
          originName: '文字源',
          bookUrl: _textBookUrl,
          name: '斗破苍穹',
          type: 8,
        ),
        _searchBook(
          origin: _kalaOrigin,
          originName: '卡拉漫画',
          bookUrl: _mangaBookUrl,
          name: '斗破苍穹',
          type: 64,
        ),
        _searchBook(
          origin: _kalaOrigin,
          originName: '卡拉漫画',
          bookUrl: 'https://www.kalamanhua.com/comic/999.html',
          name: '苍穹榜之圣灵纪元',
          type: 64,
        ),
      ],
      'groups': [],
      'hasMore': false,
    });
    await settle();
    sink!.success({
      'type': 'searchFinish',
      'taskId': taskId,
      'isEmpty': false,
      'hasMore': false,
    });
    await settle();
    return controller.items;
  }

  MethodCall lastCall(String method) =>
      calls.lastWhere((c) => c.method == method);

  test('search surfaces novel and manga as separate entries', () async {
    final items = await searchDoupo();
    expect(items, hasLength(3));
    final titles = items.map((n) => n.title).toList();
    expect(titles.where((t) => t == '斗破苍穹'), hasLength(2));
    expect(titles, contains('苍穹榜之圣灵纪元'));
    // The manga entry's registry record must carry the image type bit
    // and the 卡拉 origin — the reader's image routing keys off both.
    final manga = items.firstWhere(
      (n) => registry.recordById(n.id)?.origin == _kalaOrigin &&
          n.title == '斗破苍穹',
    );
    expect(
      isLegadoImageBookType(registry.recordById(manga.id)!.type),
      isTrue,
    );
  });

  test('manga chain: detail → chapters → image chapter opens', () async {
    final items = await searchDoupo();
    final manga = items.firstWhere(
      (n) => registry.recordById(n.id)?.origin == _kalaOrigin &&
          n.title == '斗破苍穹',
    );

    final detail = await repository.detail(manga);
    expect(detail.id, manga.id);
    final infoArgs =
        (lastCall('getBookInfo').arguments as Map).cast<String, Object?>();
    expect(infoArgs['origin'], _kalaOrigin);
    expect(infoArgs['bookUrl'], _mangaBookUrl);

    final chapters = await repository.chapters(manga.id);
    expect(chapters, hasLength(2));
    expect(chapters.first.title, '第1话');

    final images = await repository.chapterImages(manga.id, chapters.first);
    expect(images, isNotNull);
    expect(images!.origin, _kalaOrigin);
    expect(images.urls, [
      'https://image.kalaimg.top/p/1.jpg',
      'https://image.kalaimg.top/p/2.jpg',
    ]);

    // The text path over the same chapter yields the image notice,
    // never an empty page.
    final text = await repository.chapterContent(manga.id, chapters.first);
    expect(text, legadoImageChapterNotice);
  });

  test('novel chain: detail → chapters → text chapter reads', () async {
    final items = await searchDoupo();
    final novel = items.firstWhere(
      (n) => registry.recordById(n.id)?.origin == _txtOrigin,
    );

    final detail = await repository.detail(novel);
    expect(detail.id, novel.id);

    final chapters = await repository.chapters(novel.id);
    expect(chapters, hasLength(2));
    expect(chapters.first.title, '第一章');

    final contentCallsBefore =
        calls.where((c) => c.method == 'getChapterContent').length;
    // A text book never enters the image path (no engine call spent).
    expect(await repository.chapterImages(novel.id, chapters.first), isNull);
    expect(
      calls.where((c) => c.method == 'getChapterContent').length,
      contentCallsBefore,
    );

    final text = await repository.chapterContent(novel.id, chapters.first);
    expect(text, '第一章正文，斗气大陆。');
    // Reading runs the engine's full post-processing, as in Legado.
    final contentArgs =
        (lastCall('getChapterContent').arguments as Map)
            .cast<String, Object?>();
    expect(contentArgs['applyReplace'], isTrue);
  });
}

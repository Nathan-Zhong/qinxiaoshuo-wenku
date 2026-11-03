import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/legado/legado_book_registry.dart';
import 'package:wenku8_flutter/legado/legado_engine_client.dart';
import 'package:wenku8_flutter/legado/legado_novel_repository.dart';
import 'package:wenku8_flutter/legado/legado_search_controller.dart';

Map<String, Object?> _book({
  required String origin,
  required String name,
  String author = '天蚕土豆',
  String bookUrl = 'https://x.example/b1',
  int type = 8,
}) => {
  'name': name,
  'author': author,
  'bookUrl': bookUrl,
  'tocUrl': '',
  'origin': origin,
  'originName': origin,
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

Map<String, Object?> _source(
  String url,
  String name,
  int type, {
  bool hasSearch = true,
}) => {
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
  'hasSearch': hasSearch,
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls = <MethodCall>[];
    sink = null;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'init':
          return {'ok': true, 'engineVersion': 't', 'sourceCount': 3};
        case 'listSources':
          return [
            _source('https://txt.example', '文字源', 0),
            _source('https://www.kalamanhua.com', '卡拉漫画', 2),
            // Enabled text source whose searchUrl is blank (e.g. an
            // explore-only or RSS-like entry in the book-source table):
            // it can never return search results, only a junk error.
            _source('https://rss.example', '无搜索源', 0, hasSearch: false),
          ];
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

  test('search scope excludes sources without search capability', () async {
    final eligible = await repository.eligibleSources();
    expect(
      eligible.map((s) => s.sourceUrl),
      ['https://txt.example', 'https://www.kalamanhua.com'],
    );
  });

  test('identical consecutive snapshots are processed only once', () async {
    var registryNotifications = 0;
    registry.addListener(() => registryNotifications++);
    await controller.searchFor('斗破');
    await settle();
    final call = calls.singleWhere((c) => c.method == 'startSearch');
    final taskId = (call.arguments as Map)['taskId'] as int;
    final scope = (call.arguments as Map)['scope'] as Map;
    expect(scope['sourceUrls'], [
      'https://txt.example',
      'https://www.kalamanhua.com',
    ]);

    Map<String, Object?> snapshot() => {
      'type': 'searchSnapshot',
      'taskId': taskId,
      'books': [
        _book(origin: 'https://txt.example', name: '斗破苍穹', type: 8),
        _book(
          origin: 'https://www.kalamanhua.com',
          name: '斗破苍穹',
          bookUrl: 'https://www.kalamanhua.com/comic/32034.html',
          type: 64,
        ),
      ],
      'groups': [],
      'hasMore': false,
    };

    sink!.success(snapshot());
    await settle();
    expect(controller.items, hasLength(2));
    final afterFirst = registryNotifications;
    expect(afterFirst, greaterThan(0));

    // The native session emits the same snapshot again (its success +
    // groups-changed callbacks fire back to back per page). Processing
    // it again must be a no-op: no re-merge, no registry churn.
    sink!.success(snapshot());
    await settle();
    expect(registryNotifications, afterFirst);
    expect(controller.items, hasLength(2));
  });
}

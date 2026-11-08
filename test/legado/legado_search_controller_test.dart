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
  String kind = '玄幻',
}) => {
  'name': name,
  'author': author,
  'bookUrl': bookUrl,
  'tocUrl': '',
  'origin': origin,
  'originName': origin,
  'origins': [origin],
  'type': 0,
  'kind': kind,
  'coverUrl': null,
  'intro': null,
  'wordCount': null,
  'latestChapterTitle': null,
  'chapterWordCount': 0,
  'variable': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(LegadoEngineClient.methodChannelName);
  const searchChannel = EventChannel(LegadoEngineClient.searchEventChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late LegadoSearchFeedController controller;
  late List<MethodCall> calls;
  MockStreamHandlerEventSink? sink;
  Object? Function(MethodCall call)? responder;
  var hintCount = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls = <MethodCall>[];
    sink = null;
    hintCount = 0;
    responder = (call) {
      switch (call.method) {
        case 'init':
          return {'ok': true, 'engineVersion': 't', 'sourceCount': 2};
        case 'listSources':
          return [
            {
              'sourceUrl': 'https://a.example',
              'sourceName': '源A',
              'group': '',
              'type': 0,
              'enabled': true,
              'enabledExplore': true,
              'customOrder': 0,
              'weight': 0,
              'respondTimeMs': 1,
              'lastUpdateTime': 0,
              'hasLogin': false,
            },
            {
              'sourceUrl': 'https://b.example',
              'sourceName': '源B',
              'group': '',
              'type': 0,
              'enabled': true,
              'enabledExplore': true,
              'customOrder': 0,
              'weight': 0,
              'respondTimeMs': 1,
              'lastUpdateTime': 0,
              'hasLogin': false,
            },
          ];
      }
      return null;
    };
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      return responder?.call(call);
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
    final registry = LegadoBookRegistry(
      preferences: SharedPreferences.getInstance(),
    );
    await registry.ready;
    final repository = LegadoNovelRepository(
      client: client,
      registry: registry,
    );
    controller = LegadoSearchFeedController(
      engineRepository: repository,
      onNoSourcesHint: () => hintCount++,
    );
    addTearDown(controller.dispose);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(searchChannel, null);
  });

  int taskIdOfSearch() {
    final call = calls.singleWhere((c) => c.method == 'startSearch');
    return (call.arguments as Map)['taskId'] as int;
  }

  Future<void> settle() async {
    await pumpEventQueue();
    await pumpEventQueue();
  }

  test('streaming snapshots are merged and published progressively', () async {
    final search = controller.searchFor('斗破');
    await settle();
    await search;
    expect(controller.loading, isTrue);
    final taskId = taskIdOfSearch();
    // The search fans out to both eligible sources at once.
    final scope =
        (calls.singleWhere((c) => c.method == 'startSearch').arguments
                as Map)['scope']
            as Map;
    expect(scope['sourceUrls'], ['https://a.example', 'https://b.example']);

    sink!.success({
      'type': 'searchSnapshot',
      'taskId': taskId,
      'books': [_book(origin: 'https://a.example', name: '斗破苍穹')],
      'groups': [],
      'hasMore': true,
    });
    await settle();
    expect(controller.items, hasLength(1));
    expect(controller.items.single.title, '斗破苍穹');
    expect(controller.loading, isTrue);

    // Same book from the second source merges into the same row.
    sink!.success({
      'type': 'searchSnapshot',
      'taskId': taskId,
      'books': [
        _book(origin: 'https://a.example', name: '斗破苍穹'),
        _book(origin: 'https://b.example', name: '斗破苍穹'),
        _book(
          origin: 'https://b.example',
          name: '武动乾坤',
          bookUrl: 'https://x.example/b2',
        ),
      ],
      'groups': [],
      'hasMore': false,
    });
    await settle();
    expect(controller.items, hasLength(2));
    expect(controller.items.map((n) => n.title), ['斗破苍穹', '武动乾坤']);

    sink!.success({
      'type': 'searchFinish',
      'taskId': taskId,
      'isEmpty': false,
      'hasMore': false,
    });
    await settle();
    expect(controller.loading, isFalse);
    expect(controller.page, 1);
    expect(controller.hasMore, isFalse);
    expect(controller.totalItems, 2);
  });

  test('blocked tags filter Legado results and report the count', () async {
    await controller.searchFor('斗破');
    await settle();
    final taskId = taskIdOfSearch();
    sink!.success({
      'type': 'searchSnapshot',
      'taskId': taskId,
      'books': [
        _book(origin: 'https://a.example', name: '斗破苍穹'),
        _book(
          origin: 'https://b.example',
          name: '都市传说',
          bookUrl: 'https://x.example/b2',
          kind: '都市',
        ),
      ],
      'groups': [],
      'hasMore': false,
    });
    await settle();
    expect(controller.items, hasLength(2));
    expect(controller.blockedItemCount, 0);
    expect(controller.hasBlockedTags, isFalse);

    // The 玄幻 row is hidden at once; the raw list is untouched, so
    // clearing the rule restores it without a new search.
    controller.setBlockedTags(['玄幻']);
    expect(controller.items, hasLength(1));
    expect(controller.items.single.title, '都市传说');
    expect(controller.blockedItemCount, 1);
    expect(controller.hasBlockedTags, isTrue);
    expect(controller.resultStartIndex, 0);

    controller.setBlockedTags([]);
    expect(controller.items, hasLength(2));
    expect(controller.blockedItemCount, 0);
  });

  test('a new search cancels the previous native task', () async {
    await controller.searchFor('第一');
    await settle();
    final firstTask = taskIdOfSearch();
    calls.clear();
    await controller.searchFor('第二');
    await settle();
    expect(
      calls
          .where((c) => c.method == 'cancelTask')
          .map((c) => (c.arguments as Map)['taskId']),
      contains(firstTask),
    );
    // Events of the cancelled task are filtered out by taskId.
    sink!.success({
      'type': 'searchSnapshot',
      'taskId': firstTask,
      'books': [_book(origin: 'https://a.example', name: '过期结果')],
      'groups': [],
      'hasMore': false,
    });
    await settle();
    expect(controller.items, isEmpty);
  });

  test('cancelScheduledSearch stops the in-flight search', () async {
    await controller.searchFor('斗破');
    await settle();
    final taskId = taskIdOfSearch();
    calls.clear();
    controller.cancelScheduledSearch();
    await settle();
    expect(controller.loading, isFalse);
    expect(
      calls
          .where((c) => c.method == 'cancelTask')
          .map((c) => (c.arguments as Map)['taskId']),
      contains(taskId),
    );
  });

  test('no eligible sources finishes empty and fires the hint once', () async {
    responder = (call) {
      if (call.method == 'init') {
        return {'ok': true, 'engineVersion': 't', 'sourceCount': 0};
      }
      if (call.method == 'listSources') return <Object?>[];
      return null;
    };
    await controller.searchFor('斗破');
    await settle();
    expect(controller.items, isEmpty);
    expect(controller.loading, isFalse);
    expect(controller.error, isNull);
    expect(hintCount, 1);
    await controller.searchFor('别的');
    await settle();
    expect(hintCount, 1);
    controller.resetHint();
    await controller.searchFor('再来');
    await settle();
    expect(hintCount, 2);
  });

  test('bridge searchError + empty finish surfaces as feed error', () async {
    await controller.searchFor('斗破');
    await settle();
    final taskId = taskIdOfSearch();
    sink!.success({
      'type': 'searchError',
      'taskId': taskId,
      'sourceUrl': 'https://a.example',
      'errorCode': 'IllegalStateException',
      'message': 'java.lang.IllegalStateException: boom',
    });
    await settle();
    // Recorded only; the round has not finished yet.
    expect(controller.error, isNull);
    expect(controller.loading, isTrue);
    sink!.success({
      'type': 'searchFinish',
      'taskId': taskId,
      'isEmpty': true,
      'hasMore': false,
    });
    await settle();
    expect(controller.loading, isFalse);
    expect(controller.items, isEmpty);
    expect(controller.error, isNotNull);
  });

  test('legadoSearchRoundErrorText maps the Cloudflare failure', () {
    const cfError = SearchErrorEvent(
      1,
      errorCode: 'IOException',
      message: 'java.io.IOException: Failed to bypass Cloudflare challenge',
    );
    expect(
      legadoSearchRoundErrorText(cfError),
      '该网站的人机验证（Cloudflare）未能自动通过，请稍后重试',
    );
    // Other raw messages pass through; an empty message falls back
    // to the coded form.
    const other = SearchErrorEvent(
      1,
      errorCode: 'IllegalStateException',
      message: 'java.lang.IllegalStateException: boom',
    );
    expect(legadoSearchRoundErrorText(other), other.message);
    const empty = SearchErrorEvent(1, errorCode: 'X', message: '');
    expect(legadoSearchRoundErrorText(empty), '书源搜索失败（X）');
  });

  test('Cloudflare searchError surfaces as the readable feed error', () async {
    await controller.searchFor('斗破');
    await settle();
    final taskId = taskIdOfSearch();
    sink!.success({
      'type': 'searchError',
      'taskId': taskId,
      'sourceUrl': 'https://www.xiguashuwu2.com',
      'errorCode': 'IOException',
      'message': 'java.io.IOException: Failed to bypass Cloudflare challenge',
    });
    await settle();
    sink!.success({
      'type': 'searchFinish',
      'taskId': taskId,
      'isEmpty': true,
      'hasMore': false,
    });
    await settle();
    expect(controller.items, isEmpty);
    final error = controller.error;
    expect(error, isA<FormatException>());
    expect(
      (error! as FormatException).message,
      '该网站的人机验证（Cloudflare）未能自动通过，请稍后重试',
    );
  });

  test('searchError with partial results keeps items, no error', () async {
    await controller.searchFor('斗破');
    await settle();
    final taskId = taskIdOfSearch();
    sink!.success({
      'type': 'searchSnapshot',
      'taskId': taskId,
      'books': [_book(origin: 'https://a.example', name: '斗破苍穹')],
      'groups': [],
      'hasMore': false,
    });
    await settle();
    sink!.success({
      'type': 'searchError',
      'taskId': taskId,
      'sourceUrl': 'https://b.example',
      'errorCode': 'NoStackTraceException',
      'message': 'boom',
    });
    sink!.success({
      'type': 'searchFinish',
      'taskId': taskId,
      'isEmpty': false,
      'hasMore': false,
    });
    await settle();
    expect(controller.items, hasLength(1));
    expect(controller.error, isNull);
    expect(controller.loading, isFalse);
  });

  test(
    'engine failure surfaces as the feed error and retry recovers',
    () async {
      var fail = true;
      responder = (call) {
        if (call.method == 'init' && fail) {
          throw PlatformException(code: 'X', message: 'boom');
        }
        if (call.method == 'init') {
          return {'ok': true, 'engineVersion': 't', 'sourceCount': 1};
        }
        if (call.method == 'listSources') {
          return [
            {
              'sourceUrl': 'https://a.example',
              'sourceName': '源A',
              'group': '',
              'type': 0,
              'enabled': true,
              'enabledExplore': true,
              'customOrder': 0,
              'weight': 0,
              'respondTimeMs': 1,
              'lastUpdateTime': 0,
              'hasLogin': false,
            },
          ];
        }
        return null;
      };
      await controller.searchFor('斗破');
      await settle();
      expect(controller.error, isNotNull);
      expect(controller.loading, isFalse);
      fail = false;
      await controller.retry();
      await settle();
      expect(controller.error, isNull);
      expect(controller.loading, isTrue);
      sink!.success({
        'type': 'searchFinish',
        'taskId': taskIdOfSearch(),
        'isEmpty': true,
        'hasMore': false,
      });
      await settle();
      expect(controller.loading, isFalse);
      expect(controller.items, isEmpty);
    },
  );
}

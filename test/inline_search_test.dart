import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

/// Legado engine bridge stand-in (B2: discovery and search are both
/// engine-fed). Discovery gets twenty explore books so the viewport
/// scrolls like a loaded list; search is driven by pushing stream
/// events for the recorded task ids, at the message level (see the
/// note in library_features_ui_test).
class _EngineMock {
  static const _methodChannel = MethodChannel('org.mewx.wenku8/legado_engine');
  static const _searchChannelName = 'org.mewx.wenku8/legado_search_events';
  static const _codec = StandardMethodCodec();

  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final searchTaskIds = <int>[];
  final searchKeywords = <String>[];
  bool _listening = false;

  static Map<String, Object?> bookJson(String name, String bookUrl) => {
    'name': name,
    'author': '佚名',
    'bookUrl': bookUrl,
    'tocUrl': '',
    'origin': 'https://src.example',
    'originName': '示例源',
    'origins': ['https://src.example'],
    'type': 0,
    'kind': '玄幻',
    'coverUrl': null,
    'intro': '简介',
    'wordCount': null,
    'latestChapterTitle': '第一章',
    'chapterWordCount': 0,
    'variable': null,
  };

  void install() {
    _messenger.setMockMethodCallHandler(_methodChannel, (call) async {
      switch (call.method) {
        case 'init':
          return {'ok': true, 'engineVersion': 'test', 'sourceCount': 1};
        case 'listSources':
          return [
            {
              'sourceUrl': 'https://src.example',
              'sourceName': '示例源',
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
        case 'getExploreKinds':
          return [
            {'title': '全部', 'url': 'kind/all', 'viewName': 'text', 'style': 3},
          ];
        case 'getExploreBooks':
          return {
            'books': [
              for (var i = 1; i <= 20; i++)
                bookJson('发现书 $i', 'https://src.example/e/$i'),
            ],
            'hasMore': false,
          };
        case 'startSearch':
          final args = (call.arguments as Map).cast<String, Object?>();
          searchTaskIds.add(args['taskId'] as int);
          searchKeywords.add(args['keyword'] as String);
          return null;
      }
      return null;
    });
    _messenger.setMockMessageHandler(_searchChannelName, (message) async {
      if (message == null) return null;
      final call = _codec.decodeMethodCall(message);
      if (call.method == 'listen') {
        _listening = true;
        return _codec.encodeSuccessEnvelope(null);
      }
      if (call.method == 'cancel') {
        _listening = false;
        return _codec.encodeSuccessEnvelope(null);
      }
      return null;
    });
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(_methodChannel, null);
    _messenger.setMockMessageHandler(_searchChannelName, null);
  }

  void pushSnapshot(
    int taskId,
    List<Map<String, Object?>> books, {
    required bool hasMore,
  }) {
    assert(_listening, 'search stream is not listening');
    _messenger.handlePlatformMessage(
      _searchChannelName,
      _codec.encodeSuccessEnvelope({
        'type': 'searchSnapshot',
        'taskId': taskId,
        'books': books,
        'groups': <Object?>[],
        'hasMore': hasMore,
      }),
      (_) {},
    );
  }

  void pushFinish(int taskId, {required bool isEmpty}) {
    _messenger.handlePlatformMessage(
      _searchChannelName,
      _codec.encodeSuccessEnvelope({
        'type': 'searchFinish',
        'taskId': taskId,
        'isEmpty': isEmpty,
        'hasMore': false,
      }),
      (_) {},
    );
  }

  void pushError(int taskId) {
    _messenger.handlePlatformMessage(
      _searchChannelName,
      _codec.encodeErrorEnvelope(code: 'NET', message: 'boom'),
      (_) {},
    );
  }
}

/// Serves detail/chapters for whichever book a search result hands
/// over (the test platform does not wrap repositories with the
/// engine dispatch, so the detail chain needs this stand-in).
class _DetailRepository extends NovelRepository {
  const _DetailRepository();

  @override
  Future<List<Novel>> list() async => const [];

  @override
  Future<Novel?> find(int id) async => null;

  @override
  Future<List<Novel>> search(String query) async => const [];

  @override
  Future<Novel> detail(Novel novel) async => novel;

  @override
  Future<List<NovelChapter>> chapters(int id) async => const [
    NovelChapter('第一章', '', id: 1),
    NovelChapter('第二章', '', id: 2),
  ];

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async =>
      '正文内容';
}

Future<LibraryState> _mount(
  WidgetTester tester, {
  NavigatorObserver? observer,
  NovelRepository repository = const DemoNovelRepository(),
  bool reduced = false,
  required _EngineMock engine,
}) async {
  SharedPreferences.setMockInitialValues({});
  engine.install();
  final state = await LibraryState.load();
  await state.setReduceMotion(reduced);
  await tester.pumpWidget(
    MaterialApp(
      theme: novelTheme(Brightness.light),
      scrollBehavior: const NovelScrollBehavior(),
      navigatorObservers: [?observer],
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: HomeShell(state: state, repository: repository),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Finder get _search => find.byWidgetPredicate(
  (widget) => widget is GlassIconButton && widget.label == '搜索',
);
Finder get _input => find.byKey(const ValueKey('expanded-search-input'));
Finder get _searchTap =>
    find.descendant(of: _search, matching: find.byType(InkWell)).first;

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(_searchTap);
  await tester.pumpAndSettle();
}

void main() {
  late _EngineMock engine;
  setUp(() {
    engine = _EngineMock();
  });
  tearDown(() {
    engine.uninstall();
  });

  testWidgets('search grows from its own control without pushing a route', (
    tester,
  ) async {
    final observer = _Routes();
    await _mount(tester, observer: observer, engine: engine);
    final home = tester.element(find.byType(HomeShell));
    final header = tester.element(find.byType(FrostedHeader));
    final origin = tester.getRect(_search);
    final route = ModalRoute.of(home);
    final pushes = observer.pushed.length;
    await tester.tap(_searchTap);
    await tester.pump();
    final bar = find.byKey(const ValueKey('expanded-search-bar'));
    expect(tester.getRect(bar), origin);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(bar).width, greaterThan(origin.width));
    final squish = tester.widget<Transform>(
      find.byKey(const ValueKey('search-jelly-transform')),
    );
    expect(squish.transform.entry(0, 0), isNot(1));
    expect(squish.transform.entry(1, 1), isNot(1));
    await tester.pumpAndSettle();
    expect(identical(tester.element(find.byType(HomeShell)), home), isTrue);
    expect(
      identical(tester.element(find.byType(FrostedHeader)), header),
      isTrue,
    );
    expect(ModalRoute.of(tester.element(_input)), same(route));
    expect(observer.pushed.length, pushes);
    expect(tester.widget<TextField>(_input).focusNode!.hasFocus, isTrue);
    final complete = tester.getRect(bar);
    expect(complete.left, 24);
    expect(complete.right, origin.right);
    expect(complete.height, 46);
    final settled = tester.widget<Transform>(
      find.byKey(const ValueKey('search-jelly-transform')),
    );
    expect(settled.transform, Matrix4.identity());
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing search restores the discovery viewport and control', (
    tester,
  ) async {
    await _mount(tester, engine: engine);
    final list = find.byKey(const PageStorageKey('discover'));
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    );
    final offset = scroll.position.pixels;
    expect(offset, greaterThan(0));
    final origin = tester.getRect(_search);
    await _expand(tester);
    await tester.tap(find.byKey(const ValueKey('inline-search-close')));
    await tester.pumpAndSettle();
    expect(_input, findsNothing);
    expect(scroll.position.pixels, closeTo(offset, .01));
    expect(tester.getRect(_search), origin);
    expect(find.byType(FrostedHeader), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back collapses search instead of leaving home', (
    tester,
  ) async {
    await _mount(tester, engine: engine);
    await _expand(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_input, findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(_search, findsOneWidget);
  });

  testWidgets('search results keep their cover flight and query on return', (
    tester,
  ) async {
    final observer = _Routes();
    await _mount(
      tester,
      observer: observer,
      repository: const _DetailRepository(),
      engine: engine,
    );
    await _expand(tester);
    const query = '月光航线';
    await tester.enterText(_input, query);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final taskId = engine.searchTaskIds.single;
    engine.pushSnapshot(taskId, [
      _EngineMock.bookJson(query, 'https://src.example/b/1'),
    ], hasMore: false);
    engine.pushFinish(taskId, isEmpty: false);
    await tester.pumpAndSettle();
    expect(find.text('找到 1 个结果'), findsOneWidget);
    final result = find.descendant(
      of: find.byType(InlineSearchResults),
      matching: find.text(query),
    );
    final bookId = tester
        .widget<InlineSearchResults>(find.byType(InlineSearchResults))
        .feed
        .items
        .single
        .id;
    final pushes = observer.pushed.length;
    await tester.tap(result.last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(ValueKey('cover-flight-$bookId')), findsOneWidget);
    expect(observer.pushed.length, pushes + 1);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(
      find
          .descendant(
            of: find.byWidgetPredicate(
              (widget) => widget is GlassIconButton && widget.label == '返回',
            ),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_input).controller!.text, query);
    expect(find.text('找到 1 个结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion expands and closes without a jelly transform', (
    tester,
  ) async {
    await _mount(tester, reduced: true, engine: engine);
    await tester.tap(_searchTap);
    await tester.pump();
    await tester.pump();
    final transform = tester.widget<Transform>(
      find.byKey(const ValueKey('search-jelly-transform')),
    );
    expect(transform.transform, Matrix4.identity());
    expect(
      tester.getSize(find.byKey(const ValueKey('expanded-search-bar'))).width,
      752,
    );
    await tester.tap(find.byKey(const ValueKey('inline-search-close')));
    await tester.pump();
    expect(_input, findsNothing);
    // Flush the registry's debounced persist timer (B2) so the test
    // does not end with it pending.
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets(
    'pending search uses matching skeletons and discards stale data',
    (tester) async {
      await _mount(tester, engine: engine);
      await tester.tap(_searchTap);
      await tester.pumpAndSettle();
      await tester.enterText(_input, 'first');
      await tester.pump();
      expect(find.byType(SearchSkeleton), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SearchSkeleton),
          matching: find.byType(BookCollectionSkeleton),
        ),
        findsOneWidget,
      );
      expect(find.byType(BookRowSkeleton), findsAtLeastNWidgets(6));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byType(SearchSkeleton), findsOneWidget);
      await tester.enterText(_input, 'second');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(engine.searchKeywords, ['first', 'second']);
      final firstTask = engine.searchTaskIds.first;
      final secondTask = engine.searchTaskIds.last;
      // A snapshot of the superseded search is discarded by task id.
      engine.pushSnapshot(firstTask, [
        _EngineMock.bookJson('过期结果', 'https://src.example/b/stale'),
      ], hasMore: false);
      await tester.pumpAndSettle();
      expect(find.byType(SearchSkeleton), findsOneWidget);
      expect(find.text('过期结果'), findsNothing);
      engine.pushFinish(secondTask, isEmpty: true);
      await tester.pumpAndSettle();
      expect(find.byType(SearchSkeleton), findsNothing);
      expect(find.text('没有找到相关故事'), findsOneWidget);
      engine.pushSnapshot(firstTask, [
        _EngineMock.bookJson('过期结果', 'https://src.example/b/stale'),
      ], hasMore: false);
      await tester.pump();
      expect(find.text('没有找到相关故事'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inline-search-close')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed search retries in place and removes the stale error', (
    tester,
  ) async {
    await _mount(tester, engine: engine);
    await tester.tap(_searchTap);
    await tester.pumpAndSettle();
    await tester.enterText(_input, '斗破');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final failedTask = engine.searchTaskIds.single;
    engine.pushError(failedTask);
    await tester.pumpAndSettle();
    expect(find.text('搜索失败，请稍后重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(find.byType(SearchSkeleton), findsOneWidget);
    expect(find.text('搜索失败，请稍后重试'), findsNothing);
    final retryTask = engine.searchTaskIds.last;
    expect(retryTask, isNot(failedTask));
    engine.pushSnapshot(retryTask, [
      _EngineMock.bookJson('斗破苍穹', 'https://src.example/b/dp1'),
      _EngineMock.bookJson('斗破外传', 'https://src.example/b/dp2'),
    ], hasMore: false);
    engine.pushFinish(retryTask, isEmpty: false);
    await tester.pumpAndSettle();
    expect(find.text('找到 2 个结果'), findsOneWidget);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(_input, findsOneWidget);
  });
}

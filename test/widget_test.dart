import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/main.dart';

void main() {
  testWidgets('发现页和空书架可以打开', (tester) async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
    });
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.text('小说文库'), findsOneWidget);
    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();
    expect(find.text('书架还空着'), findsOneWidget);
  });

  testWidgets('底部 Dock 可以拖拽吸附切换页面', (tester) async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
    });
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();

    final first = tester.getCenter(find.byKey(const ValueKey('dock-tab-0')));
    final middle = tester.getCenter(find.byKey(const ValueKey('dock-tab-1')));
    await tester.dragFrom(first, middle - first);
    await tester.pumpAndSettle();
    expect(find.text('书架还空着'), findsOneWidget);

    await tester.dragFrom(middle, first - middle);
    await tester.pumpAndSettle();
    expect(find.text('小说文库'), findsOneWidget);
  });

  testWidgets('Dock 胶囊来回形变保持紧凑，不被两端裁切', (tester) async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
    });
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();

    final dock = find.byKey(const ValueKey('liquid-dock'));
    final dockRect = tester.getRect(dock);
    expect(find.byType(DockSelectionLens), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('发现')),
    );
    await gesture.moveBy(const Offset(24, 0));
    await gesture.moveBy(const Offset(850, 0));
    await tester.pump();
    final stretched = tester.getRect(
      find.byKey(const ValueKey('dock-fluid-surface')),
    );
    expect(stretched.left, greaterThanOrEqualTo(dockRect.left - 12));
    expect(stretched.right, lessThanOrEqualTo(dockRect.right + 12));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面请求失败不会因页面重建而重复请求', (tester) async {
    const channel = MethodChannel('org.mewx.wenku8/legacy_api');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(LegacyCover.bytes(999991), throwsFormatException);
    await expectLater(LegacyCover.bytes(999991), throwsFormatException);
    expect(calls, 1);
  });

  testWidgets('外观选择弹层可弹出并切换黑白主题', (tester) async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
    });
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('my-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-reading-entry')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('settings-appearance')),
        matching: find.text('跟随系统'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('外观模式'), findsWidgets);
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(state.theme, ThemeMode.dark);
  });

  test('书架与章节进度持久化', () async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
    });
    final state = await LibraryState.load();
    await state.toggleShelf(1);
    await state.setChapter(1, 2);

    final reloaded = await LibraryState.load();
    expect(reloaded.contains(1), isTrue);
    expect(reloaded.chapterFor(1), 2);
  });

  test('原版正文空白行被整理为可读段落', () async {
    final repository = LegacyWenkuRepository(
      request: (_) async => '  第一行  \r\n \n   \r\n 第二行\r\n',
    );
    final text = await repository.chapterContent(
      4189,
      const NovelChapter('第一章', '', id: 1),
    );
    expect(text, '第一行\n\n第二行');
  });

  testWidgets('精选书籍可进入详情与阅读器', (tester) async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
    });
    // B2 接线后发现页由 Legado 引擎供数：用通道替身喂一个书源的发现
    // 书目，详情/阅读则由下面的测试仓库承接（测试平台不套分发仓库）。
    _mockExploreChannels(tester);
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const _ChainRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('发现精选').last);
    await tester.pumpAndSettle();
    expect(find.text('简介'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('detail-read-button')));
    await tester.pumpAndSettle();
    expect(find.text('第 1 章'), findsOneWidget);

    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    expect(find.text('阅读设置'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('阅读设置'), findsNothing);
  });
}

/// Serves detail/chapters/content for whichever book the discovery
/// tap hands over, standing in for the engine-backed chain.
class _ChainRepository extends NovelRepository {
  const _ChainRepository();

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
  Future<String> chapterContent(int id, NovelChapter chapter) async =>
      '这是正文的第一段。\n\n这是正文的第二段，内容足够排满一屏用于阅读器渲染。';
}

void _mockExploreChannels(WidgetTester tester) {
  const channel = MethodChannel('org.mewx.wenku8/legado_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
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
            {
              'name': '发现精选',
              'author': '佚名',
              'bookUrl': 'https://src.example/book/9',
              'tocUrl': '',
              'origin': 'https://src.example',
              'originName': '示例源',
              'origins': ['https://src.example'],
              'type': 0,
              'kind': '玄幻',
              'coverUrl': null,
              'intro': '一本来自书源发现页的书。',
              'wordCount': null,
              'latestChapterTitle': '第二章',
              'chapterWordCount': 0,
              'variable': null,
            },
          ],
          'hasMore': false,
        };
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

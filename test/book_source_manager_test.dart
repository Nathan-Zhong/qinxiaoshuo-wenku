import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/book_source_manager_page.dart';
import 'package:wenku8_flutter/legado/legado_engine_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(LegadoEngineClient.methodChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<Map<String, Object?>> store;
  late List<MethodCall> calls;

  Map<String, Object?> sourceA() => <String, Object?>{
    'sourceUrl': 'https://a.example',
    'sourceName': 'A源',
    'group': '分组甲',
    'type': 0,
    'enabled': true,
    'enabledExplore': false,
  };
  Map<String, Object?> sourceB() => <String, Object?>{
    'sourceUrl': 'https://m.example',
    'sourceName': '漫画源',
    'type': 2,
    'enabled': false,
    'enabledExplore': false,
  };

  setUp(() {
    store = [sourceA(), sourceB()];
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments is Map
          ? (call.arguments as Map).cast<String, Object?>()
          : const <String, Object?>{};
      switch (call.method) {
        case 'init':
          return <String, Object?>{
            'ok': true,
            'engineVersion': 'test',
            'sourceCount': store.length,
          };
        case 'listSources':
          return [for (final source in store) Map<String, Object?>.of(source)];
        case 'listSourceGroups':
          return <String>['分组甲'];
        case 'setSourceEnabled':
          for (final source in store) {
            if (source['sourceUrl'] == args['sourceUrl']) {
              source['enabled'] = args['enabled'];
            }
          }
          return null;
        case 'deleteSources':
          final urls = (args['sourceUrls'] as List).cast<String>();
          final before = store.length;
          store.removeWhere((source) => urls.contains(source['sourceUrl']));
          return <String, Object?>{'deleted': before - store.length};
        case 'importSources':
          final added = <String, Object?>{
            'sourceUrl': 'https://new.example',
            'sourceName': '新源',
            'type': 0,
            'enabled': true,
            'enabledExplore': false,
          };
          store.add(added);
          return <String, Object?>{
            'added': 1,
            'updated': 0,
            'unchanged': 0,
            'failed': 0,
            'sources': [added],
            'errors': <String>[],
          };
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: const BookSourceManagerPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  MethodCall callFor(String method) =>
      calls.singleWhere((call) => call.method == method);

  testWidgets('lists sources grouped with counts and type labels', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('2 个书源'), findsOneWidget);
    expect(find.text('分组甲'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('A源'), findsOneWidget);
    expect(find.text('漫画源'), findsOneWidget);
    expect(find.text('分组甲 · 小说 · a.example'), findsOneWidget);
    expect(find.text('漫画 · m.example'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('book-source-https://a.example')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggle calls setSourceEnabled for that source', (tester) async {
    await pumpPage(tester);
    await tester.tap(
      find.byKey(const ValueKey('book-source-enabled-https://a.example')),
    );
    await tester.pumpAndSettle();
    final args = (callFor('setSourceEnabled').arguments as Map)
        .cast<String, Object?>();
    expect(args['sourceUrl'], 'https://a.example');
    expect(args['enabled'], isFalse);
    expect(store.first['enabled'], isFalse);
  });

  testWidgets('single delete confirms first, then removes the row', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == '删除书源 A源',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除书源？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    final args = (callFor('deleteSources').arguments as Map)
        .cast<String, Object?>();
    expect(args['sourceUrls'], ['https://a.example']);
    expect(find.text('A源'), findsNothing);
    expect(find.text('漫画源'), findsOneWidget);
    expect(find.text('1 个书源'), findsOneWidget);
  });

  testWidgets('batch delete removes only the selected sources', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-select-mode')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('book-source-https://m.example')),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 个书源 · 已选 1 个'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book-source-delete-selected')));
    await tester.pumpAndSettle();
    expect(find.text('删除书源？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    final args = (callFor('deleteSources').arguments as Map)
        .cast<String, Object?>();
    expect(args['sourceUrls'], ['https://m.example']);
    expect(find.text('漫画源'), findsNothing);
    expect(find.text('A源'), findsOneWidget);
  });

  testWidgets('import by JSON text refreshes the list', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-import')));
    await tester.pumpAndSettle();
    expect(find.text('导入书源'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('book-source-import-json')),
      '{"bookSourceName":"新源"}',
    );
    await tester.tap(
      find.byKey(const ValueKey('book-source-import-json-submit')),
    );
    await tester.pumpAndSettle();
    final args = (callFor('importSources').arguments as Map)
        .cast<String, Object?>();
    expect(args['payloadKind'], 'text');
    expect(args['payload'], '{"bookSourceName":"新源"}');
    expect(find.text('新源'), findsOneWidget);
    expect(find.text('3 个书源'), findsOneWidget);
    expect(find.textContaining('导入完成'), findsOneWidget);
  });

  testWidgets('empty state invites an import when there are no sources', (
    tester,
  ) async {
    store = [];
    await pumpPage(tester);
    expect(find.text('0 个书源'), findsOneWidget);
    expect(find.textContaining('还没有导入书源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

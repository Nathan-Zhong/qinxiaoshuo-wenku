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
        case 'engineSelfCheck':
          return <String, Object?>{
            'sourceTotal': 2,
            'enabledCount': 1,
            'allSources': <String>[
              'A源 | enabled=true | enabledExplore=false | type=0 | '
                  'hasExplore=false | hasSearch=true',
              '漫画源 | enabled=false | enabledExplore=false | type=2 | '
                  'hasExplore=true | hasSearch=true',
            ],
            'perSourceSearch': <String>[
              '笔趣阁 | searchUrlResolved: https://byqg.example/search/'
                  '%E6%96%97%E7%A0%B4.html | webBookSearch: ok: 0 books',
            ],
          };
        case 'setSourceEnabled':
          for (final source in store) {
            if (source['sourceUrl'] == args['sourceUrl']) {
              source['enabled'] = args['enabled'];
            }
          }
          return null;
        case 'getLoginStates':
          return <String, Object?>{'https://login.example': true};
        case 'openSourceLogin':
          return <String, Object?>{'kind': 'web'};
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

  testWidgets('self check sheet lists every source from allSources', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('引擎自检'));
    await tester.pumpAndSettle();
    expect(callFor('engineSelfCheck').method, 'engineSelfCheck');
    expect(find.text('allSources'), findsOneWidget);
    // The generic sheet rendering joins the list with newlines; both
    // sources — including the disabled one no staged probe samples —
    // are visible with their switches and capabilities.
    expect(
      find.textContaining('A源 | enabled=true | enabledExplore=false'),
      findsOneWidget,
    );
    expect(
      find.textContaining('漫画源 | enabled=false | enabledExplore=false'),
      findsOneWidget,
    );
    expect(find.textContaining('type=2'), findsOneWidget);
    // The per-source deep probe renders through the same generic path.
    expect(find.text('perSourceSearch'), findsOneWidget);
    expect(
      find.textContaining('笔趣阁 | searchUrlResolved:'),
      findsOneWidget,
    );
    expect(find.textContaining('webBookSearch: ok: 0 books'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'import sheet URL field uses a plain text keyboard with URL autofill hint',
    (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('book-source-import')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('book-source-import-url')),
      );
      // Not TextInputType.url (seen to raise Xiaomi's secure keyboard on
      // HyperOS); the URL classification travels via autofillHints.
      expect(field.keyboardType, TextInputType.text);
      expect(field.autofillHints, const [AutofillHints.url]);
      expect(field.autocorrect, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'import sheet scrolls instead of overflowing with keyboard and error',
    (tester) async {
      tester.view.physicalSize = const Size(390, 460);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: const BookSourceManagerPage(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('book-source-import')));
      await tester.pumpAndSettle();
      // Focus the URL field (keyboard is up, per the viewInsets above),
      // then produce the error line that used to push the fixed Column
      // past the shrunken sheet height.
      await tester.tap(
        find.byKey(const ValueKey('book-source-import-url')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      // Submit the empty field via its own keyboard action (the submit
      // button sits below the scroll fold at this height): the sheet's
      // onSubmitted sets the same error line.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('请先填写书源网络地址'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty state invites an import when there are no sources', (
    tester,
  ) async {
    store = [];
    await pumpPage(tester);
    expect(find.text('0 个书源'), findsOneWidget);
    expect(find.textContaining('还没有导入书源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login source shows a login button and the logged-in marker', (
    tester,
  ) async {
    store = [
      <String, Object?>{
        'sourceUrl': 'https://login.example',
        'sourceName': '登录源',
        'type': 0,
        'enabled': true,
        'enabledExplore': false,
        'hasLogin': true,
      },
    ];
    await pumpPage(tester);
    // The states probe is only asked about login-capable sources.
    final statesArgs = (callFor('getLoginStates').arguments as Map)
        .cast<String, Object?>();
    expect(statesArgs['sourceUrls'], ['https://login.example']);
    // The marker rides the existing subtitle line, nothing new drawn.
    expect(find.text('已登录 · 小说 · login.example'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('book-source-login-https://login.example')),
      findsOneWidget,
    );
    // Tapping dispatches the login natively (web kind here).
    await tester.tap(
      find.byKey(const ValueKey('book-source-login-https://login.example')),
    );
    await tester.pumpAndSettle();
    final loginArgs = (callFor('openSourceLogin').arguments as Map)
        .cast<String, Object?>();
    expect(loginArgs['sourceUrl'], 'https://login.example');
    expect(find.textContaining('已打开登录页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain sources get no login button', (tester) async {
    await pumpPage(tester);
    expect(
      find.byKey(const ValueKey('book-source-login-https://a.example')),
      findsNothing,
    );
    expect(
      calls.where((call) => call.method == 'getLoginStates'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}

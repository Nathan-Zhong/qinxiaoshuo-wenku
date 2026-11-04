import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  late int converterType;
  MockStreamHandlerEventSink? taskEvents;
  int? lastCheckTaskId;

  /// When true, the mock check round reports every source ok
  /// (drives the no-failures variant of the check-sheet tests).
  late bool checkAllOk;

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
    converterType = 1;
    taskEvents = null;
    lastCheckTaskId = null;
    checkAllOk = false;
    messenger.setMockStreamHandler(
      const EventChannel('org.mewx.wenku8/legado_task_events'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          taskEvents = events;
        },
        onCancel: (arguments) {
          taskEvents = null;
        },
      ),
    );
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
        case 'getChineseConverterType':
          return <String, Object?>{'type': converterType};
        case 'setChineseConverterType':
          converterType = args['type'] as int;
          return null;
        case 'checkSources':
          lastCheckTaskId = args['taskId'] as int;
          // Emit from a fake-zone timer (platform-message dispatch
          // from the test body lands in the real queue and only
          // flushes at teardown). The check test advances fake time
          // in steps so the sheet is subscribed before this fires.
          Future<void>.delayed(const Duration(milliseconds: 50), () {
            final sink = taskEvents;
            if (sink == null) return;
            sink.success(<String, Object?>{
              'type': 'checkProgress',
              'taskId': lastCheckTaskId,
              'sourceUrl': 'https://a.example',
              'state': 'ok',
              'done': 1,
              'total': 2,
            });
            if (checkAllOk) {
              sink.success(<String, Object?>{
                'type': 'checkProgress',
                'taskId': lastCheckTaskId,
                'sourceUrl': 'https://m.example',
                'state': 'ok',
                'done': 2,
                'total': 2,
              });
            } else {
              sink.success(<String, Object?>{
                'type': 'checkProgress',
                'taskId': lastCheckTaskId,
                'sourceUrl': 'https://m.example',
                'state': 'fail',
                'message': '搜索失效',
                'done': 2,
                'total': 2,
              });
            }
            sink.success(<String, Object?>{
              'type': 'checkDone',
              'taskId': lastCheckTaskId,
              'okCount': checkAllOk ? 2 : 1,
              'failCount': checkAllOk ? 0 : 1,
            });
          });
          return <String, Object?>{'taskId': args['taskId']};
        case 'listSubscriptions':
          return <Map<String, Object?>>[
            <String, Object?>{
              'id': 7,
              'name': '测试订阅',
              'url': 'https://sub.example/list.json',
              'type': 0,
              'customOrder': 1,
              'autoUpdate': false,
              'lastUpdate': 0,
            },
          ];
        case 'upsertSubscription':
          return Map<String, Object?>.of(args)..['id'] = 8;
        case 'deleteSubscription':
          return <String, Object?>{'ok': true};
        case 'updateSubscription':
          return <String, Object?>{
            'added': 3,
            'updated': 0,
            'unchanged': 0,
            'failed': 0,
            'sources': <Object?>[],
            'errors': <String>[],
          };
        case 'updateAllSubscriptions':
          return <String, Object?>{'taskId': args['taskId']};
        case 'listReplaceRules':
          return <Map<String, Object?>>[
            <String, Object?>{
              'id': 3,
              'name': '去广告',
              'pattern': '广告',
              'replacement': '',
              'scope': '',
              'isRegex': false,
              'isEnabled': true,
              'order': 0,
            },
          ];
        case 'setReplaceRuleEnabled':
          return null;
        case 'deleteReplaceRule':
          return <String, Object?>{'ok': true};
        case 'getBookByUrl':
          return <String, Object?>{
            'origin': 'https://a.example',
            'book': <String, Object?>{
              'name': '链接之书',
              'author': '佚名',
              'bookUrl': 'https://a.example/book/1',
              'tocUrl': 'https://a.example/book/1/index',
              'origin': 'https://a.example',
              'originName': 'A源',
              'type': 0,
            },
          };
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(
      const EventChannel('org.mewx.wenku8/legado_task_events'),
      null,
    );
  });

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
    expect(find.textContaining('笔趣阁 | searchUrlResolved:'), findsOneWidget);
    expect(find.textContaining('webBookSearch: ok: 0 books'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'import sheet URL field uses a plain text keyboard, no autofill hint, '
    'suggestions enabled',
    (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('book-source-import')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('book-source-import-url')),
      );
      // Not TextInputType.url (seen to raise Xiaomi's secure keyboard on
      // HyperOS), and no AutofillHints.url (removed in fix1).
      expect(field.keyboardType, TextInputType.text);
      expect(field.autofillHints ?? const <String>[], isEmpty);
      expect(field.autocorrect, isFalse);
      // fix2 (2026-11-03): enableSuggestions must stay TRUE. With it
      // false, Flutter's TextInputPlugin adds
      // TYPE_TEXT_VARIATION_VISIBLE_PASSWORD to the EditorInfo.inputType
      // and HyperOS hands the field to Xiaomi's secure keyboard — that,
      // not the keyboard type or autofill hint, was the root cause of
      // the secure keyboard on every import field. Legado's import
      // dialog reports a bare text input type; this keeps ours equal.
      expect(field.enableSuggestions, isTrue);
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
    expect(calls.where((call) => call.method == 'getLoginStates'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('converter row shows the current mode and switching '
      'calls setChineseConverterType', (tester) async {
    await pumpPage(tester);
    // Mock engine starts at 1 （繁转简）.
    expect(find.text('当前：繁转简（仅书源书籍）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book-source-converter')));
    await tester.pumpAndSettle();
    expect(find.text('不转换'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book-source-converter-2')));
    await tester.pumpAndSettle();
    final args = (callFor('setChineseConverterType').arguments as Map)
        .cast<String, Object?>();
    expect(args['type'], 2);
    expect(converterType, 2);
    expect(find.text('当前：简转繁（仅书源书籍）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('check button streams per-source results into the sheet', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-check')));
    await tester.pumpAndSettle();
    expect(callFor('checkSources').method, 'checkSources');
    // The mock emits from a timer on the real event loop; give it
    // real time to fire and deliver, then rebuild.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.text('校验完成：可用 1 · 失效 1'), findsOneWidget);
    expect(find.text('可用'), findsOneWidget);
    expect(find.text('失效：搜索失效'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('subscriptions sheet lists subscriptions and updates one', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-subscriptions')));
    await tester.pumpAndSettle();
    expect(callFor('listSubscriptions').method, 'listSubscriptions');
    expect(find.text('测试订阅'), findsOneWidget);
    expect(find.text('https://sub.example/list.json'), findsOneWidget);
    await tester.tap(find.text('更新'));
    await tester.pumpAndSettle();
    final args = (callFor('updateSubscription').arguments as Map)
        .cast<String, Object?>();
    expect(args['id'], 7);
    expect(find.textContaining('更新完成'), findsOneWidget);
    expect(find.textContaining('新增 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replace rules sheet lists rules; toggle flips enabled', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-replace-rules')));
    await tester.pumpAndSettle();
    expect(callFor('listReplaceRules').method, 'listReplaceRules');
    expect(find.text('去广告'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('book-source-replace-enabled-3')),
    );
    await tester.pumpAndSettle();
    final args = (callFor('setReplaceRuleEnabled').arguments as Map)
        .cast<String, Object?>();
    expect(args['id'], 3);
    expect(args['enabled'], isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('find book by url registers the book and confirms', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-import')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('book-source-book-url')),
      'https://a.example/book/1',
    );
    await tester.tap(find.byKey(const ValueKey('book-source-book-url-submit')));
    await tester.pumpAndSettle();
    final args = (callFor('getBookByUrl').arguments as Map)
        .cast<String, Object?>();
    expect(args['url'], 'https://a.example/book/1');
    // No detail opener is injected in this harness, so the page falls
    // back to the confirmation message.
    expect(find.textContaining('已找到《链接之书》'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('select-all helpers', () {
    const urls = ['https://a.example', 'https://m.example'];

    test('all selected only when every url is in the selection', () {
      expect(bookSourcesAllSelected({}, urls), isFalse);
      expect(bookSourcesAllSelected({'https://a.example'}, urls), isFalse);
      expect(
        bookSourcesAllSelected(
          {'https://a.example', 'https://m.example'},
          urls,
        ),
        isTrue,
      );
      // Extra stale entries do not un-complete a full selection.
      expect(
        bookSourcesAllSelected(
          {'https://a.example', 'https://m.example', 'https://gone.example'},
          urls,
        ),
        isTrue,
      );
    });

    test('an empty source list is never all selected', () {
      expect(bookSourcesAllSelected({}, const []), isFalse);
      expect(bookSourcesToggleSelectAll({}, const []), isEmpty);
    });

    test('toggle from a partial selection completes it', () {
      expect(
        bookSourcesToggleSelectAll({'https://a.example'}, urls),
        {'https://a.example', 'https://m.example'},
      );
      expect(
        bookSourcesToggleSelectAll({}, urls),
        {'https://a.example', 'https://m.example'},
      );
    });

    test('toggle from a full selection clears it', () {
      expect(
        bookSourcesToggleSelectAll(
          {'https://a.example', 'https://m.example'},
          urls,
        ),
        isEmpty,
      );
    });
  });

  testWidgets('select-all button toggles the whole list', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-select-mode')));
    await tester.pumpAndSettle();
    expect(find.text('全选'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book-source-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('2 个书源 · 已选 2 个'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);
    expect(find.text('删除 2 个书源'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book-source-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('2 个书源 · 已选 0 个'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('select-all completes a partial selection', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-select-mode')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('book-source-https://a.example')),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 个书源 · 已选 1 个'), findsOneWidget);
    // A partial selection still offers 全选 (not 取消全选).
    expect(find.text('全选'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book-source-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('2 个书源 · 已选 2 个'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'check sheet hands failures back preselected for batch delete',
    (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('book-source-check')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      await tester.pump();
      expect(find.text('校验完成：可用 1 · 失效 1'), findsOneWidget);
      expect(find.text('选中失效书源（1 个）'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('book-source-check-select-failed')),
      );
      await tester.pumpAndSettle();
      // Sheet closed; the page is in batch mode with only the failed
      // source preselected. Nothing has been deleted yet.
      expect(calls.where((call) => call.method == 'deleteSources'), isEmpty);
      expect(find.text('2 个书源 · 已选 1 个'), findsOneWidget);
      expect(find.text('删除 1 个书源'), findsOneWidget);
      // Deletion still goes through the standard confirm dialog.
      await tester.tap(
        find.byKey(const ValueKey('book-source-delete-selected')),
      );
      await tester.pumpAndSettle();
      expect(find.text('删除书源？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      final args = (callFor('deleteSources').arguments as Map)
          .cast<String, Object?>();
      expect(args['sourceUrls'], ['https://m.example']);
      expect(find.text('漫画源'), findsNothing);
      expect(find.text('A源'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('check sheet hides the preselect entry when nothing '
      'failed', (tester) async {
    checkAllOk = true;
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-check')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.text('校验完成：可用 2 · 失效 0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('book-source-check-select-failed')),
      findsNothing,
    );
    expect(find.textContaining('选中失效书源'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

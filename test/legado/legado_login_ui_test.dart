import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';
import 'package:wenku8_flutter/legado/legado_engine_client.dart';
import 'package:wenku8_flutter/legado/legado_login_ui.dart';
import 'package:wenku8_flutter/legado/legado_verification_ui.dart';

/// P5.3 (G3): the login chain's Dart half — the bridge DTO/client
/// mapping for getLoginData & friends, and the Wenku login sheet's
/// fork-form semantics (prefill from saved info, gather on submit,
/// button/select/toggle actions carrying the current values, failure
/// keeps the sheet open).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(LegadoEngineClient.methodChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('client mapping', () {
    late LegadoEngineClient client;
    late List<MethodCall> calls;
    Object? Function(MethodCall call)? responder;

    setUp(() {
      calls = <MethodCall>[];
      responder = null;
      client = LegadoEngineClient();
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        return responder?.call(call);
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(methodChannel, null);
    });

    MethodCall callFor(String method) =>
        calls.singleWhere((c) => c.method == method);

    test('getLoginData maps every RowUi type, values and flags', () async {
      responder = (call) => <String, Object?>{
        'sourceUrl': 'https://src.example',
        'sourceName': '示例源',
        'kind': 'form',
        'loginUrl': null,
        'rows': <Object?>[
          <String, Object?>{
            'name': '账号',
            'type': 'text',
            'action': null,
            'chars': <String>[],
            'flexBasisPercent': 0.5,
          },
          <String, Object?>{
            'name': '密码',
            'type': 'password',
            'action': null,
            'chars': <String>[],
            'flexBasisPercent': 0.0,
          },
          <String, Object?>{
            'name': '🔑登录',
            'type': 'button',
            'action': 'login()',
            'chars': <String>[],
            'flexBasisPercent': 1.0,
          },
          <String, Object?>{
            'name': '线路',
            'type': 'select',
            'action': 'onLine()',
            'chars': <String>['一线', '二线'],
            'flexBasisPercent': 0.45,
          },
          <String, Object?>{
            'name': '记住我',
            'type': 'toggle',
            'action': null,
            'chars': <String>[],
            'flexBasisPercent': 0.0,
          },
          <String, Object?>{
            'name': '分组标题',
            'type': 'title',
            'action': null,
            'chars': <String>[],
            'flexBasisPercent': 0.0,
          },
        ],
        'values': <String, String>{
          '账号': 'reader01',
          '密码': 's3cret',
          '线路': '二线',
          '记住我': 'true',
        },
        'hasLoginInfo': true,
        'hasLoginHeader': false,
      };
      final data = await client.getLoginData('https://src.example');
      expect(
        callFor('getLoginData').arguments,
        {'sourceUrl': 'https://src.example'},
      );
      expect(data.kind, LegadoLoginKind.form);
      expect(data.rows, hasLength(6));
      expect(data.rows[0].type, 'text');
      expect(data.rows[0].flexBasisPercent, 0.5);
      expect(data.rows[1].type, 'password');
      expect(data.rows[2].action, 'login()');
      expect(data.rows[3].chars, ['一线', '二线']);
      expect(data.rows[4].type, 'toggle');
      expect(data.rows[5].type, 'title');
      expect(data.rows.where((r) => r.isInput), hasLength(4));
      expect(data.values['账号'], 'reader01');
      expect(data.values['线路'], '二线');
      expect(data.hasLoginInfo, isTrue);
      expect(data.hasLoginHeader, isFalse);
    });

    test('getLoginData maps web/js/none kinds', () async {
      for (final (wire, kind) in <(String, LegadoLoginKind)>[
        ('web', LegadoLoginKind.web),
        ('js', LegadoLoginKind.js),
        ('none', LegadoLoginKind.none),
      ]) {
        responder = (call) => <String, Object?>{
          'sourceUrl': 'https://src.example',
          'sourceName': '示例源',
          'kind': wire,
          'loginUrl': wire == 'web' ? 'https://src.example/login' : null,
          'rows': <Object?>[],
          'values': <String, String>{},
          'hasLoginInfo': false,
          'hasLoginHeader': false,
        };
        final data = await client.getLoginData('https://src.example');
        expect(data.kind, kind);
        expect(
          data.loginUrl,
          wire == 'web' ? 'https://src.example/login' : isNull,
        );
      }
    });

    test('loginSource forwards the data map verbatim (empty included)',
        () async {
      responder = (call) => <String, Object?>{'ok': true, 'removed': false};
      await client.loginSource('https://src.example', {
        '账号': 'reader01',
        '密码': 's3cret',
      });
      expect(
        calls.where((c) => c.method == 'login').single.arguments,
        {
          'sourceUrl': 'https://src.example',
          'data': {'账号': 'reader01', '密码': 's3cret'},
        },
      );
      // The empty map is meaningful (fork: remove saved login info);
      // the client must not swallow it.
      await client.loginSource('https://src.example', const {});
      expect(
        (calls.where((c) => c.method == 'login').last.arguments as Map)['data'],
        <String, String>{},
      );
    });

    test('runLoginAction forwards action and current data', () async {
      responder = (call) => <String, Object?>{'ok': true};
      await client.runLoginAction(
        'https://src.example',
        action: "getCode('email')",
        data: {'账号': 'a@b.c'},
      );
      expect(callFor('runLoginAction').arguments, {
        'sourceUrl': 'https://src.example',
        'action': "getCode('email')",
        'data': {'账号': 'a@b.c'},
      });
    });

    test('openSourceLogin maps the dispatched kind', () async {
      responder = (call) => <String, Object?>{'kind': 'web'};
      expect(
        await client.openSourceLogin('https://src.example'),
        LegadoLoginKind.web,
      );
      responder = (call) => <String, Object?>{'kind': 'form'};
      expect(
        await client.openSourceLogin('https://src.example'),
        LegadoLoginKind.form,
      );
    });

    test('getLoginStates maps flags for every requested url', () async {
      responder = (call) => <String, Object?>{
        'https://a.example': true,
        'https://b.example': false,
      };
      final states = await client.getLoginStates([
        'https://a.example',
        'https://b.example',
      ]);
      expect(states, {'https://a.example': true, 'https://b.example': false});
      expect(callFor('getLoginStates').arguments, {
        'sourceUrls': ['https://a.example', 'https://b.example'],
      });
    });

    test('getLoginHeader reads the header field, null when absent',
        () async {
      responder = (call) => <String, Object?>{'header': 'Cookie: a=b'};
      expect(
        await client.getLoginHeader('https://src.example'),
        'Cookie: a=b',
      );
      responder = (call) => <String, Object?>{'header': null};
      expect(await client.getLoginHeader('https://src.example'), isNull);
    });
  });

  group('login sheet', () {
    tearDown(() {
      LegadoLoginUi.resetForTest();
      LegadoVerificationUi.resetForTest();
    });

    Future<void> io(WidgetTester tester) async {
      for (var step = 0; step < 8; step++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
    }

    Future<FakeLoginClient> pumpHarness(
      WidgetTester tester, {
      required FakeLoginClient client,
    }) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          navigatorKey: LegadoUiHost.navigatorKey,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  key: const ValueKey('open-login'),
                  onPressed: () => unawaitedShowLogin(context, client),
                  child: const Text('打开登录'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return client;
    }

    testWidgets('renders all row types with prefilled values', (
      tester,
    ) async {
      final client = FakeLoginClient();
      await pumpHarness(tester, client: client);
      await tester.tap(find.byKey(const ValueKey('open-login')));
      await io(tester);
      expect(find.text('登录书源'), findsOneWidget);
      // Title row as heading text.
      expect(find.text('分组标题'), findsOneWidget);
      // Text input prefilled from saved info.
      final accountField = tester.widget<CupertinoTextField>(
        find.byKey(const ValueKey('source-login-field-账号')),
      );
      expect(accountField.controller?.text, 'reader01');
      // Password input prefilled and obscured.
      final passwordField = tester.widget<CupertinoTextField>(
        find.byKey(const ValueKey('source-login-field-密码')),
      );
      expect(passwordField.controller?.text, 's3cret');
      expect(passwordField.obscureText, isTrue);
      // Select shows its saved value; button row shows its name.
      expect(find.text('二线'), findsOneWidget);
      expect(find.text('🔑登录'), findsOneWidget);
      // Saved-info actions are offered.
      expect(find.text('退出登录'), findsOneWidget);
    });

    testWidgets('confirm submits the gathered form data and closes', (
      tester,
    ) async {
      final client = FakeLoginClient();
      await pumpHarness(tester, client: client);
      await tester.tap(find.byKey(const ValueKey('open-login')));
      await io(tester);
      await tester.enterText(
        find.byKey(const ValueKey('source-login-field-账号')),
        'newuser',
      );
      await tester.tap(find.byKey(const ValueKey('source-login-confirm')));
      await io(tester);
      expect(client.loginCalls, hasLength(1));
      expect(client.loginCalls.single.$1, 'https://src.example');
      // Buttons/titles never contribute; select/toggle carry values.
      expect(client.loginCalls.single.$2, {
        '账号': 'newuser',
        '密码': 's3cret',
        '线路': '二线',
        '记住我': 'true',
      });
      expect(find.text('登录书源'), findsNothing);
    });

    testWidgets('button row runs its action with the current data', (
      tester,
    ) async {
      final client = FakeLoginClient();
      await pumpHarness(tester, client: client);
      await tester.tap(find.byKey(const ValueKey('open-login')));
      await io(tester);
      await tester.enterText(
        find.byKey(const ValueKey('source-login-field-账号')),
        'typed',
      );
      await tester.tap(find.text('🔑登录'));
      await io(tester);
      expect(client.actionCalls, hasLength(1));
      expect(client.actionCalls.single.$2, 'login()');
      expect(client.actionCalls.single.$3['账号'], 'typed');
      // The sheet stays open after a button action (fork semantics).
      expect(find.text('登录书源'), findsOneWidget);
    });

    testWidgets('toggle change fires the row action with the new value', (
      tester,
    ) async {
      final client = FakeLoginClient();
      await pumpHarness(tester, client: client);
      await tester.tap(find.byKey(const ValueKey('open-login')));
      await io(tester);
      await tester.tap(
        find.byKey(const ValueKey('source-login-toggle-记住我')),
      );
      await io(tester);
      expect(client.actionCalls, hasLength(1));
      expect(client.actionCalls.single.$2, 'onRemember()');
      expect(client.actionCalls.single.$3['记住我'], 'false');
    });

    testWidgets('a failing login keeps the sheet open', (tester) async {
      final client = FakeLoginClient()
        ..loginError = PlatformException(
          code: 'UNKNOWN',
          message: '账号或密码错误',
        );
      await pumpHarness(tester, client: client);
      await tester.tap(find.byKey(const ValueKey('open-login')));
      await io(tester);
      await tester.tap(find.byKey(const ValueKey('source-login-confirm')));
      await io(tester);
      expect(client.loginCalls, hasLength(1));
      expect(find.text('登录书源'), findsOneWidget);
    });

    testWidgets('platform call showSourceLogin opens the same sheet', (
      tester,
    ) async {
      final client = FakeLoginClient();
      await pumpHarness(tester, client: client);
      LegadoVerificationUi.install(
        client: client,
        contextProvider: () => LegadoUiHost.navigatorKey.currentContext,
      );
      final ui = LegadoLoginUi.install(
        client: client,
        contextProvider: () => LegadoUiHost.navigatorKey.currentContext,
      );
      final result = ui.handlePlatformCall(
        const MethodCall('showSourceLogin', {
          'sourceKey': 'https://src.example',
          'sourceName': '示例源',
          'sourceType': 0,
          'origin': 'https://src.example',
        }),
      );
      await io(tester);
      expect(find.text('登录书源'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('source-login-cancel')));
      await io(tester);
      expect(await result, isNull);
      expect(find.text('登录书源'), findsNothing);
    });

    testWidgets('the combined handler still serves captcha calls', (
      tester,
    ) async {
      final client = FakeLoginClient();
      await pumpHarness(tester, client: client);
      LegadoVerificationUi.install(
        client: client,
        contextProvider: () => LegadoUiHost.navigatorKey.currentContext,
        imageFetcher: ({required origin, required url}) async => null,
      );
      final ui = LegadoLoginUi.install(
        client: client,
        contextProvider: () => LegadoUiHost.navigatorKey.currentContext,
      );
      await expectLater(
        ui.handlePlatformCall(const MethodCall('somethingElse')),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });
}

Future<void> unawaitedShowLogin(
  BuildContext context,
  FakeLoginClient client,
) async {
  await showSourceLoginSheet(
    context,
    client: client,
    sourceUrl: 'https://src.example',
    sourceName: '示例源',
  );
}

/// A bridge-free client: every login method is faked in memory, the
/// rest of the surface is never touched by the sheet.
class FakeLoginClient extends LegadoEngineClient {
  final List<(String, Map<String, String>)> loginCalls = [];
  final List<(String, String, Map<String, String>)> actionCalls = [];
  PlatformException? loginError;

  static const _data = LegadoLoginData(
    sourceUrl: 'https://src.example',
    sourceName: '示例源',
    kind: LegadoLoginKind.form,
    rows: <LegadoLoginRow>[
      LegadoLoginRow(name: '分组标题', type: 'title'),
      LegadoLoginRow(name: '账号', type: 'text'),
      LegadoLoginRow(name: '密码', type: 'password'),
      LegadoLoginRow(name: '🔑登录', type: 'button', action: 'login()'),
      LegadoLoginRow(
        name: '线路',
        type: 'select',
        action: 'onLine()',
        chars: <String>['一线', '二线'],
      ),
      LegadoLoginRow(name: '记住我', type: 'toggle', action: 'onRemember()'),
    ],
    values: <String, String>{
      '账号': 'reader01',
      '密码': 's3cret',
      '线路': '二线',
      '记住我': 'true',
    },
    hasLoginInfo: true,
    hasLoginHeader: false,
  );

  @override
  Future<LegadoEngineInfo> init({String? dataDir}) async =>
      const LegadoEngineInfo(ok: true, engineVersion: 'fake', sourceCount: 0);

  @override
  Future<LegadoLoginData> getLoginData(String sourceUrl) async => _data;

  @override
  Future<void> loginSource(String sourceUrl, Map<String, String> data) async {
    loginCalls.add((sourceUrl, Map<String, String>.of(data)));
    final error = loginError;
    if (error != null) throw error;
  }

  @override
  Future<void> runLoginAction(
    String sourceUrl, {
    required String action,
    Map<String, String> data = const <String, String>{},
  }) async {
    actionCalls.add((sourceUrl, action, Map<String, String>.of(data)));
  }
}

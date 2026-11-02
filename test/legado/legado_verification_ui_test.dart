import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/legado/legado_engine_client.dart';
import 'package:wenku8_flutter/legado/legado_verification_ui.dart';

/// P5.2 (G1): the engine's image-captcha request reaches Dart as a
/// platform call on the bridge channel; the Wenku jelly sheet collects
/// the code and the call result carries it back to the waiting engine
/// thread. Dismissal answers null (the native side fills an empty
/// verification result, fork checkResult semantics).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  tearDown(() {
    LegadoVerificationUi.resetForTest();
  });

  /// Real-async turn + frames, the repo's io() pattern (bookmark
  /// tests): a focused text field blinks its cursor forever, so
  /// pumpAndSettle alone can never settle while the sheet is open.
  Future<void> io(WidgetTester tester) async {
    for (var step = 0; step < 8; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
  }

  Future<LegadoVerificationUi> pumpHarness(
    WidgetTester tester, {
    required CaptchaImageFetcher fetcher,
    LegadoEngineClient? client,
  }) async {
    // A phone-shaped viewport: at the default 800x600 the sheet's
    // button row falls below the fold and taps miss.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late LegadoVerificationUi ui;
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        navigatorKey: LegadoUiHost.navigatorKey,
        // Mirror NovelApp's builder: the sheet reads disableAnimations
        // from the calling (navigator) context.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();
    ui = LegadoVerificationUi.install(
      client: client ?? LegadoEngineClient(),
      contextProvider: () => LegadoUiHost.navigatorKey.currentContext,
      imageFetcher: fetcher,
    );
    return ui;
  }

  const captchaCall = MethodCall('showVerificationCode', {
    'sourceKey': 'https://src.example',
    'sourceName': '示例源',
    'sourceType': 0,
    'origin': 'https://src.example',
    'url': 'https://src.example/captcha.png?t=1',
  });

  testWidgets('sheet shows the captcha and returns the entered code', (
    tester,
  ) async {
    var fetchCount = 0;
    final ui = await pumpHarness(
      tester,
      fetcher: ({required origin, required url}) async {
        fetchCount++;
        return pngBytes;
      },
    );
    final result = ui.handlePlatformCall(captchaCall);
    await io(tester);
    expect(find.text('输入验证码'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('verification-code-image')),
      findsOneWidget,
    );
    expect(fetchCount, 1);
    await tester.enterText(
      find.byKey(const ValueKey('verification-code-field')),
      '4832',
    );
    await tester.tap(find.byKey(const ValueKey('verification-code-confirm')));
    await io(tester);
    expect(await result, '4832');
  });

  testWidgets('dismissing the sheet answers null', (tester) async {
    final ui = await pumpHarness(
      tester,
      fetcher: ({required origin, required url}) async => pngBytes,
    );
    final result = ui.handlePlatformCall(captchaCall);
    await io(tester);
    await tester.tap(find.byKey(const ValueKey('verification-code-cancel')));
    await io(tester);
    expect(await result, isNull);
  });

  testWidgets('a failed captcha fetch shows a retry that can recover', (
    tester,
  ) async {
    var attempts = 0;
    final ui = await pumpHarness(
      tester,
      fetcher: ({required origin, required url}) async {
        attempts++;
        return attempts == 1 ? null : pngBytes;
      },
    );
    final result = ui.handlePlatformCall(captchaCall);
    await io(tester);
    expect(find.textContaining('验证码图片加载失败'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('verification-code-image')));
    await io(tester);
    expect(attempts, 2);
    expect(find.textContaining('验证码图片加载失败'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('verification-code-cancel')));
    await io(tester);
    expect(await result, isNull);
  });

  test('no UI context is a platform error, never a hang', () async {
    final ui = LegadoVerificationUi.install(
      client: LegadoEngineClient(),
      contextProvider: () => null,
      imageFetcher: ({required origin, required url}) async => null,
    );
    await expectLater(
      ui.handlePlatformCall(captchaCall),
      throwsA(isA<PlatformException>()),
    );
  });

  test('unknown methods are notImplemented; an empty url answers null', () async {
    final ui = LegadoVerificationUi.install(
      client: LegadoEngineClient(),
      contextProvider: () => null,
      imageFetcher: ({required origin, required url}) async => null,
    );
    await expectLater(
      ui.handlePlatformCall(const MethodCall('somethingElse')),
      throwsA(isA<MissingPluginException>()),
    );
    expect(
      await ui.handlePlatformCall(
        const MethodCall('showVerificationCode', {'url': ''}),
      ),
      isNull,
    );
  });

  test('the client forwards platform messages to the installed handler', () async {
    final client = LegadoEngineClient();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();
    MethodCall? seen;
    client.setPlatformCallHandler((call) async {
      seen = call;
      return 'pong:${call.method}';
    });
    ByteData? reply;
    await messenger.handlePlatformMessage(
      LegadoEngineClient.methodChannelName,
      codec.encodeMethodCall(
        const MethodCall('showVerificationCode', {'a': 1}),
      ),
      (data) => reply = data,
    );
    expect(seen?.method, 'showVerificationCode');
    expect(codec.decodeEnvelope(reply!), 'pong:showVerificationCode');
    client.setPlatformCallHandler(null);
  });
}

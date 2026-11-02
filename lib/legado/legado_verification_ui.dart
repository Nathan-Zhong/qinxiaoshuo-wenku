import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_ui.dart';
import 'legado_engine_client.dart';

/// Host for the app-root navigator key: engine verification flows are
/// driven from Kotlin (a source's JS asked for a captcha while some
/// unrelated page was open), so the captcha sheet must be presentable
/// from above the whole navigation stack. Pure plumbing — the key
/// changes nothing about what any page looks like.
abstract final class LegadoUiHost {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
}

/// Fetches one captcha image's bytes, uncached: captcha URLs are
/// single-use (the same URL returns a different image every time), so
/// this deliberately bypasses every image cache — the fork loads its
/// captcha with `useBitmapCache=false` for the same reason.
typedef CaptchaImageFetcher =
    Future<Uint8List?> Function({required String origin, required String url});

/// Dart end of the engine's image-captcha request (G1, P5.2).
///
/// The Kotlin VerificationUiProvider calls `showVerificationCode` on
/// the bridge MethodChannel while an engine JS thread parks waiting
/// for the result; this handler renders the Wenku jelly sheet
/// (ArchiveSection header + captcha image + one-line field + glass
/// buttons, the bookmark-note sheet's exact construction) and answers
/// with the entered code, or null when the user dismisses — the
/// native side translates both into the engine's
/// setResult/notifyResultArrived protocol.
///
/// The browser half of verification (G2) never reaches Dart: it is a
/// native Activity, per the fork's own split.
class LegadoVerificationUi {
  LegadoVerificationUi._({
    required this.client,
    required this.contextProvider,
    required this.imageFetcher,
  });

  final LegadoEngineClient client;
  final BuildContext? Function() contextProvider;
  final CaptchaImageFetcher imageFetcher;

  static LegadoVerificationUi? _installed;

  /// Installs the platform-call handler on the shared engine client.
  /// Idempotent per client; production installs once from main().
  static LegadoVerificationUi install({
    required LegadoEngineClient client,
    required BuildContext? Function() contextProvider,
    CaptchaImageFetcher? imageFetcher,
  }) {
    final existing = _installed;
    if (existing != null && identical(existing.client, client)) {
      return existing;
    }
    final ui = LegadoVerificationUi._(
      client: client,
      contextProvider: contextProvider,
      imageFetcher: imageFetcher ?? _defaultImageFetcher(client),
    );
    client.setPlatformCallHandler(ui.handlePlatformCall);
    _installed = ui;
    return ui;
  }

  /// Test hook: forget the installed instance (handler detach is the
  /// caller's job via [LegadoEngineClient.setPlatformCallHandler]).
  static void resetForTest() => _installed = null;

  Future<Object?> handlePlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'showVerificationCode':
        final args = call.arguments;
        final map = args is Map ? args.cast<Object?, Object?>() : const {};
        final url = map['url']?.toString() ?? '';
        final origin = map['origin']?.toString() ?? '';
        final sourceName = map['sourceName']?.toString() ?? '';
        if (url.isEmpty) return null;
        final context = contextProvider();
        if (context == null || !context.mounted) {
          throw PlatformException(
            code: 'NO_CONTEXT',
            message: 'No UI context available for the captcha sheet',
          );
        }
        return showVerificationCodeSheet(
          context,
          url: url,
          origin: origin,
          sourceName: sourceName,
          imageFetcher: imageFetcher,
        );
      default:
        throw MissingPluginException(
          'No verification UI handler for ${call.method}',
        );
    }
  }

  /// Default fetcher: resolve through the engine first (G7 — source
  /// headers / cookies applied by AnalyzeUrl), then a bare HttpClient
  /// GET of the resolved target. Any failure returns null and the
  /// sheet shows its retry state instead of hanging.
  static CaptchaImageFetcher _defaultImageFetcher(LegadoEngineClient client) {
    return ({required String origin, required String url}) async {
      var fetchUrl = url;
      var headers = const <String, String>{};
      if (origin.isNotEmpty) {
        try {
          final resolved = await client.resolveImageRequest(
            origin: origin,
            url: url,
          );
          if (resolved.url.isNotEmpty) fetchUrl = resolved.url;
          headers = resolved.headers;
        } catch (_) {
          // Resolution is best-effort; the bare URL may still work.
        }
      }
      return _fetchBytes(fetchUrl, headers);
    };
  }

  static Future<Uint8List?> _fetchBytes(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      headers.forEach((name, value) {
        if (value.isEmpty) return;
        try {
          request.headers.set(name, value);
        } catch (_) {
          // A header name the platform stack refuses must not fail
          // the whole fetch (same stance as the cover loader).
        }
      });
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(
        const Duration(seconds: 10),
      )) {
        builder.add(chunk);
        if (builder.length > 4 * 1024 * 1024) return null;
      }
      final bytes = builder.takeBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    } finally {
      httpClient.close();
    }
  }
}

/// Shows the captcha sheet and resolves with the entered code, or
/// null on dismissal. Built exactly like the bookmark-note sheet:
/// jelly sheet, [ArchiveSection] header, Cupertino field, glass
/// buttons.
Future<String?> showVerificationCodeSheet(
  BuildContext context, {
  required String url,
  required String origin,
  required String sourceName,
  required CaptchaImageFetcher imageFetcher,
}) => showJellySheet<String>(
  context: context,
  heightFactor: .58,
  builder: (sheet) => _VerificationCodeSheet(
    sheet: sheet,
    url: url,
    origin: origin,
    sourceName: sourceName,
    imageFetcher: imageFetcher,
  ),
);

class _VerificationCodeSheet extends StatefulWidget {
  const _VerificationCodeSheet({
    required this.sheet,
    required this.url,
    required this.origin,
    required this.sourceName,
    required this.imageFetcher,
  });

  final BuildContext sheet;
  final String url;
  final String origin;
  final String sourceName;
  final CaptchaImageFetcher imageFetcher;

  @override
  State<_VerificationCodeSheet> createState() => _VerificationCodeSheetState();
}

enum _CaptchaImageState { loading, ready, error }

class _VerificationCodeSheetState extends State<_VerificationCodeSheet> {
  final text = TextEditingController();
  _CaptchaImageState imageState = _CaptchaImageState.loading;
  Uint8List? imageBytes;
  int loadTicket = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadImage());
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    final ticket = ++loadTicket;
    setState(() => imageState = _CaptchaImageState.loading);
    final bytes = await widget.imageFetcher(
      origin: widget.origin,
      url: widget.url,
    );
    if (!mounted || ticket != loadTicket) return;
    setState(() {
      imageBytes = bytes;
      imageState = bytes == null
          ? _CaptchaImageState.error
          : _CaptchaImageState.ready;
    });
  }

  /// Fork parity: tapping the captcha opens it full-screen (the
  /// fork's PhotoDialog); tapping the error state retries the fetch.
  void _onImageTap() {
    switch (imageState) {
      case _CaptchaImageState.ready:
        final bytes = imageBytes;
        if (bytes != null) {
          unawaited(
            showDialog<void>(
              context: context,
              builder: (dialogContext) => GestureDetector(
                onTap: () => Navigator.pop(dialogContext),
                child: ColoredBox(
                  color: Colors.black87,
                  child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
                ),
              ),
            ),
          );
        }
      case _CaptchaImageState.error:
        unawaited(_loadImage());
      case _CaptchaImageState.loading:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ArchiveSection(
          title: '输入验证码',
          code: 'SOURCE / VERIFY',
          subtitle: widget.sourceName,
        ),
        const SizedBox(height: 20),
        GestureDetector(
          key: const ValueKey('verification-code-image'),
          onTap: _onImageTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 84, maxHeight: 168),
            child: switch (imageState) {
              _CaptchaImageState.loading => const Center(
                child: CupertinoActivityIndicator(),
              ),
              _CaptchaImageState.ready => Center(
                child: Image.memory(imageBytes!, fit: BoxFit.contain),
              ),
              _CaptchaImageState.error => Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '验证码图片加载失败，点这里重试\n${widget.url}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            },
          ),
        ),
        const SizedBox(height: 18),
        CupertinoTextField(
          key: const ValueKey('verification-code-field'),
          controller: text,
          placeholder: appText(context, '输入图中验证码'),
          maxLines: 1,
          padding: const EdgeInsets.all(16),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            GlassTextButton(
              key: const ValueKey('verification-code-cancel'),
              onPressed: () => Navigator.pop(widget.sheet),
              child: const AppText('取消'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GlassPillButton(
                key: const ValueKey('verification-code-confirm'),
                icon: CupertinoIcons.checkmark,
                label: '确定',
                onPressed: () => Navigator.pop(widget.sheet, text.text),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Cover bytes fetched directly from a book source's own cover URL
/// (Legado books carry an absolute http/https `coverUrl`). This is the
/// URL-keyed twin of LegacyCoverCache: same bounded memory, same
/// failure-retry window, same peek/load/seed shape, and the request
/// function is injected so tests never touch the network.
///
/// Wenku books never come here — they keep the native LegacyCover
/// channel. Callers whose fetch fails fall back to the generated text
/// cover.
///
/// Since P5.1 (G7) a load may carry headers and a resolved fetch URL
/// produced by the engine's AnalyzeUrl resolution (the source's
/// Referer / User-Agent / per-image `,{...}` suffix rules applied
/// natively). Bytes are always cached under the cover's own URL —
/// the identity every caller peeks by — while a headered load uses a
/// separate internal failure/pending key, so a failed resolved
/// attempt never poisons the bare-URL retry window the caller falls
/// back to.
abstract final class UrlCover {
  static final _cache = UrlCoverCache(
    request: (url, headers) =>
        (debugRequestOverride ?? _fetchCoverBytes)(url, headers),
  );

  /// Tests replace the real HTTP fetch through here so no test ever
  /// touches the network; production code never sets this.
  @visibleForTesting
  static Future<Uint8List?> Function(String url, Map<String, String> headers)?
  debugRequestOverride;

  static Uint8List? peek(String url) => _cache.peek(url);

  /// Loads the cover at [url]; [fetchUrl] (defaults to [url]) is the
  /// URL actually requested and [headers] are sent with it.
  static Future<Uint8List> load(
    String url, {
    Map<String, String> headers = const {},
    String? fetchUrl,
  }) => _cache.load(url, headers: headers, fetchUrl: fetchUrl);

  /// Test/seeding hook, mirroring LegacyCover.seedLocalBytes: an explicit
  /// seed wins over any in-flight request for the same URL.
  static void seed(String url, Uint8List bytes) => _cache.seed(url, bytes);
}

/// Browser-style GET for a cover image with tight timeouts and a
/// hard size cap, so a hostile or dead image host can never hang or
/// bloat cover loading. [headers] are the G7-resolved source headers
/// (Referer is the anti-hotlink key); a User-Agent among them wins
/// over the built-in default.
Future<Uint8List?> _fetchCoverBytes(
  String url,
  Map<String, String> headers,
) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const FormatException('封面地址无效');
  }
  var userAgent =
      'Mozilla/5.0 (Linux; Android 14; Xiaomi 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'user-agent' && entry.value.isNotEmpty) {
      userAgent = entry.value;
    }
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..userAgent = userAgent;
  try {
    final request = await client.getUrl(uri).timeout(
      const Duration(seconds: 10),
    );
    headers.forEach((name, value) {
      if (value.isEmpty || name.toLowerCase() == 'user-agent') return;
      try {
        request.headers.set(name, value);
      } catch (_) {
        // A header name the platform stack refuses must not fail the
        // whole fetch.
      }
    });
    final response = await request.close().timeout(
      const Duration(seconds: 10),
    );
    if (response.statusCode != HttpStatus.ok) {
      throw FormatException('封面请求失败 (${response.statusCode})');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(
      const Duration(seconds: 10),
    )) {
      builder.add(chunk);
      if (builder.length > 8 * 1024 * 1024) {
        throw const FormatException('封面过大');
      }
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

class UrlCoverCache {
  UrlCoverCache({
    required this.request,
    this.maxBytes = 16 * 1024 * 1024,
    this.maxEntries = 256,
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       assert(maxBytes > 0 && maxEntries > 0);
  final Future<Uint8List?> Function(String url, Map<String, String> headers)
  request;
  final int maxBytes, maxEntries;
  final Duration retryDelay;
  final DateTime Function() now;
  final _entries = <String, _UrlCoverEntry>{};
  final _pending = <String, Future<Uint8List>>{};
  final _failures = <String, (DateTime, Future<Uint8List>)>{};
  int _encodedBytes = 0;
  int get encodedBytes => _encodedBytes;
  int get cachedEntries => _entries.length;
  int get pendingRequests => _pending.length;
  int get cachedFailures => _failures.length;

  _UrlCoverEntry? _touch(String url) {
    final entry = _entries.remove(url);
    if (entry != null) _entries[url] = entry;
    return entry;
  }

  Uint8List? peek(String url) => _touch(url)?.bytes;

  void seed(String url, Uint8List bytes) {
    if (url.isEmpty || bytes.isEmpty) {
      throw ArgumentError('Invalid URL cover');
    }
    final local = Uint8List.fromList(bytes).asUnmodifiableView();
    // A delayed older network response must not overwrite an explicit seed.
    _pending.remove(url);
    _failures.remove(url);
    _store(url, _UrlCoverEntry(local, Future.value(local)));
  }

  void _store(String url, _UrlCoverEntry entry) {
    final previous = _entries.remove(url);
    if (previous != null) _encodedBytes -= previous.bytes.length;
    if (entry.bytes.length > maxBytes) return;
    _entries[url] = entry;
    _encodedBytes += entry.bytes.length;
    while (_encodedBytes > maxBytes || _entries.length > maxEntries) {
      final removed = _entries.remove(_entries.keys.first)!;
      _encodedBytes -= removed.bytes.length;
    }
  }

  /// Loads the cover bytes for [url]. [fetchUrl] (defaults to [url])
  /// is what the request function actually fetches and [headers] go
  /// out with it; bytes are stored under [url] either way. A headered
  /// load's failure window and in-flight slot live under a header-
  /// signature key, separate from the bare load of the same URL.
  Future<Uint8List> load(
    String url, {
    Map<String, String> headers = const {},
    String? fetchUrl,
  }) {
    if (url.isEmpty) return Future.error(ArgumentError('Invalid cover URL'));
    final entry = _touch(url);
    if (entry != null) return entry.future;
    final key = _cacheKey(url, headers);
    final failure = _failures[key];
    if (failure != null && now().isBefore(failure.$1)) return failure.$2;
    _failures.remove(key);
    final pending = _pending[key];
    if (pending != null) return pending;
    final completer = Completer<Uint8List>();
    final future = completer.future;
    _pending[key] = future;
    unawaited(() async {
      try {
        final image = await request(fetchUrl ?? url, headers);
        if (image == null || image.isEmpty) throw const FormatException('封面为空');
        final bytes = image.asUnmodifiableView();
        if (identical(_pending[key], future)) {
          _store(url, _UrlCoverEntry(bytes, future));
        }
        completer.complete(bytes);
      } catch (error, stack) {
        if (identical(_pending[key], future)) {
          _failures[key] = (now().add(retryDelay), future);
          // Failed URLs must not grow forever while browsing offline either.
          while (_failures.length > maxEntries) {
            _failures.remove(_failures.keys.first);
          }
        }
        completer.completeError(error, stack);
      } finally {
        if (identical(_pending[key], future)) _pending.remove(key);
      }
    }());
    return future;
  }

  /// Bare loads key by the URL alone (the pre-G7 behaviour, bit for
  /// bit); a headered load keys by URL + sorted header signature.
  String _cacheKey(String url, Map<String, String> headers) {
    if (headers.isEmpty) return url;
    final names = headers.keys.toList()..sort();
    final signature = names
        .map((name) => '$name\x00${headers[name]}')
        .join('\x00');
    return '$url\x00$signature';
  }
}

class _UrlCoverEntry {
  const _UrlCoverEntry(this.bytes, this.future);
  final Uint8List bytes;
  final Future<Uint8List> future;
}

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
/// channel. Sources that need special headers / anti-hotlink handling
/// may still fail; callers fall back to the generated text cover then.
abstract final class UrlCover {
  static final _cache = UrlCoverCache(
    request: (url) => (debugRequestOverride ?? _fetchCoverBytes)(url),
  );

  /// Tests replace the real HTTP fetch through here so no test ever
  /// touches the network; production code never sets this.
  @visibleForTesting
  static Future<Uint8List?> Function(String url)? debugRequestOverride;

  static Uint8List? peek(String url) => _cache.peek(url);
  static Future<Uint8List> load(String url) => _cache.load(url);

  /// Test/seeding hook, mirroring LegacyCover.seedLocalBytes: an explicit
  /// seed wins over any in-flight request for the same URL.
  static void seed(String url, Uint8List bytes) => _cache.seed(url, bytes);
}

/// Plain browser-style GET for a cover image: no cookies, no Referer —
/// just a browser UA, tight timeouts and a hard size cap, so a hostile
/// or dead image host can never hang or bloat cover loading.
Future<Uint8List?> _fetchCoverBytes(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const FormatException('封面地址无效');
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..userAgent =
        'Mozilla/5.0 (Linux; Android 14; Xiaomi 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';
  try {
    final request = await client.getUrl(uri).timeout(
      const Duration(seconds: 10),
    );
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
  final Future<Uint8List?> Function(String) request;
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

  Future<Uint8List> load(String url) {
    if (url.isEmpty) return Future.error(ArgumentError('Invalid cover URL'));
    final entry = _touch(url);
    if (entry != null) return entry.future;
    final failure = _failures[url];
    if (failure != null && now().isBefore(failure.$1)) return failure.$2;
    _failures.remove(url);
    final pending = _pending[url];
    if (pending != null) return pending;
    final completer = Completer<Uint8List>();
    final future = completer.future;
    _pending[url] = future;
    unawaited(() async {
      try {
        final image = await request(url);
        if (image == null || image.isEmpty) throw const FormatException('封面为空');
        final bytes = image.asUnmodifiableView();
        if (identical(_pending[url], future)) {
          _store(url, _UrlCoverEntry(bytes, future));
        }
        completer.complete(bytes);
      } catch (error, stack) {
        if (identical(_pending[url], future)) {
          _failures[url] = (now().add(retryDelay), future);
          // Failed URLs must not grow forever while browsing offline either.
          while (_failures.length > maxEntries) {
            _failures.remove(_failures.keys.first);
          }
        }
        completer.completeError(error, stack);
      } finally {
        if (identical(_pending[url], future)) _pending.remove(url);
      }
    }());
    return future;
  }
}

class _UrlCoverEntry {
  const _UrlCoverEntry(this.bytes, this.future);
  final Uint8List bytes;
  final Future<Uint8List> future;
}

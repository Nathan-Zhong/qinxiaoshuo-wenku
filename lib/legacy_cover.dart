import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'legado/legado_book_registry.dart';
import 'legado/legado_books.dart';
import 'legado/legado_image_resolver.dart';
import 'url_cover.dart';

/// Bounded cover cache for both the Wenku8 catalogue and Legado sources.
///
/// Wenku8 covers come from the native bridge (`cover` on the legacy
/// channel: `action=book&do=cover&aid=<id>`), which keeps the original
/// on-disk cache. Legado source covers are resolved through the engine
/// (`resolveImageRequest`, so source headers/cookies apply) and fetched
/// through UrlCover (URL-keyed cache, browser User-Agent, tight
/// timeouts, resolved-then-bare fallback); they live in-memory only.
abstract final class LegacyCover {
  static const _channel = MethodChannel('org.mewx.wenku8/legacy_api');

  /// Source cover URL hints supplied by the caller (`Novel.coverUrl`),
  /// used when the registry record carries no cover of its own.
  static final _urlHints = <int, String>{};

  static final _cache = LegacyCoverCache(request: _request);

  // 1.0.0 parity: the peek also consults the URL-keyed cover cache
  // (a cover fetched once for one book is visible to every book
  // sharing the URL, and survives this aid-keyed cache's eviction).
  // The hint comes from the caller or from the last bytes() call.
  static Uint8List? peek(int aid, {String? url}) {
    final cached = _cache.peek(aid);
    if (cached != null) return cached;
    final hint = url ?? _urlHints[aid];
    if (hint == null || hint.isEmpty) return null;
    return UrlCover.peek(hint);
  }

  static Future<Uint8List> bytes(int aid, {String? url}) {
    if (url != null && url.isNotEmpty) _urlHints[aid] = url;
    return _cache.load(aid);
  }

  /// Explicit local fixtures never query a remote cover endpoint.
  static void seedLocalBytes(int aid, Uint8List bytes) =>
      _cache.seed(aid, bytes);

  static Future<Uint8List?> _request(int aid) async {
    if (isLegadoBookId(aid)) return _legadoCover(aid);
    return _channel.invokeMethod<Uint8List>('cover', {'aid': aid});
  }

  static final _resolver = LegadoImageResolver(
    call: ({required origin, required url}) =>
        LegadoBooks.client.resolveImageRequest(origin: origin, url: url),
  );

  static Future<Uint8List?> _legadoCover(int aid) async {
    final record = LegadoBooks.registryOrNull?.recordById(aid);
    final origin = record?.origin ?? '';
    var target = record?.coverUrl;
    if (target == null || target.trim().isEmpty) {
      target = _urlHints[aid];
    }
    if (target == null || target.trim().isEmpty) return null;
    if (target.startsWith('data:')) return _dataUri(target);
    var fetchUrl = target;
    var headers = const <String, String>{};
    if (origin.isNotEmpty) {
      try {
        final resolved = await _resolver.resolve(origin, target);
        if (resolved != null && resolved.url.isNotEmpty) {
          fetchUrl = resolved.url;
          headers = resolved.headers;
        }
      } catch (_) {
        // Resolution is best-effort; the bare URL may still work.
      }
    }
    if (fetchUrl.startsWith('data:')) return _dataUri(fetchUrl);
    // 1.0.0 parity (cover_images.dart loadLegadoCoverBytes): the fetch
    // goes through UrlCover, not a bare HttpClient — that restores four
    // behaviours the 0.5.6 re-port dropped:
    //  1. a browser Chrome User-Agent by default (a bare Dart HttpClient
    //     sends Dart/<version>, which image hosts and CDNs reject);
    //  2. a resolved-URL fetch that falls back to the bare URL when the
    //     resolved fetch fails (one failed attempt no longer means no
    //     cover at all), with a failed headered attempt never poisoning
    //     the bare retry window (separate failure keys in UrlCover);
    //  3. tight timeouts (5s connect / 10s read) and an 8MB size cap,
    //     so a dead or hostile image host can neither hang nor bloat
    //     cover loading;
    //  4. a URL-keyed cache shared by every book with the same cover,
    //     with a synchronous peek (see peek above).
    try {
      return await UrlCover.load(
        target,
        headers: headers,
        fetchUrl: fetchUrl,
      );
    } catch (_) {
      if (fetchUrl == target && headers.isEmpty) rethrow;
      return UrlCover.load(target);
    }
  }

  static Uint8List? _dataUri(String url) {
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } on FormatException {
      return null;
    }
  }
}

class LegacyCoverCache {
  LegacyCoverCache({
    required this.request,
    this.maxBytes = 16 * 1024 * 1024,
    this.maxEntries = 256,
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       assert(maxBytes > 0 && maxEntries > 0);
  final Future<Uint8List?> Function(int) request;
  final int maxBytes, maxEntries;
  final Duration retryDelay;
  final DateTime Function() now;
  final _entries = <int, _CoverEntry>{};
  final _pending = <int, Future<Uint8List>>{};
  final _failures = <int, (DateTime, Future<Uint8List>)>{};
  int _encodedBytes = 0;
  int get encodedBytes => _encodedBytes;
  int get cachedEntries => _entries.length;
  int get pendingRequests => _pending.length;
  int get cachedFailures => _failures.length;

  _CoverEntry? _touch(int aid) {
    final entry = _entries.remove(aid);
    if (entry != null) _entries[aid] = entry;
    return entry;
  }

  Uint8List? peek(int aid) => _touch(aid)?.bytes;

  void seed(int aid, Uint8List bytes) {
    if (aid <= 0 || bytes.isEmpty) throw ArgumentError('Invalid local cover');
    final local = Uint8List.fromList(bytes).asUnmodifiableView();
    // A delayed older network response must not overwrite an explicit seed.
    _pending.remove(aid);
    _failures.remove(aid);
    _store(aid, _CoverEntry(local, Future.value(local)));
  }

  void _store(int aid, _CoverEntry entry) {
    final previous = _entries.remove(aid);
    if (previous != null) _encodedBytes -= previous.bytes.length;
    if (entry.bytes.length > maxBytes) return;
    _entries[aid] = entry;
    _encodedBytes += entry.bytes.length;
    while (_encodedBytes > maxBytes || _entries.length > maxEntries) {
      final removed = _entries.remove(_entries.keys.first)!;
      _encodedBytes -= removed.bytes.length;
    }
  }

  Future<Uint8List> load(int aid) {
    if (aid <= 0) return Future.error(ArgumentError('Invalid cover ID'));
    final entry = _touch(aid);
    if (entry != null) return entry.future;
    final failure = _failures[aid];
    if (failure != null && now().isBefore(failure.$1)) return failure.$2;
    _failures.remove(aid);
    final pending = _pending[aid];
    if (pending != null) return pending;
    final completer = Completer<Uint8List>();
    final future = completer.future;
    _pending[aid] = future;
    unawaited(() async {
      try {
        final image = await request(aid);
        if (image == null || image.isEmpty) throw const FormatException('封面为空');
        final bytes = image.asUnmodifiableView();
        if (identical(_pending[aid], future)) {
          _store(aid, _CoverEntry(bytes, future));
        }
        completer.complete(bytes);
      } catch (error, stack) {
        if (identical(_pending[aid], future)) {
          _failures[aid] = (now().add(retryDelay), future);
          // Failed IDs must not grow forever while browsing offline either.
          while (_failures.length > maxEntries) {
            _failures.remove(_failures.keys.first);
          }
        }
        completer.completeError(error, stack);
      } finally {
        if (identical(_pending[aid], future)) _pending.remove(aid);
      }
    }());
    return future;
  }
}

class _CoverEntry {
  const _CoverEntry(this.bytes, this.future);
  final Uint8List bytes;
  final Future<Uint8List> future;
}

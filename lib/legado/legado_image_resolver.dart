import 'dart:async';

import 'legado_dto.dart';

/// The bridge call behind [LegadoImageResolver]; matches
/// `LegadoEngineClient.resolveImageRequest`.
typedef ImageRequestCall =
    Future<ImageRequest> Function({required String origin, required String url});

/// Bounded cache over the engine's `resolveImageRequest` (G7, P5.1).
///
/// Resolving an image URL runs the source's AnalyzeUrl machinery
/// natively (URL option suffix, source header, login header, cookies),
/// which is far too heavy to repeat for every row of a list page, so
/// each (origin, url) pair is resolved at most once per session and
/// the result is reused by every later load of the same image.
/// Failures (bridge unavailable, broken source, empty result) are
/// remembered for [retryDelay] and reported as null — the caller then
/// falls back to a bare fetch of the original URL, exactly the pre-G7
/// behaviour. In-flight resolutions are de-duplicated, so a list page
/// mounting twenty covers never queues twenty bridge calls for the
/// same image, and distinct images still resolve concurrently.
class LegadoImageResolver {
  LegadoImageResolver({
    required this.call,
    this.maxEntries = 256,
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       assert(maxEntries > 0);

  final ImageRequestCall call;
  final int maxEntries;
  final Duration retryDelay;
  final DateTime Function() _now;

  final _resolved = <String, ImageRequest>{};
  final _failures = <String, DateTime>{};
  final _pending = <String, Future<ImageRequest?>>{};

  int get cachedResolutions => _resolved.length;
  int get cachedFailures => _failures.length;

  /// The resolved fetch target for [url] under source [origin], or
  /// null when resolution is unavailable/failed (caller falls back).
  Future<ImageRequest?> resolve(String origin, String url) {
    final key = '$origin\n$url';
    final hit = _resolved[key];
    if (hit != null) {
      // Refresh LRU position: list pages re-read the first covers a lot.
      _resolved.remove(key);
      _resolved[key] = hit;
      return Future.value(hit);
    }
    final failedAt = _failures[key];
    if (failedAt != null && _now().difference(failedAt) < retryDelay) {
      return Future.value(null);
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final future = _resolve(key, origin, url);
    _pending[key] = future;
    return future.whenComplete(() {
      if (identical(_pending[key], future)) _pending.remove(key);
    });
  }

  Future<ImageRequest?> _resolve(String key, String origin, String url) async {
    try {
      final result = await call(origin: origin, url: url);
      if (result.url.isEmpty) {
        throw const FormatException('Empty resolved image URL');
      }
      _failures.remove(key);
      _resolved[key] = result;
      while (_resolved.length > maxEntries) {
        _resolved.remove(_resolved.keys.first);
      }
      return result;
    } catch (_) {
      _failures[key] = _now();
      while (_failures.length > maxEntries) {
        _failures.remove(_failures.keys.first);
      }
      return null;
    }
  }

  /// Drops every cached resolution and failure (source edits make old
  /// resolutions suspect; tests use it for isolation).
  void clear() {
    _resolved.clear();
    _failures.clear();
  }
}

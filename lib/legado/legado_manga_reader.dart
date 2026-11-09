import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../app_ui.dart';
import '../cover_images.dart';

/// Fetches one manga page's bytes for [url] under source [origin].
typedef MangaImageLoader =
    Future<Uint8List> Function({required String origin, required String url});

/// Bounded byte cache for manga chapter pages.
///
/// Manga pages are far larger than covers, so this is a separate,
/// bigger budget than UrlCoverCache's, with the same semantics: LRU
/// eviction by encoded bytes AND entry count, in-flight de-dup, and a
/// failure retry window so a dead image host is not hammered while
/// scrolling — a manual retry goes through [evict], which clears both
/// the bytes and the failure mark. Decoded sizes are memoised so a
/// page's aspect ratio is known synchronously on revisit and the
/// column does not jump while scrolling back.
class MangaImageCache {
  MangaImageCache({
    required this.loader,
    this.maxBytes = 48 * 1024 * 1024,
    this.maxEntries = 96,
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       assert(maxBytes > 0 && maxEntries > 0);

  final MangaImageLoader loader;
  final int maxBytes;
  final int maxEntries;
  final Duration retryDelay;
  final DateTime Function() _now;

  final _entries = <String, ({Uint8List bytes, Size size})>{};
  final _sizes = <String, Size>{};
  final _pending = <String, Future<({Uint8List bytes, Size size})>>{};
  final _failures = <String, (DateTime, Future<({Uint8List bytes, Size size})>)>{};
  int _encodedBytes = 0;

  int get encodedBytes => _encodedBytes;
  int get cachedEntries => _entries.length;
  int get pendingRequests => _pending.length;
  int get cachedFailures => _failures.length;

  ({Uint8List bytes, Size size})? peek(String url) {
    final entry = _entries.remove(url);
    if (entry != null) _entries[url] = entry;
    return entry;
  }

  Size? sizeOf(String url) => _sizes[url] ?? peek(url)?.size;

  void evict(String url) {
    final entry = _entries.remove(url);
    if (entry != null) _encodedBytes -= entry.bytes.length;
    _failures.remove(url);
    _pending.remove(url);
  }

  void clear() {
    _entries.clear();
    _sizes.clear();
    _failures.clear();
    _encodedBytes = 0;
  }

  Future<({Uint8List bytes, Size size})> load(String origin, String url) {
    final hit = peek(url);
    if (hit != null) return Future.value(hit);
    final failure = _failures[url];
    if (failure != null && _now().isBefore(failure.$1)) return failure.$2;
    _failures.remove(url);
    final pending = _pending[url];
    if (pending != null) return pending;
    final future = _load(origin, url);
    _pending[url] = future;
    return future.whenComplete(() {
      if (identical(_pending[url], future)) _pending.remove(url);
    });
  }

  Future<({Uint8List bytes, Size size})> _load(
    String origin,
    String url,
  ) async {
    try {
      final bytes = await loader(origin: origin, url: url);
      if (bytes.isEmpty) throw const FormatException('图片为空');
      final size = await _decodeSize(bytes);
      final result = (bytes: bytes, size: size);
      _sizes[url] = size;
      if (bytes.length <= maxBytes) {
        final previous = _entries.remove(url);
        if (previous != null) _encodedBytes -= previous.bytes.length;
        _entries[url] = result;
        _encodedBytes += bytes.length;
        while (_encodedBytes > maxBytes || _entries.length > maxEntries) {
          final removed = _entries.remove(_entries.keys.first)!;
          _encodedBytes -= removed.bytes.length;
        }
      }
      return result;
    } catch (error, stack) {
      final failed = Future<({Uint8List bytes, Size size})>.error(
        error,
        stack,
      );
      // Avoid an unhandled-async-error report when nobody ends up
      // listening to the remembered failure future.
      failed.ignore();
      _failures[url] = (_now().add(retryDelay), failed);
      while (_failures.length > maxEntries) {
        _failures.remove(_failures.keys.first);
      }
      rethrow;
    }
  }

  Future<Size> _decodeSize(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final size = Size(
          descriptor.width.toDouble(),
          descriptor.height.toDouble(),
        );
        if (size.isEmpty) throw const FormatException('图片尺寸无效');
        return size;
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }
}

/// The shared manga page cache. Its loader resolves every page
/// through the engine first (G7: the source's headers and the
/// per-image `,{...}` suffix rules), exactly like cover loads.
final legadoMangaImageCache = MangaImageCache(
  loader: ({required origin, required url}) =>
      (MangaImageDebug.loaderOverride ?? loadLegadoMangaImageBytes)(
        origin: origin,
        url: url,
      ),
);

/// Test hook: replacing the shared cache's loader keeps widget tests
/// off the network and the engine channel. Production code never
/// sets this.
abstract final class MangaImageDebug {
  @visibleForTesting
  static MangaImageLoader? loaderOverride;
}

/// Loads one manga page with the G7 anti-hotlink ladder, mirroring
/// [loadLegadoCoverBytes]: resolved URL + headers first when the
/// engine resolves the image to something different, then the bare
/// URL as its own attempt.
Future<Uint8List> loadLegadoMangaImageBytes({
  required String origin,
  required String url,
}) async {
  // Offline cache hit (P5.7): the bridge substitutes a downloaded
  // chapter image's local file path for its remote URL. A missing
  // file throws here and surfaces through the tile's existing
  // failure + retry presentation.
  if (url.startsWith('/')) return File(url).readAsBytes();
  if (origin.isNotEmpty) {
    final target = await legadoImageResolver.resolve(origin, url);
    if (target != null && (target.url != url || target.headers.isNotEmpty)) {
      try {
        return await fetchMangaImageBytes(target.url, target.headers);
      } catch (_) {
        // Resolved fetch failed: the bare fetch below is a genuinely
        // different request and gets its own attempt.
      }
    }
  }
  return fetchMangaImageBytes(url, const {});
}

/// Browser-style GET for a manga page: like the cover fetch but with
/// a page-sized cap (20MB) and slower-host timeouts.
Future<Uint8List> fetchMangaImageBytes(
  String url,
  Map<String, String> headers,
) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const FormatException('图片地址无效');
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
    ..connectionTimeout = const Duration(seconds: 8)
    ..userAgent = userAgent;
  try {
    final request = await client.getUrl(uri).timeout(
      const Duration(seconds: 15),
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
      const Duration(seconds: 15),
    );
    if (response.statusCode != HttpStatus.ok) {
      throw FormatException('图片请求失败 (${response.statusCode})');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(
      const Duration(seconds: 20),
    )) {
      builder.add(chunk);
      if (builder.length > 20 * 1024 * 1024) {
        throw const FormatException('图片过大');
      }
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

/// Warms the neighbours of the page at [around] (±2) so vertical
/// scrolling does not stall on loads. Fire-and-forget by design: the
/// cache de-dupes in-flight loads, and a failed warm simply leaves
/// the failure for the page's own widget to present with a retry.
void warmMangaImages({
  required String origin,
  required List<String> urls,
  required int around,
  MangaImageCache? cache,
}) {
  final target = cache ?? legadoMangaImageCache;
  for (final offset in const [1, -1, 2, -2]) {
    final index = around + offset;
    if (index < 0 || index >= urls.length) continue;
    final url = urls[index];
    if (target.peek(url) != null) continue;
    unawaited(target.load(origin, url).then((_) {}, onError: (Object _) {}));
  }
}

/// One manga page inside the reader's chapter column.
///
/// Presentation follows the reader's own illustration surfaces: the
/// shared loading skeleton while bytes are in flight, and the same
/// ContentPanel failure composition as a missing illustration (photo
/// icon, label, retry button) when a page cannot be fetched. Loaded
/// pages span the full text-column width with their natural aspect
/// ratio, stacked flush like the vertical-scroll manga format is.
class MangaChapterImage extends StatefulWidget {
  const MangaChapterImage({
    super.key,
    required this.origin,
    required this.url,
    this.cache,
  });

  final String origin;
  final String url;
  final MangaImageCache? cache;

  @override
  State<MangaChapterImage> createState() => _MangaChapterImageState();
}

class _MangaChapterImageState extends State<MangaChapterImage> {
  MangaImageCache get _cache => widget.cache ?? legadoMangaImageCache;

  late Future<({Uint8List bytes, Size size})> _future = _load();

  Future<({Uint8List bytes, Size size})> _load() =>
      _cache.load(widget.origin, widget.url);

  @override
  void didUpdateWidget(MangaChapterImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.origin != widget.origin) {
      _future = _load();
    }
  }

  void _retry() {
    _cache.evict(widget.url);
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cached = _cache.peek(widget.url);
    return FutureBuilder<({Uint8List bytes, Size size})>(
      key: ObjectKey(_future),
      future: _future,
      initialData: cached,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (snapshot.hasError) {
          return ContentPanel(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.photo),
                  const SizedBox(height: 10),
                  const AppText('图片加载失败'),
                  GlassTextButton(
                    onPressed: _retry,
                    child: const AppText('重试图片'),
                  ),
                ],
              ),
            ),
          );
        }
        if (data == null) {
          return const AspectRatio(
            aspectRatio: .75,
            child: LoadingSkeleton(
              layout: SkeletonLayout.cover,
              label: '正在载入图片',
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.hasBoundedWidth
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            return SizedBox(
              width: width,
              height: width / data.size.aspectRatio,
              child: Image.memory(
                data.bytes,
                width: width,
                fit: BoxFit.fill,
                cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                    .round()
                    .clamp(1, 1600)
                    .clamp(1, data.size.width.round().clamp(1, 2400)),
                filterQuality: FilterQuality.medium,
              ),
            );
          },
        );
      },
    );
  }
}

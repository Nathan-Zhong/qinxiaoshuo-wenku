import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'app_interactions.dart';
import 'catalog.dart';
import 'legacy_cover.dart';
import 'legado/legado_book_registry.dart';
import 'legado/legado_books.dart';
import 'legado/legado_image_resolver.dart';
import 'local_book_media.dart';
import 'reader_illustrations.dart';
import 'url_cover.dart';

bool _isHttpUrl(String? url) =>
    url != null && (url.startsWith('http://') || url.startsWith('https://'));

/// Shared G7 resolution cache for Legado source images: one bridge
/// resolution per (origin, url) per session, shared by every cover
/// load. Exposed so tests can inspect/reset it; production code only
/// goes through [loadLegadoCoverBytes].
final legadoImageResolver = LegadoImageResolver(
  call: ({required origin, required url}) =>
      LegadoBooks.client.resolveImageRequest(origin: origin, url: url),
);

/// The one cover-byte dispatch every display site uses, so a book shows
/// the same cover in lists, shelves, detail and the cover viewer:
///
/// - `wenku-local:` covers come from the local book's own media store;
/// - Legado books with an http/https `coverUrl` fetch the source's real
///   cover image by URL (the native Wenku cover channel only knows
///   Wenku aids and can never resolve a Legado synthetic id), resolved
///   through the engine first when the book's origin is known (G7);
/// - everything else (Wenku books, test fixtures) keeps the original
///   native LegacyCover channel, unchanged.
Future<Uint8List> coverBytesFor(Novel novel) {
  final url = novel.coverUrl;
  if (url?.startsWith('wenku-local:') == true) {
    return LocalBookMedia.loadCover(url!);
  }
  if (isLegadoBookId(novel.id) && _isHttpUrl(url)) {
    return loadLegadoCoverBytes(novel, url!);
  }
  return LegacyCover.bytes(novel.id);
}

/// Loads a Legado book's cover with G7 anti-hotlink handling:
///
/// 1. bytes already cached under the cover URL return immediately —
///    a cache hit never pays a bridge resolution (the fork's own
///    resolveSourceRequest is likewise skipped on a disk hit);
/// 2. otherwise, when the registry knows this book's origin, the URL
///    is resolved natively (cached per origin+url) and the resolved
///    URL + headers are fetched;
/// 3. any failure — no registry record, bridge down, resolution or
///    resolved fetch failing — degrades one step at a time to the
///    bare URL fetch, and only that failing surfaces the caller's
///    text-cover fallback. The peek path never resolves: it stays the
///    synchronous cache read it always was.
Future<Uint8List> loadLegadoCoverBytes(Novel novel, String url) async {
  final cached = UrlCover.peek(url);
  if (cached != null) return cached;
  final record = LegadoBooks.registryOrNull?.recordById(novel.id);
  final origin = record?.origin;
  // Bug 5 (2026-11-15): the engine's native fetch goes first — it
  // applies the source's cover decode JS (coverDecodeJs) where one
  // is declared. Any failure falls through to the ladder below, so
  // a source without decode JS behaves exactly as before.
  if (origin != null && origin.isNotEmpty) {
    try {
      final bytes = await LegadoBooks.client.fetchImageBytes(
        origin: origin,
        bookUrl: record?.bookUrl,
        url: url,
        isCover: true,
      );
      // Seed the URL-keyed cache so peek() callers see the same bytes.
      UrlCover.seed(url, bytes);
      return bytes;
    } catch (_) {
      // Native fetch failed: the ladder below is a genuinely
      // different request and gets its own attempt.
    }
  }
  if (origin != null && origin.isNotEmpty) {
    final target = await legadoImageResolver.resolve(origin, url);
    if (target != null && (target.url != url || target.headers.isNotEmpty)) {
      try {
        return await UrlCover.load(
          url,
          headers: target.headers,
          fetchUrl: target.url,
        );
      } catch (_) {
        // Resolved fetch failed (CDN rejected the headers, host
        // down, ...): the bare fetch below is a genuinely different
        // request and gets its own attempt.
      }
    }
  }
  return UrlCover.load(url);
}

/// Synchronous twin of [coverBytesFor] for hero flights and other
/// peek-only sites; null when nothing is cached yet.
Uint8List? coverPeekFor(Novel novel) {
  final url = novel.coverUrl;
  if (url?.startsWith('wenku-local:') == true) {
    return LocalBookMedia.peek(url);
  }
  if (isLegadoBookId(novel.id) && _isHttpUrl(url)) {
    return UrlCover.peek(url!);
  }
  return LegacyCover.peek(novel.id);
}

ReaderIllustrationCache novelCoverImageCache(Novel book) =>
    ReaderIllustrationCache(request: (_) => coverBytesFor(book));

Future<void> openNovelCoverImage(
  BuildContext context,
  Novel book, {
  required bool reduceMotion,
}) async {
  final url = book.coverUrl;
  if (url == null) return;
  await pushNovelPage<void>(
    context,
    ReaderIllustrationGallery(
      urls: [url],
      initialUrl: url,
      title: '小说封面',
      fileNamePrefix: book.title,
      cache: novelCoverImageCache(book),
    ),
    reduceMotion: reduceMotion,
  );
}

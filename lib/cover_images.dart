import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'app_interactions.dart';
import 'catalog.dart';
import 'legacy_cover.dart';
import 'legado/legado_book_registry.dart';
import 'local_book_media.dart';
import 'reader_illustrations.dart';
import 'url_cover.dart';

bool _isHttpUrl(String? url) =>
    url != null && (url.startsWith('http://') || url.startsWith('https://'));

/// The one cover-byte dispatch every display site uses, so a book shows
/// the same cover in lists, shelves, detail and the cover viewer:
///
/// - `wenku-local:` covers come from the local book's own media store;
/// - Legado books with an http/https `coverUrl` fetch the source's real
///   cover image by URL (the native Wenku cover channel only knows
///   Wenku aids and can never resolve a Legado synthetic id);
/// - everything else (Wenku books, test fixtures) keeps the original
///   native LegacyCover channel, unchanged.
Future<Uint8List> coverBytesFor(Novel novel) {
  final url = novel.coverUrl;
  if (url?.startsWith('wenku-local:') == true) {
    return LocalBookMedia.loadCover(url!);
  }
  if (isLegadoBookId(novel.id) && _isHttpUrl(url)) {
    return UrlCover.load(url!);
  }
  return LegacyCover.bytes(novel.id);
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

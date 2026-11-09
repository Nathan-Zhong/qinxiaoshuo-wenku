import 'package:flutter/widgets.dart';
import 'app_interactions.dart';
import 'catalog.dart';
import 'legacy_cover.dart';
import 'legado/legado_books.dart';
import 'legado/legado_image_resolver.dart';
import 'reader_illustrations.dart';

ReaderIllustrationCache novelCoverImageCache(Novel book) =>
    ReaderIllustrationCache(
      request: (_) => LegacyCover.bytes(book.id, url: book.coverUrl),
    );

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

/// Shared resolution cache for Legado source images: one bridge
/// resolution per (origin, url) per session, shared by every cover load.
final legadoImageResolver = LegadoImageResolver(
  call: ({required origin, required url}) =>
      LegadoBooks.client.resolveImageRequest(origin: origin, url: url),
);

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/cover_images.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/legado/legado_book_registry.dart';
import 'package:wenku8_flutter/url_cover.dart';

import 'support/cover_fixture.dart';

/// Covers for Legado (book-source) books: the source's real cover URL is
/// fetched and cached by URL; Wenku books keep the native channel; any
/// failure falls back to the generated text cover.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UrlCoverCache', () {
    test('successful load is cached and peekable without refetching', () async {
      var requests = 0;
      final cache = UrlCoverCache(
        request: (_) async {
          requests++;
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      expect(cache.peek('https://img.example/a.webp'), isNull);
      expect(await cache.load('https://img.example/a.webp'), [1, 2, 3]);
      expect(cache.peek('https://img.example/a.webp'), [1, 2, 3]);
      expect(await cache.load('https://img.example/a.webp'), [1, 2, 3]);
      expect(requests, 1);
      expect(cache.cachedEntries, 1);
    });

    test('empty bytes count as failure', () async {
      final cache = UrlCoverCache(request: (_) async => Uint8List(0));
      await expectLater(
        cache.load('https://img.example/empty.webp'),
        throwsFormatException,
      );
      expect(cache.peek('https://img.example/empty.webp'), isNull);
      expect(cache.cachedFailures, 1);
    });

    test('failures are not retried inside the retry window', () async {
      var now = DateTime(2026, 11, 3, 5);
      var requests = 0;
      final cache = UrlCoverCache(
        retryDelay: const Duration(seconds: 30),
        now: () => now,
        request: (_) async {
          requests++;
          if (requests == 1) throw const FormatException('boom');
          return Uint8List.fromList([9]);
        },
      );
      await expectLater(
        cache.load('https://img.example/b.webp'),
        throwsFormatException,
      );
      // Inside the window the same failed future is handed back.
      await expectLater(
        cache.load('https://img.example/b.webp'),
        throwsFormatException,
      );
      expect(requests, 1);
      now = now.add(const Duration(seconds: 31));
      expect(await cache.load('https://img.example/b.webp'), [9]);
      expect(requests, 2);
    });

    test('oldest entries are evicted past the entry cap', () async {
      final cache = UrlCoverCache(
        maxEntries: 2,
        request: (url) async => Uint8List.fromList([url.length]),
      );
      await cache.load('https://img.example/1');
      await cache.load('https://img.example/2');
      await cache.load('https://img.example/3');
      expect(cache.cachedEntries, 2);
      expect(cache.peek('https://img.example/1'), isNull);
      expect(cache.peek('https://img.example/3'), isNotNull);
    });

    test('seed wins and is returned by peek and load', () async {
      var requests = 0;
      final cache = UrlCoverCache(
        request: (_) async {
          requests++;
          return Uint8List.fromList([7]);
        },
      );
      cache.seed(
        'https://img.example/seed.webp',
        Uint8List.fromList([5, 5]),
      );
      expect(cache.peek('https://img.example/seed.webp'), [5, 5]);
      expect(await cache.load('https://img.example/seed.webp'), [5, 5]);
      expect(requests, 0);
    });
  });

  group('cover dispatch', () {
    test('legado book with https coverUrl uses the URL cache', () async {
      const url = 'https://cdn.example/covers/dispatch-seed.webp';
      final novel = Novel(
        id: legadoBookIdBase + 777,
        title: '书源封面书',
        author: '作者',
        genre: '',
        summary: '',
        coverUrl: url,
        colors: const [Colors.grey, Colors.white],
      );
      expect(isLegadoBookId(novel.id), isTrue);
      UrlCover.seed(url, Uint8List.fromList([4, 2]));
      expect(coverPeekFor(novel), [4, 2]);
      expect(await coverBytesFor(novel), [4, 2]);
    });

    test('wenku book keeps the LegacyCover channel', () async {
      final novel = coverFixtureBook(654321);
      final bytes = await coverFixtureBytes();
      LegacyCover.seedLocalBytes(novel.id, bytes);
      expect(coverPeekFor(novel), bytes);
      expect(await coverBytesFor(novel), bytes);
    });
  });

  group('NovelCover with a legado cover URL', () {
    tearDown(() => UrlCover.debugRequestOverride = null);

    Novel legadoBook(String url) => Novel(
      id: legadoBookIdBase + 888,
      title: '有真封面的书',
      author: '作者',
      genre: '',
      summary: '',
      coverUrl: url,
      colors: const [Colors.grey, Colors.white],
    );

    testWidgets('fetched cover bytes render as an Image', (tester) async {
      final bytes = (await tester.runAsync(coverFixtureBytes))!;
      UrlCover.debugRequestOverride = (_) async => bytes;
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: NovelCover(
              legadoBook('https://cdn.example/covers/widget-ok.webp'),
              width: 120,
              height: 164,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      // The generated text cover is not shown once the real cover lands.
      expect(find.text('有真封面的书'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failed cover fetch falls back to the text cover', (
      tester,
    ) async {
      UrlCover.debugRequestOverride =
          (_) async => throw const FormatException('no cover');
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: NovelCover(
              legadoBook('https://cdn.example/covers/widget-fail.webp'),
              width: 120,
              height: 164,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('有真封面的书'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/cover_images.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/legado/legado_book_registry.dart';
import 'package:wenku8_flutter/legado/legado_books.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';
import 'package:wenku8_flutter/url_cover.dart';

import 'support/cover_fixture.dart';
import 'support/legado_engine_mock.dart';

/// Covers for Legado (book-source) books: the source's real cover URL is
/// fetched and cached by URL; Wenku books keep the native channel; any
/// failure falls back to the generated text cover.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UrlCoverCache', () {
    test('successful load is cached and peekable without refetching', () async {
      var requests = 0;
      final cache = UrlCoverCache(
        request: (_, _) async {
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
      final cache = UrlCoverCache(request: (_, _) async => Uint8List(0));
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
        request: (_, _) async {
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
        request: (url, _) async => Uint8List.fromList([url.length]),
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
        request: (_, _) async {
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

  group('UrlCoverCache resolved (G7) loads', () {
    test('headers and fetchUrl reach the request; bytes key by cover URL',
        () async {
      final seen = <({String url, Map<String, String> headers})>[];
      final cache = UrlCoverCache(
        request: (url, headers) async {
          seen.add((url: url, headers: headers));
          return Uint8List.fromList([8, 8]);
        },
      );
      final bytes = await cache.load(
        'https://img.example/raw.jpg',
        headers: const {'Referer': 'https://a.example/'},
        fetchUrl: 'https://img.example/real.jpg',
      );
      expect(bytes, [8, 8]);
      expect(seen.single.url, 'https://img.example/real.jpg');
      expect(seen.single.headers, {'Referer': 'https://a.example/'});
      // Peek and later bare loads see the bytes under the cover URL.
      expect(cache.peek('https://img.example/raw.jpg'), [8, 8]);
      expect(await cache.load('https://img.example/raw.jpg'), [8, 8]);
      expect(seen, hasLength(1));
    });

    test('a failed headered load does not block the bare retry', () async {
      var attempts = 0;
      final cache = UrlCoverCache(
        request: (url, headers) async {
          attempts++;
          if (headers.isNotEmpty) throw const FormatException('rejected');
          return Uint8List.fromList([3]);
        },
      );
      await expectLater(
        cache.load(
          'https://img.example/x.jpg',
          headers: const {'Referer': 'https://a.example/'},
        ),
        throwsFormatException,
      );
      // Same URL, bare: a different cache key, fetched immediately
      // instead of being swallowed by the headered failure window.
      expect(await cache.load('https://img.example/x.jpg'), [3]);
      expect(attempts, 2);
    });

    test('a failed bare load does not block a headered retry', () async {
      var attempts = 0;
      final cache = UrlCoverCache(
        request: (url, headers) async {
          attempts++;
          if (headers.isEmpty) throw const FormatException('hotlink');
          return Uint8List.fromList([4]);
        },
      );
      await expectLater(
        cache.load('https://img.example/y.jpg'),
        throwsFormatException,
      );
      expect(
        await cache.load(
          'https://img.example/y.jpg',
          headers: const {'Referer': 'https://a.example/'},
        ),
        [4],
      );
      expect(attempts, 2);
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
      UrlCover.debugRequestOverride = (_, _) async => bytes;
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
          (_, _) async => throw const FormatException('no cover');
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

  group('G7 resolved cover loading over the bridge', () {
    final mock = LegadoEngineMock();
    final fetches = <({String url, Map<String, String> headers})>[];

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mock.install();
      mock.resolveImageHandler = null;
      mock.resolveImageError = null;
      mock.resolveImageCalls.clear();
      fetches.clear();
      legadoImageResolver.clear();
    });

    tearDown(() {
      UrlCover.debugRequestOverride = null;
      mock.uninstall();
      legadoImageResolver.clear();
    });

    /// Registers one book in the shared registry and returns its
    /// host novel; unique names keep records/ids apart per test.
    Future<Novel> registerBook(String tag, String coverUrl) async {
      final record = await LegadoBooks.registry.registerSearchBook(
        SearchBook(
          name: 'G7测试书$tag',
          author: '作者$tag',
          bookUrl: 'https://src-$tag.example/book/1',
          origin: 'https://src-$tag.example',
          originName: '源$tag',
          coverUrl: coverUrl,
        ),
      );
      return record.toNovel();
    }

    test('cover resolves once, then fetches the resolved URL + headers',
        () async {
      const coverUrl = 'https://cdn.example/covers/g7-resolved.jpg';
      const resolvedUrl = 'https://cdn.example/real/g7-resolved.jpg';
      final novel = await registerBook('resolved', coverUrl);
      mock.resolveImageHandler = (origin, url) => {
        'url': resolvedUrl,
        'headers': <String, String>{'Referer': 'https://m.example/'},
      };
      UrlCover.debugRequestOverride = (url, headers) async {
        fetches.add((url: url, headers: headers));
        return Uint8List.fromList([6, 6, 6]);
      };
      expect(await coverBytesFor(novel), [6, 6, 6]);
      expect(mock.resolveImageCalls, hasLength(1));
      expect(
        mock.resolveImageCalls.single.origin,
        'https://src-resolved.example',
      );
      expect(mock.resolveImageCalls.single.url, coverUrl);
      expect(fetches.single.url, resolvedUrl);
      expect(fetches.single.headers, {'Referer': 'https://m.example/'});
      // Second load: bytes are cached, no new resolution or fetch.
      expect(await coverBytesFor(novel), [6, 6, 6]);
      expect(coverPeekFor(novel), [6, 6, 6]);
      expect(mock.resolveImageCalls, hasLength(1));
      expect(fetches, hasLength(1));
    });

    test('a failing resolution falls back to the bare fetch', () async {
      const coverUrl = 'https://cdn.example/covers/g7-fallback.jpg';
      final novel = await registerBook('fallback', coverUrl);
      mock.resolveImageError = PlatformException(
        code: 'UNKNOWN',
        message: 'bridge down',
      );
      UrlCover.debugRequestOverride = (url, headers) async {
        fetches.add((url: url, headers: headers));
        return Uint8List.fromList([7]);
      };
      expect(await coverBytesFor(novel), [7]);
      expect(mock.resolveImageCalls, hasLength(1));
      expect(fetches.single.url, coverUrl);
      expect(fetches.single.headers, isEmpty);
    });

    test('a failing resolved fetch falls back to the bare fetch', () async {
      const coverUrl = 'https://cdn.example/covers/g7-retry.jpg';
      const resolvedUrl = 'https://dead.example/covers/g7-retry.jpg';
      final novel = await registerBook('retry', coverUrl);
      mock.resolveImageHandler = (origin, url) => {
        'url': resolvedUrl,
        'headers': <String, String>{'Referer': 'https://m.example/'},
      };
      UrlCover.debugRequestOverride = (url, headers) async {
        fetches.add((url: url, headers: headers));
        if (url == resolvedUrl) throw const FormatException('dead host');
        return Uint8List.fromList([9]);
      };
      expect(await coverBytesFor(novel), [9]);
      expect(fetches.map((f) => f.url), [resolvedUrl, coverUrl]);
    });

    test('peek never triggers a resolution', () async {
      const coverUrl = 'https://cdn.example/covers/g7-peek.jpg';
      final novel = await registerBook('peek', coverUrl);
      expect(coverPeekFor(novel), isNull);
      expect(mock.resolveImageCalls, isEmpty);
    });
  });
}

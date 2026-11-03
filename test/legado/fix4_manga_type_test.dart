import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/legado/legado_book_registry.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';
import 'package:wenku8_flutter/legado/legado_engine_client.dart';
import 'package:wenku8_flutter/legado/legado_novel_repository.dart';

/// fix4 manga routing regression (Cassidy's screenshot: 《鬼灭之刃》
/// opened as a TEXT chapter carrying the image-chapter notice).
///
/// Root cause pinned by code inspection: the fork stamps a book's
/// type from its source only in search/explore list items
/// (`BookList` → `bookSource.getBookType()`); `BookInfo` analysis
/// never assigns it. The bridge rebuilt the book for
/// getBookInfo/getChapterList from url/name/author only, so the DTO
/// came back with the entity default `BookType.text` (8), and the
/// registry's absorb overwrote the record's correct image type (64)
/// on every detail/chapter open — after which the reader's image
/// probe short-circuited to null and the chapter fell back to the
/// text path, which renders the notice for image chapters.
///
/// Two layers now hold the line, and both are pinned here:
/// 1. the bridge stamps the source's type into the built book
///    (Kotlin; compile-verified by the cloud build — not testable
///    from Dart);
/// 2. the registry absorb never strips an image bit a record
///    already carries (this file): even against a type-losing
///    BookInfo — the fixture below returns type 8 for the manga,
///    exactly what the pre-fix bridge produced — the full chain
///    detail → chapters → chapterImages still routes to images.
const _kalaOrigin = 'https://www.kalamanhua.com';
const _mangaBookUrl = 'https://www.kalamanhua.com/comic/32034.html';
const _txtOrigin = 'https://txt.example';
const _textBookUrl = 'https://txt.example/book/doupo';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('registry absorb keeps the image bit', () {
    late LegadoBookRegistry registry;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      registry = LegadoBookRegistry(
        preferences: SharedPreferences.getInstance(),
      );
      await registry.ready;
    });

    test('a type-losing BookInfo cannot demote a manga record', () async {
      final record = await registry.registerSearchBook(
        const SearchBook(
          name: '鬼灭之刃',
          author: '吾峠呼世晴',
          bookUrl: _mangaBookUrl,
          origin: _kalaOrigin,
          originName: '卡拉漫画',
          type: 64,
        ),
      );
      expect(isLegadoImageBookType(record.type), isTrue);

      // What the pre-fix bridge returned for the same book.
      registry.absorbBookInfo(
        const BookInfo(
          name: '鬼灭之刃',
          author: '吾峠呼世晴',
          bookUrl: _mangaBookUrl,
          origin: _kalaOrigin,
          originName: '卡拉漫画',
          type: 8,
        ),
      );
      final after = registry.recordById(record.id)!;
      expect(
        isLegadoImageBookType(after.type),
        isTrue,
        reason: 'detail/chapter absorbs must not strip the image bit',
      );
    });

    test('a text record stays text; a later image absorb upgrades', () async {
      final record = await registry.registerSearchBook(
        const SearchBook(
          name: '斗破苍穹',
          author: '天蚕土豆',
          bookUrl: _textBookUrl,
          origin: _txtOrigin,
          type: 8,
        ),
      );
      registry.absorbBookInfo(
        const BookInfo(
          name: '斗破苍穹',
          author: '天蚕土豆',
          bookUrl: _textBookUrl,
          origin: _txtOrigin,
          type: 8,
        ),
      );
      expect(isLegadoImageBookType(registry.recordById(record.id)!.type), isFalse);

      // The sticky rule is one-way protection, not a freeze: richer
      // type information still lands.
      registry.absorbBookInfo(
        const BookInfo(
          name: '斗破苍穹',
          author: '天蚕土豆',
          bookUrl: _textBookUrl,
          origin: _txtOrigin,
          type: 64,
        ),
      );
      expect(isLegadoImageBookType(registry.recordById(record.id)!.type), isTrue);
    });
  });

  group('repository chain against a type-losing bridge', () {
    const methodChannel = MethodChannel(LegadoEngineClient.methodChannelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    late LegadoBookRegistry registry;
    late LegadoNovelRepository repository;

    // The pre-fix bridge shape: getBookInfo / getChapterList report
    // type 8 (text) even for the type-2 manga source's book.
    Map<String, Object?> typeLosingBookInfo(String origin) => {
      'bookUrl': origin == _kalaOrigin ? _mangaBookUrl : _textBookUrl,
      'tocUrl': origin == _kalaOrigin ? _mangaBookUrl : _textBookUrl,
      'name': origin == _kalaOrigin ? '鬼灭之刃' : '斗破苍穹',
      'author': origin == _kalaOrigin ? '吾峠呼世晴' : '天蚕土豆',
      'type': 8,
      'origin': origin,
      'originName': origin == _kalaOrigin ? '卡拉漫画' : '文字源',
    };

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
        switch (call.method) {
          case 'init':
            return {'ok': true, 'engineVersion': 't', 'sourceCount': 2};
          case 'getBookInfo':
            return typeLosingBookInfo(args['origin'] as String);
          case 'getChapterList':
            final origin = args['origin'] as String;
            return {
              'book': typeLosingBookInfo(origin),
              'chapters': [
                {
                  'title': origin == _kalaOrigin ? '第1话' : '第一章',
                  'url': origin == _kalaOrigin
                      ? 'https://www.kalamanhua.com/comic/32034/1.html'
                      : 'https://txt.example/book/doupo/1',
                  'index': 0,
                },
              ],
            };
          case 'getChapterContent':
            if (args['origin'] == _kalaOrigin) {
              return {
                'content': '',
                'images': [
                  'https://image.kalaimg.top/p/1.jpg',
                  'https://image.kalaimg.top/p/2.jpg',
                ],
                'isImageChapter': true,
              };
            }
            return {
              'content': '第一章正文，斗气大陆。',
              'images': <String>[],
              'isImageChapter': false,
            };
        }
        return null;
      });
      final client = LegadoEngineClient(methodChannel: methodChannel);
      registry = LegadoBookRegistry(
        preferences: SharedPreferences.getInstance(),
      );
      await registry.ready;
      repository = LegadoNovelRepository(client: client, registry: registry);
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(methodChannel, null);
    });

    test('manga: detail → chapters → chapterImages still routes to images',
        () async {
      final record = await registry.registerSearchBook(
        const SearchBook(
          name: '鬼灭之刃',
          author: '吾峠呼世晴',
          bookUrl: _mangaBookUrl,
          origin: _kalaOrigin,
          originName: '卡拉漫画',
          type: 64,
        ),
      );
      final novel = record.toNovel();

      final detail = await repository.detail(novel);
      expect(detail.id, novel.id);
      final chapters = await repository.chapters(novel.id);
      expect(chapters, hasLength(1));

      // The reader's decision point: non-null → the manga image
      // view; null → the text path that rendered her notice page.
      final images = await repository.chapterImages(novel.id, chapters.first);
      expect(images, isNotNull);
      expect(images!.urls, [
        'https://image.kalaimg.top/p/1.jpg',
        'https://image.kalaimg.top/p/2.jpg',
      ]);
    });

    test('text book: chapterImages stays null, content reads as prose',
        () async {
      final record = await registry.registerSearchBook(
        const SearchBook(
          name: '斗破苍穹',
          author: '天蚕土豆',
          bookUrl: _textBookUrl,
          origin: _txtOrigin,
          originName: '文字源',
          type: 8,
        ),
      );
      final novel = record.toNovel();
      await repository.detail(novel);
      final chapters = await repository.chapters(novel.id);
      expect(await repository.chapterImages(novel.id, chapters.first), isNull);
      expect(
        await repository.chapterContent(novel.id, chapters.first),
        '第一章正文，斗气大陆。',
      );
    });
  });
}

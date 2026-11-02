import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';

void main() {
  group('BookSourceSummary (table A)', () {
    test('round-trips every field', () {
      const source = BookSourceSummary(
        sourceUrl: 'https://example.com',
        sourceName: '示例源',
        group: '优质',
        type: 2,
        enabled: false,
        enabledExplore: true,
        customOrder: 7,
        weight: 3,
        respondTimeMs: 1234,
        lastUpdateTime: 999,
        hasLogin: true,
        comment: '备注',
        icon: 'https://example.com/icon.png',
        exploreKindCount: 5,
        sourceJson: '{"bookSourceUrl":"https://example.com"}',
      );
      expect(BookSourceSummary.fromMap(source.toMap()), source);
    });

    test('missing optional fields fall back to defaults', () {
      final source = BookSourceSummary.fromMap(const <Object?, Object?>{
        'sourceUrl': 'https://a.example',
        'sourceName': 'A',
      });
      expect(source.enabled, isTrue);
      expect(source.type, 0);
      expect(source.group, isNull);
      expect(source.sourceJson, isNull);
      expect(source.exploreKindCount, isNull);
    });
  });

  group('SearchBook (table B)', () {
    test('round-trips, variable passes through verbatim', () {
      const book = SearchBook(
        name: '某本书',
        author: '某作者',
        bookUrl: 'https://a.example/book/1',
        tocUrl: 'https://a.example/book/1/toc',
        origin: 'https://a.example',
        originName: 'A源',
        origins: <String>['https://a.example', 'https://b.example'],
        type: 0,
        kind: '玄幻,连载',
        coverUrl: 'https://a.example/cover.jpg',
        intro: '简介',
        wordCount: '100万字',
        latestChapterTitle: '第100章',
        chapterWordCount: 3000,
        variable: '{"token":"abc"}',
      );
      final restored = SearchBook.fromMap(book.toMap());
      expect(restored, book);
      expect(restored.variable, '{"token":"abc"}');
      expect(restored.bookKey, 'https://a.example\nhttps://a.example/book/1');
    });
  });

  group('BookInfo (table C)', () {
    test('round-trips table B + C fields', () {
      const info = BookInfo(
        name: '书',
        author: '者',
        bookUrl: 'https://a.example/1',
        tocUrl: 'https://a.example/1/toc',
        origin: 'https://a.example',
        originName: 'A源',
        variable: 'v1',
        charset: 'utf-8',
        totalChapterNum: 42,
        latestChapterTime: 1700000000000,
        lastCheckCount: 2,
        canUpdate: false,
      );
      expect(BookInfo.fromMap(info.toMap()), info);
    });

    test('fromSearchBook carries identity and variable across', () {
      const book = SearchBook(
        name: '书',
        author: '者',
        bookUrl: 'https://a.example/1',
        tocUrl: 'https://a.example/1/toc',
        origin: 'https://a.example',
        variable: 'keep-me',
      );
      final info = BookInfo.fromSearchBook(book);
      expect(info.variable, 'keep-me');
      expect(info.bookKey, book.bookKey);
      expect(info.toEngineBookArgs(), <String, Object?>{
        'origin': 'https://a.example',
        'bookUrl': 'https://a.example/1',
        'tocUrl': 'https://a.example/1/toc',
        'name': '书',
        'author': '者',
        'variable': 'keep-me',
      });
    });
  });

  group('Chapter (table D)', () {
    test('round-trips every field', () {
      const chapter = Chapter(
        url: 'https://a.example/1/c1',
        title: '第一章',
        index: 0,
        isVolume: false,
        isVip: true,
        isPay: false,
        resourceUrl: 'https://a.example/res',
        tag: '更新',
        wordCount: '3000字',
        variable: 'cv',
      );
      expect(Chapter.fromMap(chapter.toMap()), chapter);
    });
  });

  group('ExploreSection (table F)', () {
    test('null url marks a group heading', () {
      final heading = ExploreSection.fromMap(const <Object?, Object?>{
        'title': '热门分类',
      });
      expect(heading.isGroupHeading, isTrue);
      final kind = ExploreSection.fromMap(const <Object?, Object?>{
        'title': '玄幻',
        'url': 'https://a.example/xuanhuan',
        'viewName': 'list',
        'style': 1,
      });
      expect(kind.isGroupHeading, isFalse);
      expect(kind.style, 1);
    });
  });

  group('LegadoSubscription (table G) and ImportResult (table E)', () {
    test('round-trip', () {
      const sub = LegadoSubscription(
        id: 9,
        name: '每日订阅',
        url: 'https://sub.example/feed.json',
        type: 1,
        customOrder: 2,
        autoUpdate: true,
        lastUpdate: 1700000000000,
      );
      expect(LegadoSubscription.fromMap(sub.toMap()), sub);

      const result = ImportResult(
        added: 3,
        updated: 1,
        unchanged: 5,
        failed: 1,
        sources: <BookSourceSummary>[
          BookSourceSummary(sourceUrl: 'https://a.example', sourceName: 'A'),
        ],
        errors: <String>['bad source'],
      );
      expect(ImportResult.fromMap(result.toMap()), result);
    });
  });

  group('ChapterContent / ImageRequest', () {
    test('map from native shapes', () {
      final content = ChapterContent.fromMap(const <Object?, Object?>{
        'content': '<p>正文</p>',
        'images': <String>['https://img.example/1.jpg'],
        'isImageChapter': true,
      });
      expect(content.isImageChapter, isTrue);
      expect(content.images, <String>['https://img.example/1.jpg']);

      final request = ImageRequest.fromMap(const <Object?, Object?>{
        'url': 'https://img.example/real.jpg',
        'headers': <String, String>{'Referer': 'https://a.example/'},
      });
      expect(request.headers['Referer'], 'https://a.example/');
    });
  });
}

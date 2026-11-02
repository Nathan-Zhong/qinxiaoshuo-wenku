import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/legado/legado_book_registry.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';
import 'package:wenku8_flutter/legado/search_merge.dart';

SearchBook _book({
  required String origin,
  String originName = '',
  String name = '斗破苍穹',
  String author = '天蚕土豆',
  String bookUrl = 'https://example.com/book/1',
  String? coverUrl,
}) {
  return SearchBook(
    name: name,
    author: author,
    bookUrl: bookUrl,
    tocUrl: '$bookUrl/toc',
    origin: origin,
    originName: originName.isEmpty ? origin : originName,
    coverUrl: coverUrl,
    intro: '简介',
    latestChapterTitle: '第100章',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<LegadoBookRegistry> newRegistry() async {
    final registry = LegadoBookRegistry(
      preferences: SharedPreferences.getInstance(),
    );
    await registry.ready;
    return registry;
  }

  group('LegadoBookRegistry', () {
    test(
      'merged registration allocates in-range ids and keeps group order',
      () async {
        final registry = await newRegistry();
        final merged = mergeSearchBooks([
          _book(origin: 'https://a.example', originName: '源A'),
          _book(origin: 'https://b.example', originName: '源B'),
          _book(
            origin: 'https://c.example',
            originName: '源C',
            name: '另一本书',
            author: '别人',
          ),
        ]);
        // mergeSearchBooks produces one group per (title, author): the
        // first two books share a group, the third is its own group.
        expect(merged, hasLength(2));
        final records = await registry.registerMerged(merged.first);
        expect(records, hasLength(2));
        expect(records.first.origin, 'https://a.example');
        for (final record in records) {
          expect(isLegadoBookId(record.id), isTrue);
          expect(record.id, greaterThanOrEqualTo(legadoBookIdBase));
        }
        final group = registry.groupOf(records.last.id);
        expect(group.map((r) => r.origin), [
          'https://a.example',
          'https://b.example',
        ]);
        // Re-registering the same snapshot reuses ids (no growth).
        final again = await registry.registerMerged(merged.first);
        expect(again.map((r) => r.id), records.map((r) => r.id));
      },
    );

    test(
      'single registration joins the merge group without reordering',
      () async {
        final registry = await newRegistry();
        final merged = mergeSearchBooks([
          _book(origin: 'https://a.example'),
          _book(origin: 'https://b.example'),
        ]);
        final records = await registry.registerMerged(merged.single);
        final extra = await registry.registerSearchBook(
          _book(origin: 'https://c.example'),
        );
        final group = registry.groupOf(extra.id);
        expect(group.map((r) => r.id), [
          records[0].id,
          records[1].id,
          extra.id,
        ]);
      },
    );

    test('records and chapter lists survive a registry restart', () async {
      final registry = await newRegistry();
      final record = await registry.registerSearchBook(
        _book(origin: 'https://a.example', coverUrl: 'https://img/c.jpg'),
      );
      await registry.saveToc(record.id, const [
        Chapter(
          url: 'https://example.com/v1',
          title: '第一卷',
          index: 0,
          isVolume: true,
        ),
        Chapter(url: 'https://example.com/c1', title: '第一章', index: 1),
        Chapter(url: 'https://example.com/c2', title: '第二章', index: 2),
      ]);
      await registry.flush();

      final restored = await newRegistry();
      final restoredRecord = restored.recordById(record.id);
      expect(restoredRecord, isNotNull);
      expect(restoredRecord!.coverUrl, 'https://img/c.jpg');
      expect(restoredRecord.name, '斗破苍穹');
      final toc = await restored.tocOf(record.id);
      expect(toc, hasLength(3));
      final dto = await restored.dtoChapter(record.id, 2);
      expect(dto?.url, 'https://example.com/c1');
    });

    test('novel mapping and chapter mapping follow host conventions', () async {
      final registry = await newRegistry();
      final record = await registry.registerSearchBook(
        _book(origin: 'https://a.example'),
      );
      final novel = record.toNovel();
      expect(novel.id, record.id);
      expect(novel.title, '斗破苍穹');
      expect(novel.author, '天蚕土豆');
      expect(novel.summary, '简介');
      expect(novel.colors, hasLength(2));

      final chapters = legadoNovelChapters(const [
        Chapter(url: 'u0', title: '正文卷', index: 0, isVolume: true),
        Chapter(url: 'u1', title: '第一章', index: 1),
        Chapter(url: 'u2', title: '第二章', index: 2),
        Chapter(url: 'u3', title: '番外卷', index: 3, isVolume: true),
        Chapter(url: 'u4', title: '番外一', index: 4),
      ]);
      expect(chapters, hasLength(3));
      expect(chapters[0].id, 2); // engine index + 1
      expect(chapters[0].volumeTitle, '正文卷');
      expect(chapters[0].volumeId, 1);
      expect(chapters[2].volumeTitle, '番外卷');
      expect(chapters[2].volumeId, 2);
    });
  });
}

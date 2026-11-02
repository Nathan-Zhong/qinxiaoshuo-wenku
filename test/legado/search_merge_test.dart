import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';
import 'package:wenku8_flutter/legado/search_merge.dart';

SearchBook hit(
  String origin,
  String bookUrl, {
  String name = '某本书',
  String author = '某作者',
  String? coverUrl,
  String? variable,
}) {
  return SearchBook(
    name: name,
    author: author,
    bookUrl: bookUrl,
    tocUrl: '$bookUrl/toc',
    origin: origin,
    originName: origin,
    variable: variable,
    coverUrl: coverUrl,
  );
}

void main() {
  group('legadoMergeKey normalization', () {
    test('folds width, case, spaces and punctuation like BookSearch', () {
      expect(
        legadoMergeKey('Ｓｗｏｒｄ　Art Online：刀剑・神域（2）', '川原 砾'),
        legadoMergeKey('sword art online 刀剑神域 2', '川原砾'),
      );
    });

    test('different authors do not share a key', () {
      expect(legadoMergeKey('同名书', '甲'), isNot(legadoMergeKey('同名书', '乙')));
    });
  });

  group('mergeSearchBooks', () {
    test('merges the same book across sources into one entry', () {
      final merged = mergeSearchBooks(<SearchBook>[
        hit('https://a.example', 'https://a.example/1'),
        hit(
          'https://b.example',
          'https://b.example/9',
          name: '某本书 ',
          coverUrl: 'https://b.example/cover.jpg',
        ),
        hit('https://c.example', 'https://c.example/3', name: '某 本书'),
      ]);
      expect(merged, hasLength(1));
      final book = merged.single;
      expect(book.origins, <String>[
        'https://a.example',
        'https://b.example',
        'https://c.example',
      ]);
      // Display cover falls back to the first source that has one.
      expect(book.coverUrl, 'https://b.example/cover.jpg');
      // Each entry keeps its own locating data.
      expect(book.sources[1].bookUrl, 'https://b.example/9');
      expect(book.sources[1].tocUrl, 'https://b.example/9/toc');
      expect(book.primary.origin, 'https://a.example');
    });

    test('keeps distinct books and group first-appearance order', () {
      final merged = mergeSearchBooks(<SearchBook>[
        hit(
          'https://a.example',
          'https://a.example/1',
          name: '甲书',
          author: '甲',
        ),
        hit(
          'https://a.example',
          'https://a.example/2',
          name: '乙书',
          author: '乙',
        ),
        hit(
          'https://b.example',
          'https://b.example/1',
          name: '甲书',
          author: '甲',
        ),
      ]);
      expect(merged.map((b) => b.name).toList(), <String>['甲书', '乙书']);
      expect(merged.first.origins, <String>[
        'https://a.example',
        'https://b.example',
      ]);
    });

    test('same author different title punctuation still merges', () {
      final merged = mergeSearchBooks(<SearchBook>[
        hit('https://a.example', 'https://a.example/1', name: '书名：上'),
        hit('https://b.example', 'https://b.example/1', name: '书名 上'),
      ]);
      expect(merged, hasLength(1));
    });

    test('duplicate hits from one source collapse to the first', () {
      final merged = mergeSearchBooks(<SearchBook>[
        hit('https://a.example', 'https://a.example/1'),
        hit('https://a.example', 'https://a.example/1-dup'),
      ]);
      expect(merged.single.sources, hasLength(1));
      expect(merged.single.primary.bookUrl, 'https://a.example/1');
    });

    test('sourceOrder reorders entries, unlisted sources keep order after', () {
      final merged = mergeSearchBooks(
        <SearchBook>[
          hit('https://a.example', 'https://a.example/1'),
          hit('https://b.example', 'https://b.example/1'),
          hit('https://c.example', 'https://c.example/1'),
        ],
        sourceOrder: <String>['https://c.example', 'https://a.example'],
      );
      expect(merged.single.origins, <String>[
        'https://c.example',
        'https://a.example',
        'https://b.example',
      ]);
      expect(merged.single.primary.origin, 'https://c.example');
    });

    test('per-source variable passes through per entry', () {
      final merged = mergeSearchBooks(<SearchBook>[
        hit('https://a.example', 'https://a.example/1', variable: 'va'),
        hit('https://b.example', 'https://b.example/1', variable: 'vb'),
      ]);
      expect(merged.single.sources[0].variable, 'va');
      expect(merged.single.sources[1].variable, 'vb');
      final asBook = merged.single.toSearchBook();
      expect(asBook.variable, 'va');
      expect(asBook.origins, <String>[
        'https://a.example',
        'https://b.example',
      ]);
    });

    test('empty input merges to empty output', () {
      expect(mergeSearchBooks(const <SearchBook>[]), isEmpty);
    });
  });
}

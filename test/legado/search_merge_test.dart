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
  int type = 8,
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
    type: type,
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

    test('text and image editions of the same book do not share a key', () {
      // fix2: the manga edition (engine BookType image bit 1 shl 6)
      // must not merge into the text edition's entry.
      expect(
        legadoMergeKey('同名书', '甲', type: 8),
        isNot(legadoMergeKey('同名书', '甲', type: 64)),
      );
      expect(
        legadoMergeKey('同名书', '甲', type: 64),
        legadoMergeKey('同名书', '甲', type: 64 | 8),
      );
    });
  });

  group('legadoSanitizeBookText', () {
    test('strips private-use and other invisible codepoints', () {
      expect(legadoHasInvisibleChars('斗\uE000破苍穹'), isTrue);
      expect(legadoSanitizeBookText('斗\uE000破苍穹'), '斗破苍穹');
      expect(legadoSanitizeBookText('甲\u200B乙\uFE0F丙'), '甲乙丙');
    });

    test('clean text passes through untouched', () {
      expect(legadoHasInvisibleChars('系统想要害我，我选择上交国家'), isFalse);
      expect(
        legadoSanitizeBookText('系统想要害我，我选择上交国家'),
        '系统想要害我，我选择上交国家',
      );
    });
  });

  group('mergeSearchBooks', () {
    test('manga edition stays a separate entry from the text edition', () {
      // fix2 regression: on the real device the manga edition of a
      // book was swallowed by the text edition's merged entry and
      // never appeared in search results at all.
      final merged = mergeSearchBooks(<SearchBook>[
        hit('https://a.example', 'https://a.example/1'),
        hit('https://manga.example', 'https://manga.example/1', type: 64),
        hit('https://manga2.example', 'https://manga2.example/7', type: 64),
      ]);
      expect(merged, hasLength(2));
      final text = merged.firstWhere((b) => b.type == 8);
      expect(text.origins, <String>['https://a.example']);
      final manga = merged.firstWhere((b) => b.type == 64);
      expect(manga.origins, <String>[
        'https://manga.example',
        'https://manga2.example',
      ]);
    });

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

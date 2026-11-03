import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/legado/search_merge.dart';

/// fix4 relevance ordering: the merged list must rank like Legado's
/// own SearchModel aggregate (exact > contains > rest; exact/contains
/// tiers by merged source count), across ALL sources at once — the
/// per-source bridge session cannot apply it, which is what left
/// late-listed sources' books (e.g. the manga) trailing the results.
MergedSearchBook _book(
  String name, {
  String author = '佚名',
  int sources = 1,
  int type = 8,
}) {
  return MergedSearchBook(
    key: legadoMergeKey(name, author, type: type),
    name: name,
    author: author,
    type: type,
    sources: [
      for (var i = 0; i < sources; i++)
        MergedSourceEntry(
          origin: 'https://s$i.example',
          bookUrl: 'https://s$i.example/$name',
          type: type,
        ),
    ],
  );
}

List<String> _names(List<MergedSearchBook> books) =>
    books.map((b) => b.name).toList();

void main() {
  group('orderMergedSearchResults', () {
    test('exact match outranks contains, contains outranks the rest', () {
      final merged = [
        _book('斗破苍穹之大主宰'),
        _book('无关的书'),
        _book('斗破苍穹'),
        _book('斗破苍穹外传'),
      ];
      final ordered = orderMergedSearchResults(merged, '斗破苍穹');
      expect(_names(ordered), [
        '斗破苍穹',
        // contains tier keeps arrival order at equal source counts
        '斗破苍穹之大主宰',
        '斗破苍穹外传',
        '无关的书',
      ]);
    });

    test('author equality counts as an exact hit', () {
      final merged = [_book('某本书', author: '天蚕土豆外传作者'), _book('另一本', author: '天蚕土豆')];
      final ordered = orderMergedSearchResults(merged, '天蚕土豆');
      expect(ordered.first.author, '天蚕土豆');
    });

    test('within the exact tier, more sources rank first', () {
      final merged = [
        _book('斗破苍穹', sources: 1),
        _book('斗破苍穹', author: '另一位作者', sources: 3),
      ];
      final ordered = orderMergedSearchResults(merged, '斗破苍穹');
      expect(ordered.first.sources, hasLength(3));
      expect(ordered.last.sources, hasLength(1));
    });

    test('same-title text and manga editions both land on top', () {
      // The manga edition must not trail the novels just because its
      // source was listed (and reported) last.
      final merged = [
        _book('别的书甲'),
        _book('斗破苍穹后传'),
        _book('别的书乙'),
        _book('斗破苍穹', type: 8),
        _book('斗破苍穹', type: 64),
      ];
      final ordered = orderMergedSearchResults(merged, '斗破苍穹');
      expect(ordered[0].name, '斗破苍穹');
      expect(ordered[1].name, '斗破苍穹');
      expect(
        {ordered[0].type, ordered[1].type},
        {8, 64},
        reason: 'text and manga editions side by side at the top',
      );
      expect(ordered[2].name, '斗破苍穹后传');
    });

    test('punctuation-only decoration still counts as exact', () {
      final merged = [_book('斗破苍穹外传'), _book('斗破·苍穹')];
      final ordered = orderMergedSearchResults(merged, '斗破苍穹');
      expect(ordered.first.name, '斗破·苍穹');
    });

    test('unrelated tier keeps pure arrival order (stable)', () {
      final merged = [
        _book('甲书', sources: 5),
        _book('乙书', sources: 1),
        _book('丙书', sources: 3),
      ];
      final ordered = orderMergedSearchResults(merged, '不存在的关键词');
      expect(_names(ordered), ['甲书', '乙书', '丙书']);
    });

    test('empty keyword and short lists pass through untouched', () {
      final merged = [_book('甲书'), _book('乙书')];
      expect(orderMergedSearchResults(merged, '  '), same(merged));
      final single = [_book('甲书')];
      expect(orderMergedSearchResults(single, '甲书'), same(single));
    });

    test('re-applying on a later snapshot settles, never demotes', () {
      // Streaming: an early snapshot has only a contains hit; when
      // the exact hit arrives in a later snapshot it takes the top,
      // and applying the order twice changes nothing further.
      final early = orderMergedSearchResults([_book('斗破苍穹外传')], '斗破苍穹');
      final late = orderMergedSearchResults(
        [...early, _book('斗破苍穹')],
        '斗破苍穹',
      );
      expect(_names(late), ['斗破苍穹', '斗破苍穹外传']);
      final again = orderMergedSearchResults(late, '斗破苍穹');
      expect(_names(again), _names(late));
    });
  });
}

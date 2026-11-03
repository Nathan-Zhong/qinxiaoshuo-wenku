import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legado/daily_discovery.dart';

/// fix4 discovery shelf: daily-random draw, seeded by (local date,
/// source, kind) — same day same shelf, next day a fresh draw,
/// switching source re-draws; the rest of the pool keeps its original
/// order below the shelf.
Novel _novel(int id) => Novel(
  id: id,
  title: '书$id',
  author: '作者',
  genre: '',
  summary: '',
  colors: const [Colors.blue, Colors.indigo],
);

List<Novel> _pool(int count, {int from = 1}) =>
    [for (var i = from; i < from + count; i++) _novel(i)];

List<int> _ids(List<Novel> books) => books.map((b) => b.id).toList();

void main() {
  final day1 = DateTime(2026, 11, 4, 9, 30);
  final day2 = DateTime(2026, 11, 5, 9, 30);
  const sourceA = 'https://a.example';
  const sourceB = 'https://b.example';
  const kind = 'https://a.example/list';

  group('DailyDiscoveryPicker', () {
    test('same day, same source: repeated draws are identical', () {
      final picker = DailyDiscoveryPicker(now: () => day1);
      final pool = _pool(25);
      final first = picker.arrange(pool, sourceUrl: sourceA, kindUrl: kind);
      final second = picker.arrange(pool, sourceUrl: sourceA, kindUrl: kind);
      expect(_ids(second), _ids(first));
      // Exactly the shelf's worth of picks, then the rest of the pool
      // in its original order; together they are the whole pool.
      expect(first, hasLength(25));
      final picks = _ids(first).take(10).toSet();
      expect(picks, hasLength(10));
      final tail = _ids(first).skip(10).toList();
      expect(tail, [for (final b in pool) if (!picks.contains(b.id)) b.id]);
    });

    test('the draw is a real shuffle, not the stream head', () {
      final picker = DailyDiscoveryPicker(now: () => day1);
      final pool = _pool(25);
      final arranged = picker.arrange(pool, sourceUrl: sourceA, kindUrl: kind);
      expect(
        _ids(arranged).take(10).toList(),
        isNot([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
      );
    });

    test('next day draws a different shelf', () {
      var today = day1;
      final picker = DailyDiscoveryPicker(now: () => today);
      final pool = _pool(30);
      final firstDay = picker.arrange(pool, sourceUrl: sourceA, kindUrl: kind);
      today = day2;
      final secondDay = picker.arrange(pool, sourceUrl: sourceA, kindUrl: kind);
      expect(
        _ids(secondDay).take(10).toList(),
        isNot(_ids(firstDay).take(10).toList()),
      );
    });

    test('switching source re-draws for the new source', () {
      final picker = DailyDiscoveryPicker(now: () => day1);
      final pool = _pool(30);
      final forA = picker.arrange(pool, sourceUrl: sourceA, kindUrl: kind);
      final forB = picker.arrange(pool, sourceUrl: sourceB, kindUrl: kind);
      expect(
        _ids(forB).take(10).toList(),
        isNot(_ids(forA).take(10).toList()),
      );
      // …and switching back returns the original day's shelf for A.
      final backToA = picker.arrange(pool, sourceUrl: sourceA, kindUrl: kind);
      expect(_ids(backToA), _ids(forA));
    });

    test('a pool that fits the shelf is shown whole, untouched', () {
      final picker = DailyDiscoveryPicker(now: () => day1);
      final pool = _pool(7);
      final arranged = picker.arrange(pool, sourceUrl: sourceA, kindUrl: kind);
      expect(identical(arranged, pool), isTrue);
      final exact = _pool(10);
      expect(
        identical(
          picker.arrange(exact, sourceUrl: sourceA, kindUrl: kind),
          exact,
        ),
        isTrue,
      );
    });

    test('no source selected: pool untouched', () {
      final picker = DailyDiscoveryPicker(now: () => day1);
      final pool = _pool(25);
      expect(
        identical(picker.arrange(pool, sourceUrl: null, kindUrl: null), pool),
        isTrue,
      );
    });

    test('paging in more books never swaps the frozen shelf', () {
      final picker = DailyDiscoveryPicker(now: () => day1);
      final firstPage = _pool(15);
      final arrangedFirst = picker.arrange(
        firstPage,
        sourceUrl: sourceA,
        kindUrl: kind,
      );
      final grownPool = _pool(28);
      final arrangedGrown = picker.arrange(
        grownPool,
        sourceUrl: sourceA,
        kindUrl: kind,
      );
      expect(
        _ids(arrangedGrown).take(10).toList(),
        _ids(arrangedFirst).take(10).toList(),
        reason: 'the day\'s picks are frozen; newcomers join the tail',
      );
      // Newcomers appear in the tail in pool order.
      final tail = _ids(arrangedGrown).skip(10).toList();
      expect(tail.sublist(tail.length - 3), [26, 27, 28]);
    });

    test('a refreshed pool missing picks is topped up deterministically', () {
      final picker = DailyDiscoveryPicker(now: () => day1);
      final pool = _pool(20);
      final arranged = picker.arrange(pool, sourceUrl: sourceA, kindUrl: kind);
      // Refresh replaces the pool with a different window of books;
      // only the picks inside ids 11..20 survive.
      final refreshed = _pool(20, from: 11);
      final survivors = [
        for (final id in _ids(arranged).take(10))
          if (id >= 11) id,
      ];
      final topped = picker.arrange(
        refreshed,
        sourceUrl: sourceA,
        kindUrl: kind,
      );
      expect(topped, hasLength(refreshed.length));
      final toppedPicks = _ids(topped).take(10).toList();
      expect(toppedPicks.toSet(), hasLength(10));
      // Surviving picks keep their draw order at the head of the shelf.
      expect(toppedPicks.take(survivors.length).toList(), survivors);
      final toppedAgain = picker.arrange(
        refreshed,
        sourceUrl: sourceA,
        kindUrl: kind,
      );
      expect(_ids(toppedAgain), _ids(topped), reason: 'top-up is stable');
    });

    test('dateKey formats yyyy-MM-dd with zero padding', () {
      expect(DailyDiscoveryPicker.dateKey(DateTime(2026, 1, 5)), '2026-01-05');
      expect(DailyDiscoveryPicker.dateKey(DateTime(2026, 11, 4)), '2026-11-04');
    });
  });
}

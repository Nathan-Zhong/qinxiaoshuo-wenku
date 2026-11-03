import '../catalog.dart';

/// Daily-random featured selection for the Legado discovery shelf
/// (fix4, Cassidy-ordered behaviour change, 2026-11-04).
///
/// The discovery page's 3D shelf shows the first [shelfSlots] books of
/// the feed; everything below it (「更多书籍」) streams in the
/// source's own order. Until now the shelf was simply the first books
/// of that stream — the same handful every day. The shelf now draws
/// its books at random from the loaded pool, under three rules she
/// set:
///
/// - the draw is seeded by (local date, source, kind): entering and
///   leaving discovery on the same day always shows the same books,
///   the next day draws a fresh set, and switching source re-draws
///   for that source;
/// - the draw is FROZEN for the day once made (the picked ids are
///   remembered), so paging in more books later in the day cannot
///   swap a shelf book out from under the reader — newcomers join the
///   「更多书籍」 stream below, in its original order;
/// - a pool smaller than the shelf shows everything it has.
///
/// Only the ORDER of the feed's items changes: the picked books move
/// to the front (in draw order), the rest keep their original
/// relative order, so the shelf takes its usual first-[shelfSlots]
/// slice and the list below keeps streaming exactly as before. Every
/// book in the pool was registered (cover prefetch, title repair) by
/// the explore repository before ordering applies, so picked books
/// get the same treatment as any other.
///
/// The ranking is a plain FNV-1a hash of `seed|bookId` — small,
/// deterministic across runs and platforms (unlike a seeded
/// [Random], whose sequence is an implementation detail), and stable
/// per book, which is what makes the freeze-and-top-up below exact.
class DailyDiscoveryPicker {
  DailyDiscoveryPicker({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// Shelf slots on the discovery page (its featured slice is
  /// `books.length.clamp(0, 10)`); kept in step with that page.
  static const int shelfSlots = 10;

  String? _pickSeed;
  List<int> _pickedIds = const [];

  /// Local-date seed component, `yyyy-MM-dd`.
  static String dateKey(DateTime value) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}-'
        '${two(value.month)}-${two(value.day)}';
  }

  /// Deterministic per-book rank under [seed]: FNV-1a (32-bit) over
  /// the UTF-16 code units of `seed|id`. Lower ranks draw first.
  static int rankOf(String seed, int bookId) {
    var hash = 0x811c9dc5;
    final text = '$seed|$bookId';
    for (var i = 0; i < text.length; i++) {
      hash ^= text.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// Returns [pool] reordered for the shelf: today's picks first (in
  /// draw order), then every remaining book in its original order.
  /// Returns [pool] untouched when there is nothing to choose
  /// (no source selected, or the pool fits the shelf whole).
  List<Novel> arrange(
    List<Novel> pool, {
    required String? sourceUrl,
    required String? kindUrl,
    int slots = shelfSlots,
  }) {
    if (sourceUrl == null || pool.length <= slots) return pool;
    final seed = '${dateKey(_now())}|$sourceUrl|${kindUrl ?? ''}';
    final byId = <int, Novel>{for (final book in pool) book.id: book};
    if (_pickSeed != seed) {
      _pickSeed = seed;
      _pickedIds = _draw(seed, pool, slots);
    }
    var picks = <Novel>[for (final id in _pickedIds) ?byId[id]];
    if (picks.length < slots) {
      // Top up deterministically: the pool shrank (refresh replaced
      // it) or first froze from a partial page. Ranking the unpicked
      // remainder under the same seed keeps the top-up stable too,
      // and the extended pick list replaces the frozen one so the
      // day keeps one consistent shelf.
      final picked = <int>{for (final book in picks) book.id};
      final rest = <Novel>[
        for (final book in pool)
          if (!picked.contains(book.id)) book,
      ]..sort((a, b) => _compareRank(seed, a, b));
      picks = [...picks, ...rest.take(slots - picks.length)];
      _pickedIds = <int>[for (final book in picks) book.id];
    }
    final pickedIds = <int>{for (final book in picks) book.id};
    return <Novel>[
      ...picks,
      for (final book in pool)
        if (!pickedIds.contains(book.id)) book,
    ];
  }

  List<int> _draw(String seed, List<Novel> pool, int slots) {
    final ranked = List<Novel>.of(pool)
      ..sort((a, b) => _compareRank(seed, a, b));
    return <int>[for (final book in ranked.take(slots)) book.id];
  }

  static int _compareRank(String seed, Novel a, Novel b) {
    final byRank = rankOf(seed, a.id).compareTo(rankOf(seed, b.id));
    return byRank != 0 ? byRank : a.id.compareTo(b.id);
  }
}

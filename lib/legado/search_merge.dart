import 'package:flutter/foundation.dart';

import 'legado_dto.dart';

/// Dart-side de-duplication for search results (PLAN item 7): the same
/// book found on several sources is shown as a single entry carrying all
/// of its sources, so the reader can switch source without losing it.
///
/// The engine's own SearchModel already aggregates this way; this pure
/// function covers flows where results arrive per source (change-source
/// candidates, partial re-implementations) and lets the result list be
/// re-merged snapshot by snapshot as streaming results come in.

/// Normalization used to decide "same book". Deliberately mirrors
/// `BookSearch._normalize` in `lib/book_search.dart` (full-width → half
/// width folding, lower-casing, and removal of whitespace and common
/// punctuation/separators) so merged grouping agrees with the host's
/// local search matching.
String legadoNormalizeTitle(String value) => _normalize(value);

String _width(String value) => String.fromCharCodes([
  for (final rune in value.runes)
    if (rune >= 0xff01 && rune <= 0xff5e)
      rune - 0xfee0
    else if (rune == 0x3000)
      0x20
    else
      rune,
]);

final RegExp _spacing = RegExp(r'[\s·・_\-—–，,。.:：()（）\[\]「」『』《》]');

String _normalize(String value) =>
    _width(value).toLowerCase().replaceAll(_spacing, '');

/// Grouping key for a book: normalized title + normalized author.
String legadoMergeKey(String name, String author) =>
    '${_normalize(name)}\u0000${_normalize(author)}';

/// One source's locating data for a merged book: everything needed to
/// open the book on that source (detail / chapters / content) later.
class MergedSourceEntry {
  const MergedSourceEntry({
    required this.origin,
    this.originName = '',
    required this.bookUrl,
    this.tocUrl = '',
    this.variable,
    this.type = 0,
  });

  /// The source id (`BookSource.bookSourceUrl`).
  final String origin;
  final String originName;
  final String bookUrl;
  final String tocUrl;

  /// Opaque per-source state, passed through verbatim for this source.
  final String? variable;
  final int type;

  String get bookKey => '$origin\n$bookUrl';

  factory MergedSourceEntry.fromSearchBook(SearchBook book) {
    return MergedSourceEntry(
      origin: book.origin,
      originName: book.originName,
      bookUrl: book.bookUrl,
      tocUrl: book.tocUrl,
      variable: book.variable,
      type: book.type,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MergedSourceEntry &&
      other.origin == origin &&
      other.originName == originName &&
      other.bookUrl == bookUrl &&
      other.tocUrl == tocUrl &&
      other.variable == variable &&
      other.type == type;

  @override
  int get hashCode =>
      Object.hash(origin, originName, bookUrl, tocUrl, variable, type);
}

/// A single search-list entry after merging: one book, all its sources.
class MergedSearchBook {
  const MergedSearchBook({
    required this.key,
    required this.name,
    required this.author,
    required this.sources,
    this.type = 0,
    this.kind,
    this.coverUrl,
    this.intro,
    this.wordCount,
    this.latestChapterTitle,
    this.chapterWordCount = 0,
  });

  /// The grouping key (see [legadoMergeKey]).
  final String key;
  final String name;
  final String author;

  /// Every source carrying this book, in display order (the order given
  /// by `sourceOrder` when merging, else first-appearance order). The
  /// first entry is the primary source.
  final List<MergedSourceEntry> sources;
  final int type;
  final String? kind;
  final String? coverUrl;
  final String? intro;
  final String? wordCount;
  final String? latestChapterTitle;
  final int chapterWordCount;

  MergedSourceEntry get primary => sources.first;

  /// All source ids, in the same order as [sources].
  List<String> get origins => <String>[for (final s in sources) s.origin];

  /// A [SearchBook] view on the primary source, with [SearchBook.origins]
  /// filled with every merged source — the shape the rest of the bridge
  /// (and `BookInfo.fromSearchBook`) consumes.
  SearchBook toSearchBook() {
    final p = primary;
    return SearchBook(
      name: name,
      author: author,
      bookUrl: p.bookUrl,
      tocUrl: p.tocUrl,
      origin: p.origin,
      originName: p.originName,
      origins: origins,
      type: type,
      kind: kind,
      coverUrl: coverUrl,
      intro: intro,
      wordCount: wordCount,
      latestChapterTitle: latestChapterTitle,
      chapterWordCount: chapterWordCount,
      variable: p.variable,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MergedSearchBook &&
      other.key == key &&
      other.name == name &&
      other.author == author &&
      listEquals(other.sources, sources) &&
      other.type == type &&
      other.kind == kind &&
      other.coverUrl == coverUrl &&
      other.intro == intro &&
      other.wordCount == wordCount &&
      other.latestChapterTitle == latestChapterTitle &&
      other.chapterWordCount == chapterWordCount;

  @override
  int get hashCode => Object.hash(
    key,
    name,
    author,
    Object.hashAll(sources),
    type,
    kind,
    coverUrl,
    intro,
    wordCount,
    latestChapterTitle,
    chapterWordCount,
  );
}

/// Merges [books] into one entry per (normalized title, normalized
/// author) group.
///
/// - Group order follows first appearance in [books].
/// - Inside a group, repeated hits from the same source collapse to the
/// first one; the entry order is first-appearance order, unless
/// [sourceOrder] is given — then entries sort by their position in
/// [sourceOrder] (sources missing from [sourceOrder] keep their
/// relative appearance order after the listed ones).
/// - Display fields (cover, intro, …) come from the first entry that
/// actually has them, scanning entries in their final order.
List<MergedSearchBook> mergeSearchBooks(
  List<SearchBook> books, {
  List<String>? sourceOrder,
}) {
  final groups = <String, List<SearchBook>>{};
  for (final book in books) {
    groups
        .putIfAbsent(legadoMergeKey(book.name, book.author), () => [])
        .add(book);
  }
  return <MergedSearchBook>[
    for (final entry in groups.entries)
      _mergeGroup(entry.key, entry.value, sourceOrder),
  ];
}

MergedSearchBook _mergeGroup(
  String key,
  List<SearchBook> group,
  List<String>? sourceOrder,
) {
  // One entry per source, first hit wins.
  final seen = <String>{};
  final unique = <SearchBook>[
    for (final book in group)
      if (seen.add(book.origin)) book,
  ];
  var ordered = unique;
  if (sourceOrder != null && sourceOrder.isNotEmpty) {
    final rank = <String, int>{
      for (var i = 0; i < sourceOrder.length; i++) sourceOrder[i]: i,
    };
    final indexed = <(int, SearchBook)>[
      for (var i = 0; i < unique.length; i++) (i, unique[i]),
    ];
    indexed.sort((a, b) {
      final rankA = rank[a.$2.origin] ?? (1 << 30);
      final rankB = rank[b.$2.origin] ?? (1 << 30);
      if (rankA != rankB) return rankA.compareTo(rankB);
      return a.$1.compareTo(b.$1);
    });
    ordered = <SearchBook>[for (final e in indexed) e.$2];
  }

  String? firstText(String? Function(SearchBook) pick) {
    for (final book in ordered) {
      final value = pick(book);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  final primaryBook = ordered.first;
  return MergedSearchBook(
    key: key,
    name: primaryBook.name,
    author: primaryBook.author,
    sources: <MergedSourceEntry>[
      for (final book in ordered) MergedSourceEntry.fromSearchBook(book),
    ],
    type: primaryBook.type,
    kind: firstText((b) => b.kind),
    coverUrl: firstText((b) => b.coverUrl),
    intro: firstText((b) => b.intro),
    wordCount: firstText((b) => b.wordCount),
    latestChapterTitle: firstText((b) => b.latestChapterTitle),
    chapterWordCount: primaryBook.chapterWordCount,
  );
}

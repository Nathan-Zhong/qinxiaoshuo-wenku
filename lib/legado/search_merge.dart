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

/// Whether [value] carries codepoints that cannot render as visible
/// glyphs in a book title: private-use-area characters (the classic
/// signature of a site's font-based anti-scraping obfuscation, where
/// list pages serve glyphs only their custom font can draw),
/// variation selectors, zero-width and bidi controls, and C0/C1
/// control codes. Such characters occupy full-width slots in the
/// discovery shelf while drawing nothing, which reads as dropped
/// characters and broken spacing.
bool legadoHasInvisibleChars(String value) => value.runes.any(_isInvisibleRune);

/// [value] with every invisible codepoint (see
/// [legadoHasInvisibleChars]) removed. Clean text passes through
/// unchanged.
String legadoSanitizeBookText(String value) => legadoHasInvisibleChars(value)
    ? String.fromCharCodes(value.runes.where((r) => !_isInvisibleRune(r)))
    : value;

bool _isInvisibleRune(int rune) =>
    (rune >= 0xe000 && rune <= 0xf8ff) || // Private Use Area
    (rune >= 0xf0000 && rune <= 0xffffd) || // Supplementary PUA-A
    (rune >= 0x100000 && rune <= 0x10fffd) || // Supplementary PUA-B
    (rune >= 0xfe00 && rune <= 0xfe0f) || // Variation Selectors
    (rune >= 0xe0100 && rune <= 0xe01ef) || // Variation Selectors Supplement
    rune == 0x200b ||
    rune == 0x200c ||
    rune == 0x200d ||
    rune == 0xfeff || // zero-width chars / BOM
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2066 && rune <= 0x2069) || // bidi controls
    (rune < 0x20 && rune != 0x09) ||
    (rune >= 0x7f && rune <= 0x9f); // C0/C1 controls

/// De-duplicates a book/author name polluted by a source's own title
/// element (seen on 漫蛙: the detail title element renders the name
/// twice and the latest chapter twice, and the engine's `@text` rule
/// concatenates every descendant, so the stored name came out as
/// "在超市后门吸烟的二人漫画在超市后门吸烟的二人漫画第54话 第54话").
/// No concatenation happens anywhere in the app — the merge code takes
/// the first non-empty name and the registry only replaces names — so
/// the repetition can only arrive inside one source-supplied string,
/// and it is cleaned where that string enters the registry.
///
/// Three narrow passes, all no-ops on a clean name:
/// 1. a leading segment repeated immediately ("AAAA…" → "AA…"):
///    the longest repeat of at least 4 characters is collapsed, then
///    the scan restarts, so only genuine doubling is removed and a
///    short legitimate repeat ("哈哈") is never touched;
/// 2. a chapter marker repeated at the very end with a space between
///    ("…第54话 第54话" → "…第54话");
/// 3. when (and only when) pass 1 or 2 collapsed something — proof
///    the element is polluted — a trailing chapter marker the site
///    glued onto the name ("…第54话") is stripped as well, since the
///    chapter already has its own `lastChapter` / directory field.
///    The site's own name form is otherwise kept verbatim (the "漫画"
///    suffix in "在超市后门吸烟的二人漫画" is how the source names the
///    book, not a repetition, so it stays).
String legadoDedupeBookName(String value) {
  var text = value.trim();
  if (text.isEmpty) return text;
  var collapsed = false;
  // Pass 1: leading immediate repeat, longest unit first.
  while (true) {
    var hit = false;
    final maxUnit = text.length ~/ 2;
    for (var unit = maxUnit; unit >= 4; unit--) {
      if (text.length < unit * 2) continue;
      final head = text.substring(0, unit);
      if (text.substring(unit, unit * 2) == head) {
        text = text.substring(unit);
        collapsed = true;
        hit = true;
        break;
      }
    }
    if (!hit) break;
  }
  // Pass 2: trailing chapter marker written twice ("第54话 第54话").
  final tailRepeat = RegExp(r'^(.*)\s+(第\d+[话章回集])$');
  final tail = tailRepeat.firstMatch(text);
  if (tail != null && tail.group(1)!.endsWith(tail.group(2)!)) {
    text = tail.group(1)!;
    collapsed = true;
  }
  // Pass 3: trailing chapter marker on a proven-polluted name.
  if (collapsed) {
    final stripped = text
        .replaceFirst(RegExp(r'第\d+[话章回集]$'), '')
        .trim();
    if (stripped.isNotEmpty) text = stripped;
  }
  return text;
}

/// Grouping key for a book: normalized title + normalized author +
/// media bucket.
///
/// The media bucket was added in fix2 (2026-11-03): without it, the
/// manga edition of a book (engine BookType image bit, `1 shl 6`) was
/// merged into the same entry as the text edition of the same
/// title+author and became invisible in the result list — the entry
/// renders from its primary (text) record and the host `Novel` model
/// carries no type marker. Text editions still merge across sources
/// with each other, and manga editions with each other, which keeps
/// the Q9 "same book, one entry, switch source inside" behaviour
/// within each medium. [type] is the engine BookType bitmask of the
/// book (see `legadoImageBookTypeBit` in legado_novel_repository.dart;
/// the constant is mirrored here to avoid an import cycle).
String legadoMergeKey(String name, String author, {int type = 0}) =>
    '${_normalize(name)}\u0000${_normalize(author)}\u0000'
    '${type & (1 << 6) != 0 ? 'img' : 'txt'}';

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
        .putIfAbsent(
          legadoMergeKey(book.name, book.author, type: book.type),
          () => [],
        )
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

/// Relevance ordering for merged search results (fix4, 2026-11-04).
///
/// Mirrors the fork SearchModel's own aggregate ordering
/// (`SearchModel.rebuildAggregate`), which the bridge's per-source
/// session shape cannot apply across sources: each unit aggregates
/// only its own source, and the host concatenates units in scope
/// order — so without this pass a book's position was decided by
/// which source happened to be listed first, not by how well it
/// matches the keyword (a manga whose source sat late in the list
/// trailed pages of loosely-related novels).
///
/// Tiers, exactly as the fork computes them:
/// 1. title or author EQUALS the keyword;
/// 2. title or author CONTAINS the keyword;
/// 3. everything else.
/// Tiers 1–2 order by merged source count, descending (more sources
/// carrying the same book = the canonical hit), ties keep arrival
/// order; tier 3 keeps pure arrival order. Text and manga entries
/// rank identically — the media bucket only separates entries, it
/// never demotes one.
///
/// One deliberate refinement over the fork's raw-string compare,
/// inherited from this file's merge normalization so ordering agrees
/// with grouping: comparisons run on [legadoNormalizeTitle] output
/// (full/half width folded, case folded, whitespace and punctuation
/// stripped), so a title that differs from the keyword only by such
/// decoration (「斗破·苍穹」, trailing spaces, full-width forms)
/// still counts as an exact hit instead of dropping to contains.
///
/// Pure and stable: safe to re-apply on every streaming snapshot —
/// an entry's tier never worsens as more sources report, so results
/// settle toward the top instead of reshuffling.
List<MergedSearchBook> orderMergedSearchResults(
  List<MergedSearchBook> merged,
  String keyword,
) {
  final key = legadoNormalizeTitle(keyword.trim());
  if (key.isEmpty || merged.length < 2) return merged;
  int tierOf(MergedSearchBook book) {
    final name = legadoNormalizeTitle(book.name);
    final author = legadoNormalizeTitle(book.author);
    if (name == key || author == key) return 0;
    if (name.contains(key) || author.contains(key)) return 1;
    return 2;
  }

  final decorated = <(int, int, MergedSearchBook)>[
    for (var i = 0; i < merged.length; i++) (tierOf(merged[i]), i, merged[i]),
  ];
  decorated.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$1 < 2) {
      final bySources = b.$3.sources.length.compareTo(a.$3.sources.length);
      if (bySources != 0) return bySources;
    }
    return a.$2.compareTo(b.$2);
  });
  return <MergedSearchBook>[for (final entry in decorated) entry.$3];
}

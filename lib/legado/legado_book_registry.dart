import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../book_identity.dart';
import '../catalog.dart';
import 'legado_dto.dart';
import 'search_merge.dart';

/// Host-side identity range for Legado engine books.
///
/// Wenku online ids are small positive ints and local books own
/// [localBookIdStart] and above; engine books live in between so every
/// host mechanism keyed by `Novel.id` (shelf, reading positions,
/// bookmarks, offline cache) treats them as ordinary online books while
/// the dispatch repository can still route them to the engine.
const int legadoBookIdBase = 0x40000000;

bool isLegadoBookId(int id) => id >= legadoBookIdBase && !isLocalBook(id);

/// The fork's `BookType.image` bit. Mirrors `legadoImageBookTypeBit`
/// in legado_novel_repository.dart (kept local to avoid an import
/// cycle; same convention as search_merge.dart).
const int _imageBookTypeBit = 1 << 6;

/// Deterministic cover colour pairs (same role as the hand-picked pairs
/// on the demo/wenku novels): books whose cover image cannot be loaded
/// fall back to the host's generated cover in these colours.
const List<List<Color>> _coverPalettes = [
  [Color(0xFF5E87B8), Color(0xFF222C5B)],
  [Color(0xFF66C9BC), Color(0xFF276A8F)],
  [Color(0xFFE6A5B7), Color(0xFF8F658E)],
  [Color(0xFFE9B277), Color(0xFFB76E6E)],
  [Color(0xFF7FB069), Color(0xFF2D4A22)],
  [Color(0xFF9B5DE5), Color(0xFF3A1C71)],
  [Color(0xFFEF476F), Color(0xFF7F1D3A)],
  [Color(0xFF118AB2), Color(0xFF073B4C)],
  [Color(0xFFF4A261), Color(0xFF9C6644)],
  [Color(0xFF6D8EA0), Color(0xFF2F3E46)],
];

List<Color> legadoCoverColors(String bookKey) {
  var hash = 0x811c9dc5;
  for (final unit in bookKey.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return _coverPalettes[hash % _coverPalettes.length];
}

/// One engine book as the host knows it: a single (origin, bookUrl)
/// locating record plus the display fields gathered from search results
/// and `getBookInfo`. Records are the registry's unit of identity; a
/// merge group (same normalized title + author) links the records of
/// one book across its sources.
class LegadoBookRecord {
  LegadoBookRecord({
    required this.id,
    required this.origin,
    required this.bookUrl,
    this.originName = '',
    this.tocUrl = '',
    this.type = 0,
    this.name = '',
    this.author = '',
    this.kind,
    this.coverUrl,
    this.intro,
    this.wordCount,
    this.latestChapterTitle,
    this.variable,
    this.totalChapterNum = 0,
    this.imageStyle,
  });

  final int id;

  /// The source id (`BookSource.bookSourceUrl`).
  final String origin;
  final String bookUrl;
  String originName;
  String tocUrl;
  int type;
  String name;
  String author;
  String? kind;
  String? coverUrl;
  String? intro;
  String? wordCount;
  String? latestChapterTitle;
  String? variable;
  int totalChapterNum;

  /// The book's source content-rule image style (fix7), absorbed from
  /// bridge book snapshots. A non-blank value on a TEXT-type book is
  /// the gate that lets the reader probe its chapters for all-image
  /// content (copymanga-style sources); the book's identity and type
  /// are unchanged.
  String? imageStyle;

  String get bookKey => '$origin\n$bookUrl';

  SearchBook toSearchBook() => SearchBook(
    name: name,
    author: author,
    bookUrl: bookUrl,
    tocUrl: tocUrl,
    origin: origin,
    originName: originName,
    type: type,
    kind: kind,
    coverUrl: coverUrl,
    intro: intro,
    wordCount: wordCount,
    latestChapterTitle: latestChapterTitle,
    variable: variable,
    imageStyle: imageStyle,
  );

  BookInfo toBookInfo() => BookInfo.fromSearchBook(toSearchBook());

  Novel toNovel() => Novel(
    id: id,
    title: name,
    author: author,
    genre: kind ?? '',
    summary: intro ?? '',
    colors: legadoCoverColors(bookKey),
    coverUrl: coverUrl,
    chapterCount: totalChapterNum,
    isComplete: (kind ?? '').contains('完结'),
  );

  /// Refreshes display fields from a search/explore hit; empty incoming
  /// values never erase richer data an earlier hit or `getBookInfo`
  /// already provided.
  void absorbSearchBook(SearchBook book) {
    name = _absorbDisplayText(name, book.name);
    author = _absorbDisplayText(author, book.author);
    if (book.originName.isNotEmpty) originName = book.originName;
    if (book.tocUrl.isNotEmpty) tocUrl = book.tocUrl;
    // fix4: the image bit is sticky. Whether a book is a manga is a
    // property of its SOURCE, and the search/explore hits stamp it
    // correctly; a later absorb must never strip it back off. (The
    // bridge used to rebuild the book for getBookInfo/getChapterList
    // without the source's type, so every detail open silently
    // reclassified a manga as text and the reader fell back to the
    // image-chapter notice. The bridge now stamps the type too; this
    // guard keeps any single type-losing hop from ever re-poisoning a
    // record.) The engine's own isImageChapter verdict still wins at
    // read time, so a wrongly-kept bit costs at most one probe fetch.
    type = book.type | (type & _imageBookTypeBit);
    kind = book.kind ?? kind;
    coverUrl = book.coverUrl ?? coverUrl;
    intro = book.intro ?? intro;
    wordCount = book.wordCount ?? wordCount;
    latestChapterTitle = book.latestChapterTitle ?? latestChapterTitle;
    variable = book.variable ?? variable;
    // fix7: the image style is a property of the book's SOURCE (like
    // the type above); a hop that does not carry it (plain search
    // hits) must never erase a value a book snapshot provided.
    if (book.imageStyle != null && book.imageStyle!.isNotEmpty) {
      imageStyle = book.imageStyle;
    }
  }

  void absorbBookInfo(BookInfo info) {
    absorbSearchBook(info.toSearchBookView());
    if (info.tocUrl.isNotEmpty) tocUrl = info.tocUrl;
    if (info.totalChapterNum > 0) totalChapterNum = info.totalChapterNum;
  }

  /// Display-text absorb rule (fix2, 2026-11-03). Some sites serve
  /// list/explore pages with font-obfuscated text: characters drawn
  /// from the private use area that only the site's own webfont can
  /// render. In the app they draw nothing while still occupying
  /// full-width slots, so titles looked like characters had been
  /// dropped at random (the detail page, which serves the real title,
  /// was unaffected — shelf and bookmark pages, fed by detail data,
  /// displayed the same book correctly).
  ///
  /// Rules: a clean incoming value refreshes as before; a damaged
  /// incoming value never replaces a clean value already held, and
  /// when nothing clean is held the invisible codepoints are stripped
  /// so what remains at least renders without phantom gaps (the
  /// discovery prefetch then repairs the full text from the detail
  /// page in the background).
  static String _absorbDisplayText(String current, String incoming) {
    if (incoming.isEmpty) return current;
    if (!legadoHasInvisibleChars(incoming)) return incoming;
    if (current.isNotEmpty && !legadoHasInvisibleChars(current)) {
      return current;
    }
    final stripped = legadoSanitizeBookText(incoming);
    return stripped.isNotEmpty ? stripped : current;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'origin': origin,
    'bookUrl': bookUrl,
    'originName': originName,
    'tocUrl': tocUrl,
    'type': type,
    'name': name,
    'author': author,
    'kind': kind,
    'coverUrl': coverUrl,
    'intro': intro,
    'wordCount': wordCount,
    'latestChapterTitle': latestChapterTitle,
    'variable': variable,
    'totalChapterNum': totalChapterNum,
    'imageStyle': imageStyle,
  };

  factory LegadoBookRecord.fromJson(Map<String, dynamic> json) {
    return LegadoBookRecord(
      id: json['id'] as int,
      origin: json['origin'] as String,
      bookUrl: json['bookUrl'] as String,
      originName: json['originName'] as String? ?? '',
      tocUrl: json['tocUrl'] as String? ?? '',
      type: json['type'] as int? ?? 0,
      // Records persisted before fix2 may hold font-obfuscated titles;
      // sanitize on load so they self-heal.
      name: legadoSanitizeBookText(json['name'] as String? ?? ''),
      author: legadoSanitizeBookText(json['author'] as String? ?? ''),
      kind: json['kind'] as String?,
      coverUrl: json['coverUrl'] as String?,
      intro: json['intro'] as String?,
      wordCount: json['wordCount'] as String?,
      latestChapterTitle: json['latestChapterTitle'] as String?,
      variable: json['variable'] as String?,
      totalChapterNum: json['totalChapterNum'] as int? ?? 0,
      imageStyle: json['imageStyle'] as String?,
    );
  }
}

/// Small extension so [LegadoBookRecord.absorbBookInfo] can reuse the
/// search-book absorption for the shared display fields.
extension on BookInfo {
  SearchBook toSearchBookView() => SearchBook(
    name: name,
    author: author,
    bookUrl: bookUrl,
    tocUrl: tocUrl,
    origin: origin,
    originName: originName,
    type: type,
    kind: kind,
    coverUrl: coverUrl,
    intro: intro,
    wordCount: wordCount,
    latestChapterTitle: latestChapterTitle,
    chapterWordCount: chapterWordCount,
    variable: variable,
    imageStyle: imageStyle,
  );
}

/// Persistent registry of every engine book the host has seen.
///
/// Owns the int-id allocation inside [legadoBookIdBase] range, the
/// merge groups used by the detail page's source list, and a persisted
/// copy of each book's chapter list so a book reopened from the shelf
/// can rebuild its directory even before the engine answers (and as a
/// fallback when a fetch fails).
class LegadoBookRegistry extends ChangeNotifier {
  LegadoBookRegistry({Future<SharedPreferences>? preferences})
    : _prefsFuture = preferences ?? SharedPreferences.getInstance() {
    _ready = _load();
  }

  static const String _registryKey = 'legado_registry_v1';
  static String _tocKey(int id) => 'legado_toc_v1_$id';

  final Future<SharedPreferences> _prefsFuture;
  late final Future<void> _ready;
  SharedPreferences? _prefs;
  bool _loaded = false;

  final Map<int, LegadoBookRecord> _records = {};
  final Map<String, int> _idByBookKey = {};

  /// Merge group key -> entry ids in display order (primary first).
  final Map<String, List<int>> _groups = {};
  final Map<int, String> _groupById = {};
  final Map<int, List<Chapter>> _tocs = {};
  int _nextSeq = 0;
  Timer? _persistTimer;

  /// Monotonic persist generations (fix3): a background-isolate encode
  /// can finish after a newer persist was scheduled; only the latest
  /// generation may write, so a stale encode never overwrites fresher
  /// state.
  int _persistSeq = 0;
  final Map<int, int> _tocPersistSeq = {};

  /// Completes once the persisted state has been read. All mutating or
  /// allocating operations await it internally; synchronous lookups are
  /// only meaningful after it (the UI paths that use them run after a
  /// repository call, which awaits it too).
  ///
  /// Once [_loaded] is set this returns a fresh, already-complete
  /// future instead of the load future itself: the load future belongs
  /// to whichever zone happened to construct the registry, and handing
  /// it out forever would couple every later caller to that zone.
  Future<void> get ready => _loaded ? Future<void>.value() : _ready;
  bool get loaded => _loaded;

  Future<void> _load() async {
    try {
      _prefs = await _prefsFuture;
      final raw = _prefs!.getString(_registryKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _nextSeq = decoded['nextSeq'] as int? ?? 0;
          final entries = decoded['entries'];
          if (entries is List) {
            for (final item in entries) {
              if (item is Map<String, dynamic>) {
                try {
                  final record = LegadoBookRecord.fromJson(item);
                  _records[record.id] = record;
                  _idByBookKey[record.bookKey] = record.id;
                } catch (_) {
                  // One damaged record never blocks the rest.
                }
              }
            }
          }
          final groups = decoded['groups'];
          if (groups is Map<String, dynamic>) {
            for (final entry in groups.entries) {
              final ids = entry.value;
              if (ids is List) {
                final list = <int>[
                  for (final id in ids)
                    if (id is int && _records.containsKey(id)) id,
                ];
                if (list.isNotEmpty) {
                  _groups[entry.key] = list;
                  for (final id in list) {
                    _groupById[id] = entry.key;
                  }
                }
              }
            }
          }
        }
      }
    } catch (_) {
      // A damaged registry degrades to "no known books"; shelf snapshots
      // in LibraryState are independent and survive regardless.
    }
    _loaded = true;
    notifyListeners();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persist());
    });
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null || !_loaded) return;
    try {
      final payload = <String, Object?>{
        'nextSeq': _nextSeq,
        'entries': [for (final record in _records.values) record.toJson()],
        'groups': {
          for (final entry in _groups.entries) entry.key: entry.value,
        },
      };
      // fix3 (performance): the whole-registry JSON encode used to run
      // on the UI isolate on every debounced persist; with a few
      // hundred registered books that is a visible hitch during search
      // and discovery browsing. Large payloads are encoded in a
      // background isolate instead (the payload is plain JSON values,
      // safe to send across). Small registries keep the synchronous
      // path — cheaper than spawning an isolate, and identical output.
      final entries = payload['entries'] as List<Object?>;
      final seq = ++_persistSeq;
      final encoded = entries.length > 100
          ? await compute(jsonEncode, payload)
          : jsonEncode(payload);
      if (seq != _persistSeq) return; // superseded while encoding
      await prefs.setString(_registryKey, encoded);
    } catch (_) {
      // Persistence is best-effort; in-memory state stays authoritative
      // for this process.
    }
  }

  /// Flushes any pending registry write (used by tests and shutdown).
  Future<void> flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    await _persist();
  }

  int _allocateId() {
    final id = legadoBookIdBase + _nextSeq;
    _nextSeq++;
    return id;
  }

  LegadoBookRecord _upsert(SearchBook book) {
    final existing = _idByBookKey[book.bookKey];
    if (existing != null) {
      final record = _records[existing]!;
      record.absorbSearchBook(book);
      return record;
    }
    final record = LegadoBookRecord(
      id: _allocateId(),
      origin: book.origin,
      bookUrl: book.bookUrl,
      originName: book.originName,
      tocUrl: book.tocUrl,
      type: book.type,
      // Sanitized on the way in (fix2): a font-obfuscated list title
      // is stored without its invisible codepoints; see
      // _absorbDisplayText for the full rule.
      name: legadoSanitizeBookText(book.name),
      author: legadoSanitizeBookText(book.author),
      kind: book.kind,
      coverUrl: book.coverUrl,
      intro: book.intro,
      wordCount: book.wordCount,
      latestChapterTitle: book.latestChapterTitle,
      variable: book.variable,
      imageStyle: book.imageStyle,
    );
    _records[record.id] = record;
    _idByBookKey[record.bookKey] = record.id;
    final key = legadoMergeKey(book.name, book.author, type: book.type);
    final group = _groups.putIfAbsent(key, () => <int>[]);
    if (!group.contains(record.id)) group.add(record.id);
    _groupById[record.id] = key;
    return record;
  }

  /// Registers one standalone hit (explore lists, one-shot searches):
  /// the book joins its merge group without disturbing the group's
  /// established order. Returns the record.
  Future<LegadoBookRecord> registerSearchBook(SearchBook book) async {
    await ready;
    final record = _upsert(book);
    _schedulePersist();
    notifyListeners();
    return record;
  }

  /// Registers a merged search result: every source entry is upserted
  /// and the group's order becomes the merge order (previously known
  /// entries that are missing from this snapshot keep their place at
  /// the end). Returns the records in display order.
  Future<List<LegadoBookRecord>> registerMerged(MergedSearchBook merged) async {
    await ready;
    final records = <LegadoBookRecord>[
      for (final source in merged.sources)
        _upsert(
          SearchBook(
            name: merged.name,
            author: merged.author,
            bookUrl: source.bookUrl,
            tocUrl: source.tocUrl,
            origin: source.origin,
            originName: source.originName,
            type: source.type,
            kind: merged.kind,
            coverUrl: merged.coverUrl,
            intro: merged.intro,
            wordCount: merged.wordCount,
            latestChapterTitle: merged.latestChapterTitle,
            chapterWordCount: merged.chapterWordCount,
            variable: source.variable,
          ),
        ),
    ];
    final orderedIds = [for (final record in records) record.id];
    final previous = _groups[merged.key] ?? const <int>[];
    final mergedOrder = <int>[
      ...orderedIds,
      for (final id in previous)
        if (!orderedIds.contains(id)) id,
    ];
    _groups[merged.key] = mergedOrder;
    for (final id in mergedOrder) {
      _groupById[id] = merged.key;
    }
    _schedulePersist();
    notifyListeners();
    return [for (final id in mergedOrder) _records[id]!];
  }

  LegadoBookRecord? recordById(int id) => _records[id];

  /// Every registered record, in allocation order.
  List<LegadoBookRecord> get allRecords {
    final records = _records.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(records);
  }

  Future<LegadoBookRecord?> recordByIdAsync(int id) async {
    await ready;
    return _records[id];
  }

  Novel? novelById(int id) => _records[id]?.toNovel();

  /// All records of the merge group [id] belongs to, in display order
  /// (the record itself first when no group information exists).
  List<LegadoBookRecord> groupOf(int id) {
    final key = _groupById[id];
    if (key == null) {
      final record = _records[id];
      return record == null ? const [] : [record];
    }
    return <LegadoBookRecord>[
      for (final member in _groups[key] ?? const <int>[])
        if (_records[member] != null) _records[member]!,
    ];
  }

  void absorbBookInfo(BookInfo info) {
    final id = _idByBookKey[info.bookKey];
    if (id == null) return;
    _records[id]!.absorbBookInfo(info);
    _schedulePersist();
    notifyListeners();
  }

  // -------------------------------------------------------------------
  // Chapter lists (table D snapshots per book)
  // -------------------------------------------------------------------

  Future<void> saveToc(int id, List<Chapter> chapters) async {
    await ready;
    _tocs[id] = List.unmodifiable(chapters);
    final record = _records[id];
    if (record != null && chapters.isNotEmpty) {
      record.totalChapterNum = chapters.where((c) => !c.isVolume).length;
    }
    notifyListeners();
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      // Same fix3 rule as the registry blob: long chapter lists are
      // encoded off the UI isolate, latest generation wins.
      final maps = [for (final chapter in chapters) chapter.toMap()];
      final seq = (_tocPersistSeq[id] ?? 0) + 1;
      _tocPersistSeq[id] = seq;
      final encoded = maps.length > 300
          ? await compute(jsonEncode, maps)
          : jsonEncode(maps);
      if (_tocPersistSeq[id] != seq) return;
      await prefs.setString(_tocKey(id), encoded);
    } catch (_) {
      // Same best-effort rule as the registry blob.
    }
  }

  /// The last chapter list fetched (or persisted) for [id], if any.
  Future<List<Chapter>?> tocOf(int id) async {
    await ready;
    final cached = _tocs[id];
    if (cached != null) return cached;
    final prefs = _prefs;
    if (prefs == null) return null;
    try {
      final raw = prefs.getString(_tocKey(id));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final chapters = <Chapter>[
        for (final item in decoded)
          if (item is Map) Chapter.fromMap(item.cast<Object?, Object?>()),
      ];
      _tocs[id] = List.unmodifiable(chapters);
      return _tocs[id];
    } catch (_) {
      return null;
    }
  }

  /// The engine chapter behind a host [NovelChapter] (host chapter ids
  /// are `Chapter.index + 1`; see [novelChaptersOf]).
  Future<Chapter?> dtoChapter(int id, int novelChapterId) async {
    final toc = await tocOf(id);
    if (toc == null) return null;
    for (final chapter in toc) {
      if (chapter.index + 1 == novelChapterId) return chapter;
    }
    return null;
  }
}

/// Maps an engine chapter list onto host chapters: volume headings
/// become the volume metadata of the chapters that follow them (the
/// host directory renders volume rows from that metadata), and each
/// chapter's host id is its engine index + 1.
List<NovelChapter> legadoNovelChapters(List<Chapter> chapters) {
  final result = <NovelChapter>[];
  var volumeId = 0;
  var volumeTitle = '';
  for (final chapter in chapters) {
    if (chapter.isVolume) {
      volumeId++;
      volumeTitle = chapter.title;
      continue;
    }
    result.add(
      NovelChapter(
        chapter.title,
        '',
        id: chapter.index + 1,
        volumeId: volumeId,
        volumeTitle: volumeTitle,
      ),
    );
  }
  return result;
}

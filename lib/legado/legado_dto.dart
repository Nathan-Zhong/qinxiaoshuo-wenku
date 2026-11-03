import 'package:flutter/foundation.dart';

/// DTOs exchanged with the Legado engine over the platform channels.
///
/// Field sets follow the bridge draft in ENGINE-study.md §4.3 (tables A–G)
/// one-to-one. All values are StandardMessageCodec-safe types; maps arriving
/// from the native side are `Map<Object?, Object?>`, so every `fromMap`
/// accepts a plain [Map] and coerces defensively.
///
/// The `variable` fields are opaque engine state: they must be stored
/// verbatim and passed back unchanged, otherwise some sources fail to
/// resolve their book info (ENGINE-study table B note).

Map<String, Object?> _keyed(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return const <String, Object?>{};
}

String _str(Map<String, Object?> map, String key, [String fallback = '']) {
  final value = map[key];
  if (value is String) return value;
  if (value == null) return fallback;
  return value.toString();
}

String? _strOrNull(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  return value is String ? value : value.toString();
}

int _int(Map<String, Object?> map, String key, [int fallback = 0]) {
  final value = map[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool _bool(Map<String, Object?> map, String key, [bool fallback = false]) {
  final value = map[key];
  if (value is bool) return value;
  if (value is num) return value != 0;
  return fallback;
}

double _double(Map<String, Object?> map, String key, [double fallback = 0]) {
  final value = map[key];
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

List<String> _strList(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is List) {
    return <String>[
      for (final item in value)
        if (item != null) '$item',
    ];
  }
  return const <String>[];
}

List<T> _mapList<T>(
  Map<String, Object?> map,
  String key,
  T Function(Map<String, Object?>) decode,
) {
  final value = map[key];
  if (value is List) {
    return <T>[for (final item in value) decode(_keyed(item))];
  }
  return <T>[];
}

Map<String, String> _strMap(Map<String, Object?> map, String key) {
  final value = _keyed(map[key]);
  return <String, String>{
    for (final entry in value.entries) entry.key: entry.value?.toString() ?? '',
  };
}

/// Table A — a book source as shown in source lists / management pages.
/// Full source JSON is only carried by [sourceJson] on single-source reads.
class BookSourceSummary {
  const BookSourceSummary({
    required this.sourceUrl,
    required this.sourceName,
    this.group,
    this.type = 0,
    this.enabled = true,
    this.enabledExplore = false,
    this.customOrder = 0,
    this.weight = 0,
    this.respondTimeMs = 0,
    this.lastUpdateTime = 0,
    this.hasLogin = false,
    this.comment,
    this.icon,
    this.exploreKindCount,
    this.sourceJson,
    this.hasSearch = true,
  });

  /// Primary key (`BookSource.bookSourceUrl`); doubles as a book's origin.
  final String sourceUrl;
  final String sourceName;
  final String? group;

  /// 0 = text, 2 = image/manga. Other values are filtered out by the UI
  /// layer per PLAN item 5.
  final int type;
  final bool enabled;
  final bool enabledExplore;
  final int customOrder;
  final int weight;
  final int respondTimeMs;
  final int lastUpdateTime;
  final bool hasLogin;
  final String? comment;
  final String? icon;
  final int? exploreKindCount;

  /// Full source JSON, only present on `getSource` results.
  final String? sourceJson;

  /// Whether the source can search at all (non-blank `searchUrl`).
  /// Added in fix3: the app search scope excludes sources without a
  /// search URL — including one only ever produced the engine's
  /// 「搜索url不能为空」 error inside the shared search round. Maps
  /// from older native builds lack the key and default to true.
  final bool hasSearch;

  factory BookSourceSummary.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return BookSourceSummary(
      sourceUrl: _str(m, 'sourceUrl'),
      sourceName: _str(m, 'sourceName'),
      group: _strOrNull(m, 'group'),
      type: _int(m, 'type'),
      enabled: _bool(m, 'enabled', true),
      enabledExplore: _bool(m, 'enabledExplore'),
      customOrder: _int(m, 'customOrder'),
      weight: _int(m, 'weight'),
      respondTimeMs: _int(m, 'respondTimeMs'),
      lastUpdateTime: _int(m, 'lastUpdateTime'),
      hasLogin: _bool(m, 'hasLogin'),
      comment: _strOrNull(m, 'comment'),
      icon: _strOrNull(m, 'icon'),
      exploreKindCount: m['exploreKindCount'] == null
          ? null
          : _int(m, 'exploreKindCount'),
      sourceJson: _strOrNull(m, 'sourceJson'),
      hasSearch: _bool(m, 'hasSearch', true),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'sourceUrl': sourceUrl,
    'sourceName': sourceName,
    'group': group,
    'type': type,
    'enabled': enabled,
    'enabledExplore': enabledExplore,
    'customOrder': customOrder,
    'weight': weight,
    'respondTimeMs': respondTimeMs,
    'lastUpdateTime': lastUpdateTime,
    'hasLogin': hasLogin,
    'comment': comment,
    'icon': icon,
    'exploreKindCount': exploreKindCount,
    'sourceJson': sourceJson,
    'hasSearch': hasSearch,
  };

  @override
  bool operator ==(Object other) =>
      other is BookSourceSummary &&
      other.sourceUrl == sourceUrl &&
      other.sourceName == sourceName &&
      other.group == group &&
      other.type == type &&
      other.enabled == enabled &&
      other.enabledExplore == enabledExplore &&
      other.customOrder == customOrder &&
      other.weight == weight &&
      other.respondTimeMs == respondTimeMs &&
      other.lastUpdateTime == lastUpdateTime &&
      other.hasLogin == hasLogin &&
      other.comment == comment &&
      other.icon == icon &&
      other.exploreKindCount == exploreKindCount &&
      other.sourceJson == sourceJson &&
      other.hasSearch == hasSearch;

  @override
  int get hashCode => Object.hash(
    sourceUrl,
    sourceName,
    group,
    type,
    enabled,
    enabledExplore,
    customOrder,
    weight,
    respondTimeMs,
    lastUpdateTime,
    hasLogin,
    comment,
    icon,
    exploreKindCount,
    sourceJson,
    hasSearch,
  );
}

/// Table B — one search/explore result row. The engine's SearchModel
/// already aggregates the same book across sources; [origins] then holds
/// every source that found it. Dart-side merging of raw per-source
/// results lives in `search_merge.dart`.
class SearchBook {
  const SearchBook({
    required this.name,
    required this.author,
    required this.bookUrl,
    required this.origin,
    this.tocUrl = '',
    this.originName = '',
    this.origins = const <String>[],
    this.type = 0,
    this.kind,
    this.coverUrl,
    this.intro,
    this.wordCount,
    this.latestChapterTitle,
    this.chapterWordCount = 0,
    this.variable,
  });

  final String name;
  final String author;
  final String bookUrl;
  final String tocUrl;

  /// The source this row's [bookUrl]/[tocUrl]/[variable] belong to
  /// (`BookSource.bookSourceUrl`).
  final String origin;
  final String originName;

  /// All sources carrying this book after aggregation (includes [origin]).
  final List<String> origins;
  final int type;
  final String? kind;
  final String? coverUrl;
  final String? intro;
  final String? wordCount;
  final String? latestChapterTitle;
  final int chapterWordCount;

  /// Opaque per-source state; pass back verbatim to `getBookInfo`.
  final String? variable;

  /// Engine-side identity of a book: `origin + "\n" + bookUrl`.
  String get bookKey => '$origin\n$bookUrl';

  factory SearchBook.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return SearchBook(
      name: _str(m, 'name'),
      author: _str(m, 'author'),
      bookUrl: _str(m, 'bookUrl'),
      tocUrl: _str(m, 'tocUrl'),
      origin: _str(m, 'origin'),
      originName: _str(m, 'originName'),
      origins: _strList(m, 'origins'),
      type: _int(m, 'type'),
      kind: _strOrNull(m, 'kind'),
      coverUrl: _strOrNull(m, 'coverUrl'),
      intro: _strOrNull(m, 'intro'),
      wordCount: _strOrNull(m, 'wordCount'),
      latestChapterTitle: _strOrNull(m, 'latestChapterTitle'),
      chapterWordCount: _int(m, 'chapterWordCount'),
      variable: _strOrNull(m, 'variable'),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'name': name,
    'author': author,
    'bookUrl': bookUrl,
    'tocUrl': tocUrl,
    'origin': origin,
    'originName': originName,
    'origins': origins,
    'type': type,
    'kind': kind,
    'coverUrl': coverUrl,
    'intro': intro,
    'wordCount': wordCount,
    'latestChapterTitle': latestChapterTitle,
    'chapterWordCount': chapterWordCount,
    'variable': variable,
  };

  SearchBook copyWith({
    String? name,
    String? author,
    String? bookUrl,
    String? tocUrl,
    String? origin,
    String? originName,
    List<String>? origins,
    int? type,
    String? kind,
    String? coverUrl,
    String? intro,
    String? wordCount,
    String? latestChapterTitle,
    int? chapterWordCount,
    String? variable,
  }) {
    return SearchBook(
      name: name ?? this.name,
      author: author ?? this.author,
      bookUrl: bookUrl ?? this.bookUrl,
      tocUrl: tocUrl ?? this.tocUrl,
      origin: origin ?? this.origin,
      originName: originName ?? this.originName,
      origins: origins ?? this.origins,
      type: type ?? this.type,
      kind: kind ?? this.kind,
      coverUrl: coverUrl ?? this.coverUrl,
      intro: intro ?? this.intro,
      wordCount: wordCount ?? this.wordCount,
      latestChapterTitle: latestChapterTitle ?? this.latestChapterTitle,
      chapterWordCount: chapterWordCount ?? this.chapterWordCount,
      variable: variable ?? this.variable,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SearchBook &&
      other.name == name &&
      other.author == author &&
      other.bookUrl == bookUrl &&
      other.tocUrl == tocUrl &&
      other.origin == origin &&
      other.originName == originName &&
      listEquals(other.origins, origins) &&
      other.type == type &&
      other.kind == kind &&
      other.coverUrl == coverUrl &&
      other.intro == intro &&
      other.wordCount == wordCount &&
      other.latestChapterTitle == latestChapterTitle &&
      other.chapterWordCount == chapterWordCount &&
      other.variable == variable;

  @override
  int get hashCode => Object.hash(
    name,
    author,
    bookUrl,
    tocUrl,
    origin,
    originName,
    Object.hashAll(origins),
    type,
    kind,
    coverUrl,
    intro,
    wordCount,
    latestChapterTitle,
    chapterWordCount,
    variable,
  );
}

/// Table C — an engine book snapshot after `getBookInfo`. The host keeps
/// the full snapshot and sends `origin/bookUrl/tocUrl/variable/name/author`
/// back verbatim when asking for chapters or content.
class BookInfo {
  const BookInfo({
    required this.name,
    required this.author,
    required this.bookUrl,
    required this.origin,
    this.tocUrl = '',
    this.originName = '',
    this.origins = const <String>[],
    this.type = 0,
    this.kind,
    this.coverUrl,
    this.intro,
    this.wordCount,
    this.latestChapterTitle,
    this.chapterWordCount = 0,
    this.variable,
    this.charset,
    this.totalChapterNum = 0,
    this.latestChapterTime = 0,
    this.lastCheckCount = 0,
    this.canUpdate = true,
  });

  final String name;
  final String author;
  final String bookUrl;
  final String tocUrl;
  final String origin;
  final String originName;
  final List<String> origins;
  final int type;
  final String? kind;
  final String? coverUrl;
  final String? intro;
  final String? wordCount;
  final String? latestChapterTitle;
  final int chapterWordCount;
  final String? variable;
  final String? charset;
  final int totalChapterNum;

  /// Milliseconds since epoch.
  final int latestChapterTime;
  final int lastCheckCount;
  final bool canUpdate;

  String get bookKey => '$origin\n$bookUrl';

  factory BookInfo.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return BookInfo(
      name: _str(m, 'name'),
      author: _str(m, 'author'),
      bookUrl: _str(m, 'bookUrl'),
      tocUrl: _str(m, 'tocUrl'),
      origin: _str(m, 'origin'),
      originName: _str(m, 'originName'),
      origins: _strList(m, 'origins'),
      type: _int(m, 'type'),
      kind: _strOrNull(m, 'kind'),
      coverUrl: _strOrNull(m, 'coverUrl'),
      intro: _strOrNull(m, 'intro'),
      wordCount: _strOrNull(m, 'wordCount'),
      latestChapterTitle: _strOrNull(m, 'latestChapterTitle'),
      chapterWordCount: _int(m, 'chapterWordCount'),
      variable: _strOrNull(m, 'variable'),
      charset: _strOrNull(m, 'charset'),
      totalChapterNum: _int(m, 'totalChapterNum'),
      latestChapterTime: _int(m, 'latestChapterTime'),
      lastCheckCount: _int(m, 'lastCheckCount'),
      canUpdate: _bool(m, 'canUpdate', true),
    );
  }

  factory BookInfo.fromSearchBook(SearchBook book) {
    return BookInfo(
      name: book.name,
      author: book.author,
      bookUrl: book.bookUrl,
      tocUrl: book.tocUrl,
      origin: book.origin,
      originName: book.originName,
      origins: book.origins,
      type: book.type,
      kind: book.kind,
      coverUrl: book.coverUrl,
      intro: book.intro,
      wordCount: book.wordCount,
      latestChapterTitle: book.latestChapterTitle,
      chapterWordCount: book.chapterWordCount,
      variable: book.variable,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'name': name,
    'author': author,
    'bookUrl': bookUrl,
    'tocUrl': tocUrl,
    'origin': origin,
    'originName': originName,
    'origins': origins,
    'type': type,
    'kind': kind,
    'coverUrl': coverUrl,
    'intro': intro,
    'wordCount': wordCount,
    'latestChapterTitle': latestChapterTitle,
    'chapterWordCount': chapterWordCount,
    'variable': variable,
    'charset': charset,
    'totalChapterNum': totalChapterNum,
    'latestChapterTime': latestChapterTime,
    'lastCheckCount': lastCheckCount,
    'canUpdate': canUpdate,
  };

  /// The subset of fields the engine needs back to rebuild its `Book`
  /// when fetching the chapter list or chapter content.
  Map<String, Object?> toEngineBookArgs() => <String, Object?>{
    'origin': origin,
    'bookUrl': bookUrl,
    'tocUrl': tocUrl,
    'name': name,
    'author': author,
    if (variable != null) 'variable': variable,
  };

  @override
  bool operator ==(Object other) =>
      other is BookInfo &&
      other.name == name &&
      other.author == author &&
      other.bookUrl == bookUrl &&
      other.tocUrl == tocUrl &&
      other.origin == origin &&
      other.originName == originName &&
      listEquals(other.origins, origins) &&
      other.type == type &&
      other.kind == kind &&
      other.coverUrl == coverUrl &&
      other.intro == intro &&
      other.wordCount == wordCount &&
      other.latestChapterTitle == latestChapterTitle &&
      other.chapterWordCount == chapterWordCount &&
      other.variable == variable &&
      other.charset == charset &&
      other.totalChapterNum == totalChapterNum &&
      other.latestChapterTime == latestChapterTime &&
      other.lastCheckCount == lastCheckCount &&
      other.canUpdate == canUpdate;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    name,
    author,
    bookUrl,
    tocUrl,
    origin,
    originName,
    Object.hashAll(origins),
    type,
    kind,
    coverUrl,
    intro,
    wordCount,
    latestChapterTitle,
    chapterWordCount,
    variable,
    charset,
    totalChapterNum,
    latestChapterTime,
    lastCheckCount,
    canUpdate,
  ]);
}

/// Table D — one chapter of a book's table of contents.
class Chapter {
  const Chapter({
    required this.url,
    required this.title,
    required this.index,
    this.isVolume = false,
    this.isVip = false,
    this.isPay = false,
    this.resourceUrl,
    this.tag,
    this.wordCount,
    this.variable,
  });

  final String url;
  final String title;
  final int index;
  final bool isVolume;
  final bool isVip;
  final bool isPay;
  final String? resourceUrl;
  final String? tag;
  final String? wordCount;

  /// Opaque per-chapter engine state; pass back verbatim.
  final String? variable;

  factory Chapter.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return Chapter(
      url: _str(m, 'url'),
      title: _str(m, 'title'),
      index: _int(m, 'index'),
      isVolume: _bool(m, 'isVolume'),
      isVip: _bool(m, 'isVip'),
      isPay: _bool(m, 'isPay'),
      resourceUrl: _strOrNull(m, 'resourceUrl'),
      tag: _strOrNull(m, 'tag'),
      wordCount: _strOrNull(m, 'wordCount'),
      variable: _strOrNull(m, 'variable'),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'url': url,
    'title': title,
    'index': index,
    'isVolume': isVolume,
    'isVip': isVip,
    'isPay': isPay,
    'resourceUrl': resourceUrl,
    'tag': tag,
    'wordCount': wordCount,
    'variable': variable,
  };

  @override
  bool operator ==(Object other) =>
      other is Chapter &&
      other.url == url &&
      other.title == title &&
      other.index == index &&
      other.isVolume == isVolume &&
      other.isVip == isVip &&
      other.isPay == isPay &&
      other.resourceUrl == resourceUrl &&
      other.tag == tag &&
      other.wordCount == wordCount &&
      other.variable == variable;

  @override
  int get hashCode => Object.hash(
    url,
    title,
    index,
    isVolume,
    isVip,
    isPay,
    resourceUrl,
    tag,
    wordCount,
    variable,
  );
}

/// Result of `getChapterContent`: the cleaned chapter body. For image
/// (manga) chapters [content] still holds the raw HTML/text and [images]
/// carries the extracted image URLs in reading order.
class ChapterContent {
  const ChapterContent({
    required this.content,
    this.images = const <String>[],
    this.isImageChapter = false,
  });

  final String content;
  final List<String> images;
  final bool isImageChapter;

  factory ChapterContent.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return ChapterContent(
      content: _str(m, 'content'),
      images: _strList(m, 'images'),
      isImageChapter: _bool(m, 'isImageChapter'),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'content': content,
    'images': images,
    'isImageChapter': isImageChapter,
  };

  @override
  bool operator ==(Object other) =>
      other is ChapterContent &&
      other.content == content &&
      listEquals(other.images, images) &&
      other.isImageChapter == isImageChapter;

  @override
  int get hashCode =>
      Object.hash(content, Object.hashAll(images), isImageChapter);
}

/// Table F — one explore (discovery) entry of a source. A null [url]
/// marks a group heading row rather than a browsable category.
class ExploreSection {
  const ExploreSection({
    required this.title,
    this.url,
    this.viewName,
    this.style = 0,
  });

  final String title;
  final String? url;
  final String? viewName;
  final int style;

  bool get isGroupHeading => url == null || url!.isEmpty;

  factory ExploreSection.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return ExploreSection(
      title: _str(m, 'title'),
      url: _strOrNull(m, 'url'),
      viewName: _strOrNull(m, 'viewName'),
      style: _int(m, 'style'),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'title': title,
    'url': url,
    'viewName': viewName,
    'style': style,
  };

  @override
  bool operator ==(Object other) =>
      other is ExploreSection &&
      other.title == title &&
      other.url == url &&
      other.viewName == viewName &&
      other.style == style;

  @override
  int get hashCode => Object.hash(title, url, viewName, style);
}

/// One page of an explore book list (`getExploreBooks` result).
class ExploreBookPage {
  const ExploreBookPage({required this.books, this.hasMore = false});

  final List<SearchBook> books;
  final bool hasMore;

  factory ExploreBookPage.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return ExploreBookPage(
      books: _mapList(m, 'books', SearchBook.fromMap),
      hasMore: _bool(m, 'hasMore'),
    );
  }
}

/// Table E — outcome of an import or subscription update, aligned with
/// the engine's three-state comparison (added / updated / unchanged).
class ImportResult {
  const ImportResult({
    this.added = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.failed = 0,
    this.sources = const <BookSourceSummary>[],
    this.errors = const <String>[],
  });

  final int added;
  final int updated;
  final int unchanged;
  final int failed;

  /// Sources that ended up stored by this import.
  final List<BookSourceSummary> sources;
  final List<String> errors;

  factory ImportResult.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return ImportResult(
      added: _int(m, 'added'),
      updated: _int(m, 'updated'),
      unchanged: _int(m, 'unchanged'),
      failed: _int(m, 'failed'),
      sources: _mapList(m, 'sources', BookSourceSummary.fromMap),
      errors: _strList(m, 'errors'),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'added': added,
    'updated': updated,
    'unchanged': unchanged,
    'failed': failed,
    'sources': <Map<String, Object?>>[for (final s in sources) s.toMap()],
    'errors': errors,
  };

  @override
  bool operator ==(Object other) =>
      other is ImportResult &&
      other.added == added &&
      other.updated == updated &&
      other.unchanged == unchanged &&
      other.failed == failed &&
      listEquals(other.sources, sources) &&
      listEquals(other.errors, errors);

  @override
  int get hashCode => Object.hash(
    added,
    updated,
    unchanged,
    failed,
    Object.hashAll(sources),
    Object.hashAll(errors),
  );
}

/// Table G — a source subscription (auto-updating import feed).
class LegadoSubscription {
  const LegadoSubscription({
    this.id = 0,
    required this.name,
    required this.url,
    this.type = 0,
    this.customOrder = 0,
    this.autoUpdate = false,
    this.lastUpdate = 0,
  });

  /// 0 means "new" when upserting.
  final int id;
  final String name;
  final String url;
  final int type;
  final int customOrder;
  final bool autoUpdate;

  /// Milliseconds since epoch of the last successful update.
  final int lastUpdate;

  factory LegadoSubscription.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return LegadoSubscription(
      id: _int(m, 'id'),
      name: _str(m, 'name'),
      url: _str(m, 'url'),
      type: _int(m, 'type'),
      customOrder: _int(m, 'customOrder'),
      autoUpdate: _bool(m, 'autoUpdate'),
      lastUpdate: _int(m, 'lastUpdate'),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'name': name,
    'url': url,
    'type': type,
    'customOrder': customOrder,
    'autoUpdate': autoUpdate,
    'lastUpdate': lastUpdate,
  };

  @override
  bool operator ==(Object other) =>
      other is LegadoSubscription &&
      other.id == id &&
      other.name == name &&
      other.url == url &&
      other.type == type &&
      other.customOrder == customOrder &&
      other.autoUpdate == autoUpdate &&
      other.lastUpdate == lastUpdate;

  @override
  int get hashCode =>
      Object.hash(id, name, url, type, customOrder, autoUpdate, lastUpdate);
}

/// A global replace rule (draft API, ENGINE-study §4.2 last table).
class LegadoReplaceRule {
  const LegadoReplaceRule({
    this.id = 0,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.scope,
    this.isRegex = false,
    this.isEnabled = true,
    this.order = 0,
  });

  final int id;
  final String name;
  final String pattern;
  final String replacement;
  final String? scope;
  final bool isRegex;
  final bool isEnabled;
  final int order;

  factory LegadoReplaceRule.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return LegadoReplaceRule(
      id: _int(m, 'id'),
      name: _str(m, 'name'),
      pattern: _str(m, 'pattern'),
      replacement: _str(m, 'replacement'),
      scope: _strOrNull(m, 'scope'),
      isRegex: _bool(m, 'isRegex'),
      isEnabled: _bool(m, 'isEnabled', true),
      order: _int(m, 'order'),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'scope': scope,
    'isRegex': isRegex,
    'isEnabled': isEnabled,
    'order': order,
  };

  @override
  bool operator ==(Object other) =>
      other is LegadoReplaceRule &&
      other.id == id &&
      other.name == name &&
      other.pattern == pattern &&
      other.replacement == replacement &&
      other.scope == scope &&
      other.isRegex == isRegex &&
      other.isEnabled == isEnabled &&
      other.order == order;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    pattern,
    replacement,
    scope,
    isRegex,
    isEnabled,
    order,
  );
}

/// Result of `resolveImageRequest`: the real URL plus the headers the
/// image must be fetched with (anti-hotlink rules of the source applied).
class ImageRequest {
  const ImageRequest({required this.url, this.headers = const {}});

  final String url;
  final Map<String, String> headers;

  factory ImageRequest.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return ImageRequest(url: _str(m, 'url'), headers: _strMap(m, 'headers'));
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'url': url,
    'headers': headers,
  };

  @override
  bool operator ==(Object other) =>
      other is ImageRequest &&
      other.url == url &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(
    url,
    Object.hashAllUnordered(
      headers.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

/// How a source expects to be logged in (bridge `getLoginData`).
enum LegadoLoginKind {
  /// A loginUi form exists; render [LegadoLoginData.rows].
  form,

  /// loginUrl is a web page; login happens in the browser window.
  web,

  /// loginUrl is a script with no form; `login()` runs unattended.
  js,

  /// The source carries no usable login configuration.
  none,
}

/// One row of a source's login form — the engine's `RowUi`, carried
/// field-for-field. [type] is one of the fork's RowUi.Type values
/// (`text`, `password`, `button`, `toggle`, `title`, `select`);
/// unknown types render as buttons, as the fork's dialog does.
class LegadoLoginRow {
  const LegadoLoginRow({
    required this.name,
    required this.type,
    this.action,
    this.chars = const <String>[],
    this.flexBasisPercent = 0,
  });

  /// Field label; doubles as the login-info key for input rows.
  final String name;
  final String type;

  /// Button/select/toggle rows: a JS snippet from the source's login
  /// script, or an absolute URL to open. Null for plain input rows.
  final String? action;

  /// Options for `select` rows.
  final List<String> chars;

  /// The fork's grid width hint (layout_flexBasisPercent). Carried
  /// for fidelity; the Wenku sheet stacks rows full-width.
  final double flexBasisPercent;

  bool get isInput =>
      type == 'text' || type == 'password' || type == 'select' || type == 'toggle';

  factory LegadoLoginRow.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    final charsRaw = m['chars'];
    return LegadoLoginRow(
      name: _str(m, 'name'),
      type: _str(m, 'type', 'text'),
      action: _strOrNull(m, 'action'),
      chars: <String>[
        if (charsRaw is List)
          for (final item in charsRaw) item?.toString() ?? '',
      ],
      flexBasisPercent: _double(m, 'flexBasisPercent'),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'name': name,
    'type': type,
    'action': action,
    'chars': chars,
    'flexBasisPercent': flexBasisPercent,
  };

  @override
  bool operator ==(Object other) =>
      other is LegadoLoginRow &&
      other.name == name &&
      other.type == type &&
      other.action == action &&
      listEquals(other.chars, chars) &&
      other.flexBasisPercent == flexBasisPercent;

  @override
  int get hashCode =>
      Object.hash(name, type, action, Object.hashAll(chars), flexBasisPercent);
}

/// Result of `getLoginData`: everything the login sheet renders.
///
/// [values] holds the saved login info the fork's dialog would
/// prefill (input rows only, keyed by row name) — it can contain the
/// user's own saved password, on its way back into the form where it
/// started. Never log it.
class LegadoLoginData {
  const LegadoLoginData({
    required this.sourceUrl,
    required this.sourceName,
    required this.kind,
    this.loginUrl,
    this.rows = const <LegadoLoginRow>[],
    this.values = const <String, String>{},
    this.hasLoginInfo = false,
    this.hasLoginHeader = false,
  });

  final String sourceUrl;
  final String sourceName;
  final LegadoLoginKind kind;

  /// The login page URL; only present when [kind] is web.
  final String? loginUrl;
  final List<LegadoLoginRow> rows;

  /// Prefill values for input rows (see class doc).
  final Map<String, String> values;

  /// Whether the engine holds saved login info for this source.
  final bool hasLoginInfo;

  /// Whether a login header is saved for this source.
  final bool hasLoginHeader;

  factory LegadoLoginData.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return LegadoLoginData(
      sourceUrl: _str(m, 'sourceUrl'),
      sourceName: _str(m, 'sourceName'),
      kind: switch (_str(m, 'kind')) {
        'web' => LegadoLoginKind.web,
        'js' => LegadoLoginKind.js,
        'none' => LegadoLoginKind.none,
        _ => LegadoLoginKind.form,
      },
      loginUrl: _strOrNull(m, 'loginUrl'),
      rows: _mapList(m, 'rows', LegadoLoginRow.fromMap),
      values: _strMap(m, 'values'),
      hasLoginInfo: _bool(m, 'hasLoginInfo'),
      hasLoginHeader: _bool(m, 'hasLoginHeader'),
    );
  }
}

/// Result of `getChapterList`: the book snapshot with the fields the
/// engine wrote back (chapter count / latest chapter) plus the chapters.
class ChapterListResult {
  const ChapterListResult({required this.book, required this.chapters});

  final BookInfo book;
  final List<Chapter> chapters;

  factory ChapterListResult.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return ChapterListResult(
      book: BookInfo.fromMap(_keyed(m['book'])),
      chapters: _mapList(m, 'chapters', Chapter.fromMap),
    );
  }
}

/// Result of `getBookByUrl`: which source claimed the URL, plus its book.
class BookByUrlResult {
  const BookByUrlResult({required this.origin, required this.book});

  final String origin;
  final BookInfo book;

  factory BookByUrlResult.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return BookByUrlResult(
      origin: _str(m, 'origin'),
      book: BookInfo.fromMap(_keyed(m['book'])),
    );
  }
}

/// Result of `applyChangeSource`: the book on the new source, its chapter
/// list, and where the old reading position lands in it.
class ChangeSourceResult {
  const ChangeSourceResult({
    required this.book,
    required this.chapters,
    required this.matchedChapterIndex,
  });

  final BookInfo book;
  final List<Chapter> chapters;
  final int matchedChapterIndex;

  factory ChangeSourceResult.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return ChangeSourceResult(
      book: BookInfo.fromMap(_keyed(m['book'])),
      chapters: _mapList(m, 'chapters', Chapter.fromMap),
      matchedChapterIndex: _int(m, 'matchedChapterIndex'),
    );
  }
}

/// Per-source tally inside a search snapshot.
class SearchGroupCount {
  const SearchGroupCount({
    required this.origin,
    this.originName = '',
    this.count = 0,
  });

  final String origin;
  final String originName;
  final int count;

  factory SearchGroupCount.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return SearchGroupCount(
      origin: _str(m, 'origin'),
      originName: _str(m, 'originName'),
      count: _int(m, 'count'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SearchGroupCount &&
      other.origin == origin &&
      other.originName == originName &&
      other.count == count;

  @override
  int get hashCode => Object.hash(origin, originName, count);
}

/// Result of the spike-level `ping` call: proves the native engine AAR is
/// linked into the host and its facade answers, before any business method
/// is implemented natively.
class LegadoPingResult {
  const LegadoPingResult({
    this.engineVersion = '',
    this.includedModules = const <String>[],
    this.upstreamCommit = '',
  });

  final String engineVersion;
  final List<String> includedModules;
  final String upstreamCommit;

  factory LegadoPingResult.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return LegadoPingResult(
      engineVersion: _str(m, 'engineVersion'),
      includedModules: _strList(m, 'includedModules'),
      upstreamCommit: _str(m, 'upstreamCommit'),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'engineVersion': engineVersion,
    'includedModules': includedModules,
    'upstreamCommit': upstreamCommit,
  };

  @override
  bool operator ==(Object other) =>
      other is LegadoPingResult &&
      other.engineVersion == engineVersion &&
      other.upstreamCommit == upstreamCommit &&
      listEquals(other.includedModules, includedModules);

  @override
  int get hashCode =>
      Object.hash(engineVersion, upstreamCommit, Object.hashAll(includedModules));
}

/// Engine info returned by `init`.
class LegadoEngineInfo {
  const LegadoEngineInfo({
    this.ok = false,
    this.engineVersion = '',
    this.sourceCount = 0,
  });

  final bool ok;
  final String engineVersion;
  final int sourceCount;

  factory LegadoEngineInfo.fromMap(Map<Object?, Object?> map) {
    final m = _keyed(map);
    return LegadoEngineInfo(
      ok: _bool(m, 'ok'),
      engineVersion: _str(m, 'engineVersion'),
      sourceCount: _int(m, 'sourceCount'),
    );
  }
}

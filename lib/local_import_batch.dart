import 'book_documents.dart';
import 'catalog.dart';
import 'cloud_sources.dart' show cloudFailureMessage;
import 'local_book_series.dart';
import 'local_books.dart';

typedef LocalImportFailure = ({String name, String message});

/// A non-fatal remark produced by one imported document: the book is in the
/// library, but something about it (a category, a series link) was not saved.
typedef LocalImportNotice = ({String name, String message});

class LocalImportReport {
  const LocalImportReport({
    required this.bookIds,
    required this.added,
    required this.existing,
    this.failures = const [],
    this.notices = const [],
  });

  final List<int> bookIds;
  final int added;
  final int existing;
  final List<LocalImportFailure> failures;
  final List<LocalImportNotice> notices;

  String get summary => [
    if (added > 0) '已导入 $added 本',
    if (existing > 0) '$existing 本已在书库',
    if (failures.isNotEmpty) '${failures.length} 本未导入',
  ].join(' · ');
}

/// Read/parse one source at a time. A bad document must not discard the rest
/// of a user-selected batch, and no merge prompt interrupts this operation.
///
/// [importSelection] handles sources that carry a durable original (linked or
/// derived documents); [importFile] handles plain copies. Both register the
/// book with the library before returning.
Future<LocalImportReport> importLocalDocuments({
  required List<BookDocumentSelection> selections,
  required BookDocuments documents,
  required LocalBookStore books,
  required Future<Novel> Function(BookDocumentSelection selected) importSelection,
  required Future<Novel> Function(String name, String path) importFile,
  bool releaseSources = false,
  void Function(Iterable<BookDocumentSelection> failed)? onCleanupFailed,
  void Function(int completed, int total)? onProgress,
}) async {
  final ids = <int>[];
  final failures = <LocalImportFailure>[];
  var added = 0;
  var existing = 0;
  for (final (index, selected) in selections.indexed) {
    try {
      if (selected.error case final error?) throw FormatException(error);
      final path = selected.path;
      if (path == null) throw StateError('文件尚未准备完成');
      final before = books.originals.length;
      final book = selected.originReference != null
          ? await importSelection(selected)
          : await importFile(selected.name, path);
      ids.add(book.id);
      if (books.originals.length > before) {
        added++;
      } else {
        existing++;
      }
    } catch (error) {
      failures.add((name: selected.name, message: cloudFailureMessage(error)));
      if (releaseSources) onCleanupFailed?.call([selected]);
    }
    onProgress?.call(index + 1, selections.length);
  }
  return LocalImportReport(
    bookIds: ids,
    added: added,
    existing: existing,
    failures: failures,
  );
}

/// Single-source import used by the book-open monitor: one selection in, one
/// report out, with no progress reporting.
Future<LocalImportReport> importLocalBatch({
  required List<BookDocumentSelection> selections,
  required BookDocuments documents,
  required LocalBookStore books,
  required Future<Novel> Function(String name, String path) importFile,
  void Function(int completed, int total)? onProgress,
}) => importLocalDocuments(
  selections: selections,
  documents: documents,
  books: books,
  importSelection: (selected) => importFile(selected.name, selected.path!),
  importFile: importFile,
  onProgress: onProgress,
);

class LocalImportGroup {
  const LocalImportGroup({
    required this.seed,
    required this.title,
    required this.volumes,
    this.targetId,
    this.needsTarget = false,
  });

  final int seed;
  final String title;
  final int? targetId;
  final bool needsTarget;
  final List<({int bookId, String title})> volumes;
}

/// Suggestions only. The caller presents all groups after the batch finishes;
/// durable originals and reading records are changed only on confirmation.
List<LocalImportGroup> localImportGroups(
  LocalBookStore books,
  Iterable<int> ids,
) {
  final groups = <LocalImportGroup>[];
  final claimed = <int>{};
  for (final id in ids) {
    if (claimed.contains(id) || books.seriesFor(id) != null) continue;
    final related = books.relatedVolumes(id);
    if (related.isEmpty) continue;
    final targets = related
        .map((b) => books.seriesFor(b.id))
        .whereType<LocalBookSeries>()
        .toList();
    final target = targets.firstOrNull;
    final order = <({int bookId, String title})>[
      ...?target?.volumes.map((v) => (bookId: v.bookId, title: v.title)),
    ];
    final originals =
        [
          books.book(id)!,
          ...related,
        ].where((b) => books.seriesFor(b.id) == null).toList()..sort(
          (a, b) => (books.seriesHint(a.id)?.number ?? double.infinity)
              .compareTo(books.seriesHint(b.id)?.number ?? double.infinity),
        );
    for (final book in originals) {
      claimed.add(book.id);
      final hint = books.seriesHint(book.id);
      final before = hint == null
          ? -1
          : order.indexWhere((v) {
              final other = books.seriesHint(v.bookId);
              return other?.key == hint.key && other!.number > hint.number;
            });
      final entry = (bookId: book.id, title: hint?.volumeTitle ?? book.title);
      if (before < 0) {
        order.add(entry);
      } else {
        order.insert(before, entry);
      }
    }
    groups.add(
      LocalImportGroup(
        seed: id,
        title: target?.title ?? books.seriesHint(id)!.title,
        volumes: order,
        targetId: target?.id,
        needsTarget: targets.length > 1,
      ),
    );
  }
  return groups;
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_collection_layout.dart';
import 'bookmark_note_sheet.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_books.dart';
import 'offline_repository.dart';
import 'pages.dart' show NovelRow, ReaderPage;
import 'quote_card.dart';

/// A merged volume keeps its original recovery records. Show the equivalent
/// bookmark in the active series once, without deleting those recovery copies.
List<({int novelId, ReaderBookmark bookmark})> libraryBookmarks(
  LibraryState state, {
  LocalBookStore? books,
}) => state.bookmarkEntries.where((entry) {
  final series = books?.seriesFor(entry.novelId);
  if (series == null || series.id == entry.novelId) return true;
  final original =
      books!.book(entry.novelId) ?? state.cachedNovel(entry.novelId);
  if (original == null) return true;
  final chapter = state.chapterForPosition(original, entry.bookmark.position);
  final volume = series.volumes
      .where((v) => v.bookId == entry.novelId)
      .firstOrNull;
  if (chapter == null ||
      volume == null ||
      chapter >= volume.chapterIds.length) {
    return true;
  }
  final source = entry.bookmark.position;
  return !state.bookmarksFor(series.id).any((mark) {
    final target = mark.position;
    return target.chapterId == volume.chapterIds[chapter] &&
        mark.quote == entry.bookmark.quote &&
        target.paragraphIndex == source.paragraphIndex &&
        target.textOffset == source.textOffset &&
        target.offset == source.offset &&
        target.width == source.width &&
        target.fontSize == source.fontSize &&
        target.lineHeight == source.lineHeight;
  });
}).toList();

Novel? _knownNovel(LibraryState state, NovelRepository repository, int id) =>
    repository is OfflineNovelRepository
    ? repository.local?.book(id) ??
          repository.cache.book(id)?.novel ??
          state.cachedNovel(id)
    : state.cachedNovel(id);

LocalBookStore? _localStore(NovelRepository repository) =>
    repository is OfflineNovelRepository ? repository.local : null;

/// The 书签 dock tab (B3 定版）: books grouped exactly like the bookshelf
/// page — same [BookCollectionView] scroll/reflow, same [NovelRow] cover /
/// title / author rows, same trailing text slot, except the rows list only
/// books that carry bookmarks and the slot shows the bookmark count.
/// Tapping a book opens [BookBookmarksPage] with that book's bookmarks.
class BookmarkLibraryPage extends StatefulWidget {
  const BookmarkLibraryPage({
    super.key,
    required this.state,
    required this.repository,
    this.showHeader = true,
  });
  final LibraryState state;
  final NovelRepository repository;

  /// False when the page sits in the home dock as the 书签 tab: the shell
  /// pins [buildHeader] itself, exactly like the other dock pages.
  final bool showHeader;

  Widget buildHeader(BuildContext context) => const Align(
    alignment: Alignment.centerLeft,
    child: ArchiveMasthead(title: '书签', code: 'PERSONAL / EXCERPTS'),
  );

  @override
  State<BookmarkLibraryPage> createState() => _BookmarkLibraryPageState();
}

class _BookmarkLibraryPageState extends State<BookmarkLibraryPage> {
  final Map<int, Future<Novel?>> _requests = {};

  Novel? _known(int id) => _knownNovel(widget.state, widget.repository, id);

  Future<Novel?> _resolve(int id) async {
    final book = await widget.repository.find(id);
    if (book != null) await widget.state.rememberNovel(book);
    return book;
  }

  @override
  Widget build(BuildContext context) => widget.showHeader
      ? ArchiveFeaturePage(
          title: '书签',
          code: 'PERSONAL / EXCERPTS',
          child: _collection(context, dock: false),
        )
      : _collection(context, dock: true);

  Widget _collection(BuildContext context, {required bool dock}) =>
      AnimatedBuilder(
        animation: widget.state.bookmarkChanges,
        builder: (context, _) {
          final entries = libraryBookmarks(
            widget.state,
            books: _localStore(widget.repository),
          );
          final byBook = <int, List<ReaderBookmark>>{};
          for (final entry in entries) {
            byBook
                .putIfAbsent(entry.novelId, () => <ReaderBookmark>[])
                .add(entry.bookmark);
          }
          final groups = byBook.entries.toList()
            ..sort((a, b) {
              int latest(List<ReaderBookmark> marks) => marks.fold(
                0,
                (value, mark) =>
                    mark.position.updatedAt > value
                        ? mark.position.updatedAt
                        : value,
              );
              return latest(b.value).compareTo(latest(a.value));
            });
          return BookCollectionView.builder(
            key: const PageStorageKey('bookmarks'),
            leadingCount: groups.isEmpty ? 2 : 1,
            padding: dock
                ? EdgeInsets.fromLTRB(
                    24,
                    MediaQuery.paddingOf(context).top +
                        FrostedHeader.toolbarHeight +
                        20,
                    24,
                    MediaQuery.paddingOf(context).bottom + 120,
                  )
                : featurePadding(context),
            itemCount: groups.isEmpty ? 2 : groups.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AppText(
                      groups.isEmpty
                          ? '0 条书签'
                          : '${groups.length} 本书 · ${entries.length} 条书签',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              }
              if (groups.isEmpty) {
                // The bookshelf page's empty-state composition, with the
                // bookmarks guidance copy the flat page used before B3.
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 90),
                  child: Column(
                    children: [
                      Icon(
                        CupertinoIcons.bookmark,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        size: 34,
                      ),
                      const SizedBox(height: 18),
                      const AppText(
                        '书签还空着',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      AppText(
                        '长按正文选择喜欢的句子，点「书签」即可收藏',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              }
              return _row(context, groups[index - 1], index - 1);
            },
          );
        },
      );

  Widget _row(
    BuildContext context,
    MapEntry<int, List<ReaderBookmark>> group,
    int rowIndex,
  ) {
    final id = group.key;
    final book = _known(id);
    return FutureBuilder<Novel?>(
      key: ValueKey('bookmark-book-resolve-$id'),
      initialData: book,
      future: book == null
          ? _requests.putIfAbsent(id, () => _resolve(id))
          : _requests[id],
      builder: (context, snapshot) {
        final resolved = book ?? snapshot.data;
        final pending = snapshot.connectionState != ConnectionState.done;
        return LoadedContentSequence(
          generation: resolved?.id,
          child: resolved != null || !pending
              ? LoadedContentItem(
                  index: rowIndex,
                  placeholder: const BookRowSkeleton(),
                  child: NovelRow(
                    key: ValueKey('bookmark-book-$id'),
                    novel:
                        resolved ??
                        Novel(
                          id: id,
                          title: '书籍 $id',
                          author: '',
                          genre: '',
                          summary: '',
                          colors: const [Colors.grey, Colors.white],
                        ),
                    onTap: () => pushNovelPage<void>(
                      context,
                      BookBookmarksPage(
                        novelId: id,
                        state: widget.state,
                        repository: widget.repository,
                      ),
                      reduceMotion: widget.state.reduceMotion,
                    ),
                    // The shelf row's trailing slot, unchanged: the 46px
                    // action area above, the small primary text below —
                    // here the text counts this book's bookmarks instead
                    // of reading progress.
                    trailing: SizedBox(
                      width: 74,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 46),
                          AppText(
                            '共 ${group.value.length} 条书签',
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : BookRowSkeleton(label: '正在载入书籍 $id'),
        );
      },
    );
  }
}

/// One book's bookmarks （点开书签页的一本书）: the pre-B3 flat page's
/// entry composition ([ContentPanel] cards with serif quote, chapter line
/// and glass action row) filtered to a single book, ordered by chapter,
/// each entry carrying its 感想 (note) with an edit affordance.
class BookBookmarksPage extends StatefulWidget {
  const BookBookmarksPage({
    super.key,
    required this.novelId,
    required this.state,
    required this.repository,
  });
  final int novelId;
  final LibraryState state;
  final NovelRepository repository;

  @override
  State<BookBookmarksPage> createState() => _BookBookmarksPageState();
}

class _BookBookmarksPageState extends State<BookBookmarksPage> {
  String? _opening;
  Novel? _novel;
  bool _novelLoaded = false;

  @override
  void initState() {
    super.initState();
    final known = _knownNovel(widget.state, widget.repository, widget.novelId);
    if (known != null) {
      _novel = known;
      _novelLoaded = true;
    } else {
      widget.repository
          .find(widget.novelId)
          .then((book) {
            if (!mounted) return;
            setState(() {
              _novel = book;
              _novelLoaded = true;
            });
          })
          .catchError((Object _) {
            if (mounted) setState(() => _novelLoaded = true);
          });
    }
  }

  int _chapterIndex(ReaderBookmark mark) {
    final novel = _novel;
    if (novel != null) {
      final index = widget.state.chapterForPosition(novel, mark.position);
      if (index != null) return index;
    }
    return mark.position.chapter;
  }

  List<ReaderBookmark> _marksInChapterOrder() {
    final marks =
        libraryBookmarks(
              widget.state,
              books: _localStore(widget.repository),
            )
            .where((entry) => entry.novelId == widget.novelId)
            .map((entry) => entry.bookmark)
            .toList()
          ..sort((a, b) {
            final byChapter = _chapterIndex(
              a,
            ).compareTo(_chapterIndex(b));
            if (byChapter != 0) return byChapter;
            final pa = a.position, pb = b.position;
            final byParagraph = (pa.paragraphIndex ?? -1).compareTo(
              pb.paragraphIndex ?? -1,
            );
            if (byParagraph != 0) return byParagraph;
            final byText = (pa.textOffset ?? 0).compareTo(pb.textOffset ?? 0);
            if (byText != 0) return byText;
            return pa.offset.compareTo(pb.offset);
          });
    return marks;
  }

  Future<void> _open(ReaderBookmark mark) async {
    if (_opening != null) return;
    final id = widget.novelId;
    setState(() => _opening = mark.id);
    try {
      final repository = widget.repository;
      if (isLocalBook(id) &&
          repository is OfflineNovelRepository &&
          repository.local?.book(id) == null) {
        throw const FormatException('本地原书已移除，摘录仍可查看和分享');
      }
      var novel =
          _knownNovel(widget.state, repository, id) ??
          await repository.find(id);
      if (novel == null) throw const FormatException('暂时无法读取原书，请检查本机文件或网络');
      if (novel.chapters.isEmpty) {
        novel = novel.withChapters(await repository.chapters(novel.id));
      }
      final chapter = widget.state.chapterForPosition(novel, mark.position);
      if (chapter == null) throw const FormatException('原章节已变动，摘录仍保留');
      if (!mounted) return;
      await pushNovelPage<void>(
        context,
        ReaderPage(
          novel: novel,
          state: widget.state,
          repository: repository,
          initialChapter: chapter,
          initialBookmark: mark,
        ),
        reduceMotion: widget.state.reduceMotion,
      );
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '暂时无法打开原文，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _remove(ReaderBookmark mark) async {
    if (!await confirmNovelAction(
      context,
      title: '删除这条书签？',
      message: '原书和阅读进度不会改变。',
      confirmLabel: '删除书签',
      reduceMotion: widget.state.reduceMotion,
    )) {
      return;
    }
    try {
      await widget.state.removeBookmark(widget.novelId, mark.id);
    } catch (_) {
      if (mounted) showNovelFeedback(context, '书签删除失败，请重试');
    }
  }

  Future<void> _editNote(ReaderBookmark mark) async {
    final note = await showBookmarkNoteSheet(
      context,
      initial: mark.note,
      editing: mark.note.isNotEmpty,
      reduceMotion: widget.state.reduceMotion,
    );
    if (note == null) return;
    try {
      await widget.state.updateBookmarkNote(widget.novelId, mark.id, note);
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '感想保存失败，请重试',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: _novel?.title ?? '书籍 ${widget.novelId}',
    code: 'PERSONAL / EXCERPTS',
    child: AnimatedBuilder(
      animation: widget.state.bookmarkChanges,
      builder: (context, _) {
        final marks = _marksInChapterOrder();
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView.builder(
              padding: featurePadding(context),
              itemCount: marks.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppText(
                        '${marks.length} 条书签',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (marks.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 36),
                          child: AppText(
                            '这本书还没有书签。\n在阅读器里添加的书签会按章节顺序出现在这里。',
                            style: TextStyle(height: 1.8),
                          ),
                        ),
                    ],
                  );
                }
                return _entry(context, marks[index - 1]);
              },
            ),
          ),
        );
      },
    ),
  );

  Widget _entry(BuildContext context, ReaderBookmark mark) {
    final chapter = _novelLoaded && _novel != null
        ? widget.state.chapterForPosition(_novel!, mark.position)
        : null;
    final time = mark.position.updatedAt;
    final meta = [
      if (chapter != null) '第 ${chapter + 1} 章',
      if (time > 0) '添加于 ${_bookmarkTime(time)}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ContentPanel(
        key: ValueKey('my-bookmark-${mark.id}'),
        onTap: () => _open(mark),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (mark.quote.isNotEmpty) ...[
              AppText(
                mark.quote,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'SourceHanSerifCN',
                  fontSize: 15,
                  height: 1.75,
                ),
              ),
              const SizedBox(height: 20),
            ],
            AppText(
              mark.chapterTitle,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 6),
              AppText(
                meta,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (mark.note.isNotEmpty) ...[
              const SizedBox(height: 12),
              AppText(
                '感想',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              AppText(mark.note, style: const TextStyle(fontSize: 14, height: 1.7)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                GlassTextButton(
                  key: ValueKey('bookmark-read-${mark.id}'),
                  onPressed: _opening == null ? () => _open(mark) : null,
                  child: AppText(_opening == mark.id ? '正在打开…' : '回到原文'),
                ),
                if (mark.quote.isNotEmpty)
                  GlassTextButton(
                    key: ValueKey('bookmark-share-${mark.id}'),
                    onPressed: () => pushNovelPage<void>(
                      context,
                      QuoteCardPage(
                        data: QuoteCardData(
                          text: mark.quote,
                          book: _novel?.title ?? '书籍 ${widget.novelId}',
                          author: _novel?.author ?? '',
                          chapter: mark.chapterTitle,
                        ),
                      ),
                      reduceMotion: widget.state.reduceMotion,
                    ),
                    child: const AppText('分享图片'),
                  ),
                GlassTextButton(
                  key: ValueKey('bookmark-note-${mark.id}'),
                  onPressed: () => _editNote(mark),
                  child: AppText(mark.note.isEmpty ? '写感想' : '修改感想'),
                ),
                GlassIconButton(
                  icon: CupertinoIcons.trash,
                  label: '删除书签 ${mark.id}',
                  onPressed: () => _remove(mark),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Same timestamp shape as the reading-history page (`yyyy-MM-dd HH:mm`).
String _bookmarkTime(int timestamp) {
  final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

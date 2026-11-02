import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';

import 'support/offline_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final novel = offlineFixtureBook(71);
  Future<LibraryState> state() async {
    SharedPreferences.setMockInitialValues({});
    final result = await LibraryState.load();
    addTearDown(result.dispose);
    return result;
  }

  ReadingPosition position({double offset = 720, int chapter = 1}) =>
      ReadingPosition(
        chapter: chapter,
        chapterId: novel.chapters[chapter].id,
        offset: offset,
        fraction: offset / 3000,
        fontSize: 19,
        lineHeight: 1.9,
        width: 390,
        updatedAt: 100,
      );

  test(
    'bookmarks persist, deduplicate and follow stable IDs after insertion',
    () async {
      final library = await state();
      final first = await library.addBookmark(
        novel: novel,
        position: position(),
      );
      final duplicate = await library.addBookmark(
        novel: novel,
        position: position(offset: 723),
      );
      expect(duplicate!.id, first!.id);
      expect(library.bookmarksFor(71), hasLength(1));
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      final mark = reloaded.bookmarksFor(71).single;
      expect(mark.position.offset, 720);
      expect(mark.position.lineHeight, 1.9);
      final inserted = novel.withChapters([
        const NovelChapter('插入章节', '', id: 71000),
        ...novel.chapters,
      ]);
      expect(reloaded.chapterForPosition(inserted, mark.position), 2);
      final removed = novel.withChapters([
        novel.chapters.first,
        novel.chapters.last,
      ]);
      expect(reloaded.chapterForPosition(removed, mark.position), isNull);
      await reloaded.removeBookmark(71, mark.id);
      expect((await LibraryState.load()).bookmarksFor(71), isEmpty);
    },
  );

  test(
    'bookmark notes are written at creation, edited in place and cleared',
    () async {
      final library = await state();
      final noted = await library.addBookmark(
        novel: novel,
        position: position(),
        note: '  写下当时的想法  ',
      );
      expect(noted!.note, '写下当时的想法');
      // Notes ride the same JSON record as quotes: a reload keeps them,
      // and a note-less bookmark still omits the key entirely.
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.bookmarksFor(71).single.note, '写下当时的想法');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('reader_bookmarks_71')!;
      expect(raw, contains('"note":"写下当时的想法"'));

      await library.updateBookmarkNote(71, noted.id, '改过之后的感想');
      expect(library.bookmarksFor(71).single.note, '改过之后的感想');
      expect(library.bookmarksFor(71).single.id, noted.id);
      expect(
        library.bookmarksFor(71).single.position.offset,
        noted.position.offset,
      );
      // Editing notifies the bookmarks channel exactly once per change.
      var notifications = 0;
      library.bookmarkChanges.addListener(() => notifications++);
      await library.updateBookmarkNote(71, noted.id, '改过之后的感想');
      expect(notifications, 0);
      await library.updateBookmarkNote(71, noted.id, '');
      expect(notifications, 1);
      expect(library.bookmarksFor(71).single.note, '');
      expect(
        (await LibraryState.load()).bookmarksFor(71).single.note,
        '',
      );
      await expectLater(
        Future<void>(() => library.updateBookmarkNote(71, noted.id, 'x' * 12001)),
        throwsFormatException,
      );
      await expectLater(
        library.addBookmark(
          novel: novel,
          position: position(offset: 2000),
          note: 'x' * 12001,
        ),
        throwsFormatException,
      );
      // A duplicate add keeps the existing bookmark (and its note) as-is.
      final plain = await library.addBookmark(
        novel: novel,
        position: position(offset: 1500),
      );
      final duplicate = await library.addBookmark(
        novel: novel,
        position: position(offset: 1503),
        note: '不应覆盖',
      );
      expect(duplicate!.id, plain!.id);
      expect(
        library.bookmarksFor(71).firstWhere((m) => m.id == plain.id).note,
        '',
      );
    },
  );

  test(
    'concurrent duplicate additions and deletion preserve invocation order',
    () async {
      final library = await state();
      final results = await Future.wait([
        library.addBookmark(novel: novel, position: position()),
        library.addBookmark(novel: novel, position: position()),
      ]);
      expect(results.first!.id, results.last!.id);
      expect(library.bookmarksFor(71), hasLength(1));
      await Future.wait([
        library.addBookmark(novel: novel, position: position(offset: 1000)),
        library.removeBookmark(71, results.first!.id),
      ]);
      final marks = (await LibraryState.load()).bookmarksFor(71);
      expect(marks, hasLength(1));
      expect(marks.single.position.offset, 1000);
    },
  );

  test(
    'bookmark mutations notify only bookmarks and do not alter resume/history',
    () async {
      final library = await state();
      var marks = 0;
      var global = 0;
      var history = 0;
      var appearance = 0;
      var reader = 0;
      library.bookmarkChanges.addListener(() => marks++);
      library.addListener(() => global++);
      library.historyChanges.addListener(() => history++);
      library.appearanceChanges.addListener(() => appearance++);
      library.readerSettingsChanges.addListener(() => reader++);
      final mark = await library.addBookmark(
        novel: novel,
        position: position(),
      );
      await library.removeBookmark(71, mark!.id);
      expect(marks, 2);
      expect([global, history, appearance, reader], [0, 0, 0, 0]);
      expect(library.readingHistoryIds, isEmpty);
      expect(library.positionFor(71), isNull);
    },
  );

  test(
    'damaged bookmark is isolated and old reading records default to original line spacing',
    () async {
      final valid = ReaderBookmark(
        id: 'valid',
        chapterTitle: '第二章',
        position: position(),
      );
      SharedPreferences.setMockInitialValues({
        'reader_bookmarks_71': jsonEncode([
          {'bad': true},
          valid.toJson(),
          valid.toJson(),
        ]),
        'reading_position_71': jsonEncode({
          'chapter': 1,
          'chapterId': 71002,
          'offset': 720,
        }),
        'readerFontSize': 999.0,
        'readerLineHeight': double.nan,
      });
      final library = await LibraryState.load();
      addTearDown(library.dispose);
      expect(library.bookmarksFor(71).single.id, 'valid');
      expect(library.positionFor(71)!.lineHeight, 1.72);
      expect(library.fontSize, 27);
      expect(library.lineHeight, 1.72);
    },
  );

  test(
    '120 position saves encode a large unchanged directory only once',
    () async {
      final library = await state();
      final large = offlineFixtureBook(71, chapters: 1200);
      await library.rememberNovel(large);
      final encodes = library.debugMetadataEncodeCount;
      for (var index = 0; index < 120; index++) {
        await library.savePosition(
          novel: large,
          chapter: 10,
          offset: index * 20,
          maximum: 10000,
          width: 390,
          notify: false,
        );
      }
      expect(library.debugMetadataEncodeCount, encodes);
      final revised = large.withChapters([
        ...large.chapters,
        const NovelChapter('新章节', '', id: 9999),
      ]);
      await library.rememberNovel(revised);
      expect(library.debugMetadataEncodeCount, encodes + 1);
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.cachedNovel(71)!.chapterCount, 1201);
      expect(reloaded.positionFor(71)!.offset, 2380);
    },
  );

  test(
    'reader previews use narrow notifiers and persist only on commit',
    () async {
      final library = await state();
      var global = 0;
      var appearance = 0;
      var reader = 0;
      library.addListener(() => global++);
      library.appearanceChanges.addListener(() => appearance++);
      library.readerSettingsChanges.addListener(() => reader++);
      await library.setFontSize(22, persist: false);
      await library.setLineHeight(1.9, persist: false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('readerFontSize'), isFalse);
      expect(prefs.containsKey('readerLineHeight'), isFalse);
      expect([global, appearance, reader], [0, 0, 2]);
      await library.setFontSize(22);
      await library.setLineHeight(1.9);
      expect(reader, 2);
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.fontSize, 22);
      expect(reloaded.lineHeight, 1.9);
    },
  );
}

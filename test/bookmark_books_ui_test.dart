import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/bookmark_library_page.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'reader_modes_test.dart' show settleReader;
import 'support/visual_review.dart';

/// B3 定版：书签页按书分组（书架页同款书目行）、点开一本书看该书的
/// 书签与感想（章节顺序）、感想在阅读器加书签时可写、事后可补改。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);

  const content = '''A beautiful morning.

The sunlight shines through the window.

Tomorrow we will meet again.''';
  final bookA = Novel(
    id: 71234,
    title: '窗边的风',
    author: '作者甲',
    genre: '日常',
    summary: '',
    colors: const [Colors.grey, Colors.white],
    chapters: const [
      NovelChapter('第一章 相遇', content, id: 7123401),
      NovelChapter('第二章 离别', content, id: 7123402),
    ],
  );
  final bookB = Novel(
    id: 71235,
    title: '山间的信',
    author: '作者乙',
    genre: '日常',
    summary: '',
    colors: const [Colors.grey, Colors.white],
    chapters: const [NovelChapter('第一章 来信', content, id: 7123501)],
  );

  late LibraryState state;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
      'reduceMotion': true,
    });
    state = await LibraryState.load();
  });
  tearDown(() => state.dispose());

  ReadingPosition at(int chapter, int chapterId, {int updatedAt = 100}) =>
      ReadingPosition(
        chapter: chapter,
        chapterId: chapterId,
        offset: 0,
        fraction: 0,
        width: 390,
        fontSize: 19,
        lineHeight: 1.72,
        updatedAt: updatedAt,
        paragraphIndex: 1,
        textOffset: 4,
      );

  Finder glassButton(String label) => find
      .descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is GlassIconButton && widget.label == label,
        ),
        matching: find.byType(InkWell),
      )
      .first;

  /// Bookmark writes are real async IO (same pattern as
  /// reader_tools_features_test's `_io`): let them land before asserting.
  Future<void> io(WidgetTester tester) async {
    for (var step = 0; step < 8; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('bookmarks tab groups by book with shelf-style rows and counts', (
    tester,
  ) async {
    // The page now opens with the bookshelf's 立体书架 preview above the
    // rows (shelf layout is the default); give the test a tall enough
    // viewport for the preview, the section header and the lazy rows to
    // all be built at once. Assertions below are unchanged.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await state.addBookmark(
        novel: bookA,
        position: at(1, 7123402, updatedAt: 300),
        quote: '第二章的句子',
      );
      await state.addBookmark(
        novel: bookA,
        position: at(0, 7123401, updatedAt: 200),
        quote: '第一章的句子',
      );
      await state.addBookmark(
        novel: bookB,
        position: at(0, 7123501, updatedAt: 100),
        quote: '另一本书的句子',
        note: '先写好的感想',
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: novelTheme(Brightness.light),
        home: BookmarkLibraryPage(
          state: state,
          repository: const DemoNovelRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookmark-book-71234')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookmark-book-71235')), findsOneWidget);
    expect(find.text('共 2 条书签'), findsOneWidget);
    expect(find.text('共 1 条书签'), findsOneWidget);
    expect(find.text('2 本书 · 3 条书签'), findsOneWidget);
    // Titles appear in the row and in the route header mini-title.
    expect(find.text('窗边的风'), findsWidgets);
    expect(find.text('山间的信'), findsWidgets);
    // Flat excerpt list is gone from the tab: quotes live inside each book.
    expect(find.text('第一章的句子'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bookmarks shelf preview shows ALL bookmarked books (fix6: no 10-book cap)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 12 distinct books, one bookmark each -> 12 groups. The old data
      // path fed the carousel groups.take(10); fix6 feeds all groups.
      final many = [
        for (var i = 1; i <= 12; i++)
          Novel(
            id: 73000 + i,
            title: '书签作品 $i',
            author: '作者',
            genre: '日常',
            summary: '',
            colors: const [Colors.grey, Colors.white],
            chapters: [
              NovelChapter('第一章', content, id: (73000 + i) * 10 + 1),
            ],
          ),
      ];
      await tester.runAsync(() async {
        for (var i = 0; i < many.length; i++) {
          await state.addBookmark(
            novel: many[i],
            position: at(0, (73000 + i + 1) * 10 + 1, updatedAt: 100 + i),
            quote: '第 ${i + 1} 本书的句子',
          );
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          home: BookmarkLibraryPage(
            state: state,
            repository: const DemoNovelRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ArchiveFileCarousel>(find.byType(ArchiveFileCarousel))
            .books
            .length,
        12,
      );
      expect(find.text('12 本书 · 12 条书签'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one book page lists bookmarks in chapter order with notes, editing and deletion',
    (tester) async {
      late ReaderBookmark secondChapter, firstChapter;
      await tester.runAsync(() async {
        secondChapter = (await state.addBookmark(
          novel: bookA,
          position: at(1, 7123402, updatedAt: 300),
          quote: '第二章的句子',
        ))!;
        firstChapter = (await state.addBookmark(
          novel: bookA,
          position: at(0, 7123401, updatedAt: 200),
          quote: '第一章的句子',
        ))!;
      });
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          home: BookBookmarksPage(
            novelId: bookA.id,
            state: state,
            repository: const DemoNovelRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 条书签'), findsOneWidget);
      // Chapter order wins over insertion order (newest was added first).
      final firstTop = tester.getTopLeft(
        find.byKey(ValueKey('my-bookmark-${firstChapter.id}')),
      );
      final secondTop = tester.getTopLeft(
        find.byKey(ValueKey('my-bookmark-${secondChapter.id}')),
      );
      expect(firstTop.dy, lessThan(secondTop.dy));
      expect(find.text('第一章的句子'), findsOneWidget);
      expect(find.text('第二章的句子'), findsOneWidget);

      // Write a note afterwards （定版 A 的事后补写）.
      await tester.tap(
        find.byKey(ValueKey('bookmark-note-${firstChapter.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bookmark-note-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-note-field')),
        '读到这里很感动',
      );
      await tester.tap(find.byKey(const ValueKey('bookmark-note-save')));
      await io(tester);
      expect(
        state.bookmarksFor(bookA.id).firstWhere((m) => m.id == firstChapter.id).note,
        '读到这里很感动',
      );
      expect(find.text('读到这里很感动'), findsOneWidget);
      expect(find.text('修改感想'), findsOneWidget);

      // Delete the other bookmark through the original confirm flow.
      await tester.tap(glassButton('删除书签 ${secondChapter.id}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除书签').last);
      await io(tester);
      expect(state.bookmarksFor(bookA.id), hasLength(1));
      expect(find.text('第二章的句子'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('adding a bookmark in the reader offers an optional note', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: novelTheme(Brightness.light),
        home: ReaderPage(
          novel: bookA,
          state: state,
          repository: const DemoNovelRepository(),
          initialChapter: 0,
        ),
      ),
    );
    await settleReader(tester);
    await tester.tap(glassButton('阅读设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加当前位置书签'));
    await io(tester);
    // The note sheet is the very next step; writing is optional.
    expect(find.byKey(const ValueKey('bookmark-note-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('bookmark-note-field')),
      '开篇就抓住了我',
    );
    await tester.tap(find.byKey(const ValueKey('bookmark-note-save')));
    await io(tester);
    final mark = state.bookmarksFor(bookA.id).single;
    expect(mark.note, '开篇就抓住了我');
    expect(find.text('已添加书签'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'shelf layout shows the 3D preview and section like the bookshelf, '
    'carousel opens that book\'s bookmarks, list layout hides the preview',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await state.addBookmark(
          novel: bookA,
          position: at(1, 7123402, updatedAt: 300),
          quote: '第二章的句子',
        );
        await state.addBookmark(
          novel: bookA,
          position: at(0, 7123401, updatedAt: 200),
          quote: '第一章的句子',
        );
        await state.addBookmark(
          novel: bookB,
          position: at(0, 7123501, updatedAt: 100),
          quote: '另一本书的句子',
        );
      });
      expect(state.shelfLayout, 'shelf');
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          home: BookmarkLibraryPage(
            state: state,
            repository: const DemoNovelRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Same structure as ShelfPage: carousel preview, then the
      // 全部书籍 / PERSONAL / INDEX section, then the rows.
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('archive-file-carousel')),
        findsOneWidget,
      );
      expect(find.text('全部书籍'), findsOneWidget);
      expect(find.byKey(const ValueKey('bookmark-book-71234')), findsOneWidget);
      expect(find.text('共 2 条书签'), findsOneWidget);

      // The focused preview book is the most recently bookmarked one
      // (bookA); its open affordance goes to that book's bookmarks page,
      // not to a book detail page.
      // The label row sits under the 3D bank's hit area at its centre;
      // the tap still lands on the JellyTapSurface (navigation below
      // proves it), so the missed-hit warning is expected noise here.
      await tester.tap(
        find.byKey(const ValueKey('archive-shelf-open')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BookBookmarksPage), findsOneWidget);
      expect(find.text('2 条书签'), findsOneWidget);
      expect(find.text('第一章的句子'), findsOneWidget);
      expect(find.text('第二章的句子'), findsOneWidget);
      await tester.tap(glassButton('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(BookmarkLibraryPage), findsOneWidget);
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);

      // Switching the shelf to list-only layout (the bookshelf page's
      // own setting) hides the preview here too, via shelfViewChanges.
      await tester.runAsync(() => state.setShelfView(layout: 'list'));
      await tester.pumpAndSettle();
      expect(state.shelfLayout, 'list');
      expect(find.byType(ArchiveFileCarousel), findsNothing);
      expect(find.text('全部书籍'), findsNothing);
      expect(find.byKey(const ValueKey('bookmark-book-71234')), findsOneWidget);
      expect(find.text('共 2 条书签'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

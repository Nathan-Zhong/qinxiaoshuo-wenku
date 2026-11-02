import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/cloud_sources.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_import_batch.dart';
import 'package:wenku8_flutter/local_import_review.dart';
import 'package:wenku8_flutter/local_library_page.dart';
import 'cloud_library_ui_test.dart' show LocalDocumentsFixture, ioSettle;
import 'cloud_sources_test.dart' show MemoryCloudVault;
import 'support/local_series_fixture.dart';
import 'support/visual_review.dart';

class _Documents extends LocalDocumentsFixture {
  _Documents(this.selections);
  final List<BookDocumentSelection> selections;
  bool released = false;
  int picks = 0;
  @override
  Future<List<BookDocumentSelection>> pickBooks() async {
    picks++;
    return selections;
  }

  @override
  Future<void> releaseBooks(Iterable<BookDocumentSelection> books) async {
    released = true;
  }
}

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  setUp(() => SharedPreferences.setMockInitialValues({'reduceMotion': true}));

  Future<
    ({LocalBookStore books, Directory temp, List<BookDocumentSelection> picks})
  >
  sources(WidgetTester tester, {bool mixed = false}) async =>
      (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('local-batch-');
        final books = LocalBookStore(Directory('${dir.path}/library'));
        await books.load();
        final picks = <BookDocumentSelection>[];
        for (final n in [4, 2, 1, 3]) {
          final file = File('${dir.path}/v$n.epub');
          await file.writeAsBytes(seriesEpubFixture(n));
          picks.add(
            BookDocumentSelection(name: '星海图书馆.$n.epub', path: file.path),
          );
        }
        if (mixed) {
          final broken = File('${dir.path}/broken.epub');
          await broken.writeAsBytes([1, 2]);
          picks.insert(
            1,
            BookDocumentSelection(name: '损坏.epub', path: broken.path),
          );
          picks.insert(
            2,
            const BookDocumentSelection(name: '读取失败.txt', error: '提供方无法读取'),
          );
          picks.add(picks.first);
        }
        return (books: books, temp: dir, picks: picks);
      }))!;

  testWidgets(
    'local page import menu offers only cloud import after local import removal',
    (tester) async {
      // 定版清单第 3 条：本地文件导入入口已移除。原用例经本地页菜单的
      // 「导入书籍」进入四卷批量导入并合并系列，该 UI 路径已无入口可达，
      // 故改为断言菜单只剩网盘导入、且不会触发任何文件挑选；批量导入
      // 本身的逻辑仍由下面两个直接调用 importLocalBatch 的用例覆盖。
      final f = await sources(tester);
      final library = await LibraryState.load();
      final docs = _Documents(f.picks);
      final cloud = CloudSourceSettings(storage: MemoryCloudVault());
      addTearDown(library.dispose);
      addTearDown(f.books.dispose);
      addTearDown(cloud.dispose);
      addTearDown(() => f.temp.delete(recursive: true));
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: LocalLibraryPage(
            books: f.books,
            state: library,
            documents: docs,
            cloudSettings: cloud,
            onOpen: (_, _) {},
          ),
        ),
      );
      await ioSettle(tester);
      await tester.tap(find.byKey(const ValueKey('local-import-book')));
      await tester.pumpAndSettle();
      expect(find.text('导入书籍'), findsNothing);
      expect(find.text('扫描本地文件夹'), findsNothing);
      expect(find.text('从网盘导入'), findsOneWidget);
      expect(docs.picks, 0);
      expect(f.books.books, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('batch failures and duplicates do not interrupt later volumes', (
    tester,
  ) async {
    final f = await sources(tester, mixed: true);
    addTearDown(f.books.dispose);
    addTearDown(() => f.temp.delete(recursive: true));
    final progress = <int>[];
    final report = (await tester.runAsync(
      () => importLocalBatch(
        selections: f.picks,
        books: f.books,
        importFile: (name, path) => f.books.importFile(name, path),
        onProgress: (done, _) {
          progress.add(done);
          expect(f.books.series, isEmpty);
        },
      ),
    ))!;
    expect(report.added, 4);
    expect(report.existing, 1);
    expect(report.failures.map((f) => f.name), ['损坏.epub', '读取失败.txt']);
    expect(report.bookIds.length, 4);
    expect(progress, [1, 2, 3, 4, 5, 6, 7]);
    expect(localImportGroups(f.books, report.bookIds).length, 1);
  });

  testWidgets(
    'unrelated series remain separate suggestions; existing series accepts new volumes',
    (tester) async {
      final f = await sources(tester);
      addTearDown(f.books.dispose);
      addTearDown(() => f.temp.delete(recursive: true));
      var report = (await tester.runAsync(() async {
        final report = await importLocalBatch(
          selections: f.picks,
          books: f.books,
          importFile: (name, path) => f.books.importFile(name, path),
        );
        for (final n in [1, 2]) {
          await f.books.import(
            LocalBookInput('远山来信.$n.epub', seriesEpubFixture(n, title: '远山来信')),
          );
        }
        return report;
      }))!;
      final groups = localImportGroups(
        f.books,
        f.books.originals.map((b) => b.id),
      );
      expect(groups.map((g) => g.title).toSet(), {'星海图书馆', '远山来信'});
      final first = groups.firstWhere((g) => g.title == '星海图书馆');
      final series = (await tester.runAsync(
        () => f.books.saveSeries(
          title: first.title,
          volumes: first.volumes.take(2).toList(),
        ),
      ))!;
      final append = localImportGroups(f.books, report.bookIds).single;
      expect(append.targetId, series.id);
      expect(append.volumes.length, 4);
      final library = await LibraryState.load();
      addTearDown(library.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => LocalImportReview(
                      books: f.books,
                      library: library,
                      report: report,
                    ),
                  ),
                ),
                child: const Text('查看结果'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看结果'));
      await tester.pumpAndSettle();
      final skip = find.byKey(const ValueKey('import-keep-separate'));
      await tester.scrollUntilVisible(
        skip,
        180,
        scrollable: find
            .descendant(
              of: find.byType(LocalImportReview),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(skip);
      await tester.pumpAndSettle();
      await tester.tap(skip);
      await tester.pumpAndSettle();
      expect(f.books.series.single.id, series.id);
      expect(
        f.books.series.single.volumes.length,
        2,
        reason: 'Dismissal must not merge anything.',
      );
      report = LocalImportReport(
        bookIds: f.books.originals.map((b) => b.id).toList(),
        added: 6,
        existing: 0,
      );
      await tester.tap(find.text('查看结果'));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('import-confirm-merge'));
      await tester.scrollUntilVisible(
        confirm,
        180,
        scrollable: find
            .descendant(
              of: find.byType(LocalImportReview),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('确认合并 2 个系列'), findsOneWidget);
      await tester.tap(confirm);
      await ioSettle(
        tester,
        until: () => find.byType(LocalImportReview).evaluate().isEmpty,
      );
      expect(f.books.series.map((s) => s.volumes.length).toSet(), {4, 2});
      expect(library.shelf, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

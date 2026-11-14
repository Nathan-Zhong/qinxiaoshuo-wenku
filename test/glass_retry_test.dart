import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/pages.dart';

void main() {
  testWidgets(
    'glass library retry replaces the failed future with a real result',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
      });
      // B2: the discovery feed is served by the Legado engine bridge —
      // the first explore fetch fails, the retry succeeds.
      final engine = _FlakyExplore();
      engine.install();
      addTearDown(engine.uninstall);
      final state = await LibraryState.load();
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      expect(find.text('书籍加载失败'), findsOneWidget);
      expect(find.byType(GlassTextButton), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('书籍加载失败'), findsNothing);
      expect(find.text('重试之书'), findsWidgets);
      expect(find.text('轻小说文库'), findsOneWidget);
      expect(engine.attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'glass detail retry keeps its cover and replaces failed metadata',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
      });
      final state = await LibraryState.load();
      final repository = _RetryDetail();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: DetailLoaderPage(
            novel: demoNovels.first,
            state: state,
            repository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('书籍详情加载失败'), findsOneWidget);
      final cover = find.descendant(
        of: find.byType(DetailPage),
        matching: find.byType(NovelCover),
      );
      final coverElement = tester.element(cover);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('书籍详情加载失败'), findsNothing);
      expect(find.text('简介'), findsOneWidget);
      expect(tester.element(cover), same(coverElement));
      expect(repository.attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('glass chapter retry swaps the failed content future safely', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
    });
    final state = await LibraryState.load();
    final repository = _RetryContent();
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        home: ReaderPage(
          novel: demoNovels.first,
          state: state,
          repository: repository,
          initialChapter: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('章节加载失败'), findsOneWidget);
    expect(find.byType(GlassTextButton), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('章节加载失败'), findsNothing);
    expect(find.text('恢复的正文。'), findsOneWidget);
    expect(repository.attempts, 2);
    expect(tester.takeException(), isNull);
  });
}

/// Engine bridge stand-in whose explore fetch fails exactly once.
class _FlakyExplore {
  static const _channel = MethodChannel('org.mewx.wenku8/legado_engine');
  int attempts = 0;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'init':
              return {'ok': true, 'engineVersion': 'test', 'sourceCount': 1};
            case 'listSources':
              return [
                {
                  'sourceUrl': 'https://src.example',
                  'sourceName': '示例源',
                  'group': '',
                  'type': 0,
                  'enabled': true,
                  'enabledExplore': true,
                  'customOrder': 0,
                  'weight': 0,
                  'respondTimeMs': 1,
                  'lastUpdateTime': 0,
                  'hasLogin': false,
                },
              ];
            case 'getExploreKinds':
              return [
                {
                  'title': '全部',
                  'url': 'kind/all',
                  'viewName': 'text',
                  'style': 3,
                },
              ];
            case 'getExploreBooks':
              attempts++;
              if (attempts == 1) {
                throw PlatformException(code: 'NET', message: 'down');
              }
              return {
                'books': [
                  {
                    'name': '重试之书',
                    'author': '佚名',
                    'bookUrl': 'https://src.example/book/7',
                    'tocUrl': '',
                    'origin': 'https://src.example',
                    'originName': '示例源',
                    'origins': ['https://src.example'],
                    'type': 0,
                    'kind': '玄幻',
                    'coverUrl': null,
                    'intro': '重试后出现的书。',
                    'wordCount': null,
                    'latestChapterTitle': '第一章',
                    'chapterWordCount': 0,
                    'variable': null,
                  },
                ],
                'hasMore': false,
              };
          }
          return null;
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

class _RetryDetail extends DemoNovelRepository {
  int attempts = 0;
  @override
  Future<Novel> detail(Novel novel) async {
    if (attempts++ == 0) throw StateError('fixture detail failure');
    return novel;
  }
}

class _RetryContent extends DemoNovelRepository {
  int attempts = 0;
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    if (identical(chapter, demoNovels.first.chapters.first) &&
        attempts++ == 0) {
      throw StateError('fixture content failure');
    }
    return '恢复的正文。';
  }
}

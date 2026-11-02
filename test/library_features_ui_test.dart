import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/my_page.dart';

Novel _book(int id) => Novel(
  id: id,
  title: '功能作品 $id',
  author: '功能作者',
  genre: '轻小说',
  summary: '作品介绍',
  colors: const [Colors.blue, Colors.black],
  chapters: [
    NovelChapter(
      '章节 A',
      List.generate(180, (i) => '段落 $i：这是一段用于检验阅读位置保存与恢复的正文。' * 3).join('\n\n'),
      id: 11,
    ),
    NovelChapter(
      '章节 B',
      List.generate(120, (i) => '下一章段落 $i：正文。' * 5).join('\n\n'),
      id: 22,
    ),
  ],
);

class _Repository extends DemoNovelRepository {
  final calls = <(NovelSort, int)>[];
  var failList = false;
  var failSecond = false;
  var failFind = false;
  var failContent = false;
  int findCalls = 0;

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    calls.add((sort, page));
    if (failList || (failSecond && page == 2)) throw StateError('network');
    return NovelPage(
      items: List.generate(20, (i) => _book((page - 1) * 20 + i + 1)),
      page: page,
      totalPages: 2,
    );
  }

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) => browse(page: page, refresh: refresh);

  @override
  Future<Novel?> find(int id) async {
    findCalls++;
    if (failFind) throw StateError('network');
    return _book(id);
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    if (failContent) throw StateError('network');
    return chapter.content;
  }
}

Finder _control(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) => w is GlassIconButton && w.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

/// Legado engine bridge stand-in: one source with two explore kinds,
/// twenty books per explore page, and a push-driven search stream.
class _EngineMock {
  static const _methodChannel = MethodChannel('org.mewx.wenku8/legado_engine');
  static const _searchChannel = EventChannel(
    'org.mewx.wenku8/legado_search_events',
  );

  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final exploreRequests = <(String, int)>[];
  var failExplore = false;
  var failSecondExplorePage = false;

  /// The search EventChannel is mocked at the message level (listen /
  /// cancel answered with the standard codec, events pushed as success
  /// envelopes): MockStreamHandler's activation path rejects streams
  /// started from inside a testWidgets fake-async zone.
  static const _codec = StandardMethodCodec();
  static bool _searchListening = false;
  int? searchTaskId;

  static Map<String, Object?> bookJson(String name, String bookUrl) => {
    'name': name,
    'author': '功能作者',
    'bookUrl': bookUrl,
    'tocUrl': '',
    'origin': 'https://src.example',
    'originName': '示例源',
    'origins': ['https://src.example'],
    'type': 0,
    'kind': '玄幻',
    'coverUrl': null,
    'intro': '简介',
    'wordCount': null,
    'latestChapterTitle': '第一章',
    'chapterWordCount': 0,
    'variable': null,
  };

  static Map<String, Object?> searchBookJson(String name, String bookUrl) =>
      bookJson(name, bookUrl);

  void install() {
    _messenger.setMockMethodCallHandler(_methodChannel, (call) async {
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
            {'title': '玄幻', 'url': 'kind/xh', 'viewName': 'text', 'style': 3},
            {'title': '都市', 'url': 'kind/ds', 'viewName': 'text', 'style': 3},
          ];
        case 'getExploreBooks':
          final args = (call.arguments as Map).cast<String, Object?>();
          final kind = args['kindUrl'] as String;
          final page = args['page'] as int;
          exploreRequests.add((kind, page));
          if (failExplore || (failSecondExplorePage && page == 2)) {
            throw PlatformException(code: 'NET', message: 'down');
          }
          final prefix = kind == 'kind/ds' ? '都市书' : '玄幻书';
          return {
            'books': [
              for (var i = 1; i <= 20; i++)
                bookJson(
                  '$prefix ${(page - 1) * 20 + i}',
                  'https://src.example/$kind/${(page - 1) * 20 + i}',
                ),
            ],
            'hasMore': page < 2,
          };
        case 'startSearch':
          final args = (call.arguments as Map).cast<String, Object?>();
          searchTaskId = args['taskId'] as int;
          return null;
      }
      return null;
    });
    _messenger.setMockMessageHandler(_searchChannel.name, (message) async {
      if (message == null) return null;
      final call = _codec.decodeMethodCall(message);
      if (call.method == 'listen') {
        _searchListening = true;
        return _codec.encodeSuccessEnvelope(null);
      }
      if (call.method == 'cancel') {
        _searchListening = false;
        return _codec.encodeSuccessEnvelope(null);
      }
      return null;
    });
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(_methodChannel, null);
    _messenger.setMockMessageHandler(_searchChannel.name, null);
    _searchListening = false;
  }

  void _pushSearchEvent(Map<String, Object?> event) {
    assert(_searchListening, 'search stream is not listening');
    _messenger.handlePlatformMessage(
      _searchChannel.name,
      _codec.encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  void pushSearchSnapshot(
    List<Map<String, Object?>> books, {
    required bool hasMore,
  }) {
    _pushSearchEvent({
      'type': 'searchSnapshot',
      'taskId': searchTaskId,
      'books': books,
      'groups': <Object?>[],
      'hasMore': hasMore,
    });
  }

  void pushSearchFinish() {
    _pushSearchEvent({
      'type': 'searchFinish',
      'taskId': searchTaskId,
      'isEmpty': false,
      'hasMore': false,
    });
  }
}

ScrollableState _scroll(WidgetTester tester, Finder parent) =>
    tester.state<ScrollableState>(
      find.descendant(of: parent, matching: find.byType(Scrollable)).first,
    );

Future<LibraryState> _mount(
  WidgetTester tester,
  _Repository repository, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    'readerChromeVisible': true,
    'readerChromeHintSeen': true,
    'shelfLayout': 'list',
    ...prefs,
  });
  final state = await LibraryState.load();
  await tester.pumpWidget(NovelApp(state: state, repository: repository));
  await tester.pumpAndSettle();
  return state;
}

Future<void> _reader(
  WidgetTester tester,
  LibraryState state,
  _Repository repository, {
  int chapter = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: novelTheme(Brightness.light),
      home: ReaderPage(
        novel: _book(5000),
        state: state,
        repository: repository,
        initialChapter: chapter,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // B2: discovery is fed by the Legado engine (selected source's
  // explore lists), so these cases drive the bridge stand-in instead
  // of the shell repository's catalogue methods.
  testWidgets(
    'explore loads page two lazily and the picker switches source kinds',
    (tester) async {
      final engine = _EngineMock()..install();
      addTearDown(engine.uninstall);
      final repository = _Repository();
      await _mount(tester, repository);
      final feed = tester.widget<DiscoverPage>(find.byType(DiscoverPage)).feed!;
      expect(feed.items.length, 20);
      expect(feed.items.first.title, startsWith('玄幻书'));
      final scroll = _scroll(
        tester,
        find.byKey(const PageStorageKey('discover')),
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(feed.page, 2);
      expect(feed.items.length, 40);
      expect(find.byType(NovelRow).evaluate().length, lessThan(25));
      scroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(_control('分类与排序'));
      await tester.pumpAndSettle();
      expect(find.byType(GlassOverlaySurface), findsOneWidget);
      await tester.tap(find.text('都市'));
      await tester.pumpAndSettle();
      expect(engine.exploreRequests, contains(('kind/ds', 1)));
      expect(feed.page, 1);
      expect(feed.items.first.title, startsWith('都市书'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pagination errors retain books and only explicit retry resumes loading',
    (tester) async {
      final engine = _EngineMock()..failSecondExplorePage = true;
      engine.install();
      addTearDown(engine.uninstall);
      await _mount(tester, _Repository());
      final scroll = _scroll(
        tester,
        find.byKey(const PageStorageKey('discover')),
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('加载下一页失败'), findsOneWidget);
      expect(engine.exploreRequests.length, 2);
      final feed = tester.widget<DiscoverPage>(find.byType(DiscoverPage)).feed!;
      expect(feed.items.length, 20);
      engine.failSecondExplorePage = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(feed.items.length, 40);
      expect(feed.page, 2);
    },
  );

  testWidgets('inline search continues beyond its first twenty matches', (
    tester,
  ) async {
    final engine = _EngineMock()..install();
    addTearDown(engine.uninstall);
    await _mount(tester, _Repository());
    await tester.tap(_control('搜索'));
    await tester.pumpAndSettle();
    final results = find.byType(InlineSearchResults);
    final feed = tester.widget<InlineSearchResults>(results).feed;
    await tester.enterText(find.byType(TextField).first, '搜索书');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(engine.searchTaskId, isNotNull);
    // Streaming search: snapshots grow the same result list in place
    // instead of paging, so matches past the first twenty just appear.
    engine.pushSearchSnapshot([
      for (var i = 1; i <= 20; i++)
        _EngineMock.searchBookJson('搜索书 $i', 'https://src.example/s/$i'),
    ], hasMore: true);
    await tester.pumpAndSettle();
    expect(feed.items.length, 20);
    engine.pushSearchSnapshot([
      for (var i = 1; i <= 40; i++)
        _EngineMock.searchBookJson('搜索书 $i', 'https://src.example/s/$i'),
    ], hasMore: false);
    engine.pushSearchFinish();
    await tester.pumpAndSettle();
    expect(feed.items.length, 40);
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets(
    'shelf and settings remain available when the recent list fails',
    (tester) async {
      final engine = _EngineMock()..failExplore = true;
      engine.install();
      addTearDown(engine.uninstall);
      SharedPreferences.setMockInitialValues({
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
        'shelfLayout': 'list',
      });
      final state = await LibraryState.load();
      await state.toggleShelf(5000, novel: _book(5000));
      await state.setChapter(5000, 1);
      final repository = _Repository();
      await tester.pumpWidget(NovelApp(state: state, repository: repository));
      await tester.pumpAndSettle();
      expect(find.text('书籍加载失败'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dock-tab-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shelf-book-5000')), findsOneWidget);
      expect(find.text('2/2'), findsOneWidget);
      expect(repository.findCalls, 0);
      await tester.tap(find.byKey(const ValueKey('dock-tab-3')));
      await tester.pumpAndSettle();
      expect(find.byType(MyPage), findsOneWidget);
      expect(find.text('书籍加载失败'), findsNothing);
    },
  );

  testWidgets(
    'old shelf IDs load independently, retry and cache their metadata',
    (tester) async {
      final repository = _Repository()..failFind = true;
      final state = await _mount(
        tester,
        repository,
        prefs: {
          'shelf': ['5000'],
          'chapter_5000': 1,
        },
      );
      await tester.tap(find.byKey(const ValueKey('dock-tab-1')));
      await tester.pumpAndSettle();
      expect(find.text('1 本'), findsOneWidget);
      expect(find.text('书籍 5000 暂未载入'), findsOneWidget);
      expect(state.contains(5000), isTrue);
      repository.failFind = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shelf-book-5000')), findsOneWidget);
      expect((await LibraryState.load()).cachedNovel(5000)!.title, '功能作品 5000');
    },
  );

  testWidgets('shelf removal can be undone without losing chapter progress', (
    tester,
  ) async {
    final state = await _mount(tester, _Repository());
    await state.toggleShelf(5000, novel: _book(5000));
    await state.setChapter(5000, 1);
    await tester.tap(find.byKey(const ValueKey('dock-tab-1')));
    await tester.pumpAndSettle();
    await tester.tap(_control('功能作品 5000书架操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移出书架'));
    await tester.pumpAndSettle();
    expect(state.contains(5000), isFalse);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(state.contains(5000), isTrue);
    expect(find.text('2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reader restores its real scroll position after closing and reloading preferences',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
        'reduceMotion': true,
      });
      var state = await LibraryState.load();
      final repository = _Repository();
      await _reader(tester, state, repository);
      var scroll = _scroll(tester, find.byKey(const ValueKey('reader-scroll')));
      scroll.position.jumpTo(18000);
      await tester.pumpAndSettle();
      final offset = scroll.position.pixels;
      // Scroll-end persistence deliberately waits for stable idle so a new
      // contact does not inherit anchor calculation and disk work.
      await tester.pump(const Duration(milliseconds: 180));
      expect(state.positionFor(5000)!.offset, closeTo(offset, .1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      state = await LibraryState.load();
      await _reader(
        tester,
        state,
        repository,
        chapter: state.chapterForNovel(_book(5000)),
      );
      scroll = _scroll(tester, find.byKey(const ValueKey('reader-scroll')));
      expect(scroll.position.pixels, closeTo(offset, 1));
      expect(state.positionFor(5000)!.chapterId, 11);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'next chapter starts at zero and backgrounding persists progress',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
        'reduceMotion': true,
      });
      final state = await LibraryState.load();
      await _reader(tester, state, _Repository());
      final scroll = _scroll(
        tester,
        find.byKey(const ValueKey('reader-scroll')),
      );
      scroll.position.jumpTo(1200);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dock-tab-2')));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, 0);
      expect(state.chapterFor(5000), 1);
      scroll.position.jumpTo(600);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      final reloaded = await LibraryState.load();
      expect(reloaded.positionFor(5000)!.chapterId, 22);
      expect(reloaded.positionFor(5000)!.offset, closeTo(600, 1));
    },
  );

  testWidgets(
    'a failed chapter load never overwrites a saved reading position',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
        'reduceMotion': true,
      });
      final state = await LibraryState.load();
      await state.savePosition(
        novel: _book(5000),
        chapter: 0,
        offset: 700,
        maximum: 10000,
        width: 800,
      );
      await _reader(
        tester,
        state,
        _Repository()..failContent = true,
        chapter: 1,
      );
      expect(find.text('章节加载失败'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final reloaded = await LibraryState.load();
      expect(reloaded.positionFor(5000)!.offset, 700);
      expect(reloaded.chapterFor(5000), 0);
    },
  );

  testWidgets('a missing shelf book can still be removed and restored', (
    tester,
  ) async {
    final state = await _mount(
      tester,
      _Repository()..failFind = true,
      prefs: {
        'shelf': ['5000'],
        'chapter_5000': 1,
      },
    );
    await tester.tap(find.byKey(const ValueKey('dock-tab-1')));
    await tester.pumpAndSettle();
    await tester.tap(_control('书籍 5000 书架操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移出书架'));
    await tester.pumpAndSettle();
    expect(state.shelf, isEmpty);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(state.shelf, {5000});
    expect(state.chapterFor(5000), 1);
  });

  testWidgets(
    'continue reading resolves the saved chapter ID after a directory insertion',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
        'reduceMotion': true,
      });
      final state = await LibraryState.load();
      final old = _book(5000);
      await state.savePosition(
        novel: old,
        chapter: 1,
        offset: 700,
        maximum: 10000,
        width: 800,
      );
      final novel = old.withChapters([
        const NovelChapter('插入章节', '新增正文', id: 5),
        ...old.chapters,
      ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: DetailPage(
            novel: novel,
            state: state,
            repository: _Repository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detail-read-button')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).initialChapter,
        2,
      );
      expect(state.positionFor(5000)!.chapterId, 22);
      expect(state.chapterFor(5000), 2);
      expect(tester.takeException(), isNull);
    },
  );
}

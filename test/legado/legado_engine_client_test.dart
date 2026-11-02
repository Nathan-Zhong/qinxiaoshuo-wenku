import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';
import 'package:wenku8_flutter/legado/legado_engine_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(LegadoEngineClient.methodChannelName);
  const searchChannel = EventChannel(LegadoEngineClient.searchEventChannelName);
  const taskChannel = EventChannel(LegadoEngineClient.taskEventChannelName);

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late LegadoEngineClient client;
  late List<MethodCall> calls;
  Object? Function(MethodCall call)? responder;

  setUp(() {
    calls = <MethodCall>[];
    responder = null;
    client = LegadoEngineClient(
      methodChannel: methodChannel,
      searchEventChannel: searchChannel,
      taskEventChannel: taskChannel,
    );
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      return responder?.call(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(searchChannel, null);
    messenger.setMockStreamHandler(taskChannel, null);
  });

  MethodCall callFor(String method) =>
      calls.singleWhere((c) => c.method == method);

  Map<String, Object?> argsOf(String method) =>
      (callFor(method).arguments as Map).cast<String, Object?>();

  group('engine handshake', () {
    test('ping maps facade answer', () async {
      responder = (call) => <String, Object?>{
        'engineVersion': '0.1.0-spike1',
        'includedModules': <String>[':foundation', ':data'],
        'upstreamCommit': 'd31c0a2',
      };
      final result = await client.ping();
      expect(callFor('ping').arguments, isNull);
      expect(result.engineVersion, '0.1.0-spike1');
      expect(result.includedModules, <String>[':foundation', ':data']);
      expect(result.upstreamCommit, 'd31c0a2');
    });

    test('init maps engine info', () async {
      responder = (call) => <String, Object?>{
        'ok': true,
        'engineVersion': '0.1.0-spike1',
        'sourceCount': 0,
      };
      final info = await client.init();
      expect(argsOf('init'), isEmpty);
      expect(info.ok, isTrue);
      expect(info.engineVersion, '0.1.0-spike1');
      expect(info.sourceCount, 0);
    });
  });

  group('source management', () {
    test('listSources sends filters and maps summaries', () async {
      responder = (call) => <Object?>[
        <String, Object?>{
          'sourceUrl': 'https://a.example',
          'sourceName': 'A源',
          'type': 0,
          'enabled': true,
          'enabledExplore': true,
        },
        <String, Object?>{
          'sourceUrl': 'https://m.example',
          'sourceName': '漫画源',
          'type': 2,
          'enabled': false,
        },
      ];
      final sources = await client.listSources(group: '优质', enabledOnly: true);
      final args = argsOf('listSources');
      expect(args['group'], '优质');
      expect(args['enabledOnly'], isTrue);
      expect(args['exploreOnly'], isFalse);
      expect(sources, hasLength(2));
      expect(sources.first.sourceName, 'A源');
      expect(sources.last.type, 2);
      expect(sources.last.enabled, isFalse);
    });

    test('getSource returns null when native has no such source', () async {
      responder = (call) => null;
      expect(await client.getSource('https://none.example'), isNull);
      expect(argsOf('getSource')['sourceUrl'], 'https://none.example');
    });

    test('setSourceEnabled single and batch argument shapes', () async {
      await client.setSourceEnabled('https://a.example', false);
      await client.setSourcesEnabled(<String>['https://a.example'], true);
      final all = calls.where((c) => c.method == 'setSourceEnabled').toList();
      expect(all, hasLength(2));
      final first = (all[0].arguments as Map).cast<String, Object?>();
      final second = (all[1].arguments as Map).cast<String, Object?>();
      expect(first['sourceUrl'], 'https://a.example');
      expect(first['enabled'], isFalse);
      expect(second['sourceUrls'], <String>['https://a.example']);
      expect(second['enabled'], isTrue);
    });

    test('deleteSources returns the native deleted count', () async {
      responder = (call) => <String, Object?>{'deleted': 2};
      final deleted = await client.deleteSources(<String>[
        'https://a.example',
        'https://b.example',
      ]);
      expect(deleted, 2);
      expect(argsOf('deleteSources')['sourceUrls'], <String>[
        'https://a.example',
        'https://b.example',
      ]);
    });

    test('checkSources returns the task id it sent', () async {
      responder = (call) {
        final args = (call.arguments as Map).cast<String, Object?>();
        return <String, Object?>{'taskId': args['taskId']};
      };
      final taskId = await client.checkSources(
        sourceUrls: <String>['https://a.example'],
      );
      expect(taskId, argsOf('checkSources')['taskId']);
      expect(taskId, greaterThan(0));
    });
  });

  group('import', () {
    final importReply = <String, Object?>{
      'added': 2,
      'updated': 1,
      'unchanged': 0,
      'failed': 1,
      'sources': <Object?>[
        <String, Object?>{'sourceUrl': 'https://a.example', 'sourceName': 'A源'},
      ],
      'errors': <String>['broken json'],
    };

    test('importFromJsonText uses payloadKind text and maps result', () async {
      responder = (call) => importReply;
      final result = await client.importFromJsonText('[{"bookSourceUrl":1}]');
      final args = argsOf('importSources');
      expect(args['payloadKind'], 'text');
      expect(args['payload'], '[{"bookSourceUrl":1}]');
      expect(result.added, 2);
      expect(result.updated, 1);
      expect(result.failed, 1);
      expect(result.sources.single.sourceUrl, 'https://a.example');
      expect(result.errors, <String>['broken json']);
    });

    test('importFromUrl uses payloadKind url', () async {
      responder = (call) => importReply;
      await client.importFromUrl('https://sub.example/all.json');
      final args = argsOf('importSources');
      expect(args['payloadKind'], 'url');
      expect(args['payload'], 'https://sub.example/all.json');
    });

    test('importFromFilePath uses payloadKind filePath', () async {
      responder = (call) => importReply;
      await client.importFromFilePath('/data/sources.json');
      expect(argsOf('importSources')['payloadKind'], 'filePath');
    });
  });

  group('explore', () {
    test('getExploreKinds and getExploreBooks map results', () async {
      responder = (call) {
        if (call.method == 'getExploreKinds') {
          return <Object?>[
            <String, Object?>{'title': '分类'},
            <String, Object?>{
              'title': '玄幻',
              'url': 'https://a.example/c/1',
              'style': 0,
            },
          ];
        }
        return <String, Object?>{
          'books': <Object?>[
            <String, Object?>{
              'name': '书',
              'author': '者',
              'bookUrl': 'https://a.example/1',
              'origin': 'https://a.example',
            },
          ],
          'hasMore': true,
        };
      };
      final kinds = await client.getExploreKinds('https://a.example');
      expect(kinds.first.isGroupHeading, isTrue);
      expect(kinds.last.title, '玄幻');
      final page = await client.getExploreBooks(
        sourceUrl: 'https://a.example',
        kindUrl: 'https://a.example/c/1',
        page: 2,
      );
      expect(argsOf('getExploreBooks')['page'], 2);
      expect(page.hasMore, isTrue);
      expect(page.books.single.name, '书');
    });
  });

  group('book chain', () {
    const info = BookInfo(
      name: '书',
      author: '者',
      bookUrl: 'https://a.example/1',
      tocUrl: 'https://a.example/1/toc',
      origin: 'https://a.example',
      variable: 'var-1',
    );

    test('getBookInfo passes variable through and maps the reply', () async {
      responder = (call) => <String, Object?>{
        'name': '书',
        'author': '者',
        'bookUrl': 'https://a.example/1',
        'tocUrl': 'https://a.example/1/toc',
        'origin': 'https://a.example',
        'variable': 'var-2',
        'totalChapterNum': 12,
        'canUpdate': true,
      };
      final result = await client.getBookInfo(
        origin: 'https://a.example',
        bookUrl: 'https://a.example/1',
        variable: 'var-1',
      );
      expect(argsOf('getBookInfo')['variable'], 'var-1');
      expect(result.variable, 'var-2');
      expect(result.totalChapterNum, 12);
    });

    test('getChapterList sends engine book args and maps chapters', () async {
      responder = (call) => <String, Object?>{
        'book': <String, Object?>{
          'name': '书',
          'author': '者',
          'bookUrl': 'https://a.example/1',
          'origin': 'https://a.example',
          'totalChapterNum': 2,
        },
        'chapters': <Object?>[
          <String, Object?>{
            'url': 'https://a.example/1/c1',
            'title': '第一章',
            'index': 0,
          },
          <String, Object?>{
            'url': 'https://a.example/1/c2',
            'title': '第二章',
            'index': 1,
            'isVip': true,
          },
        ],
      };
      final result = await client.getChapterList(book: info);
      final args = argsOf('getChapterList');
      expect(args['origin'], 'https://a.example');
      expect(args['bookUrl'], 'https://a.example/1');
      expect(args['tocUrl'], 'https://a.example/1/toc');
      expect(args['variable'], 'var-1');
      expect(args['forceRefresh'], isFalse);
      expect(result.book.totalChapterNum, 2);
      expect(result.chapters, hasLength(2));
      expect(result.chapters.last.isVip, isTrue);
    });

    test('getChapterContent maps images for manga chapters', () async {
      responder = (call) => <String, Object?>{
        'content': '<img src="https://img.example/1.jpg">',
        'images': <String>['https://img.example/1.jpg'],
        'isImageChapter': true,
      };
      const chapter = Chapter(
        url: 'https://a.example/1/c1',
        title: '第一话',
        index: 0,
      );
      final content = await client.getChapterContent(
        book: info,
        chapter: chapter,
      );
      final args = argsOf('getChapterContent');
      expect(args['chapterUrl'], 'https://a.example/1/c1');
      expect(args['chapterIndex'], 0);
      expect(args['applyReplace'], isFalse);
      expect(content.isImageChapter, isTrue);
      expect(content.images, <String>['https://img.example/1.jpg']);
    });

    test('resolveImageRequest returns url and headers', () async {
      responder = (call) => <String, Object?>{
        'url': 'https://img.example/real.jpg',
        'headers': <String, String>{'Referer': 'https://a.example/'},
      };
      final request = await client.resolveImageRequest(
        origin: 'https://a.example',
        url: 'https://img.example/raw.jpg',
      );
      expect(request.url, 'https://img.example/real.jpg');
      expect(request.headers, <String, String>{
        'Referer': 'https://a.example/',
      });
    });

    test('applyChangeSource sends progress anchor and maps match', () async {
      responder = (call) => <String, Object?>{
        'book': <String, Object?>{
          'name': '书',
          'author': '者',
          'bookUrl': 'https://b.example/1',
          'origin': 'https://b.example',
        },
        'chapters': <Object?>[],
        'matchedChapterIndex': 7,
      };
      final result = await client.applyChangeSource(
        oldBookKey: 'https://a.example\nhttps://a.example/1',
        newOrigin: 'https://b.example',
        newBookUrl: 'https://b.example/1',
        durChapterIndex: 7,
        durChapterTitle: '第八章',
      );
      final args = argsOf('applyChangeSource');
      expect(args['durChapterIndex'], 7);
      expect(args['durChapterTitle'], '第八章');
      expect(result.matchedChapterIndex, 7);
      expect(result.book.origin, 'https://b.example');
    });
  });

  group('subscriptions', () {
    test(
      'upsertSubscription round-trips and update maps ImportResult',
      () async {
        responder = (call) {
          if (call.method == 'upsertSubscription') return call.arguments;
          return <String, Object?>{'added': 4, 'updated': 0};
        };
        const sub = LegadoSubscription(
          name: '源仓库订阅',
          url: 'https://sub.example/feed.json',
          autoUpdate: true,
        );
        final saved = await client.upsertSubscription(sub);
        expect(saved.name, '源仓库订阅');
        expect(saved.autoUpdate, isTrue);
        final result = await client.updateSubscription(3);
        expect(argsOf('updateSubscription')['id'], 3);
        expect(result.added, 4);
      },
    );
  });

  group('search streaming', () {
    test(
      'startSearch sends args; stream filters by taskId; cancel works',
      () async {
        MockStreamHandlerEventSink? sink;
        messenger.setMockStreamHandler(
          searchChannel,
          MockStreamHandler.inline(
            onListen: (arguments, events) => sink = events,
            onCancel: (arguments) {},
          ),
        );
        responder = (call) => null;

        final handle = client.startSearch(
          keyword: '刀剑',
          sourceUrls: <String>['https://a.example'],
          precision: true,
        );
        final received = <LegadoSearchEvent>[];
        final subscription = handle.events.listen(received.add);
        await pumpEventQueue();

        final args = argsOf('startSearch');
        expect(args['taskId'], handle.taskId);
        expect(args['keyword'], '刀剑');
        expect(args['precision'], isTrue);
        expect(
          (args['scope'] as Map).cast<String, Object?>()['sourceUrls'],
          <String>['https://a.example'],
        );
        expect(sink, isNotNull);

        // An event for another task must not leak into this stream.
        sink!.success(<String, Object?>{
          'type': 'searchSnapshot',
          'taskId': handle.taskId + 999,
          'books': <Object?>[],
          'hasMore': false,
        });
        sink!.success(<String, Object?>{
          'type': 'searchSnapshot',
          'taskId': handle.taskId,
          'books': <Object?>[
            <String, Object?>{
              'name': '刀剑神域',
              'author': '川原砾',
              'bookUrl': 'https://a.example/1',
              'origin': 'https://a.example',
              'origins': <String>['https://a.example'],
            },
          ],
          'groups': <Object?>[
            <String, Object?>{
              'origin': 'https://a.example',
              'originName': 'A源',
              'count': 1,
            },
          ],
          'hasMore': true,
        });
        sink!.success(<String, Object?>{
          'type': 'searchFinish',
          'taskId': handle.taskId,
          'isEmpty': false,
          'hasMore': true,
        });
        await pumpEventQueue();

        expect(received, hasLength(2));
        final snapshot = received.first as SearchSnapshotEvent;
        expect(snapshot.books.single.name, '刀剑神域');
        expect(snapshot.groups.single.count, 1);
        expect(snapshot.hasMore, isTrue);
        expect(received.last, isA<SearchFinishEvent>());

        await handle.cancel();
        expect(argsOf('cancelTask')['taskId'], handle.taskId);
        await subscription.cancel();
      },
    );
  });

  group('task events', () {
    test('check progress and done parse from the task channel', () async {
      MockStreamHandlerEventSink? sink;
      messenger.setMockStreamHandler(
        taskChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) => sink = events,
          onCancel: (arguments) {},
        ),
      );
      final events = <LegadoTaskEvent>[];
      final subscription = client.taskEvents.listen(events.add);
      await pumpEventQueue();
      sink!.success(<String, Object?>{
        'type': 'checkProgress',
        'taskId': 5,
        'sourceUrl': 'https://a.example',
        'state': 'fail',
        'message': 'timeout',
        'done': 1,
        'total': 3,
      });
      sink!.success(<String, Object?>{
        'type': 'checkDone',
        'taskId': 5,
        'okCount': 2,
        'failCount': 1,
      });
      sink!.success(<String, Object?>{'type': 'somethingNew', 'taskId': 5});
      await pumpEventQueue();

      expect(events, hasLength(3));
      final progress = events[0] as CheckProgressEvent;
      expect(progress.ok, isFalse);
      expect(progress.message, 'timeout');
      expect(progress.done, 1);
      expect((events[1] as CheckDoneEvent).okCount, 2);
      expect(events[2], isA<UnknownTaskEvent>());
      await subscription.cancel();
    });
  });
}

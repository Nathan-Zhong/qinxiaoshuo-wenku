import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared Legado engine bridge stand-in for widget tests (B2:
/// discovery and global search are engine-fed, so shell tests that
/// used to rely on the catalogue repository now drive this mock).
///
/// Defaults serve one source whose explore list mirrors the demo
/// catalogue's first books, so title-based finders keep working.
/// Search is driven by pushing stream events for the recorded task
/// ids; the EventChannel is mocked at the message level because
/// MockStreamHandler rejects activations from fake-async zones.
class LegadoEngineMock {
  static const methodChannel = MethodChannel('org.mewx.wenku8/legado_engine');
  static const searchChannelName = 'org.mewx.wenku8/legado_search_events';
  static const _codec = StandardMethodCodec();

  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Explore books served by getExploreBooks (single page by default).
  List<Map<String, Object?>> exploreBooks = [
    bookJson(moonBook),
    bookJson(glassBook),
  ];
  bool exploreHasMore = false;

  /// Explore kinds served by getExploreKinds.
  List<Map<String, Object?>> exploreKinds = [
    {'title': '全部', 'url': 'kind/all', 'viewName': 'text', 'style': 3},
  ];

  /// Optional per-kind explore lists, keyed by kind url; wins over
  /// [exploreBooks] when the requested kind has an entry.
  Map<String, List<Map<String, Object?>>> exploreBooksByKind = {};

  /// When set, getExploreBooks throws this instead of answering.
  Object? exploreError;

  /// When set, getExploreBooks waits for this completer first.
  Completer<void>? exploreGate;

  final exploreCalls = <int>[];
  final searchTaskIds = <int>[];
  final searchKeywords = <String>[];
  bool _listening = false;

  static const moonBook = (
    name: '月光航线',
    author: '林见舟',
    url: 'https://src.example/b/moon',
  );
  static const glassBook = (
    name: '玻璃海纪事',
    author: '沈听澜',
    url: 'https://src.example/b/glass',
  );

  static Map<String, Object?> bookJson(
    ({String name, String author, String url}) book,
  ) => {
    'name': book.name,
    'author': book.author,
    'bookUrl': book.url,
    'tocUrl': '',
    'origin': 'https://src.example',
    'originName': '示例源',
    'origins': ['https://src.example'],
    'type': 0,
    'kind': '都市 · 治愈',
    'coverUrl': null,
    'intro': '在城市最后一班渡轮上，两个素不相识的人交换了写给未来的信。',
    'wordCount': null,
    'latestChapterTitle': '第一章',
    'chapterWordCount': 0,
    'variable': null,
  };

  void install() {
    _messenger.setMockMethodCallHandler(methodChannel, (call) async {
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
          return exploreKinds;
        case 'getExploreBooks':
          final args = (call.arguments as Map).cast<String, Object?>();
          exploreCalls.add(args['page'] as int);
          final gate = exploreGate;
          if (gate != null) await gate.future;
          final error = exploreError;
          if (error != null) throw error;
          final books = exploreBooksByKind[args['kindUrl']] ?? exploreBooks;
          return {'books': books, 'hasMore': exploreHasMore};
        case 'startSearch':
          final args = (call.arguments as Map).cast<String, Object?>();
          searchTaskIds.add(args['taskId'] as int);
          searchKeywords.add(args['keyword'] as String);
          return null;
      }
      return null;
    });
    _messenger.setMockMessageHandler(searchChannelName, (message) async {
      if (message == null) return null;
      final call = _codec.decodeMethodCall(message);
      if (call.method == 'listen') {
        _listening = true;
        return _codec.encodeSuccessEnvelope(null);
      }
      if (call.method == 'cancel') {
        _listening = false;
        return _codec.encodeSuccessEnvelope(null);
      }
      return null;
    });
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(methodChannel, null);
    _messenger.setMockMessageHandler(searchChannelName, null);
  }

  void pushSnapshot(
    int taskId,
    List<Map<String, Object?>> books, {
    bool hasMore = false,
  }) {
    assert(_listening, 'search stream is not listening');
    _messenger.handlePlatformMessage(
      searchChannelName,
      _codec.encodeSuccessEnvelope({
        'type': 'searchSnapshot',
        'taskId': taskId,
        'books': books,
        'groups': <Object?>[],
        'hasMore': hasMore,
      }),
      (_) {},
    );
  }

  void pushFinish(int taskId, {bool isEmpty = false}) {
    _messenger.handlePlatformMessage(
      searchChannelName,
      _codec.encodeSuccessEnvelope({
        'type': 'searchFinish',
        'taskId': taskId,
        'isEmpty': isEmpty,
        'hasMore': false,
      }),
      (_) {},
    );
  }

  void pushError() {
    _messenger.handlePlatformMessage(
      searchChannelName,
      _codec.encodeErrorEnvelope(code: 'NET', message: 'boom'),
      (_) {},
    );
  }
}

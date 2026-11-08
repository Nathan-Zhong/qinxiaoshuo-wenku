import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'library_state.dart';
import 'local_books.dart';
import 'online_book_handoff.dart';
import 'reader_content.dart';

/// The wire contract stays deliberately small: a versioned JSON envelope with
/// a device identity, a four-digit confirmation code and one of two payloads.
/// No reading body, login session or device geometry ever crosses the network.
const _protocol = 'wenku8-lan-reading';
const _version = 1;
const _preferredPort = 47821;
const _discoveryPort = 47822;
const _maxBodyBytes = 512 * 1024;
const _peerLifetime = Duration(seconds: 20);
const _beaconInterval = Duration(seconds: 6);

const _deviceIdKey = 'lan_reading_device_id';
const _deviceNameKey = 'lan_reading_device_name';
const _pairedKey = 'lan_reading_paired_devices';

/// One device seen on the same Wi-Fi, either through the broadcast beacon or a
/// manual address. `seenAt` only controls expiration; it is never persisted.
class LanPeer {
  const LanPeer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.seenAt,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final DateTime seenAt;
}

/// A device the user confirmed once; later handoffs from it skip the digits.
class LanPairedDevice {
  const LanPairedDevice({required this.id, required this.name});

  final String id;
  final String name;
}

/// The receiver-side result handed to the reader: a concrete local [Novel]
/// instance plus a position that belongs to that book on this device.
class LanHandoffResolved {
  const LanHandoffResolved({required this.book, required this.position});

  final Novel book;
  final ReadingPosition position;
}

/// A received handoff. [online] is true for a website book and null for a
/// local book, which is the receiver's cue to reuse the current reader.
class LanHandoffReceipt {
  const LanHandoffReceipt({
    required this.id,
    required this.fromDeviceId,
    required this.fromDeviceName,
    required this.bookTitle,
    required this.chapterTitle,
    required this.chapter,
    required this.chapterId,
    required this.pairingCode,
    required this.requiresConfirmation,
    required this.online,
    required this.payload,
    required this.receivedAt,
  });

  final String id;
  final String fromDeviceId;
  final String fromDeviceName;
  final String bookTitle;
  final String chapterTitle;
  final int chapter;
  final int chapterId;
  final String pairingCode;
  final bool requiresConfirmation;
  final bool? online;
  final Map<String, dynamic> payload;
  final DateTime receivedAt;
}

/// What the send sheet shows after a successful POST.
class LanSendResult {
  const LanSendResult({
    required this.ok,
    required this.message,
    this.pairingCode,
  });

  final bool ok;
  final String message;
  final String? pairingCode;
}

/// Holds the single pending handoff and owns receipt resolution. Resolution is
/// deliberately separate from receipt: the app validates first, then opens the
/// reader, and only then dismisses the reminder.
class LanReadingHandoff extends ChangeNotifier {
  LanReadingHandoff._(this._sync);

  final LanReadingSync _sync;
  LanHandoffReceipt? _received;

  LanHandoffReceipt? get received => _received;

  void receive(LanHandoffReceipt receipt) {
    _received = receipt;
    notifyListeners();
  }

  void dismissReceipt() {
    if (_received == null) return;
    _received = null;
    notifyListeners();
  }

  /// Confirms the device for future handoffs. The pending receipt is kept so
  /// that the caller can still compare it by identity while opening the book.
  Future<void> acceptReceipt(LanHandoffReceipt receipt) =>
      _sync._rememberPaired(receipt.fromDeviceId, receipt.fromDeviceName);

  Future<LanHandoffResolved> resolveReceipt(LanHandoffReceipt receipt) {
    if (receipt.online == true) return _resolveOnline(receipt);
    return _resolveLocal(receipt);
  }

  Future<LanHandoffResolved> _resolveOnline(LanHandoffReceipt receipt) async {
    final online = OnlineBookHandoff.fromJson(receipt.payload);
    try {
      final resolved = await online.resolve(_sync.repository);
      return LanHandoffResolved(
        book: resolved.book,
        position: resolved.position,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('本机无法打开这本在线书，未更改阅读位置');
    }
  }

  Future<LanHandoffResolved> _resolveLocal(LanHandoffReceipt receipt) async {
    final store = _sync.books;
    if (store == null) {
      throw const FormatException('本机没有启用本地书库，无法续读这本本地书');
    }
    final payload = receipt.payload;
    final positionValue = payload['position'];
    if (positionValue is! Map) {
      throw const FormatException('续读位置格式有误');
    }
    final Map<String, dynamic> positionMap;
    try {
      positionMap = Map<String, dynamic>.from(positionValue);
    } catch (_) {
      throw const FormatException('续读位置格式有误');
    }
    var chapterId = payload['chapterId'];
    if (chapterId is! int || chapterId <= 0) chapterId = receipt.chapterId;

    Novel? book;
    final identity = payload['identity'];
    if (identity is String && identity.isNotEmpty) {
      book = store.bookForHandoff(identity);
    }
    if (book == null) {
      // Older local imports may lack a digest; an exact title/author match is
      // only accepted when it is unambiguous, and the chapter check below still
      // guards against opening a different edition.
      final title = payload['title'];
      final author = payload['author'];
      if (title is String && title.isNotEmpty) {
        final matches = store.books
            .where(
              (candidate) =>
                  candidate.title == title &&
                  (author is! String || candidate.author == author),
            )
            .toList();
        if (matches.length == 1) book = matches.single;
      }
    }
    if (book == null) {
      throw const FormatException('接收设备找不到这本本地书，请先在两台设备导入同一个文件');
    }
    final index = book.chapters.indexWhere((chapter) => chapter.id == chapterId);
    if (index < 0) {
      throw const FormatException('两台设备这本书的目录不同，未更改阅读位置');
    }
    final chapter = book.chapters[index];
    final String body;
    try {
      body = await _sync.repository.chapterContent(book.id, chapter);
    } catch (_) {
      throw const FormatException('本机暂时无法读取目标章节，未更改阅读位置');
    }
    final content = await ReaderContent.parse(body);
    final incoming = ReadingPosition.fromJson(positionMap);
    final paragraph = incoming.paragraphIndex;
    if (paragraph == null ||
        paragraph < 0 ||
        paragraph >= content.paragraphs.length ||
        (incoming.textOffset ?? 0) > content.paragraphs[paragraph].length) {
      throw const FormatException('目标段落位置已变化，请重新发送续读；未更改阅读位置');
    }
    return LanHandoffResolved(
      book: book,
      position: ReadingPosition.fromJson({
        ...incoming.toJson(),
        'chapter': index,
        'chapterId': chapter.id,
        'offset': 0,
        'width': 0,
        'layout': '',
        'contentRevision': content.revision,
      }),
    );
  }
}

/// LAN transport for "continue reading on my other device". Discovery uses a
/// UDP broadcast; the handoff itself is one JSON POST. Every socket failure is
/// swallowed and reported as "unavailable" instead of blocking app startup.
class LanReadingSync extends ChangeNotifier {
  LanReadingSync({
    required this.state,
    required SharedPreferences preferences,
    this.books,
    required this.repository,
  }) : _preferences = preferences,
       _paired = _loadPaired(preferences);

  final LibraryState state;
  final LocalBookStore? books;
  final NovelRepository repository;
  final SharedPreferences _preferences;

  HttpServer? _http;
  RawDatagramSocket? _udp;
  Timer? _beacon;
  String _deviceId = '';
  String _deviceName = '';
  String _address = '';
  String? _unavailableReason;
  bool _initialized = false;
  bool _disposed = false;
  LanReadingHandoff? _handoff;
  final Map<String, LanPeer> _peers = {};
  final Map<String, LanPairedDevice> _paired;
  final Set<String> _broadcastAddresses = {};

  /// Created lazily so [dispose] never needs to construct it.
  LanReadingHandoff get handoff => _handoff ??= LanReadingHandoff._(this);

  bool get available => _http != null;
  bool get discoveryAvailable => _udp != null;
  String? get unavailableReason => _unavailableReason;
  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  int? get port => _http?.port;

  /// The address the other device can type, when the interface lookup worked.
  String get address {
    if (_address.isEmpty) return '';
    final http = _http;
    return http == null ? _address : '$_address:${http.port}';
  }

  List<LanPeer> get peers {
    final values = _peers.values.toList()
      ..sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    return List.unmodifiable(values);
  }

  List<LanPairedDevice> get pairedDevices {
    final values = _paired.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List.unmodifiable(values);
  }

  bool isPaired(String deviceId) => _paired.containsKey(deviceId);

  /// Starts both listeners. Nothing here is allowed to throw: a failed bind
  /// simply marks the feature unavailable and keeps the rest of the app intact.
  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    try {
      await _loadIdentity();
    } catch (_) {
      if (_deviceId.isEmpty) _deviceId = _newToken(24);
    }
    await _startServer();
    if (_http == null) {
      _unavailableReason = '无法在本机打开局域网端口，局域网续读当前不可用';
      if (!_disposed) notifyListeners();
      return;
    }
    await _startDiscovery();
    if (!_disposed) notifyListeners();
    unawaited(_resolveAddress());
  }

  Future<void> _loadIdentity() async {
    var id = _preferences.getString(_deviceIdKey);
    if (id == null || id.isEmpty) {
      id = _newToken(24);
      try {
        await _preferences.setString(_deviceIdKey, id);
      } catch (_) {}
    }
    _deviceId = id;
    final saved = _preferences.getString(_deviceNameKey)?.trim();
    _deviceName = saved != null && saved.isNotEmpty
        ? _trim(saved, 32)
        : _defaultDeviceName();
  }

  Future<void> _startServer() async {
    try {
      _http = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _preferredPort,
      ).timeout(const Duration(seconds: 4));
    } catch (_) {
      try {
        _http = await HttpServer.bind(
          InternetAddress.anyIPv4,
          0,
        ).timeout(const Duration(seconds: 4));
      } catch (_) {
        _http = null;
      }
    }
    final http = _http;
    if (http == null) return;
    http.listen(
      (request) {
        unawaited(_handleRequest(request));
      },
      onError: (Object _) {},
    );
  }

  Future<void> _startDiscovery() async {
    for (final reusePort in [true, false]) {
      try {
        _udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _discoveryPort,
          reuseAddress: true,
          reusePort: reusePort,
        ).timeout(const Duration(seconds: 4));
        break;
      } catch (_) {
        _udp = null;
      }
    }
    final socket = _udp;
    if (socket == null) return;
    try {
      socket.broadcastEnabled = true;
    } catch (_) {}
    socket.listen(_onSocketEvent, onError: (Object _) {});
    _sendBeacon();
    _beacon = Timer.periodic(_beaconInterval, (_) {
      _sendBeacon();
      _expirePeers();
    });
  }

  Future<void> _resolveAddress() async {
    final addresses = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      bool preferred(NetworkInterface value) =>
          RegExp(r'wlan|wifi|en\d|eth', caseSensitive: false).hasMatch(
            value.name,
          );
      final ordered = [
        ...interfaces.where(preferred),
        ...interfaces.where((value) => !preferred(value)),
      ];
      for (final interface in ordered) {
        for (final address in interface.addresses) {
          if (address.type != InternetAddressType.IPv4) continue;
          if (address.isLoopback) continue;
          if (address.address.isNotEmpty) addresses.add(address.address);
        }
      }
      for (final address in addresses) {
        final parts = address.split('.');
        if (parts.length == 4) {
          _broadcastAddresses.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
    } catch (_) {}
    if (_disposed) return;
    if (addresses.isNotEmpty) _address = addresses.first;
    notifyListeners();
    _sendBeacon();
  }

  /// Asks nearby devices to announce themselves again.
  void refreshPeers() {
    _sendBeacon();
    notifyListeners();
  }

  Future<void> renameDevice(String name) async {
    final next = _trim(name.trim(), 32);
    if (next.isEmpty || next == _deviceName) return;
    _deviceName = next;
    try {
      await _preferences.setString(_deviceNameKey, next);
    } catch (_) {}
    _sendBeacon();
    if (!_disposed) notifyListeners();
  }

  Future<void> unpair(String deviceId) async {
    if (_paired.remove(deviceId) == null) return;
    await _writePaired();
    if (!_disposed) notifyListeners();
  }

  /// Resolves a manually typed `host` or `host:port`, verifies that the other
  /// side speaks this protocol and remembers it as a peer for this session.
  Future<LanPeer> connectTo(String input) async {
    var raw = input.trim();
    if (raw.isEmpty) {
      throw const FormatException('请输入设备地址，例如 192.168.1.23:47821');
    }
    if (!raw.contains('://')) raw = 'http://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException('设备地址格式有误');
    }
    final port = uri.hasPort ? uri.port : _preferredPort;
    final ping = await _requestJson(
      'GET',
      Uri(scheme: 'http', host: uri.host, port: port, path: '/lan-reading/ping'),
    );
    if (ping['protocol'] != _protocol) {
      throw const FormatException('这台设备没有开启局域网续读');
    }
    final id = ping['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('设备没有回应有效的身份信息');
    }
    if (id == _deviceId) {
      throw const FormatException('这是本机地址，请填写另一台设备');
    }
    final name = ping['name'];
    final peer = LanPeer(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name : uri.host,
      host: uri.host,
      port: port,
      seenAt: DateTime.now(),
    );
    _peers[id] = peer;
    if (!_disposed) notifyListeners();
    return peer;
  }

  /// Builds the right payload for the book, posts it once, and returns the
  /// digit code the sender has to read out. Failures throw [FormatException]
  /// with a message safe to show in the sheet.
  Future<LanSendResult> sendHandoff({
    required LanPeer peer,
    required Novel book,
    required ReadingPosition position,
  }) async {
    final code = _pairingCode();
    final envelope = <String, Object?>{
      'protocol': _protocol,
      'version': _version,
      'pairingCode': code,
      'from': {
        'id': _deviceId,
        'name': _deviceName,
        'port': _http?.port ?? 0,
      },
    };
    if (isLocalBook(book.id)) {
      final store = books;
      if (store == null) {
        throw const FormatException('本机没有本地书库，无法发送这本本地书');
      }
      if (position.chapter < 0 || position.chapter >= book.chapters.length) {
        throw const FormatException('当前章节已变化，请重新打开本章后再试');
      }
      final chapter = book.chapters[position.chapter];
      if (position.chapterId <= 0 || chapter.id != position.chapterId) {
        throw const FormatException('当前章节尚未准备好，请重新打开本章后再试');
      }
      final paragraph =
          position.paragraphIndex ??
          ((position.fraction == 0 && position.offset == 0) ? 0 : null);
      if (paragraph == null) {
        throw const FormatException('当前阅读位置尚未准备好，请在页面上轻点一下再试');
      }
      String identity = '';
      try {
        identity = store.readingIdentity(book.id) ?? '';
      } catch (_) {}
      final normalized = ReadingPosition.fromJson({
        ...position.toJson(),
        'paragraphIndex': paragraph,
        'textOffset': position.textOffset ?? 0,
      });
      envelope
        ..['kind'] = 'local'
        ..['bookTitle'] = book.title
        ..['chapterTitle'] = chapter.title
        ..['chapter'] = position.chapter
        ..['chapterId'] = chapter.id
        ..['payload'] = {
          'identity': identity,
          'bookId': book.id,
          'title': book.title,
          'author': book.author,
          'chapterId': chapter.id,
          'position': normalized.toJson(),
        };
    } else {
      final online = await OnlineBookHandoff.prepare(
        book: book,
        position: position,
        repository: repository,
      );
      final json = online.toJson();
      final chapterTitle = json['chapterTitle'];
      envelope
        ..['kind'] = 'online'
        ..['bookTitle'] = book.title
        ..['chapterTitle'] = chapterTitle is String ? chapterTitle : ''
        ..['chapter'] = position.chapter
        ..['chapterId'] = position.chapterId
        ..['payload'] = json;
    }
    await _requestJson(
      'POST',
      Uri(
        scheme: 'http',
        host: peer.host,
        port: peer.port,
        path: '/lan-reading/handoff',
      ),
      body: envelope,
    );
    return LanSendResult(
      ok: true,
      message: '已发送到 ${peer.name}',
      pairingCode: code,
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    var status = HttpStatus.ok;
    Object? body;
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/lan-reading/ping') {
        body = {
          'protocol': _protocol,
          'version': _version,
          'id': _deviceId,
          'name': _deviceName,
          'port': _http?.port ?? 0,
        };
      } else if (request.method == 'POST' && path == '/lan-reading/handoff') {
        final raw = await _readBody(request);
        final decoded = jsonDecode(raw);
        final receipt = _acceptEnvelope(
          decoded,
          request.connectionInfo?.remoteAddress.address,
        );
        body = {'ok': true, 'received': receipt.id};
      } else {
        status = HttpStatus.notFound;
        body = {'ok': false, 'error': '未知的局域网续读请求'};
      }
    } on FormatException catch (error) {
      status = HttpStatus.badRequest;
      body = {
        'ok': false,
        'error': error.message.isEmpty ? '续读数据格式有误' : error.message,
      };
    } catch (_) {
      status = HttpStatus.internalServerError;
      body = {'ok': false, 'error': '接收续读时出现错误'};
    }
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('cache-control', 'no-store');
      request.response.write(jsonEncode(body));
      await request.response.close();
    } catch (_) {}
  }

  Future<String> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > _maxBodyBytes) {
        throw const FormatException('续读数据过大');
      }
    }
    return utf8.decode(builder.takeBytes());
  }

  LanHandoffReceipt _acceptEnvelope(Object? raw, String? remoteHost) {
    if (raw is! Map) throw const FormatException('续读数据格式有误');
    if (raw['protocol'] != _protocol || raw['version'] != _version) {
      throw const FormatException('两台设备的版本不兼容，请更新应用后再试');
    }
    final kind = raw['kind'];
    if (kind != 'online' && kind != 'local') {
      throw const FormatException('不支持的续读类型');
    }
    final from = raw['from'];
    if (from is! Map) throw const FormatException('续读数据缺少来源设备');
    final fromId = from['id'];
    final fromName = from['name'];
    final fromPort = from['port'];
    if (fromId is! String ||
        fromId.isEmpty ||
        fromId.length > 128 ||
        fromName is! String ||
        fromName.length > 64 ||
        fromPort is! int ||
        fromPort < 0 ||
        fromPort > 65535) {
      throw const FormatException('来源设备信息有误');
    }
    final code = raw['pairingCode'];
    if (code is! String || !RegExp(r'^[0-9]{4}$').hasMatch(code)) {
      throw const FormatException('核对码有误');
    }
    final payloadValue = raw['payload'];
    if (payloadValue is! Map) throw const FormatException('续读内容有误');
    final Map<String, dynamic> payload;
    try {
      payload = Map<String, dynamic>.from(payloadValue);
    } catch (_) {
      throw const FormatException('续读内容有误');
    }
    final bookTitle = raw['bookTitle'];
    final chapterTitle = raw['chapterTitle'];
    final chapter = raw['chapter'];
    final chapterId = raw['chapterId'];
    if (bookTitle is! String ||
        bookTitle.isEmpty ||
        bookTitle.length > 2048 ||
        chapterTitle is! String ||
        chapterTitle.length > 2048 ||
        chapter is! int ||
        chapter < 0 ||
        chapter > 100000 ||
        chapterId is! int ||
        chapterId < 0) {
      throw const FormatException('书籍续读信息有误');
    }
    final paired = isPaired(fromId);
    final receipt = LanHandoffReceipt(
      id: _newToken(12),
      fromDeviceId: fromId,
      fromDeviceName: fromName.isEmpty ? '另一台设备' : fromName,
      bookTitle: bookTitle,
      chapterTitle: chapterTitle,
      chapter: chapter,
      chapterId: chapterId,
      pairingCode: code,
      requiresConfirmation: !paired,
      online: kind == 'online' ? true : null,
      payload: payload,
      receivedAt: DateTime.now(),
    );
    if (remoteHost != null && remoteHost.isNotEmpty && fromPort > 0) {
      final existing = _peers[fromId];
      final name = receipt.fromDeviceName;
      _peers[fromId] = LanPeer(
        id: fromId,
        name: name,
        host: remoteHost,
        port: fromPort,
        seenAt: DateTime.now(),
      );
      if (existing == null ||
          existing.host != remoteHost ||
          existing.port != fromPort ||
          existing.name != name) {
        if (!_disposed) notifyListeners();
      }
      if (paired && existing != null && existing.name != name) {
        unawaited(_rememberPaired(fromId, name));
      }
    }
    handoff.receive(receipt);
    return receipt;
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    Uri uri, {
    Object? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 5));
      request.headers.contentType = ContentType.json;
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 6));
      var decoded = <String, dynamic>{};
      try {
        final value = jsonDecode(text);
        if (value is Map) decoded = Map<String, dynamic>.from(value);
      } catch (_) {}
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = decoded['error'];
        throw FormatException(
          error is String && error.isNotEmpty ? error : '接收设备拒绝了这次续读',
        );
      }
      return decoded;
    } on TimeoutException {
      throw const FormatException('连接超时，请确认两台设备在同一个 Wi-Fi 下');
    } on SocketException {
      throw const FormatException('无法连接这台设备，请确认地址和 Wi-Fi');
    } catch (error) {
      if (error is FormatException) rethrow;
      throw const FormatException('局域网连接失败，请重试');
    } finally {
      client.close(force: true);
    }
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _udp;
    if (socket == null) return;
    while (true) {
      final datagram = socket.receive();
      if (datagram == null) break;
      _onBeacon(datagram);
    }
  }

  void _onBeacon(Datagram datagram) {
    try {
      final value = jsonDecode(utf8.decode(datagram.data));
      if (value is! Map) return;
      if (value['protocol'] != _protocol || value['version'] != _version) return;
      final id = value['id'];
      final name = value['name'];
      final port = value['port'];
      if (id is! String || id.isEmpty || id == _deviceId) return;
      if (name is! String || name.length > 64) return;
      if (port is! int || port <= 0 || port > 65535) return;
      final host = datagram.address.address;
      if (host.isEmpty) return;
      final existing = _peers[id];
      _peers[id] = LanPeer(
        id: id,
        name: name.isEmpty ? host : name,
        host: host,
        port: port,
        seenAt: DateTime.now(),
      );
      if (existing == null ||
          existing.name != name ||
          existing.host != host ||
          existing.port != port) {
        if (!_disposed) notifyListeners();
      }
    } catch (_) {}
  }

  void _expirePeers() {
    final cutoff = DateTime.now().subtract(_peerLifetime);
    final expired = [
      for (final peer in _peers.values)
        if (peer.seenAt.isBefore(cutoff)) peer.id,
    ];
    if (expired.isEmpty) return;
    for (final id in expired) {
      _peers.remove(id);
    }
    if (!_disposed) notifyListeners();
  }

  void _sendBeacon() {
    final socket = _udp;
    if (socket == null || _disposed) return;
    final payload = utf8.encode(
      jsonEncode({
        'protocol': _protocol,
        'version': _version,
        'id': _deviceId,
        'name': _deviceName,
        'port': _http?.port ?? 0,
      }),
    );
    try {
      socket.send(payload, InternetAddress('255.255.255.255'), _discoveryPort);
    } catch (_) {}
    for (final address in _broadcastAddresses) {
      try {
        socket.send(payload, InternetAddress(address), _discoveryPort);
      } catch (_) {}
    }
  }

  Future<void> _rememberPaired(String deviceId, String name) async {
    if (deviceId.isEmpty) return;
    _paired[deviceId] = LanPairedDevice(
      id: deviceId,
      name: name.isEmpty ? '另一台设备' : name,
    );
    await _writePaired();
    if (!_disposed) notifyListeners();
  }

  Future<void> _writePaired() async {
    try {
      await _preferences.setStringList(_pairedKey, [
        for (final device in _paired.values) jsonEncode([device.id, device.name]),
      ]);
    } catch (_) {}
  }

  static Map<String, LanPairedDevice> _loadPaired(SharedPreferences prefs) {
    final result = <String, LanPairedDevice>{};
    try {
      final saved = prefs.getStringList(_pairedKey) ?? const <String>[];
      for (final raw in saved) {
        final value = jsonDecode(raw);
        if (value is List &&
            value.length >= 2 &&
            value[0] is String &&
            value[1] is String) {
          final id = value[0] as String;
          if (id.isEmpty) continue;
          result[id] = LanPairedDevice(
            id: id,
            name: value[1] as String,
          );
        }
      }
    } catch (_) {}
    return result;
  }

  static String _defaultDeviceName() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty && host.toLowerCase() != 'localhost') {
        return _trim(host, 32);
      }
    } catch (_) {}
    return '我的设备';
  }

  static String _trim(String value, int maximum) =>
      value.length <= maximum ? value : value.substring(0, maximum);

  static String _newToken(int length) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return [
      for (var i = 0; i < length; i++)
        alphabet[random.nextInt(alphabet.length)],
    ].join();
  }

  static String _pairingCode() =>
      (1000 + Random().nextInt(9000)).toString();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _beacon?.cancel();
    _beacon = null;
    try {
      _udp?.close();
    } catch (_) {}
    _udp = null;
    try {
      _http?.close(force: true);
    } catch (_) {}
    _http = null;
    _peers.clear();
    _handoff?.dispose();
    _handoff = null;
    super.dispose();
  }
}

/// Makes the local sync engine available to the settings page and the reader
/// without threading another constructor parameter through every widget.
class LanSyncScope extends InheritedWidget {
  const LanSyncScope({super.key, required this.sync, required super.child});

  final LanReadingSync? sync;

  static LanReadingSync? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanSyncScope>()?.sync;

  @override
  bool updateShouldNotify(LanSyncScope oldWidget) => oldWidget.sync != sync;
}

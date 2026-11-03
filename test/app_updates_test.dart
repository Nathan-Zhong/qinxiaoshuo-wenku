import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';

const _repo = 'example/reader';
Map<String, dynamic> _json({
  String tag = 'v0.3.0',
  List<Map<String, dynamic>>? assets,
}) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'body': '### 新功能\n- 阅读改进',
  'assets':
      assets ??
      [
        for (final abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64'])
          {
            'name': 'wenku8-${ReleaseVersion.parse(tag)!.name}-$abi.apk',
            'size': 16,
            'browser_download_url':
                'https://github.com/$_repo/releases/download/$tag/wenku8-${ReleaseVersion.parse(tag)!.name}-$abi.apk',
          },
      ],
};
const _installed = InstalledApp(
  version: '0.2.0',
  build: 2,
  abis: ['arm64-v8a', 'armeabi-v7a'],
);

class _Platform implements UpdatePlatform {
  String result = 'opened';
  String? failure;
  String failureCode = 'APK_REJECTED';
  int installs = 0;
  int reads = 0;
  InstalledApp current = _installed;
  Completer<void>? installGate;
  final handedOff = <File>[];
  final opened = <Uri>[];
  String? inspectFailure;
  int? installBuild;
  int verifiedBuild = 7;
  @override
  Future<InstalledApp> installedApp() async {
    reads++;
    return current;
  }

  @override
  Future<UpdatePackageInfo> inspect(
    File apk,
    String version, {
    int? build,
  }) async {
    if (inspectFailure != null) {
      throw PlatformException(code: 'APK_REJECTED', message: inspectFailure);
    }
    return UpdatePackageInfo(version: version, build: build ?? verifiedBuild);
  }

  @override
  Future<String> install(File apk, String version, {int? build}) async {
    installs++;
    installBuild = build;
    handedOff.add(apk);
    if (installGate != null) await installGate!.future;
    if (failure != null) {
      throw PlatformException(code: failureCode, message: failure);
    }
    return result;
  }

  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> openRelease(Uri page) async {
    opened.add(page);
  }
}

class _Source implements UpdateSource {
  AppRelease? release = AppRelease.fromGithub(_json(), _repo);
  int checks = 0;
  bool fail = false;
  Object? failure;
  bool? fileExistedBeforeDownload;
  Completer<void>? gate;
  Completer<void>? checkGate;
  List<int> data = [1, 2, 3];
  int downloads = 0;
  @override
  Future<AppRelease?> latest() async {
    checks++;
    if (checkGate != null) await checkGate!.future;
    if (fail) throw const SocketException('offline');
    if (failure != null) throw failure!;
    return release;
  }

  @override
  Future<void> download(
    UpdateAsset asset,
    File file,
    UpdateDownload task,
    void Function(int) progress,
  ) async {
    downloads++;
    fileExistedBeforeDownload = await file.exists();
    await file.writeAsBytes(data);
    progress(data.length);
    if (gate != null) await gate!.future;
    task.check();
    if (fail) throw const SocketException('offline');
    if (failure != null) throw failure!;
  }
}

class _Headers extends Fake implements HttpHeaders {
  _Headers([this.location]);
  final String? location;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  String? value(String name) =>
      name == HttpHeaders.locationHeader ? location : null;
}

class _Reply extends Stream<List<int>> implements HttpClientResponse {
  _Reply(this.statusCode, this.chunks, [String? location])
    : headers = _Headers(location);
  @override
  final int statusCode;
  final List<List<int>> chunks;
  @override
  final HttpHeaders headers;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.reply);
  final _Reply reply;
  @override
  final HttpHeaders headers = _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  Future<HttpClientResponse> close() async => reply;
}

class _Client extends Fake implements HttpClient {
  _Client(this.replies);
  final List<_Reply> replies;
  final urls = <Uri>[];
  Completer<HttpClientRequest>? requestGate;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    if (requestGate != null) return requestGate!.future;
    return _Request(replies.removeAt(0));
  }

  @override
  void close({bool force = false}) {}
  @override
  Future<HttpClientRequest> headUrl(Uri url) => getUrl(url);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // fix2 (2026-11-03): update checking is disabled in this self-use
  // build — it pointed at the original Wenku8 repository. The
  // service-flow tests that exercised check/download/install against
  // a live (fake) source, and the whole prompt-flow test file, were
  // removed with the behaviour they pinned; what remains below is
  // the still-live pure logic (version comparison, release/asset
  // parsing, transport) plus this pin of the disabled contract.
  test('update checking is permanently off in the self-use build', () async {
    SharedPreferences.setMockInitialValues({});
    final updates = AppUpdates(
      preferences: await SharedPreferences.getInstance(),
      source: _Source(),
      platform: _Platform(),
    );
    addTearDown(updates.dispose);
    expect(updates.autoCheck, isFalse);
    await updates.check();
    await updates.check(automatic: true);
    expect(updates.checked, isFalse);
    expect(updates.available, isFalse);
    expect(updates.release, isNull);
  });

  test(
    'semantic versions compare numerically and build-only releases are newer',
    () {
      expect(
        ReleaseVersion.parse(
          'v0.10.0',
        )!.compareTo(ReleaseVersion.parse('0.9.9')!),
        greaterThan(0),
      );
      for (final tag in ['v1', 'v0.3.0-beta', 'v0.3.0/../../x', '0.3.0+bad']) {
        expect(ReleaseVersion.parse(tag), isNull);
      }
      expect(
        AppRelease.fromGithub(
          _json(tag: 'v0.2.0'),
          _repo,
        )!.isNewerThan(_installed),
        false,
      );
      expect(
        AppRelease.fromGithub(
          _json(tag: 'v0.2.0+3'),
          _repo,
        )!.isNewerThan(_installed),
        true,
      );
      expect(
        AppRelease.fromGithub(_json(), _repo)!.isNewerThan(_installed),
        true,
      );
    },
  );
  test(
    'stable, repository-bound assets select the device ABI without mixing architectures',
    () {
      final release = AppRelease.fromGithub(_json(), _repo)!;
      expect(
        release.assetFor(_installed.abis)!.name,
        endsWith('-arm64-v8a.apk'),
      );
      expect(release.assetFor(['riscv64']), isNull);
      for (final field in ['draft', 'prerelease']) {
        expect(AppRelease.fromGithub(_json()..[field] = true, _repo), isNull);
      }
      final bad = _json(
        assets: [
          {
            'name': 'wenku8-x-arm64-v8a.apk',
            'size': 16,
            'browser_download_url': 'https://evil.example/a.apk',
          },
          {
            'name': 'wenku8-x-arm64-v8a.apk',
            'size': 16,
            'browser_download_url':
                'https://github.com/other/repo/releases/download/v0.3.0/wenku8-x-arm64-v8a.apk',
          },
          {
            'name': 'wenku8-x-arm64-v8a.apk',
            'size': 0,
            'browser_download_url':
                'https://github.com/$_repo/releases/download/v0.3.0/wenku8-x-arm64-v8a.apk',
          },
        ],
      );
      expect(AppRelease.fromGithub(bad, _repo)!.assets, isEmpty);
    },
  );

  test(
    'encoded build tags retain all APKs and reject mismatched URL segments',
    () {
      const tag = 'v0.3.0+29';
      const name = 'wenku8-0.3.0-arm64-v8a.apk';
      final encoded = _json(tag: tag);
      for (final asset
          in (encoded['assets'] as List).cast<Map<String, dynamic>>()) {
        asset['browser_download_url'] =
            (asset['browser_download_url'] as String).replaceFirst(
              '/$tag/',
              '/${Uri.encodeComponent(tag)}/',
            );
      }
      final release = AppRelease.fromGithub(encoded, _repo)!;
      expect(release.assets, hasLength(3));
      for (final abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']) {
        expect(release.assetFor([abi])!.name, 'wenku8-0.3.0-$abi.apk');
      }
      expect(
        release.isNewerThan(
          const InstalledApp(version: '0.3.0', build: 27, abis: ['arm64-v8a']),
        ),
        true,
      );
      for (final path in [
        '/other/repo/releases/download/v0.3.0%2B29/$name',
        '/$_repo/releases/download/v0.3.0%2B28/$name',
        '/$_repo/releases/download/v0.3.0%252B29/$name',
        '/example%2Freader/releases/download/v0.3.0%2B29/$name',
        '/$_repo/releases/download/v0.3.0%2B29/extra/$name',
        '/$_repo/releases/download/v0.3.0%2B29/wenku8-other-arm64-v8a.apk',
      ]) {
        final rejected = AppRelease.fromGithub(
          _json(
            tag: tag,
            assets: [
              {
                'name': name,
                'size': 16,
                'browser_download_url': 'https://github.com$path',
              },
            ],
          ),
          _repo,
        )!;
        expect(rejected.assets, isEmpty, reason: path);
      }
    },
  );

  late Directory temp;
  late _Source source;
  late _Platform platform;
  late AppUpdates updates;
  var now = DateTime(2026, 10, 15);
  setUp(() async {
    now = DateTime(2026, 10, 15);
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('wenku8-update-test-');
    source = _Source();
    platform = _Platform();
    updates = AppUpdates(
      preferences: await SharedPreferences.getInstance(),
      source: source,
      platform: platform,
      directory: () async => temp,
      clock: () => now,
    );
  });
  tearDown(() async {
    updates.dispose();
    await temp.delete(recursive: true);
  });
  test(
    'replacing an asset under the same tag invalidates the ready APK',
    () async {
      await updates.check();
      await updates.download();
      final replacement = _json();
      for (final asset in replacement['assets'] as List) {
        (asset as Map<String, dynamic>)['size'] = 32;
      }
      source.release = AppRelease.fromGithub(replacement, _repo);
      await updates.check();
      expect(updates.downloaded, isNull);
      await updates.install();
      expect(platform.installs, 0);
    },
  );
  test(
    'GitHub transport checks status and treats 404 as no published release',
    () async {
      final client = _Client([
        _Reply(404, []),
        _Reply(200, [utf8.encode(jsonEncode(_json()))]),
        _Reply(403, []),
      ]);
      final github = GithubUpdateSource(
        repository: _repo,
        clientFactory: () => client,
      );
      expect(await github.latest(), isNull);
      expect((await github.latest())!.version.name, '0.3.0');
      await expectLater(github.latest(), throwsA(isA<HttpException>()));
      expect(
        client.urls.first.toString(),
        'https://api.github.com/repos/$_repo/releases/latest',
      );
    },
  );
  test(
    'APK transfer validates redirect destinations, byte count and supplied integrity digest',
    () async {
      final data = utf8.encode('signed APK fixture');
      final asset = UpdateAsset(
        name: 'wenku8-0.3.0-arm64-v8a.apk',
        url: Uri.parse(
          'https://github.com/$_repo/releases/download/v0.3.0/app.apk',
        ),
        size: data.length,
        digest: sha256.convert(data).toString(),
      );
      final file = File('${temp.path}/transfer.apk');
      final good = _Client([
        _Reply(302, [], 'https://release-assets.githubusercontent.com/asset'),
        _Reply(200, [data.sublist(0, 4), data.sublist(4)]),
      ]);
      await GithubUpdateSource(
        clientFactory: () => good,
      ).download(asset, file, UpdateDownload(), (_) {});
      expect(await file.readAsBytes(), data);
      final evil = _Client([
        _Reply(302, [], 'https://evil.example/package.apk'),
      ]);
      await expectLater(
        GithubUpdateSource(
          clientFactory: () => evil,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
      final incomplete = _Client([
        _Reply(200, [data.sublist(1)]),
      ]);
      await expectLater(
        GithubUpdateSource(
          clientFactory: () => incomplete,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsA(isA<UpdateServiceUnavailable>()),
      );
      final changed = [...data]..[0] ^= 1;
      final tampered = _Client([
        _Reply(200, [changed]),
      ]);
      await expectLater(
        GithubUpdateSource(
          clientFactory: () => tampered,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
    },
  );
  test(
    'mirror changes transport only and keeps canonical release identity',
    () async {
      final metadata = _json(tag: 'v0.3.0+57');
      (metadata['assets'] as List).first['id'] = 57;
      final client = _Client([
        _Reply(200, [utf8.encode(jsonEncode(metadata))]),
      ]);
      final source = GithubUpdateSource(
        repository: _repo,
        gateway: Uri.parse(updateMirrorOrigin),
        clientFactory: () => client,
      );
      final release = (await source.latest())!;
      expect(
        client.urls.single.toString(),
        '$updateMirrorOrigin/api/releases/latest',
      );
      expect(release.page.host, 'github.com');
      expect(release.assets.first.url.host, 'github.com');
      expect(release.assets.first.id, 57);
    },
  );
  test(
    'mirror downloads immutable asset ID and still checks digest and size',
    () async {
      final bytes = utf8.encode('APK bytes');
      final asset = UpdateAsset(
        name: 'wenku8-0.3.0-arm64-v8a.apk',
        url: Uri.parse(
          'https://github.com/$_repo/releases/download/v0.3.0%2B57/wenku8-0.3.0-arm64-v8a.apk',
        ),
        size: bytes.length,
        id: 57,
        digest: sha256.convert(bytes).toString(),
      );
      final client = _Client([
        _Reply(200, [bytes]),
      ]);
      final file = File('${temp.path}/mirror.apk');
      await GithubUpdateSource(
        repository: _repo,
        gateway: Uri.parse(updateMirrorOrigin),
        clientFactory: () => client,
      ).download(asset, file, UpdateDownload(), (_) {});
      expect(client.urls.single.host, 'git.3952039.xyz');
      expect(client.urls.single.pathSegments, asset.url.pathSegments);
      expect(client.urls.single.queryParameters, {'asset': '57'});
      expect(await file.readAsBytes(), bytes);
      final changed = _Client([
        _Reply(200, [utf8.encode('bad bytes')]),
      ]);
      await expectLater(
        GithubUpdateSource(
          repository: _repo,
          gateway: Uri.parse(updateMirrorOrigin),
          clientFactory: () => changed,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
    },
  );
  test(
    'mirror transport reports redirects as unavailable and rejects external assets',
    () async {
      final client = _Client([
        _Reply(
          302,
          [],
          'https://github.com/$_repo/releases/download/v0.3.0/app.apk',
        ),
      ]);
      final source = GithubUpdateSource(
        repository: _repo,
        gateway: Uri.parse(updateMirrorOrigin),
        clientFactory: () => client,
      );
      final file = File('${temp.path}/mirror.apk');
      final release = AppRelease.fromGithub(_json(), _repo)!;
      await expectLater(
        source.download(release.assets.first, file, UpdateDownload(), (_) {}),
        throwsA(isA<UpdateServiceUnavailable>()),
      );
      expect(client.urls, hasLength(1));
      final external = UpdateAsset(
        name: 'file.apk',
        url: Uri.parse('https://evil.test/file.apk'),
        size: 4,
      );
      await expectLater(
        source.download(external, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
      expect(client.urls, hasLength(1));
    },
  );
  test(
    'official app always chooses mirror-first without a user channel preference',
    () async {
      final service = AppUpdates(preferences: updates.preferences);
      addTearDown(service.dispose);
      expect(service.source, isA<MirrorFirstUpdateSource>());
      expect(service.projectPage.host, 'git.3952039.xyz');
      expect(service.releasePage.host, 'git.3952039.xyz');
      await updates.preferences.setString('appUpdateChannel', 'github');
      final restarted = AppUpdates(preferences: updates.preferences);
      addTearDown(restarted.dispose);
      expect(restarted.source, isA<MirrorFirstUpdateSource>());
    },
  );

  test(
    'mirror rate limiting falls back once; a real no-release response does not',
    () async {
      final mirrorClient = _Client([_Reply(429, []), _Reply(404, [])]);
      final original = _Source();
      final source = MirrorFirstUpdateSource(
        mirror: GithubUpdateSource(
          repository: _repo,
          gateway: Uri.parse(updateMirrorOrigin),
          clientFactory: () => mirrorClient,
        ),
        original: original,
      );
      expect(await source.latest(), original.release);
      expect(original.checks, 1);
      expect(await source.latest(), isNull);
      expect(original.checks, 1);
      expect(mirrorClient.urls, hasLength(2));
    },
  );

  test(
    'an interrupted mirror transfer restarts cleanly and retains the verified asset',
    () async {
      final mirror = _Source()..fail = true;
      final original = _Source()..data = [8, 9, 10, 11];
      final routes = <bool>[], progress = <int>[];
      final source = MirrorFirstUpdateSource(
        mirror: mirror,
        original: original,
        onRoute: routes.add,
      );
      final file = File('${temp.path}/fallback.apk');
      await source.download(
        mirror.release!.assets.first,
        file,
        UpdateDownload(),
        progress.add,
      );
      expect(await file.readAsBytes(), original.data);
      expect(original.fileExistedBeforeDownload, false);
      expect(routes, [false, true]);
      expect(progress, [3, 0, 4]);
      expect(original.downloads, 1);
    },
  );

  test(
    'cancelled transfers and integrity/identity failures never retry another source',
    () async {
      final mirror = _Source()..failure = const FormatException('安装包校验失败');
      final original = _Source();
      final source = MirrorFirstUpdateSource(
        mirror: mirror,
        original: original,
      );
      final file = File('${temp.path}/cancelled.apk');
      await expectLater(
        source.download(
          mirror.release!.assets.first,
          file,
          UpdateDownload(),
          (_) {},
        ),
        throwsFormatException,
      );
      expect(original.downloads, 0);
      mirror.failure = null;
      mirror.gate = Completer<void>();
      final task = UpdateDownload();
      final download = source.download(
        mirror.release!.assets.first,
        file,
        task,
        (_) {},
      );
      final assertion = expectLater(download, throwsA(isA<UpdateCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      task.cancel();
      mirror.gate!.complete();
      await assertion;
      expect(original.downloads, 0);
    },
  );
  test(
    'direct fallback revalidates the exact release asset ID before downloading',
    () async {
      final data = utf8.encode('verified update');
      final metadata = _json(
        assets: [
          {
            'name': 'wenku8-0.3.0-arm64-v8a.apk',
            'size': data.length,
            'id': 57,
            'digest': 'sha256:${sha256.convert(data)}',
            'browser_download_url':
                'https://github.com/$_repo/releases/download/v0.3.0/wenku8-0.3.0-arm64-v8a.apk',
          },
        ],
      );
      final asset = AppRelease.fromGithub(metadata, _repo)!.assets.single;
      final good = _Client([
        _Reply(200, [utf8.encode(jsonEncode(metadata))]),
        _Reply(200, [data]),
      ]);
      final file = File('${temp.path}/immutable.apk');
      await GithubUpdateSource(
        repository: _repo,
        clientFactory: () => good,
      ).download(asset, file, UpdateDownload(), (_) {});
      expect(good.urls.first.path, '/repos/$_repo/releases/tags/v0.3.0');
      expect(await file.readAsBytes(), data);
      final replaced = jsonDecode(jsonEncode(metadata)) as Map<String, dynamic>;
      (replaced['assets'] as List).single['id'] = 58;
      final bad = _Client([
        _Reply(200, [utf8.encode(jsonEncode(replaced))]),
      ]);
      await expectLater(
        GithubUpdateSource(
          repository: _repo,
          clientFactory: () => bad,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
      expect(bad.urls, hasLength(1));
    },
  );
  testWidgets(
    'a stalled mirror DNS/connection times out and falls back automatically',
    (tester) async {
      final client = _Client([])..requestGate = Completer<HttpClientRequest>();
      final original = _Source();
      final source = MirrorFirstUpdateSource(
        mirror: GithubUpdateSource(
          repository: _repo,
          gateway: Uri.parse(updateMirrorOrigin),
          clientFactory: () => client,
        ),
        original: original,
      );
      AppRelease? result;
      final pending = source.latest().then((value) {
        result = value;
      });
      await tester.pump(const Duration(seconds: 4, milliseconds: 1));
      await pending;
      expect(result, original.release);
      expect(original.checks, 1);
    },
  );
  test(
    'project/download entry opens the mirror first and falls back without a source picker',
    () async {
      final client = _Client([_Reply(200, []), _Reply(503, [])]);
      await HttpOverrides.runZoned(() async {
        await updates.openProjectPage();
        expect(platform.opened.last.host, 'git.3952039.xyz');
        await updates.openProjectPage(showRelease: true);
        expect(platform.opened.last.host, 'github.com');
        expect(client.urls, hasLength(2));
      }, createHttpClient: (_) => client);
    },
  );
}

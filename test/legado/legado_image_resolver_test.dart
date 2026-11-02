import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/legado/legado_dto.dart';
import 'package:wenku8_flutter/legado/legado_image_resolver.dart';

/// G7 (P5.1): the Dart-side resolution cache over the engine's
/// resolveImageRequest — one bridge call per (origin, url), failures
/// degrade to null inside a retry window so callers fall back to the
/// bare fetch instead of hammering a broken bridge.
void main() {
  group('LegadoImageResolver', () {
    test('same origin+url resolves only once', () async {
      var calls = 0;
      final resolver = LegadoImageResolver(
        call: ({required origin, required url}) async {
          calls++;
          return ImageRequest(
            url: 'https://img.example/real.jpg',
            headers: const {'Referer': 'https://a.example/'},
          );
        },
      );
      final first = await resolver.resolve('https://a.example', 'raw');
      final second = await resolver.resolve('https://a.example', 'raw');
      expect(calls, 1);
      expect(first, second);
      expect(first!.url, 'https://img.example/real.jpg');
      expect(first.headers, {'Referer': 'https://a.example/'});
      expect(resolver.cachedResolutions, 1);
    });

    test('cache key includes the origin', () async {
      var calls = 0;
      final resolver = LegadoImageResolver(
        call: ({required origin, required url}) async {
          calls++;
          return ImageRequest(url: url);
        },
      );
      await resolver.resolve('https://a.example', 'same-url');
      await resolver.resolve('https://b.example', 'same-url');
      await resolver.resolve('https://a.example', 'other-url');
      expect(calls, 3);
    });

    test('concurrent resolves share one bridge call', () async {
      var calls = 0;
      final gate = Completer<void>();
      final resolver = LegadoImageResolver(
        call: ({required origin, required url}) async {
          calls++;
          await gate.future;
          return ImageRequest(url: url);
        },
      );
      final pending = [
        resolver.resolve('https://a.example', 'u'),
        resolver.resolve('https://a.example', 'u'),
        resolver.resolve('https://a.example', 'u'),
      ];
      gate.complete();
      final results = await Future.wait(pending);
      expect(calls, 1);
      expect(results.every((r) => r != null), isTrue);
    });

    test('failure returns null and is not retried inside the window', () async {
      var now = DateTime(2026, 11, 3, 6);
      var calls = 0;
      final resolver = LegadoImageResolver(
        retryDelay: const Duration(seconds: 30),
        now: () => now,
        call: ({required origin, required url}) async {
          calls++;
          throw StateError('bridge down');
        },
      );
      expect(await resolver.resolve('o', 'u'), isNull);
      expect(await resolver.resolve('o', 'u'), isNull);
      expect(calls, 1);
      expect(resolver.cachedFailures, 1);
      now = now.add(const Duration(seconds: 31));
      expect(await resolver.resolve('o', 'u'), isNull);
      expect(calls, 2);
    });

    test('empty resolved url counts as a failure', () async {
      final resolver = LegadoImageResolver(
        call: ({required origin, required url}) async =>
            const ImageRequest(url: ''),
      );
      expect(await resolver.resolve('o', 'u'), isNull);
      expect(resolver.cachedResolutions, 0);
      expect(resolver.cachedFailures, 1);
    });

    test('oldest resolutions are evicted past the entry cap', () async {
      var calls = 0;
      final resolver = LegadoImageResolver(
        maxEntries: 2,
        call: ({required origin, required url}) async {
          calls++;
          return ImageRequest(url: url);
        },
      );
      await resolver.resolve('o', '1');
      await resolver.resolve('o', '2');
      await resolver.resolve('o', '3');
      expect(resolver.cachedResolutions, 2);
      await resolver.resolve('o', '1');
      expect(calls, 4, reason: 'the evicted entry resolves again');
      await resolver.resolve('o', '3');
      expect(calls, 4, reason: 'the surviving entry stays cached');
    });
  });
}

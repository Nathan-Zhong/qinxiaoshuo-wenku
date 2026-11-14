import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/wenku_account.dart';

import 'feature_completion_state_test.dart' show profileXml;

String _cloudXml() =>
    '<metadata><book aid="71" date="2026-10-05"><name>作品 71</name><chapter cid="71000">最新章节</chapter></book></metadata>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initialize retries after a transient failure instead of latching dead', () async {
    var userinfoCalls = 0;
    final account = WenkuAccount(
      hasSession: () async => true,
      clearSession: () async {},
      request: (action) async {
        if (action == 'action=userinfo') {
          userinfoCalls++;
          if (userinfoCalls == 1) throw StateError('offline');
          return profileXml;
        }
        return profileXml;
      },
    );
    addTearDown(account.dispose);

    await account.initialize();
    expect(account.profile, isNull);
    expect(account.authenticated, isTrue);

    await account.initialize();
    expect(userinfoCalls, 2);
    expect(account.profile?.displayName, '读者');
    expect(account.authenticated, isTrue);
  });

  test('a non-userinfo 4 does not clear the session when userinfo is alive', () async {
    var clearCalls = 0;
    var bookcaseCalls = 0;
    final account = WenkuAccount(
      hasSession: () async => true,
      clearSession: () async {
        clearCalls++;
      },
      request: (action) async {
        if (action == 'action=userinfo') return profileXml;
        if (action == 'action=bookcase&t=0') {
          bookcaseCalls++;
          if (bookcaseCalls == 1) return '4';
          return _cloudXml();
        }
        return profileXml;
      },
    );
    addTearDown(account.dispose);
    await account.initialize();
    expect(account.authenticated, isTrue);

    await expectLater(account.refreshCloud(), throwsA(isA<WenkuApiError>()));
    expect(clearCalls, 0);
    expect(account.authenticated, isTrue);

    final books = await account.refreshCloud();
    expect(books.map((book) => book.id), [71]);
    expect(clearCalls, 0);
  });

  test('a userinfo 4 still clears the session (authoritative expiry)', () async {
    var clearCalls = 0;
    final account = WenkuAccount(
      hasSession: () async => true,
      clearSession: () async {
        clearCalls++;
      },
      request: (action) async {
        if (action == 'action=userinfo') return '4';
        return profileXml;
      },
    );
    addTearDown(account.dispose);
    await account.initialize();
    expect(account.authenticated, isFalse);
    expect(clearCalls, 1);
  });
}

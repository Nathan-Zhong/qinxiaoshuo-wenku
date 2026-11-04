import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/updates/app_changelog.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';
import 'package:wenku8_flutter/updates/release_highlights.dart';

// Rewritten in fix2 (2026-11-03): this file used to pin the original
// Wenku8 0.4.1 "restoration" release — its version constants and its
// policy headline announcing that custom book sources would no
// longer be supported. 小说文库 is a self-use fork whose whole point
// is imported Legado sources, so those pins were replaced with
// assertions about our own changelog and versioning.
void main() {
  test('own version constants match the changelog head and pubspec line', () {
    expect(currentAppVersion, '1.0.10');
    expect(currentAppBuild, 10010);
    expect(appChangelog.first.version, currentAppVersion);
    expect(appChangelog.first.build, currentAppBuild);
  });

  // fix5 (2026-11-04): Cassidy ordered the changelog to keep only
  // the three most recent versions — each new version retires the
  // fourth-oldest entry (1.0.9 retired 1.0.6).
  test('changelog is newest-first and keeps only the three most '
      'recent versions', () {
    expect(appChangelog, hasLength(3));
    expect(
      appChangelog.map((e) => e.version).toList(),
      ['1.0.10', '1.0.9', '1.0.8'],
    );
    for (final entry in appChangelog) {
      expect(entry.summary, isNotEmpty);
      expect(entry.items, isNotEmpty);
      expect(entry.date, isNotEmpty);
    }
  });

  test('release highlights derive from our changelog, one section per '
      'version', () {
    expect(currentReleaseSummary, appChangelog.first.summary);
    expect(currentReleaseSections, hasLength(appChangelog.length));
    for (var i = 0; i < appChangelog.length; i++) {
      expect(
        currentReleaseSections[i].title,
        contains(appChangelog[i].version),
      );
      expect(currentReleaseSections[i].items, appChangelog[i].items);
    }
    expect(currentReleaseNotes, contains(appChangelog.first.version));
  });

  test('no trace of the original build\u2019s source policy remains', () {
    const oldPolicy = '只保留轻小说文库源和本地导入功能';
    for (final entry in appChangelog) {
      for (final text in [...entry.summary, ...entry.items]) {
        expect(text, isNot(contains(oldPolicy)));
      }
    }
    expect(currentReleaseNotes, isNot(contains(oldPolicy)));
  });
}

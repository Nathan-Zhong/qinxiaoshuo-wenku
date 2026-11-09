import 'app_changelog.dart';

class ReleaseSection {
  const ReleaseSection(this.title, this.items);
  final String title;
  final List<String> items;
}

/// 关于页「本版更新」卡片直接读 [appChangelog] 的最新一条，
/// 不再使用上游轻小说文库的版本说明（那些说明讲的是原版功能，
/// 和我们自己的迭代内容对不上）。
final AppVersionNotes _latest = appChangelog.first;

final List<String> currentReleaseSummary = <String>[
  ..._latest.summary,
  ..._latest.items,
];

final String currentReleaseNotes = [
  '### 本次更新',
  '',
  for (final item in _latest.summary) '- **$item**',
  '',
  for (final item in _latest.items) '- $item',
].join('\n');

const publicReleaseNotes = '';

final List<ReleaseSection> currentReleaseSections = <ReleaseSection>[
  ReleaseSection('本次更新', <String>[..._latest.summary, ..._latest.items]),
];

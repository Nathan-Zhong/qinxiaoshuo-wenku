/// 小说文库自己的更新日志（自用版，Cassidy 2026-11-03 下令设立）。
///
/// 原轻小说文库的版本说明已全部移除；从 1.0.0 起，这里记录的都是
/// 小说文库自己的功能更新与问题修复，由我们自己维护。发新版时：
/// 1. 在 [appChangelog] 最前面加一条新记录（新版在前）；
/// 2. 同步 pubspec.yaml 的版本号；
/// 3. 同步 app_updates.dart 的 currentAppVersion / currentAppBuild；
/// 4. **只保留最近三个版本**（Cassidy，2026-11-04 下令）：加完新版
///    条目后，把排在第四位的老版本条目整段删掉，让列表恒为三条。
///
/// 文案口径（Cassidy，2026-11-04）：每个版本只列要点，一条一行
/// 点明更新内容，不要长段落。
library;

class AppVersionNotes {
  const AppVersionNotes({
    required this.version,
    required this.build,
    required this.date,
    required this.summary,
    required this.items,
  });

  /// 语义版本号，如 '1.0.3'。
  final String version;

  /// 构建号，如 10003。
  final int build;

  /// 发布日期，如 '2026-11-04'。
  final String date;

  /// 关于页「本版更新」卡片上的摘要（1–2 条大白话，第一条会
  /// 以大号粗体显示，和原来的卡片样式一致）。
  final List<String> summary;

  /// 「详细更新说明」里这一版的条目（要点式短句，一条一行）。
  final List<String> items;
}

/// 版本记录，新版本在最前面，恒为最近三条（规则见文件头注释）。
/// 详细更新说明里每个版本占一页，按这个顺序翻页。
const appChangelog = <AppVersionNotes>[
  AppVersionNotes(
    version: '1.0.16',
    build: 10016,
    date: '2026-11-09',
    summary: ['书架筛选里清掉「本地导入」这个已经用不上的来源。'],
    items: [
      '书架的「书籍来源」和立体书架来源里去掉「本地导入 / 本地书籍」',
      '以前选过该来源的，自动回落到「全部来源」',
    ],
  ),
  AppVersionNotes(
    version: '1.0.15',
    build: 10015,
    date: '2026-11-09',
    summary: ['搜索结果只剩书源命中时，也带上「书源」小标题。'],
    items: [
      '搜索只命中书源时，结果同样显示「书源」小标题，不再和文库结果混在一起',
      '底部导航的书签图标改成手绘线稿风格，和另外三栏统一',
    ],
  ),
  AppVersionNotes(
    version: '1.0.14',
    build: 10014,
    date: '2026-11-09',
    summary: ['「我的」页去掉重复的书签入口，书架四栏里的书签就够用了。'],
    items: [
      '「我的」页删掉书签卡片，书签只从底部导航进入',
      '「我的」页补上「赞助与反馈」：赞助原作者、问题反馈（GitHub Issues）',
    ],
  ),

];

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
    version: '1.0.7',
    build: 10007,
    date: '2026-11-04',
    summary: ['拷贝漫画这类源现在能看图了。'],
    items: [
      '拷贝漫画等「标记是小说、内容全是图」的书源，现在打开章节能直接竖滑看图',
    ],
  ),
  AppVersionNotes(
    version: '1.0.6',
    build: 10006,
    date: '2026-11-04',
    summary: ['SF轻小说等明文网站的源恢复可用，书架书签的立体书架显示全部书籍。'],
    items: [
      '修复 SF轻小说校验失败：这类老网站用的是明文网址，现在和阅读 App 一样放行',
      '哔哩轻小说这类书源的搜索小脚本，改走和阅读 App 一样的共享网络通道（带 Cookie 和网站验证处理）',
      '漫画柜等书源在网站换网址后能刷新出新目录：源自带的目录刷新现在生效了',
      '书架、书签页的立体书架改为显示全部书籍，不再只显示前 10 本',
      '校验失败时会显示具体原因，不再只有笼统的一句报错',
    ],
  ),
  AppVersionNotes(
    version: '1.0.5',
    build: 10005,
    date: '2026-11-04',
    summary: ['书源管理更好用了：能批量清理失效源。'],
    items: [
      '校验完成后可一键选中全部失效书源，确认后再删除',
      '书源管理新增「全选」，也可一键取消全选',
      '详细更新说明只保留最近三个版本',
    ],
  ),
];

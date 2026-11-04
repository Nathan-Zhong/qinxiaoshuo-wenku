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
    version: '1.0.6',
    build: 10006,
    date: '2026-11-04',
    summary: ['SF轻小说等明文网站的源恢复可用，书架书签的立体书架显示全部书籍。'],
    items: [
      '修复 SF轻小说校验失败：这类老网站用的是明文网址，现在和阅读 App 一样放行',
      '修复哔哩轻小说搜索时报「JS执行出错」：它的搜索握手现在走 App 的共享网络（带 Cookie 和网站验证处理）',
      '书架、书签页的立体书架改为显示全部书籍，不再只显示前 10 本',
      '校验失败的提示带上具体原因，不再只有笼统的一句报错',
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
  AppVersionNotes(
    version: '1.0.4',
    build: 10004,
    date: '2026-11-04',
    summary: ['漫画点开能看图了，搜索也更靠谱了。'],
    items: [
      '修复漫画点开只能看到提示页、看不了图的问题',
      '全书源一起搜时，漫画源不再被网站验证拖没：超时或被验证页顶替会自动预热重试',
      '搜索排序对齐阅读 App：书名或作者与搜索词完全一致的先出，其余相关在后，文字和漫画同等对待',
      '发现页立体书架改为每日随机选书：同一天同一书源不变，隔天换一批',
    ],
  ),
];

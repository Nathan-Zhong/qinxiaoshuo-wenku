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
    version: '1.0.13',
    build: 10013,
    date: '2026-11-09',
    summary: ['修好需要登录的书源：网页登录不再被表单挡住。'],
    items: [
      '书源登录的「网页登录」直接打开书源自己的登录页，表单登录不再是唯一入口',
      '搜索结果里的书源条目显示具体书源名，不再笼统写「在线」',
    ],
  ),
  AppVersionNotes(
    version: '1.0.12',
    build: 10012,
    date: '2026-11-09',
    summary: ['清掉本地导入残留，应用不再接管系统里的打开文件。'],
    items: [
      '删除本地导入的页面与文件打开接管，只保留书架里的在线阅读',
      '书架与书签的筛选标签去掉本地导入相关的旧文案',
    ],
  ),
  AppVersionNotes(
    version: '1.0.11',
    build: 10011,
    date: '2026-11-09',
    summary: ['换成轻小说文库官方界面，书源功能嵌进去。'],
    items: [
      '界面按轻小说文库 App 重做：发现、书架、书签、我的四栏，立体书架、统计、桌面小组件都回来了',
      '修复封面全部加载不出来',
      '删除本地导入，底部不再有「本地」入口',
      '搜书结果分成两段：上面轻小说文库，下面书源，中间淡实线分隔',
      '书源搜索结果能正常显示，书源登录支持网页登录',
      '书架和书签的立体书架不再限制本数，加入的书全部横向展示',
    ],
  ),
];

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
    date: '2026-11-15',
    summary: ['文库登录不再动不动掉线，书源搜索更好用了。'],
    items: [
      '修复文库账号无法保存登录状态：读取失败不再删盘，单次坏响应不再清掉已存会话，非 userinfo 接口回 4 先用 userinfo 确认再决定，启动失败后可重试',
      '修复大部分 Legado 书源无法适配：搜索预热改为解析后的真实搜索地址，查不到的书源会报出具体原因，导入失败会显示是哪个源、哪个字段坏了',
    ],
  ),
  AppVersionNotes(
    version: '1.0.10',
    build: 10010,
    date: '2026-11-04',
    summary: ['漫画团恢复可用。'],
    items: [
      '修复漫画团校验时「JS执行出错」：这类源正文解密时，脚本引擎有个小毛病会把文字弄错格式，这次在引擎里对齐了原版阅读的处理方式',
    ],
  ),
  AppVersionNotes(
    version: '1.0.9',
    build: 10009,
    date: '2026-11-04',
    summary: ['漫画柜等失效书源恢复可用。'],
    items: [
      '修复漫画柜校验时「JS执行出错」：上一版补的加密函数在打包时被改名失效，这次直接补进引擎本体',
      '阅友小说等书源一并恢复：补齐它们搜索、正文要用的加密函数',
    ],
  ),
];

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_source_manager_page.dart';
import 'reading_statistics_page.dart';
import 'catalog.dart';
import 'dock_layout.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'offline_repository.dart';
import 'pages.dart' show SettingsPage, openDetail;
import 'ui_notifiers.dart';
import 'updates/app_updates.dart';
import 'updates/update_page.dart';
import 'wenku_features.dart';

class MyPage extends StatelessWidget {
  const MyPage({
    super.key,
    required this.state,
    required this.repository,
    this.showHeader = true,
  });
  final LibraryState state;
  final NovelRepository repository;
  final bool showHeader;

  Widget buildHeader(BuildContext context) => const Align(
    alignment: Alignment.centerLeft,
    child: ArchiveMasthead(title: '我的', code: '04 / PERSONAL ARCHIVE'),
  );

  @override
  Widget build(BuildContext context) {
    final features = WenkuFeaturesScope.maybeOf(context);
    final updates = AppUpdatesScope.maybeOf(context);
    return GlassHeaderLayout(
      showHeader: showHeader,
      header: buildHeader(context),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            key: const PageStorageKey('my-page'),
            padding: featurePadding(
              context,
            ).copyWith(bottom: DockLayout.scrollPaddingOf(context)),
            children: [
              AnimatedBuilder(
                animation: Listenable.merge([
                  features?.account ?? state.bookmarkChanges,
                  ?features?.shelfSync,
                ]),
                builder: (context, _) {
                  final account = features?.account;
                  final profile = account?.profile;
                  return ContentPanel(
                    key: const ValueKey('my-account'),
                    onTap: account == null
                        ? null
                        : () => pushNovelPage<void>(
                            context,
                            WenkuAccountPage(
                              account: account,
                              state: state,
                              repository: repository,
                            ),
                            reduceMotion: state.reduceMotion,
                          ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: account?.authenticated == true
                              ? SizedBox(
                                  width: 56,
                                  height: 56,
                                  child: account?.avatar == null
                                      ? const ArchiveIcon(
                                          CupertinoIcons.person_crop_circle,
                                          size: 40,
                                        )
                                      : Image.memory(
                                          account!.avatar!,
                                          fit: BoxFit.cover,
                                          cacheWidth:
                                              (56 *
                                                      MediaQuery.devicePixelRatioOf(
                                                        context,
                                                      ))
                                                  .ceil(),
                                          errorBuilder: (_, _, _) =>
                                              const ArchiveIcon(
                                                CupertinoIcons
                                                    .person_crop_circle,
                                                size: 40,
                                              ),
                                        ),
                                )
                              : Image.asset(
                                  'assets/branding/app-icon.png',
                                  width: 56,
                                  height: 56,
                                  cacheWidth:
                                      (56 *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .ceil(),
                                  cacheHeight:
                                      (56 *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .ceil(),
                                ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppText(
                                account?.authenticated == true
                                    ? profile?.displayName ?? '文库账号'
                                    : '登录文库账号',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 7),
                              AppText(
                                account?.authenticated == true
                                    ? profile == null
                                          ? '账号已连接'
                                          : '${profile.score} 积分 · ${profile.rank}${features?.shelfSync == null
                                                ? ''
                                                : features!.shelfSync!.syncing
                                                ? '\n书架正在同步'
                                                : features.shelfSync!.error != null
                                                ? '\n书架待同步 · ${features.shelfSync!.error}'
                                                : features.shelfSync!.syncedAt != null
                                                ? '\n书架已与文库同步'
                                                : ''}'
                                    : '轻小说文库账号 · 云书架与每日签到',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const ArchiveIcon(
                          CupertinoIcons.chevron_right,
                          size: 14,
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              FeatureEntry(
                key: const ValueKey('my-statistics'),
                title: '统计',
                subtitle: '阅读记录、藏书与书签',
                icon: CupertinoIcons.chart_bar,
                onTap: () => pushNovelPage<void>(
                  context,
                  ReadingStatisticsPage(state: state, repository: repository),
                  reduceMotion: state.reduceMotion,
                ),
              ),
              FeatureEntry(
                key: const ValueKey('my-book-sources'),
                title: '书源管理',
                subtitle: '导入与管理 Legado 书源',
                icon: CupertinoIcons.list_bullet,
                onTap: () => pushNovelPage<void>(
                  context,
                  BookSourceManagerPage(
                    onOpenBook: (pageContext, novel) => openDetail(
                      pageContext,
                      novel,
                      state,
                      repository,
                      forceDetails: true,
                    ),
                  ),
                  reduceMotion: state.reduceMotion,
                ),
              ),
              const SizedBox(height: 14),
              FeatureEntry(
                key: const ValueKey('my-settings'),
                title: '设置',
                subtitle: '阅读、外观、性能与本地数据',
                icon: CupertinoIcons.settings,
                onTap: () => pushNovelPage<void>(
                  context,
                  ArchiveFeaturePage(
                    title: '设置',
                    code: 'SYSTEM / PREFERENCES',
                    child: SettingsPage(
                      state: state,
                      repository: repository,
                      showHeader: false,
                    ),
                  ),
                  reduceMotion: state.reduceMotion,
                ),
              ),
              const SizedBox(height: 14),
              FeatureEntry(
                key: const ValueKey('my-about'),
                title: '关于',
                subtitle:
                    '版本 ${updates?.installed?.version ?? currentAppVersion}${updates?.available == true ? ' · 有新版本' : ''}',
                icon: CupertinoIcons.info_circle,
                onTap: () => pushNovelPage<void>(
                  context,
                  AppUpdatePage(updates: updates),
                  reduceMotion: state.reduceMotion,
                ),
              ),
              const SizedBox(height: 14),
              FeatureEntry(
                key: const ValueKey('my-support'),
                title: '赞助与反馈',
                subtitle: '自愿赞助 · 最新版本问题反馈',
                icon: CupertinoIcons.heart,
                onTap: () => pushNovelPage<void>(
                  context,
                  const SupportFeedbackPage(),
                  reduceMotion: state.reduceMotion,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 官方「赞助与反馈」的本地版：赞助指向原作者的爱发电，
/// 反馈指向我们自己仓库的 Issues（官方那条是给原项目用的）。
class SupportFeedbackPage extends StatelessWidget {
  const SupportFeedbackPage({super.key});

  static final Uri _sponsor = Uri.parse('https://afdian.com/a/mikufoxxx');
  static final Uri _feedback = Uri.parse(
    'https://github.com/Nathan-Zhong/xiaoshuo-wenku/issues',
  );

  Future<void> _open(BuildContext context, Uri uri) async {
    final done = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!done && context.mounted) {
      showNovelFeedback(context, '没有可以打开链接的应用');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ArchiveFeaturePage(
      title: '赞助与反馈',
      code: 'SUPPORT / FEEDBACK',
      child: ListView(
        padding: featurePadding(context),
        children: [
          FeatureEntry(
            key: const ValueKey('support-sponsor'),
            title: '赞助原作者',
            subtitle: '爱发电 · 自愿赞助，不影响功能',
            icon: CupertinoIcons.gift,
            onTap: () => _open(context, _sponsor),
          ),
          const SizedBox(height: 14),
          FeatureEntry(
            key: const ValueKey('support-feedback'),
            title: '问题反馈',
            subtitle: 'GitHub Issues · 附上版本号与复现步骤',
            icon: CupertinoIcons.exclamationmark_bubble,
            onTap: () => _open(context, _feedback),
          ),
          const SizedBox(height: 24),
          ContentPanel(
            child: AppText(
              '这个版本是我们自己编译维护的，装包来自本地构建，'
              '不走官方更新通道；遇到问题请走上面的 Issues。',
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

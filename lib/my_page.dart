import 'package:flutter/cupertino.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'pages.dart' show SettingsPage, openDetail;
import 'updates/app_updates.dart';
import 'updates/update_page.dart';
import 'book_source_manager_page.dart';
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
            ).copyWith(bottom: MediaQuery.paddingOf(context).bottom + 120),
            children: [
              if (WenkuFeaturesScope.maybeOf(context) case final features?) ...[
                FeatureEntry(
                  key: const ValueKey('my-wenku-account'),
                  title: '文库账号',
                  subtitle: features.account.authenticated
                      ? '已登录 ${features.account.profile?.displayName ?? ''}'
                      : '登录后可用云书架、出版文库与书评',
                  icon: CupertinoIcons.person_crop_circle,
                  onTap: () => pushNovelPage<void>(
                    context,
                    WenkuAccountPage(
                      account: features.account,
                      state: state,
                      repository: repository,
                    ),
                    reduceMotion: state.reduceMotion,
                  ),
                ),
                const SizedBox(height: 14),
              ],
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
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_documents.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'legado/legado.dart';
import 'legado/legado_login_ui.dart';

/// Book-source management for the embedded Legado engine.
///
/// Built entirely from the app's existing parts — [ArchiveFeaturePage]
/// frame, [ContentPanel] rows, [AppControls] toggles, jelly sheets and
/// [GlassPillButton] batch bar (the same pattern as the local-book batch
/// page) — so the page reads as a native part of the app. All engine work
/// goes through [LegadoEngineClient]; the engine is initialised (its
/// `init` is idempotent) before every operation that needs it.
class BookSourceManagerPage extends StatefulWidget {
  const BookSourceManagerPage({
    super.key,
    this.client,
    this.documents,
    this.onOpenBook,
  });

  final LegadoEngineClient? client;
  final BookDocuments? documents;

  /// Opens a found book's detail page (按链接找书 success path). The
  /// host shell injects it (it owns the library state + repository the
  /// detail route needs); without it the page falls back to a
  /// confirmation message — the book is registered either way, so it
  /// stays reachable through search.
  final void Function(BuildContext context, Novel novel)? onOpenBook;

  @override
  State<BookSourceManagerPage> createState() => _BookSourceManagerPageState();
}

/// Converter modes in fork order: 0 不转换 / 1 繁转简 / 2 简转繁.
const List<String> chineseConverterLabels = ['不转换', '繁转简', '简转繁'];

/// Whether every selectable source row is currently selected.
/// Group header rows are not sources and never counted; an empty
/// list is never "all selected".
bool bookSourcesAllSelected(Set<String> selected, Iterable<String> allUrls) {
  final urls = allUrls.toSet();
  return urls.isNotEmpty && urls.every(selected.contains);
}

/// The selection after one tap on 全选/取消全选: anything short of
/// fully selected completes the selection; fully selected clears it.
Set<String> bookSourcesToggleSelectAll(
  Set<String> selected,
  Iterable<String> allUrls,
) => bookSourcesAllSelected(selected, allUrls)
    ? <String>{}
    : allUrls.toSet();

class _BookSourceManagerPageState extends State<BookSourceManagerPage> {
  late final LegadoEngineClient _client = widget.client ?? LegadoEngineClient();
  late final BookDocuments _documents = widget.documents ?? BookDocuments();

  bool _loading = true;
  bool _deleting = false;
  bool _checking = false;
  bool _sourceChecking = false;

  /// Simplified/traditional conversion for Legado books (engine-side
  /// AppConfig value; 0 不转换 / 1 繁转简 / 2 简转繁). Loaded
  /// best-effort with the source list; the engine default is 0.
  int _converterType = 0;
  String? _error;
  List<BookSourceSummary> _sources = const [];
  List<String> _groups = const [];
  bool _selecting = false;
  final Set<String> _selected = {};

  /// Sources with saved login state in the engine (info or header),
  /// shown as a 「已登录」 subtitle marker. Best-effort decoration:
  /// refreshed after loads and logins, never blocking the list.
  Set<String> _loggedIn = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _client.init();
      final sources = await _client.listSources();
      final groups = await _client.listSourceGroups();
      final converterType = await _client.getChineseConverterType().catchError(
        (_) => 0,
      );
      if (!mounted) return;
      _converterType = converterType.clamp(0, 2);
      setState(() {
        _sources = sources;
        _groups = groups;
        _loading = false;
        _selected.removeWhere(
          (url) => !sources.any((source) => source.sourceUrl == url),
        );
        if (_sources.isEmpty) _selecting = false;
      });
      unawaited(_loadLoginStates(sources));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '书源加载失败，请检查后重试';
      });
    }
  }

  List<({String? group, List<BookSourceSummary> sources})> get _sections {
    final byGroup = <String, List<BookSourceSummary>>{};
    final ungrouped = <BookSourceSummary>[];
    for (final source in _sources) {
      final group = source.group?.trim();
      if (group == null || group.isEmpty) {
        ungrouped.add(source);
      } else {
        byGroup.putIfAbsent(group, () => []).add(source);
      }
    }
    final order = <String>[
      for (final group in _groups)
        if (byGroup.containsKey(group)) group,
      for (final group in byGroup.keys)
        if (!_groups.contains(group)) group,
    ];
    return [
      for (final group in order) (group: group, sources: byGroup[group]!),
      if (ungrouped.isNotEmpty) (group: null, sources: ungrouped),
    ];
  }

  bool get _allSelected => bookSourcesAllSelected(_selected, [
    for (final source in _sources) source.sourceUrl,
  ]);

  void _toggleSelectAll() {
    setState(() {
      final next = bookSourcesToggleSelectAll(_selected, [
        for (final source in _sources) source.sourceUrl,
      ]);
      _selected
        ..clear()
        ..addAll(next);
    });
  }

  String _typeLabel(int type) => switch (type) {
    0 => '小说',
    1 => '有声',
    2 => '漫画',
    3 => '文件',
    _ => '其他',
  };

  String _subtitle(BookSourceSummary source) {
    final host = Uri.tryParse(source.sourceUrl)?.host;
    return [
      if (_loggedIn.contains(source.sourceUrl)) '已登录',
      if (source.group != null && source.group!.trim().isNotEmpty)
        source.group!.trim(),
      _typeLabel(source.type),
      if (host != null && host.isNotEmpty) host else source.sourceUrl,
    ].join(' · ');
  }

  /// Refreshes the 「已登录」 markers for the login-capable sources
  /// in [sources] (one batched bridge call; failures just leave the
  /// previous markers — they are decoration, not state of record).
  Future<void> _loadLoginStates(List<BookSourceSummary> sources) async {
    final urls = [
      for (final source in sources)
        if (source.hasLogin) source.sourceUrl,
    ];
    if (urls.isEmpty) {
      if (mounted && _loggedIn.isNotEmpty) {
        setState(() => _loggedIn = const {});
      }
      return;
    }
    try {
      final states = await _client.getLoginStates(urls);
      if (!mounted) return;
      setState(() {
        _loggedIn = {
          for (final entry in states.entries)
            if (entry.value) entry.key,
        };
      });
    } catch (_) {
      // Markers are best-effort; a failed probe keeps the old ones.
    }
  }

  /// The row's login entry (login sources only), dispatched like the
  /// fork's showSourceLogin: form sources open the login sheet here;
  /// web sources have already opened the login browser natively;
  /// script sources ran their login() in the engine.
  Future<void> _openLogin(BookSourceSummary source) async {
    try {
      await _client.init();
      final kind = await _client.openSourceLogin(source.sourceUrl);
      if (!mounted) return;
      switch (kind) {
        case LegadoLoginKind.form:
          await showSourceLoginSheet(
            context,
            client: _client,
            sourceUrl: source.sourceUrl,
            sourceName: source.sourceName,
          );
        case LegadoLoginKind.web:
          showNovelFeedback(context, '已打开登录页，在网页里登录后返回即可');
        case LegadoLoginKind.js:
          showNovelFeedback(context, '已执行登录脚本');
        case LegadoLoginKind.none:
          showNovelFeedback(context, '该书源没有可用的登录方式');
      }
      await _loadLoginStates(_sources);
    } on PlatformException catch (error) {
      if (!mounted) return;
      showNovelFeedback(context, '登录出错：${error.message ?? '请重试'}');
    } catch (_) {
      if (!mounted) return;
      showNovelFeedback(context, '登录出错，请重试');
    }
  }

  Future<void> _setEnabled(BookSourceSummary source, bool value) async {
    final index = _sources.indexWhere(
      (item) => item.sourceUrl == source.sourceUrl,
    );
    if (index < 0) return;
    final before = _sources;
    setState(() {
      _sources = [
        for (final item in _sources)
          if (item.sourceUrl == source.sourceUrl)
            _withEnabled(item, value)
          else
            item,
      ];
    });
    try {
      await _client.setSourceEnabled(source.sourceUrl, value);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sources = before);
      showNovelFeedback(context, '书源状态保存失败，请重试');
    }
  }

  BookSourceSummary _withEnabled(BookSourceSummary source, bool enabled) =>
      BookSourceSummary(
        sourceUrl: source.sourceUrl,
        sourceName: source.sourceName,
        group: source.group,
        type: source.type,
        enabled: enabled,
        enabledExplore: source.enabledExplore,
        customOrder: source.customOrder,
        weight: source.weight,
        respondTimeMs: source.respondTimeMs,
        lastUpdateTime: source.lastUpdateTime,
        hasLogin: source.hasLogin,
        comment: source.comment,
        icon: source.icon,
        exploreKindCount: source.exploreKindCount,
      );

  Future<void> _deleteSources(
    List<String> urls, {
    required String label,
  }) async {
    if (!await confirmNovelAction(
      context,
      title: '删除书源？',
      message: '$label将被删除，之后可以重新导入。',
      confirmLabel: '删除',
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    )) {
      return;
    }
    setState(() => _deleting = true);
    try {
      await _client.deleteSources(urls);
      if (!mounted) return;
      setState(() {
        _sources = [
          for (final source in _sources)
            if (!urls.contains(source.sourceUrl)) source,
        ];
        _selected.removeAll(urls);
        _deleting = false;
        if (_sources.isEmpty) _selecting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _deleting = false);
      showNovelFeedback(context, '书源删除失败，请重试');
    }
  }

  /// Runs the bridge's staged self-check (DB counts, JS eval, explore
  /// kinds, one real search) and shows the raw report in a jelly sheet
  /// — the fastest way to see WHERE the engine chain breaks on device.
  Future<void> _runSelfCheck() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await _client.init();
      final result = await _client.engineSelfCheck();
      if (!mounted) return;
      await showJellySheet<void>(
        context: context,
        reduceMotion: MediaQuery.disableAnimationsOf(context),
        builder: (_) => _SelfCheckSheet(result: result),
      );
    } catch (_) {
      if (!mounted) return;
      showNovelFeedback(context, '自检失败，请重试');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openImport() async {
    final result = await showJellySheet<Object?>(
      context: context,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (sheet) =>
          _ImportSourceSheet(client: _client, documents: _documents),
    );
    if (result == null || !mounted) return;
    if (result is BookByUrlResult) {
      await _openFoundBook(result);
      return;
    }
    if (result is! ImportResult) return;
    final parts = [
      if (result.added > 0) '新增 ${result.added}',
      if (result.updated > 0) '更新 ${result.updated}',
      if (result.unchanged > 0) '未变 ${result.unchanged}',
      if (result.failed > 0) '失败 ${result.failed}',
    ];
    showNovelFeedback(
      context,
      parts.isEmpty ? '导入完成' : '导入完成：${parts.join(' · ')}',
    );
    await _load();
  }

  /// 按链接找书 success path: register the claimed book so the whole
  /// host (detail / reader / shelf) can reach it, then open its
  /// detail page through the shell-provided opener when present.
  Future<void> _openFoundBook(BookByUrlResult result) async {
    final book = result.book;
    final record = await LegadoBooks.registry.registerSearchBook(
      SearchBook(
        name: book.name,
        author: book.author,
        bookUrl: book.bookUrl,
        tocUrl: book.tocUrl,
        origin: result.origin,
        originName: book.originName,
        type: book.type,
        kind: book.kind,
        coverUrl: book.coverUrl,
        intro: book.intro,
        wordCount: book.wordCount,
        latestChapterTitle: book.latestChapterTitle,
        chapterWordCount: book.chapterWordCount,
        variable: book.variable,
      ),
    );
    if (!mounted) return;
    final opener = widget.onOpenBook;
    if (opener != null) {
      opener(context, record.toNovel());
    } else {
      showNovelFeedback(context, '已找到《${book.name}》，可在搜索中打开');
    }
  }

  /// Batch source check (G12): the sheet owns the task — it subscribes
  /// to the task channel first, then starts the check with its own
  /// pre-allocated task id, so no progress event can slip past.
  ///
  /// When the sheet is closed via its 「选中失效书源」 action it pops
  /// with this round's failed source urls; the page then enters batch
  /// selection with exactly those preselected, and deletion still
  /// goes through the usual bottom bar + confirmation (fix5).
  Future<void> _runSourceCheck() async {
    if (_sourceChecking) return;
    setState(() => _sourceChecking = true);
    try {
      await _client.init();
      if (!mounted) return;
      final names = {
        for (final source in _sources) source.sourceUrl: source.sourceName,
      };
      final failedUrls = await showJellySheet<List<String>>(
        context: context,
        reduceMotion: MediaQuery.disableAnimationsOf(context),
        builder: (_) => _CheckSourcesSheet(
          client: _client,
          taskId: _client.newTaskId(),
          sourceNames: names,
        ),
      );
      // Checking rewrites groups/comments/respond times in the engine
      // DB; refresh the list so failure groups become visible.
      if (mounted) await _load();
      if (mounted && failedUrls != null && failedUrls.isNotEmpty) {
        setState(() {
          final alive = {
            for (final source in _sources) source.sourceUrl,
          };
          _selected
            ..clear()
            ..addAll(failedUrls.where(alive.contains));
          if (_selected.isNotEmpty) _selecting = true;
        });
      }
    } catch (_) {
      if (!mounted) return;
      showNovelFeedback(context, '校验失败，请重试');
    } finally {
      if (mounted) setState(() => _sourceChecking = false);
    }
  }

  Future<void> _openSubscriptions() async {
    await _client.init();
    if (!mounted) return;
    await showJellySheet<void>(
      context: context,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (_) => _SubscriptionsSheet(client: _client),
    );
    await _load();
  }

  Future<void> _openReplaceRules() async {
    await _client.init();
    if (!mounted) return;
    await showJellySheet<void>(
      context: context,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (_) => _ReplaceRulesSheet(client: _client),
    );
  }

  /// The converter switch (Cassidy-ordered): a same-style option
  /// sheet; the choice is written straight to the engine's config,
  /// where the content pipeline reads it (Legado books only).
  Future<void> _openConverterSheet() async {
    final picked = await showJellySheet<int>(
      context: context,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (_) => _ConverterSheet(current: _converterType),
    );
    if (picked == null || picked == _converterType || !mounted) return;
    try {
      await _client.setChineseConverterType(picked);
      if (!mounted) return;
      setState(() => _converterType = picked);
      showNovelFeedback(
        context,
        '简繁转换已设为「${chineseConverterLabels[picked]}」（仅对书源书籍生效）',
      );
    } catch (_) {
      if (!mounted) return;
      showNovelFeedback(context, '设置失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '书源管理',
    code: 'SYSTEM / BOOK SOURCES',
    child: Column(
      children: [
        Expanded(
          child: ListView(
            padding: featurePadding(context).copyWith(
              bottom: featurePadding(context).bottom + (_selecting ? 84 : 0),
            ),
            children: [
              Row(
                children: [
                  Expanded(
                    child: AppText(
                      _selecting
                          ? '${_sources.length} 个书源 · 已选 ${_selected.length} 个'
                          : '${_sources.length} 个书源',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_selecting)
                    GlassTextButton(
                      key: const ValueKey('book-source-select-all'),
                      compact: true,
                      onPressed: _deleting ? null : _toggleSelectAll,
                      child: AppText(_allSelected ? '取消全选' : '全选'),
                    ),
                  if (_selecting && _selected.isNotEmpty)
                    GlassTextButton(
                      compact: true,
                      onPressed: _deleting
                          ? null
                          : () => setState(_selected.clear),
                      child: const AppText('清空选择'),
                    ),
                  if (!_selecting)
                    GlassTextButton(
                      key: const ValueKey('book-source-self-check'),
                      compact: true,
                      onPressed: _loading || _checking
                          ? null
                          : () => unawaited(_runSelfCheck()),
                      child: AppText(_checking ? '自检中…' : '引擎自检'),
                    ),
                  if (!_selecting)
                    GlassTextButton(
                      key: const ValueKey('book-source-import'),
                      compact: true,
                      onPressed: _loading ? null : _openImport,
                      child: const AppText('导入书源'),
                    ),
                  if (_sources.isNotEmpty)
                    GlassTextButton(
                      key: const ValueKey('book-source-select-mode'),
                      compact: true,
                      onPressed: () => setState(() {
                        _selecting = !_selecting;
                        if (!_selecting) _selected.clear();
                      }),
                      child: AppText(_selecting ? '完成' : '选择'),
                    ),
                ],
              ),
              FeatureError(_error),
              if (_error != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: GlassTextButton(
                    compact: true,
                    onPressed: _loading ? null : _load,
                    child: const AppText('重试'),
                  ),
                ),
              if (!_selecting) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    GlassTextButton(
                      key: const ValueKey('book-source-check'),
                      compact: true,
                      onPressed: _sourceChecking || _loading
                          ? null
                          : () => unawaited(_runSourceCheck()),
                      child: AppText(_sourceChecking ? '校验中…' : '校验书源'),
                    ),
                    const SizedBox(width: 8),
                    GlassTextButton(
                      key: const ValueKey('book-source-subscriptions'),
                      compact: true,
                      onPressed: _loading
                          ? null
                          : () => unawaited(_openSubscriptions()),
                      child: const AppText('订阅管理'),
                    ),
                    const SizedBox(width: 8),
                    GlassTextButton(
                      key: const ValueKey('book-source-replace-rules'),
                      compact: true,
                      onPressed: _loading
                          ? null
                          : () => unawaited(_openReplaceRules()),
                      child: const AppText('替换规则'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              ContentPanel(
                key: const ValueKey('book-source-converter'),
                onTap: () => unawaited(_openConverterSheet()),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText(
                            '简繁转换',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 5),
                          AppText(
                            '当前：${chineseConverterLabels[_converterType]}'
                            '（仅书源书籍）',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: SizedBox(
                    height: 88,
                    child: LoadingSkeleton(
                      layout: SkeletonLayout.bookRow,
                      label: '正在加载书源',
                    ),
                  ),
                )
              else if (_sources.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: AppText(
                    '还没有导入书源。\n点「导入书源」，用网络地址、JSON 文本或文件导入。',
                    style: TextStyle(height: 1.8),
                  ),
                )
              else
                for (final section in _sections) ...[
                  if (_sections.length > 1 || section.group != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 10),
                      child: AppText(
                        section.group ?? '未分组',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final source in section.sources) _sourceRow(source),
                ],
            ],
          ),
        ),
        if (_selecting)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: SizedBox(
                width: double.infinity,
                child: GlassPillButton(
                  key: const ValueKey('book-source-delete-selected'),
                  icon: CupertinoIcons.trash,
                  label: _selected.isEmpty
                      ? '请选择书源'
                      : '删除 ${_selected.length} 个书源',
                  onPressed: _deleting || _selected.isEmpty
                      ? null
                      : () => _deleteSources(
                          _selected.toList(),
                          label: '所选的 ${_selected.length} 个书源',
                        ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _sourceRow(BookSourceSummary source) {
    final chosen = _selected.contains(source.sourceUrl);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        selected: _selecting ? chosen : null,
        child: ContentPanel(
          key: ValueKey('book-source-${source.sourceUrl}'),
          onTap: _selecting
              ? () => setState(() {
                  chosen
                      ? _selected.remove(source.sourceUrl)
                      : _selected.add(source.sourceUrl);
                })
              : null,
          child: Row(
            children: [
              if (_selecting) ...[
                Icon(
                  chosen
                      ? CupertinoIcons.checkmark_circle_fill
                      : CupertinoIcons.circle,
                  size: 23,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      source.sourceName.isEmpty
                          ? source.sourceUrl
                          : source.sourceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    AppText(
                      _subtitle(source),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (source.comment != null &&
                        source.comment!.trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      AppText(
                        source.comment!.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!_selecting) ...[
                const SizedBox(width: 8),
                AppControls.toggle(
                  context,
                  key: ValueKey('book-source-enabled-${source.sourceUrl}'),
                  value: source.enabled,
                  onChanged: (value) => _setEnabled(source, value),
                ),
                if (source.hasLogin)
                  GlassIconButton(
                    key: ValueKey('book-source-login-${source.sourceUrl}'),
                    icon: CupertinoIcons.person_crop_circle,
                    label: '登录书源 ${source.sourceName}',
                    onPressed: () => unawaited(_openLogin(source)),
                  ),
                GlassIconButton(
                  icon: CupertinoIcons.trash,
                  label: '删除书源 ${source.sourceName}',
                  onPressed: _deleting
                      ? null
                      : () => _deleteSources([
                          source.sourceUrl,
                        ], label: '「${source.sourceName}」'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Import sheet: network URL, pasted JSON text, or a picked file — all
/// three end in the same engine `importSources` call, mirroring the
/// layout of the app's other jelly sheets (see `confirmNovelAction`).
class _ImportSourceSheet extends StatefulWidget {
  const _ImportSourceSheet({required this.client, required this.documents});

  final LegadoEngineClient client;
  final BookDocuments documents;

  @override
  State<_ImportSourceSheet> createState() => _ImportSourceSheetState();
}

class _ImportSourceSheetState extends State<_ImportSourceSheet> {
  final _url = TextEditingController();
  final _json = TextEditingController();
  final _bookUrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _json.dispose();
    _bookUrl.dispose();
    super.dispose();
  }

  /// 按链接找书 (G16): the engine matches the pasted book-page link to
  /// an imported source and fetches its info; success closes the
  /// sheet with the [BookByUrlResult] for the page to register + open.
  Future<void> _findBook() async {
    if (_busy) return;
    final url = _bookUrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请先粘贴书籍详情页链接');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.client.init();
      final result = await widget.client.getBookByUrl(url);
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _busy = false;
          _error = '没有已导入的书源认领这个链接';
        });
        return;
      }
      Navigator.pop(context, result);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message ?? '找书失败，请重试';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '找书失败，请重试';
      });
    }
  }

  Future<void> _run(Future<ImportResult> Function() action) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.client.init();
      final result = await action();
      if (!mounted) return;
      if (result.added + result.updated + result.unchanged == 0) {
        setState(() {
          _busy = false;
          _error = result.errors.isNotEmpty
              ? result.errors.first
              : '没有识别到书源，请检查内容后重试';
        });
        return;
      }
      Navigator.pop(context, result);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message ?? '导入失败，请重试';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '导入失败，请重试';
      });
    }
  }

  Future<void> _importFromFile() async {
    if (_busy) return;
    final picked = await widget.documents.pickBook();
    if (picked == null || !mounted) return;
    try {
      await _run(() => widget.client.importFromFilePath(picked.path));
    } finally {
      await widget.documents.releaseBooks([
        BookDocumentSelection(name: picked.name, path: picked.path),
      ]);
    }
  }

  @override
  // Scrollable, mirroring _SelfCheckSheet: this sheet is tall (two
  // fields, three import buttons, an optional error line) and the glass
  // overlay already shrinks the sheet's max height by the keyboard's
  // viewInsets (_popupSafeRect), so a fixed Column overflowed and
  // painted the debug overflow stripe as soon as the keyboard opened.
  // Inside a SingleChildScrollView the same content scrolls instead,
  // and the focused field is revealed by the scrollable as usual.
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppText(
            '导入书源',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('book-source-import-url'),
            controller: _url,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: true,
            // Keyboard behaviour (fix2, 2026-11-03): this field must
            // report the plainest possible text input type to the
            // system, exactly like Legado's own import dialog (bare
            // KeyboardOptions.Default -> EditorInfo.inputType 0x1).
            // Two traps were found the hard way:
            //  - TextInputType.url / AutofillHints.url (removed earlier)
            //    can make HyperOS treat the field as sensitive.
            //  - enableSuggestions MUST stay true here: with it false,
            //    Flutter's TextInputPlugin hard-codes
            //    TYPE_TEXT_VARIATION_VISIBLE_PASSWORD into the
            //    EditorInfo.inputType, and HyperOS hands any
            //    password-family variation to Xiaomi's secure
            //    keyboard — even though this is not a password field.
            //    (fix1 removed the autofill hint only; the secure
            //    keyboard kept appearing because of this flag.)
            // autocorrect stays false; suggestions being enabled only
            // restores the normal system keyboard, like Legado.
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (_url.text.trim().isEmpty) {
                setState(() => _error = '请先填写书源网络地址');
              } else {
                unawaited(
                  _run(() => widget.client.importFromUrl(_url.text.trim())),
                );
              }
            },
            decoration: const InputDecoration(
              labelText: '书源网络地址',
              hintText: 'https://…',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          GlassTextButton(
            key: const ValueKey('book-source-import-url-submit'),
            onPressed: _busy
                ? null
                : () {
                    if (_url.text.trim().isEmpty) {
                      setState(() => _error = '请先填写书源网络地址');
                      return;
                    }
                    unawaited(
                      _run(() => widget.client.importFromUrl(_url.text.trim())),
                    );
                  },
            child: AppText(_busy ? '正在导入…' : '从网络导入'),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('book-source-import-json'),
            controller: _json,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: true,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '书源 JSON',
              hintText: '粘贴一个或多个书源的 JSON 文本',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          GlassTextButton(
            key: const ValueKey('book-source-import-json-submit'),
            onPressed: _busy
                ? null
                : () {
                    if (_json.text.trim().isEmpty) {
                      setState(() => _error = '请先粘贴书源 JSON');
                      return;
                    }
                    unawaited(
                      _run(() => widget.client.importFromJsonText(_json.text)),
                    );
                  },
            child: AppText(_busy ? '正在导入…' : '从文本导入'),
          ),
          const SizedBox(height: 12),
          GlassTextButton(
            key: const ValueKey('book-source-import-file'),
            onPressed: _busy ? null : () => unawaited(_importFromFile()),
            child: const AppText('从文件导入'),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('book-source-book-url'),
            controller: _bookUrl,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: true,
            keyboardType: TextInputType.text,
            // Keyboard: plain text type, no autofill hint, and
            // enableSuggestions stays true — see the fix2 note on the
            // import URL field above.
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => unawaited(_findBook()),
            decoration: const InputDecoration(
              labelText: '书籍详情页链接',
              hintText: '粘贴书籍页网址，直接打开这本书',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          GlassTextButton(
            key: const ValueKey('book-source-book-url-submit'),
            onPressed: _busy ? null : () => unawaited(_findBook()),
            child: AppText(_busy ? '处理中…' : '按链接找书'),
          ),
          FeatureError(_error),
          const SizedBox(height: 8),
          GlassTextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const AppText('取消'),
          ),
        ],
      ),
    ),
  );
}

/// Self-check report sheet: renders the bridge's staged probe results
/// as plain label/value lines, in the same sheet typography as the
/// import sheet. Deliberately raw — this is a diagnostic surface.
class _SelfCheckSheet extends StatelessWidget {
  const _SelfCheckSheet({required this.result});

  final Map<String, Object?> result;

  static String _format(Object? value) {
    if (value is List) {
      return value.isEmpty ? '(无)' : value.map(_format).join('\n');
    }
    if (value is Map) {
      return value.entries
          .map((entry) => '${entry.key}: ${_format(entry.value)}')
          .join('\n');
    }
    return value?.toString() ?? '';
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppText(
            '引擎自检',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          for (final entry in result.entries) ...[
            AppText(
              entry.key,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            AppText(_format(entry.value), style: const TextStyle(height: 1.6)),
            const SizedBox(height: 12),
          ],
          GlassTextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('关闭'),
          ),
        ],
      ),
    ),
  );
}

/// Batch source-check results sheet (G12): subscribes to the task
/// channel first, then starts the check with its own pre-allocated
/// task id so no progress event can slip past the subscription.
/// Renders one line per finished source, in the self-check sheet's
/// plain label/value style.
class _CheckSourcesSheet extends StatefulWidget {
  const _CheckSourcesSheet({
    required this.client,
    required this.taskId,
    required this.sourceNames,
  });

  final LegadoEngineClient client;
  final int taskId;
  final Map<String, String> sourceNames;

  @override
  State<_CheckSourcesSheet> createState() => _CheckSourcesSheetState();
}

class _CheckSourcesSheetState extends State<_CheckSourcesSheet> {
  StreamSubscription<LegadoTaskEvent>? _subscription;
  final List<CheckProgressEvent> _results = [];
  int _done = 0;
  int _total = 0;
  bool _finished = false;
  int _okCount = 0;
  int _failCount = 0;
  String? _startError;

  @override
  void initState() {
    super.initState();
    _subscription = widget.client.taskEvents.listen((event) {
      if (event.taskId != widget.taskId || !mounted) return;
      setState(() {
        if (event is CheckProgressEvent) {
          _results.add(event);
          _done = event.done;
          _total = event.total;
        } else if (event is CheckDoneEvent) {
          _finished = true;
          _okCount = event.okCount;
          _failCount = event.failCount;
        }
      });
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await widget.client.checkSources(taskId: widget.taskId);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _finished = true;
        _startError = error.message ?? '校验启动失败';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _finished = true;
        _startError = '校验启动失败';
      });
    }
  }

  /// This round's failed sources, one entry per source in result
  /// order — handed back to the page when the sheet is closed via
  /// 「选中失效书源」, which preselects them for batch deletion.
  List<String> get _failedUrls {
    final seen = <String>{};
    return [
      for (final result in _results)
        if (!result.ok && seen.add(result.sourceUrl)) result.sourceUrl,
    ];
  }

  @override
  void dispose() {
    if (!_finished) {
      unawaited(widget.client.cancelTask(widget.taskId));
    }
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppText(
            '校验书源',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          AppText(
            _finished
                ? '校验完成：可用 $_okCount · 失效 $_failCount'
                : '校验中… 已完成 $_done${_total > 0 ? ' / $_total' : ''}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          if (_startError != null) FeatureError(_startError),
          for (final result in _results) ...[
            AppText(
              widget.sourceNames[result.sourceUrl] ?? result.sourceUrl,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            AppText(
              result.ok
                  ? '可用'
                  : '失效${result.message == null ? '' : '：${result.message}'}',
              style: TextStyle(
                fontSize: 12,
                color: result.ok
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (_finished && _startError == null && _failedUrls.isNotEmpty) ...[
            GlassTextButton(
              key: const ValueKey('book-source-check-select-failed'),
              onPressed: () => Navigator.pop(context, _failedUrls),
              child: AppText('选中失效书源（${_failedUrls.length} 个）'),
            ),
            const SizedBox(height: 8),
          ],
          GlassTextButton(
            onPressed: () => Navigator.pop(context),
            child: AppText(_finished ? '关闭' : '后台继续校验（点此关闭）'),
          ),
        ],
      ),
    ),
  );
}

/// Converter option sheet: three same-style rows, a check mark on the
/// current mode; tapping one closes with its value.
class _ConverterSheet extends StatelessWidget {
  const _ConverterSheet({required this.current});

  final int current;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppText(
            '简繁转换',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          AppText(
            '只对书源（Legado）书籍的正文生效，文库书籍不受影响。',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < chineseConverterLabels.length; i++) ...[
            ContentPanel(
              key: ValueKey('book-source-converter-$i'),
              onTap: () => Navigator.pop(context, i),
              child: Row(
                children: [
                  Expanded(
                    child: AppText(
                      chineseConverterLabels[i],
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  if (i == current)
                    Icon(
                      CupertinoIcons.check_mark,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          GlassTextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('取消'),
          ),
        ],
      ),
    ),
  );
}

String _formatSubscriptionTime(int millis) {
  if (millis <= 0) return '未更新';
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

/// Subscription type labels for the add form's cycling selector, in
/// the fork's RuleSub type order (0 书源 / 2 替换 / 3 目录 / 4 字典 /
/// 5 语音).
const Map<int, String> subscriptionTypeLabels = {
  0: '书源',
  2: '替换规则',
  3: '目录规则',
  4: '字典规则',
  5: '语音源',
};

/// Subscription management sheet (G13): add a subscription address,
/// list the current subscriptions, update or delete each, and kick a
/// batch update. Imports land through the engine's normal import
/// path, so imported sources appear in the page's list afterwards.
class _SubscriptionsSheet extends StatefulWidget {
  const _SubscriptionsSheet({required this.client});

  final LegadoEngineClient client;

  @override
  State<_SubscriptionsSheet> createState() => _SubscriptionsSheetState();
}

class _SubscriptionsSheetState extends State<_SubscriptionsSheet> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  List<LegadoSubscription> _subscriptions = const [];
  bool _loading = true;
  bool _busy = false;
  int _type = 0;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final subscriptions = await widget.client.listSubscriptions();
      if (!mounted) return;
      setState(() {
        _subscriptions = subscriptions;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '订阅列表读取失败';
      });
    }
  }

  Future<void> _add() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请先填写订阅地址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      var name = _name.text.trim();
      if (name.isEmpty) {
        name = Uri.tryParse(url)?.host ?? url;
      }
      await widget.client.upsertSubscription(
        LegadoSubscription(name: name, url: url, type: _type),
      );
      if (!mounted) return;
      _name.clear();
      _url.clear();
      setState(() {
        _busy = false;
        _message = '订阅已添加，点该订阅的「更新」拉取内容';
      });
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '订阅添加失败，请重试';
      });
    }
  }

  Future<void> _update(LegadoSubscription subscription) async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await widget.client.updateSubscription(subscription.id);
      if (!mounted) return;
      final parts = [
        if (result.added > 0) '新增 ${result.added}',
        if (result.updated > 0) '更新 ${result.updated}',
        if (result.unchanged > 0) '未变 ${result.unchanged}',
        if (result.failed > 0) '失败 ${result.failed}',
      ];
      setState(() {
        _busy = false;
        _message =
            '「${subscription.name}」更新完成'
            '${parts.isEmpty ? '' : '：${parts.join(' · ')}'}';
        _error = result.errors.isNotEmpty ? result.errors.first : null;
      });
      await _load();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message ?? '更新失败，请重试';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '更新失败，请重试';
      });
    }
  }

  Future<void> _delete(LegadoSubscription subscription) async {
    final confirmed = await confirmNovelAction(
      context,
      title: '删除订阅',
      message: '删除订阅「${subscription.name}」？已导入的内容会保留。',
      confirmLabel: '删除',
    );
    if (!confirmed || !mounted) return;
    try {
      await widget.client.deleteSubscription(subscription.id);
      if (!mounted) return;
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '删除失败，请重试');
    }
  }

  Future<void> _updateAll() async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await widget.client.updateAllSubscriptions();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = '已开始更新全部订阅，稍后重开本页查看结果';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '更新启动失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppText(
            '订阅管理',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('book-source-subscription-name'),
            controller: _name,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '订阅名称（可空）',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('book-source-subscription-url'),
            controller: _url,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: true,
            keyboardType: TextInputType.text,
            // Keyboard: plain text type, no autofill hint, and
            // enableSuggestions stays true — see the fix2 note on the
            // import URL field above.
            decoration: const InputDecoration(
              labelText: '订阅地址',
              hintText: 'https://…',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              GlassTextButton(
                key: const ValueKey('book-source-subscription-type'),
                compact: true,
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        final types = subscriptionTypeLabels.keys.toList();
                        _type =
                            types[(types.indexOf(_type) + 1) % types.length];
                      }),
                child: AppText('类型：${subscriptionTypeLabels[_type]}（点按切换）'),
              ),
              const Spacer(),
              GlassTextButton(
                key: const ValueKey('book-source-subscription-add'),
                compact: true,
                onPressed: _busy ? null : () => unawaited(_add()),
                child: const AppText('添加订阅'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: GlassTextButton(
              key: const ValueKey('book-source-subscription-update-all'),
              compact: true,
              onPressed: _busy ? null : () => unawaited(_updateAll()),
              child: const AppText('全部更新'),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 10),
            AppText(
              _message!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          FeatureError(_error),
          const SizedBox(height: 14),
          if (_loading)
            const AppText('正在加载订阅…')
          else if (_subscriptions.isEmpty)
            const AppText('还没有订阅。添加订阅地址后，点「更新」即可批量导入。')
          else
            for (final subscription in _subscriptions) ...[
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      subscription.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    AppText(
                      subscription.url,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    AppText(
                      '${subscriptionTypeLabels[subscription.type] ?? '书源'}'
                      ' · 上次更新：${_formatSubscriptionTime(subscription.lastUpdate)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        GlassTextButton(
                          compact: true,
                          onPressed: _busy
                              ? null
                              : () => unawaited(_update(subscription)),
                          child: const AppText('更新'),
                        ),
                        const SizedBox(width: 8),
                        GlassTextButton(
                          compact: true,
                          onPressed: _busy
                              ? null
                              : () => unawaited(_delete(subscription)),
                          child: const AppText('删除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
          GlassTextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('关闭'),
          ),
        ],
      ),
    ),
  );
}

/// Replace-rule sheet (G14): the deliberately small management
/// surface — list with enable toggles and delete, plus JSON import
/// through the same import channel as sources. A per-field visual
/// editor is intentionally not built (rules are fully manageable by
/// importing JSON, exactly like the fork's batch flows).
class _ReplaceRulesSheet extends StatefulWidget {
  const _ReplaceRulesSheet({required this.client});

  final LegadoEngineClient client;

  @override
  State<_ReplaceRulesSheet> createState() => _ReplaceRulesSheetState();
}

class _ReplaceRulesSheetState extends State<_ReplaceRulesSheet> {
  final _json = TextEditingController();
  List<LegadoReplaceRule> _rules = const [];
  bool _loading = true;
  bool _busy = false;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rules = await widget.client.listReplaceRules();
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '替换规则读取失败';
      });
    }
  }

  Future<void> _import() async {
    if (_json.text.trim().isEmpty) {
      setState(() => _error = '请先粘贴替换规则 JSON');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await widget.client.importFromJsonText(_json.text);
      if (!mounted) return;
      final parts = [
        if (result.added > 0) '新增 ${result.added}',
        if (result.updated > 0) '更新 ${result.updated}',
        if (result.unchanged > 0) '未变 ${result.unchanged}',
        if (result.failed > 0) '失败 ${result.failed}',
      ];
      setState(() {
        _busy = false;
        _message = parts.isEmpty ? '导入完成' : '导入完成：${parts.join(' · ')}';
      });
      await _load();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message ?? '导入失败，请重试';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '导入失败，请重试';
      });
    }
  }

  Future<void> _toggle(LegadoReplaceRule rule, bool enabled) async {
    try {
      await widget.client.setReplaceRuleEnabled(rule.id, enabled);
      if (!mounted) return;
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '设置失败，请重试');
    }
  }

  Future<void> _delete(LegadoReplaceRule rule) async {
    final confirmed = await confirmNovelAction(
      context,
      title: '删除替换规则',
      message: '删除规则「${rule.name}」？',
      confirmLabel: '删除',
    );
    if (!confirmed || !mounted) return;
    try {
      await widget.client.deleteReplaceRule(rule.id);
      if (!mounted) return;
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '删除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppText(
            '替换规则',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          AppText(
            '替换规则在读取正文时生效（把指定文字换成另一段文字）。',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          if (_loading)
            const AppText('正在加载替换规则…')
          else if (_rules.isEmpty)
            const AppText('还没有替换规则。用下方文本框导入规则 JSON。')
          else
            for (final rule in _rules) ...[
              ContentPanel(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText(
                            rule.name.isEmpty ? rule.pattern : rule.name,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          AppText(
                            '${rule.pattern} → ${rule.replacement}'
                            '${(rule.scope ?? '').isEmpty ? '' : ' · ${rule.scope}'}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AppControls.toggle(
                      context,
                      key: ValueKey('book-source-replace-enabled-${rule.id}'),
                      value: rule.isEnabled,
                      onChanged: _busy
                          ? null
                          : (value) => unawaited(_toggle(rule, value)),
                    ),
                    GlassIconButton(
                      onPressed: _busy ? null : () => unawaited(_delete(rule)),
                      label: '删除规则 ${rule.name}',
                      icon: CupertinoIcons.trash,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('book-source-replace-import-json'),
            controller: _json,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: true,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '替换规则 JSON',
              hintText: '粘贴替换规则的 JSON 文本',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          GlassTextButton(
            key: const ValueKey('book-source-replace-import-submit'),
            onPressed: _busy ? null : () => unawaited(_import()),
            child: AppText(_busy ? '正在导入…' : '从文本导入'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 10),
            AppText(
              _message!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          FeatureError(_error),
          const SizedBox(height: 8),
          GlassTextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('关闭'),
          ),
        ],
      ),
    ),
  );
}

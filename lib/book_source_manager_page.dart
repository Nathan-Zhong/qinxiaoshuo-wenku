import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_documents.dart';
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
  const BookSourceManagerPage({super.key, this.client, this.documents});

  final LegadoEngineClient? client;
  final BookDocuments? documents;

  @override
  State<BookSourceManagerPage> createState() => _BookSourceManagerPageState();
}

class _BookSourceManagerPageState extends State<BookSourceManagerPage> {
  late final LegadoEngineClient _client = widget.client ?? LegadoEngineClient();
  late final BookDocuments _documents = widget.documents ?? BookDocuments();

  bool _loading = true;
  bool _deleting = false;
  bool _checking = false;
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
      if (!mounted) return;
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
    final result = await showJellySheet<ImportResult>(
      context: context,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (sheet) =>
          _ImportSourceSheet(client: _client, documents: _documents),
    );
    if (result == null || !mounted) return;
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
              const SizedBox(height: 16),
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
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _json.dispose();
    super.dispose();
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
            enableSuggestions: false,
            // Plain text, NOT TextInputType.url: on HyperOS the url
            // keyboard type was seen to raise Xiaomi's secure keyboard
            // for this field, as if it were a sensitive input. The URL
            // classification is kept for the system via autofillHints
            // instead. (Which keyboard ultimately opens is the system's
            // call; this is the app-side best effort.)
            keyboardType: TextInputType.text,
            autofillHints: const [AutofillHints.url],
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
            enableSuggestions: false,
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

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_interactions.dart';
import '../app_ui.dart';
import '../feature_pages.dart';
import 'legado_dto.dart';
import 'legado_engine_client.dart';
import 'legado_verification_ui.dart';

/// Dart end of source login (G3, P5.3): the login form sheet, built
/// exactly like the bookmark-note / captcha sheets (jelly sheet,
/// [ArchiveSection] header, Cupertino fields, glass buttons) and
/// rendering the engine's RowUi rows one per line — text/password
/// inputs, select and toggle rows, button rows, title rows.
///
/// Two entrances share the sheet:
/// - the management page (user taps a login source's login button),
///   which calls [showSourceLoginSheet] directly;
/// - the engine's JS (`source.showLoginDialog()`), which arrives as
///   the platform call `showSourceLogin` on the bridge channel —
///   [LegadoLoginUi] routes it here and answers when the sheet
///   closes, which is the signal the native side turns into the
///   engine's login-finished wakeup.
///
/// Form semantics mirror the fork's SourceLoginDialog: the confirm
/// button submits every input row's current value (an all-button
/// form submits an empty map, which the engine treats as "remove
/// saved login info"); button rows and select/toggle changes run
/// their row's action script with the current values bound.
class LegadoLoginUi {
  LegadoLoginUi._({required this.client, required this.contextProvider});

  final LegadoEngineClient client;
  final BuildContext? Function() contextProvider;

  static LegadoLoginUi? _installed;

  /// The installed instance, if any.
  static LegadoLoginUi? get installed => _installed;

  /// Installs the combined platform-call handler on the shared
  /// engine client: `showSourceLogin` is served here, everything
  /// else (the captcha call) is forwarded to the verification UI.
  /// Install AFTER [LegadoVerificationUi.install], as main() does —
  /// this replaces the handler that install set.
  static LegadoLoginUi install({
    required LegadoEngineClient client,
    required BuildContext? Function() contextProvider,
  }) {
    final ui = LegadoLoginUi._(
      client: client,
      contextProvider: contextProvider,
    );
    client.setPlatformCallHandler(ui.handlePlatformCall);
    _installed = ui;
    return ui;
  }

  /// Test hook: forget the installed instance.
  static void resetForTest() => _installed = null;

  Future<Object?> handlePlatformCall(MethodCall call) async {
    if (call.method == 'showSourceLogin') {
      final args = call.arguments;
      final map = args is Map ? args.cast<Object?, Object?>() : const {};
      final origin = map['origin']?.toString() ?? '';
      final sourceName = map['sourceName']?.toString() ?? '';
      if (origin.isEmpty) return null;
      final context = contextProvider();
      if (context == null || !context.mounted) {
        throw PlatformException(
          code: 'NO_CONTEXT',
          message: 'No UI context available for the login sheet',
        );
      }
      await showSourceLoginSheet(
        context,
        client: client,
        sourceUrl: origin,
        sourceName: sourceName,
      );
      return null;
    }
    final verification = LegadoVerificationUi.installed;
    if (verification != null) {
      return verification.handlePlatformCall(call);
    }
    throw MissingPluginException('No UI handler for ${call.method}');
  }
}

/// Shows the login sheet for one source and resolves when it closes.
Future<void> showSourceLoginSheet(
  BuildContext context, {
  required LegadoEngineClient client,
  required String sourceUrl,
  required String sourceName,
}) => showJellySheet<void>(
  context: context,
  heightFactor: .8,
  builder: (sheet) => _SourceLoginSheet(
    sheet: sheet,
    client: client,
    sourceUrl: sourceUrl,
    sourceName: sourceName,
  ),
);

class _SourceLoginSheet extends StatefulWidget {
  const _SourceLoginSheet({
    required this.sheet,
    required this.client,
    required this.sourceUrl,
    required this.sourceName,
  });

  final BuildContext sheet;
  final LegadoEngineClient client;
  final String sourceUrl;
  final String sourceName;

  @override
  State<_SourceLoginSheet> createState() => _SourceLoginSheetState();
}

class _SourceLoginSheetState extends State<_SourceLoginSheet> {
  LegadoLoginData? data;
  String? loadError;
  bool busy = false;

  /// Text controllers for text/password rows, keyed by row name
  /// (the fork keys form state by row name too).
  final Map<String, TextEditingController> textControllers = {};

  /// Current values for select/toggle rows, keyed by row name.
  final Map<String, String> choiceValues = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final controller in textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loadError = null;
      data = null;
    });
    try {
      await widget.client.init();
      final result = await widget.client.getLoginData(widget.sourceUrl);
      if (!mounted) return;
      // Fallback for sources with no login page and no form rows
      // (kind none, e.g. 番茄小说): the sheet would otherwise be a
      // dead end. Offer a plain account/password form that submits
      // through the same loginSource path as a source-defined form —
      // the entered values are saved as the source's login info and
      // the source's login() runs after, exactly as for form rows.
      final rows = result.kind == LegadoLoginKind.none
          ? const <LegadoLoginRow>[
              LegadoLoginRow(name: '账号', type: 'text'),
              LegadoLoginRow(name: '密码', type: 'password'),
            ]
          : result.rows;
      for (final row in rows) {
        switch (row.type) {
          case 'text':
          case 'password':
            textControllers[row.name] = TextEditingController(
              text: result.values[row.name] ?? '',
            );
          case 'select':
          case 'toggle':
            choiceValues[row.name] =
                result.values[row.name] ??
                (row.type == 'toggle'
                    ? 'false'
                    : (row.chars.isNotEmpty ? row.chars.first : ''));
        }
      }
      setState(
        () => data = LegadoLoginData(
          sourceUrl: result.sourceUrl,
          sourceName: result.sourceName,
          kind: result.kind,
          loginUrl: result.loginUrl,
          rows: rows,
          values: result.values,
          hasLoginInfo: result.hasLoginInfo,
          hasLoginHeader: result.hasLoginHeader,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => loadError = '登录表单加载失败，请重试');
    }
  }

  /// The fork's getLoginData(): one entry per input row, in row
  /// order — buttons and titles never contribute.
  Map<String, String> gatherData() {
    final result = <String, String>{};
    for (final row in data?.rows ?? const <LegadoLoginRow>[]) {
      switch (row.type) {
        case 'text':
        case 'password':
          result[row.name] = textControllers[row.name]?.text ?? '';
        case 'select':
        case 'toggle':
          result[row.name] = choiceValues[row.name] ?? '';
      }
    }
    return result;
  }

  void _feedback(String message) {
    if (!mounted) return;
    showNovelFeedback(context, message);
  }

  /// Runs a row action (button tap, select/toggle change). Fork
  /// semantics: errors are surfaced and the sheet stays open.
  Future<void> _runAction(LegadoLoginRow row) async {
    final action = row.action;
    if (action == null || action.isEmpty || busy) return;
    setState(() => busy = true);
    try {
      await widget.client.runLoginAction(
        widget.sourceUrl,
        action: action,
        data: gatherData(),
      );
    } on PlatformException catch (error) {
      _feedback('操作失败：${error.message ?? '请重试'}');
    } catch (_) {
      _feedback('操作失败，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Opens the engine's web-login window (the source's own web page),
  /// which is the only way sources that gate full text behind a web
  /// session (e.g. 第10章后全文需登录) can sign in: the form rows alone
  /// only carry a JS verification result that those sources refuse.
  Future<void> _webLogin() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final kind = await widget.client.openSourceLogin(widget.sourceUrl, webOnly: true);
      if (!mounted) return;
      switch (kind) {
        case LegadoLoginKind.web:
          _feedback('已打开网页登录，登录完成后返回本页确认');
          unawaited(_load());
        case LegadoLoginKind.js:
          _feedback('已运行登录脚本，请在弹出的页面中完成');
          unawaited(_load());
        case LegadoLoginKind.form:
          _feedback('该书源没有独立登录页，请使用表单登录');
        case LegadoLoginKind.none:
          // The engine answers "none" both when the source has no
          // login at all and when its loginUrl is a script (番茄小说
          // / 漫蛙书源): those sources still offer web login through
          // their own button rows in the form. Point at the form
          // instead of claiming there is no login page.
          if (data?.kind == LegadoLoginKind.form) {
            _feedback('该书源的网页登录在表单里，请点表单中的登录按钮');
          } else {
            _feedback('该书源没有登录页，请使用表单登录');
          }
      }
    } on PlatformException catch (error) {
      _feedback('网页登录失败：${error.message ?? '请重试'}');
    } catch (_) {
      _feedback('网页登录失败，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _submit() async {
    if (busy) return;
    if (data?.kind == LegadoLoginKind.none) {
      // The fallback form has no source-defined rows to fall back
      // on: two blank fields would save empty credentials.
      final account = textControllers['账号']?.text.trim() ?? '';
      final password = textControllers['密码']?.text ?? '';
      if (account.isEmpty && password.isEmpty) {
        _feedback('请先输入账号和密码');
        return;
      }
    }
    setState(() => busy = true);
    try {
      await widget.client.loginSource(widget.sourceUrl, gatherData());
      if (!mounted || !widget.sheet.mounted) return;
      // Feedback first: the notice lives on the root overlay, while
      // this sheet's context dies with the pop.
      _feedback('登录成功');
      Navigator.pop(widget.sheet);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => busy = false);
      _feedback('登录出错：${error.message ?? '请重试'}');
    } catch (_) {
      if (!mounted) return;
      setState(() => busy = false);
      _feedback('登录出错，请重试');
    }
  }

  Future<void> _logout() async {
    if (busy) return;
    final confirmed = await confirmNovelAction(
      context,
      title: '退出登录？',
      message: '将删除「${widget.sourceName}」保存的登录信息与登录头。',
      confirmLabel: '退出登录',
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
    if (!confirmed || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.client.logoutSource(widget.sourceUrl);
      if (!mounted || !widget.sheet.mounted) return;
      _feedback('已退出登录');
      Navigator.pop(widget.sheet);
    } catch (_) {
      if (!mounted) return;
      setState(() => busy = false);
      _feedback('退出登录失败，请重试');
    }
  }

  Future<void> _showLoginHeader() async {
    String? header;
    try {
      header = await widget.client.getLoginHeader(widget.sourceUrl);
    } catch (_) {
      header = null;
    }
    if (!mounted) return;
    if (header == null || header.isEmpty) {
      _feedback('没有保存的登录头');
      return;
    }
    await showJellySheet<void>(
      context: context,
      heightFactor: .58,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ArchiveSection(
                title: '登录头',
                code: 'SOURCE / LOGIN HEADER',
                subtitle: widget.sourceName,
              ),
              const SizedBox(height: 16),
              AppText(header!, style: const TextStyle(height: 1.6)),
              const SizedBox(height: 18),
              GlassTextButton(
                onPressed: () => Navigator.pop(sheet),
                child: const AppText('关闭'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _removeLoginHeader() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.client.removeLoginHeader(widget.sourceUrl);
      if (!mounted) return;
      setState(() {
        busy = false;
        final current = data;
        if (current != null) {
          data = LegadoLoginData(
            sourceUrl: current.sourceUrl,
            sourceName: current.sourceName,
            kind: current.kind,
            loginUrl: current.loginUrl,
            rows: current.rows,
            values: current.values,
            hasLoginInfo: current.hasLoginInfo,
            hasLoginHeader: false,
          );
        }
      });
      _feedback('已删除登录头');
    } catch (_) {
      if (!mounted) return;
      setState(() => busy = false);
      _feedback('删除登录头失败，请重试');
    }
  }

  Future<void> _pickSelect(LegadoLoginRow row) async {
    if (busy || row.chars.isEmpty) return;
    final picked = await showJellySheet<String>(
      context: context,
      heightFactor: .58,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ArchiveSection(
                title: row.name,
                code: 'SOURCE / SELECT',
                subtitle: widget.sourceName,
              ),
              const SizedBox(height: 16),
              for (final option in row.chars)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ContentPanel(
                    key: ValueKey(
                      'source-login-option-${row.name}-$option',
                    ),
                    onTap: () => Navigator.pop(sheet, option),
                    child: AppText(option),
                  ),
                ),
              GlassTextButton(
                onPressed: () => Navigator.pop(sheet),
                child: const AppText('取消'),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (choiceValues[row.name] == picked) return;
    setState(() => choiceValues[row.name] = picked);
    // Fork: a select change fires the row's action with the new value.
    await _runAction(row);
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ArchiveSection(
          title: '登录书源',
          code: 'SOURCE / LOGIN',
          subtitle: widget.sourceName,
        ),
        const SizedBox(height: 20),
        if (data == null && loadError == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Center(child: CupertinoActivityIndicator()),
          )
        else if (loadError != null) ...[
          AppText(loadError!, style: const TextStyle(height: 1.6)),
          const SizedBox(height: 18),
          GlassTextButton(
            key: const ValueKey('source-login-retry'),
            onPressed: () => unawaited(_load()),
            child: const AppText('重试'),
          ),
        ] else
          ..._formChildren(),
      ],
    ),
  );

  List<Widget> _formChildren() {
    final current = data!;
    if (current.kind == LegadoLoginKind.none) {
      // No login page and no source-defined form: the fallback
      // account/password form above. No web-login button — there is
      // no login page to open.
      return [
        const AppText(
          '该书源没有登录页，可直接输入账号密码登录。',
          style: TextStyle(height: 1.6),
        ),
        const SizedBox(height: 18),
        for (final row in current.rows) ...[
          _rowWidget(row),
          const SizedBox(height: 14),
        ],
        ..._formFooter(current, includeWebLogin: false),
      ];
    }
    if (current.kind != LegadoLoginKind.form) {
      // Defensive: entrances dispatch web/js before opening the
      // sheet, so a non-form kind here only appears if the source
      // changed under us — say so plainly instead of an empty form.
      return [
        const AppText(
          '该书源不使用表单登录，请从书源管理页的登录入口打开。',
          style: TextStyle(height: 1.6),
        ),
        const SizedBox(height: 18),
        GlassTextButton(
          onPressed: () => Navigator.pop(widget.sheet),
          child: const AppText('关闭'),
        ),
      ];
    }
    return [
      for (final row in current.rows) ...[
        _rowWidget(row),
        const SizedBox(height: 14),
      ],
      ..._formFooter(current, includeWebLogin: true),
    ];
  }

  /// Buttons shared by the source-defined form and the no-login-page
  /// fallback form: saved-login actions, then (form sources only)
  /// the web-login button, then cancel/confirm.
  List<Widget> _formFooter(
    LegadoLoginData current, {
    required bool includeWebLogin,
  }) => [
    if (current.hasLoginInfo || current.hasLoginHeader) ...[
      Wrap(
        spacing: 8,
        children: [
          if (current.hasLoginInfo)
            GlassTextButton(
              key: const ValueKey('source-login-logout'),
              compact: true,
              onPressed: busy ? null : () => unawaited(_logout()),
              child: const AppText('退出登录'),
            ),
          if (current.hasLoginHeader)
            GlassTextButton(
              key: const ValueKey('source-login-show-header'),
              compact: true,
              onPressed: busy ? null : () => unawaited(_showLoginHeader()),
              child: const AppText('查看登录头'),
            ),
          if (current.hasLoginHeader)
            GlassTextButton(
              key: const ValueKey('source-login-remove-header'),
              compact: true,
              onPressed: busy ? null : () => unawaited(_removeLoginHeader()),
              child: const AppText('删除登录头'),
            ),
        ],
      ),
      const SizedBox(height: 14),
    ],
    if (includeWebLogin) ...[
      GlassTextButton(
        key: const ValueKey('source-login-web'),
        onPressed: busy ? null : () => unawaited(_webLogin()),
        child: const AppText('网页登录（部分书源需要）'),
      ),
      const SizedBox(height: 12),
    ],
    Row(
      children: [
        GlassTextButton(
          key: const ValueKey('source-login-cancel'),
          onPressed: busy ? null : () => Navigator.pop(widget.sheet),
          child: const AppText('取消'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: GlassPillButton(
            key: const ValueKey('source-login-confirm'),
            icon: CupertinoIcons.checkmark,
            label: busy ? '处理中…' : '确定',
            onPressed: busy ? null : () => unawaited(_submit()),
          ),
        ),
      ],
    ),
  ];

  Widget _rowWidget(LegadoLoginRow row) {
    switch (row.type) {
      case 'password':
        // The Wenku sheets have no dedicated password field; the
        // platform text field with obscureText is the functional
        // minimum (same CupertinoTextField as the captcha sheet).
        return CupertinoTextField(
          key: ValueKey('source-login-field-${row.name}'),
          controller: textControllers[row.name],
          placeholder: row.name,
          obscureText: true,
          maxLines: 1,
          padding: const EdgeInsets.all(16),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        );
      case 'text':
        return CupertinoTextField(
          key: ValueKey('source-login-field-${row.name}'),
          controller: textControllers[row.name],
          placeholder: row.name,
          maxLines: 1,
          padding: const EdgeInsets.all(16),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        );
      case 'toggle':
        return Row(
          children: [
            Expanded(child: AppText(row.name)),
            AppControls.toggle(
              context,
              key: ValueKey('source-login-toggle-${row.name}'),
              value: choiceValues[row.name] == 'true',
              onChanged: busy
                  ? null
                  : (value) async {
                      setState(
                        () => choiceValues[row.name] = value.toString(),
                      );
                      // Fork: a toggle change fires the row's action.
                      await _runAction(row);
                    },
            ),
          ],
        );
      case 'select':
        return ContentPanel(
          key: ValueKey('source-login-select-${row.name}'),
          onTap: busy ? null : () => unawaited(_pickSelect(row)),
          child: Row(
            children: [
              Expanded(child: AppText(row.name)),
              AppText(
                choiceValues[row.name] ?? '',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(CupertinoIcons.chevron_down, size: 14),
            ],
          ),
        );
      case 'title':
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: AppText(
            row.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      default:
        // 'button' — and any unknown type, which the fork's dialog
        // also falls through to a button.
        return GlassTextButton(
          key: ValueKey('source-login-button-${row.name}'),
          onPressed: busy ? null : () => unawaited(_runAction(row)),
          child: AppText(row.name),
        );
    }
  }
}

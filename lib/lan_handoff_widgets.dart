import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_language.dart';
import 'app_ui.dart';
import 'archive_design.dart';
import 'archive_icons.dart';
import 'catalog.dart';
import 'lan_reading_sync.dart';
import 'library_state.dart';

/// 浮在界面最上层的「收到续读」提示。
///
/// 它挂在 [MaterialApp.builder] 里，Navigator、Scaffold 之外，
/// 所以只能使用不依赖 Overlay 的组件，也不在这里调用任何 SnackBar。
class LanHandoffMonitor extends StatefulWidget {
  const LanHandoffMonitor({
    super.key,
    required this.handoff,
    required this.onContinue,
    required this.reduceMotion,
    required this.noticeWrapper,
    required this.child,
  });

  final LanReadingHandoff? handoff;
  final Future<void> Function(LanHandoffReceipt receipt) onContinue;
  final bool reduceMotion;
  final Widget Function(Widget notice) noticeWrapper;
  final Widget child;

  @override
  State<LanHandoffMonitor> createState() => _LanHandoffMonitorState();
}

class _LanHandoffMonitorState extends State<LanHandoffMonitor> {
  LanHandoffReceipt? _busy;
  LanHandoffReceipt? _errorReceipt;
  String? _error;

  @override
  void didUpdateWidget(LanHandoffMonitor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.handoff, widget.handoff)) {
      _busy = null;
      _errorReceipt = null;
      _error = null;
    }
  }

  Future<void> _continue(LanHandoffReceipt receipt) async {
    final handoff = widget.handoff;
    if (handoff == null || _busy != null) return;
    setState(() {
      _busy = receipt;
      _errorReceipt = null;
      _error = null;
    });
    String? failure;
    try {
      await handoff.acceptReceipt(receipt);
      await widget.onContinue(receipt);
    } catch (error) {
      failure = switch (error) {
        FormatException(:final String message) => message,
        _ => '继续阅读失败，请稍后再试',
      };
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _errorReceipt = failure == null ? null : receipt;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final handoff = widget.handoff;
    if (handoff == null) return widget.child;
    return AnimatedBuilder(
      animation: handoff,
      child: widget.child,
      builder: (context, child) {
        final receipt = handoff.received;
        return Stack(
          textDirection: TextDirection.ltr,
          children: [
            Positioned.fill(child: child ?? const SizedBox.shrink()),
            if (receipt != null)
              Positioned(
                top: 0,
                left: 12,
                right: 12,
                child: SafeArea(
                  bottom: false,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: widget.noticeWrapper(
                        _LanHandoffCard(
                          receipt: receipt,
                          busy: identical(_busy, receipt),
                          error: identical(_errorReceipt, receipt) ? _error : null,
                          onContinue: () => _continue(receipt),
                          onDismiss: () => handoff.dismissReceipt(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LanHandoffCard extends StatelessWidget {
  const _LanHandoffCard({
    required this.receipt,
    required this.busy,
    required this.error,
    required this.onContinue,
    required this.onDismiss,
  });

  final LanHandoffReceipt receipt;
  final bool busy;
  final String? error;
  final VoidCallback onContinue;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = Theme.of(context).colorScheme.onSurface;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final chapterTitle = receipt.chapterTitle.trim();
    final progress = chapterTitle.isEmpty
        ? '第 ${receipt.chapter + 1} 章'
        : '第 ${receipt.chapter + 1} 章 · $chapterTitle';
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: dark ? ArchiveDesign.darkRaised : ArchiveDesign.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: dark ? ArchiveDesign.darkOutline : const Color(0xFFDAD7CE),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.42 : 0.14),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ArchiveIcon(
                    CupertinoIcons.wifi,
                    size: 16,
                    color: muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppText(
                      '来自 ${receipt.fromDeviceName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        letterSpacing: 0.4,
                        color: muted,
                      ),
                    ),
                  ),
                  AppText(
                    '续读',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 2,
                      color: muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              AppText(
                receipt.bookTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  height: 1.3,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: ink,
                ),
              ),
              const SizedBox(height: 4),
              AppText(
                progress,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, height: 1.4, color: muted),
              ),
              if (receipt.requiresConfirmation) ...[
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: dark
                        ? ArchiveDesign.darkMilk.withValues(alpha: 0.06)
                        : ArchiveDesign.background,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppText(
                          '核对两台设备上的数字是否相同',
                          maxLines: 2,
                          style: TextStyle(fontSize: 11, height: 1.35, color: muted),
                        ),
                      ),
                      const SizedBox(width: 10),
                      AppText(
                        receipt.pairingCode,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 5,
                          color: ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                AppText(
                  error!,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  GlassTextButton(
                    compact: true,
                    onPressed: busy ? null : onDismiss,
                    child: const AppText('忽略'),
                  ),
                  const SizedBox(width: 8),
                  GlassTextButton(
                    compact: true,
                    onPressed: busy ? null : onContinue,
                    child: busy
                        ? const CupertinoActivityIndicator(radius: 7)
                        : const AppText('继续阅读'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 阅读器里「发送到另一台设备」的底部面板。
class LanSendBookSheet extends StatefulWidget {
  const LanSendBookSheet({
    super.key,
    required this.sync,
    required this.book,
    required this.position,
    required this.reduceMotion,
  });

  final LanReadingSync sync;
  final Novel book;
  final ReadingPosition position;
  final bool reduceMotion;

  @override
  State<LanSendBookSheet> createState() => _LanSendBookSheetState();
}

class _LanSendBookSheetState extends State<LanSendBookSheet> {
  final TextEditingController _manual = TextEditingController();
  String? _busyPeerId;
  bool _manualOpen = false;
  bool _manualBusy = false;
  String? _error;
  String? _sentCode;
  String? _message;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  Future<void> _send(LanPeer peer) async {
    if (_busyPeerId != null) return;
    setState(() {
      _busyPeerId = peer.id;
      _error = null;
      _message = null;
    });
    String? failure;
    LanSendResult? result;
    try {
      result = await widget.sync.sendHandoff(
        peer: peer,
        book: widget.book,
        position: widget.position,
      );
    } catch (error) {
      failure = switch (error) {
        FormatException(:final String message) => message,
        _ => '发送失败，请检查两台设备是否还在同一个 Wi-Fi 下',
      };
    }
    if (!mounted) return;
    final done = result;
    if (done == null) {
      setState(() {
        _busyPeerId = null;
        _error = failure ?? '发送失败，请稍后再试';
      });
      return;
    }
    setState(() {
      _busyPeerId = null;
      if (done.ok) {
        _sentCode = done.pairingCode;
        _message = done.message;
      } else {
        _error = done.message.isEmpty ? '发送失败，请稍后再试' : done.message;
      }
    });
  }

  Future<void> _connect() async {
    final value = _manual.text.trim();
    if (value.isEmpty) {
      setState(() => _error = '请先输入对方的地址，例如 192.168.1.23:47821');
      return;
    }
    setState(() {
      _manualBusy = true;
      _error = null;
      _message = null;
    });
    String? failure;
    LanPeer? peer;
    try {
      peer = await widget.sync.connectTo(value);
    } catch (error) {
      failure = switch (error) {
        FormatException(:final String message) => message,
        _ => '连不上这个地址，请确认端口和 Wi-Fi',
      };
    }
    if (!mounted) return;
    final connected = peer;
    if (connected == null) {
      setState(() {
        _manualBusy = false;
        _error = failure ?? '连不上这个地址，请确认端口和 Wi-Fi';
      });
      return;
    }
    setState(() {
      _manualBusy = false;
      _message = '已连接 ${connected.name}，点一下设备即可发送';
      _manualOpen = false;
      _manual.clear();
    });
  }

  String get _chapterLabel {
    final chapters = widget.book.chapters;
    final index = widget.position.chapter;
    if (index < 0 || index >= chapters.length) return '第 ${index + 1} 章';
    return '第 ${index + 1} 章 · ${chapters[index].title}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.sync,
      builder: (context, _) {
        final theme = Theme.of(context);
        final ink = theme.colorScheme.onSurface;
        final muted = theme.colorScheme.onSurfaceVariant;
        final peers = widget.sync.peers;
        final onlineIds = peers.map((peer) => peer.id).toSet();
        final offlinePaired = widget.sync.pairedDevices
            .where((device) => !onlineIds.contains(device.id))
            .toList(growable: false);
        final empty = peers.isEmpty && offlinePaired.isEmpty;
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
          children: [
            const ArchiveSection(
              title: '发送到另一台设备',
              code: 'HANDOFF / SEND',
              subtitle: '两台设备连着同一个 Wi-Fi 时，会在这里出现。',
            ),
            const SizedBox(height: 16),
            ContentPanel(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  ArchiveIcon(
                    CupertinoIcons.book,
                    size: 20,
                    color: muted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppText(
                          widget.book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        AppText(
                          _chapterLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!widget.sync.available) ...[
              const SizedBox(height: 16),
              AppText(
                widget.sync.unavailableReason ??
                    '这台设备暂时无法打开局域网端口，局域网续读不可用。',
                style: TextStyle(fontSize: 12, height: 1.5, color: theme.colorScheme.error),
              ),
            ],
            if (_sentCode != null) ...[
              const SizedBox(height: 18),
              ContentPanel(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      '已经发送。请在另一台设备上核对这串数字：',
                      style: TextStyle(fontSize: 12, height: 1.5, color: muted),
                    ),
                    const SizedBox(height: 10),
                    AppText(
                      _sentCode!,
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 10,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 6),
                    AppText(
                      _message ?? '对方点「继续阅读」后，就会跳到同样的位置。',
                      style: TextStyle(fontSize: 12, height: 1.5, color: muted),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: GlassTextButton(
                        compact: true,
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const AppText('完成'),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 18),
              if (!widget.sync.available)
                const SizedBox.shrink()
              else if (empty)
                AppText(
                  '还没有发现设备。\n请确认两台设备连着同一个 Wi-Fi，并且都打开了「局域网续读」；也可以让对方把地址告诉你，在下面手动连接。',
                  style: TextStyle(fontSize: 13, height: 1.6, color: muted),
                )
              else ...[
                for (final peer in peers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _LanPeerTile(
                      name: peer.name,
                      detail:
                          '${peer.host}:${peer.port}${widget.sync.isPaired(peer.id) ? ' · 已配对' : ''}',
                      busy: _busyPeerId == peer.id,
                      enabled: _busyPeerId == null,
                      onTap: () => _send(peer),
                    ),
                  ),
                if (offlinePaired.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  AppText(
                    '已配对但当前不在线',
                    style: TextStyle(fontSize: 11, letterSpacing: 0.6, color: muted),
                  ),
                  const SizedBox(height: 6),
                  for (final device in offlinePaired)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _LanPeerTile(
                        name: device.name,
                        detail: '不在线',
                        busy: false,
                        enabled: false,
                        onTap: null,
                      ),
                    ),
                ],
              ],
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: GlassTextButton(
                  compact: true,
                  onPressed: () => setState(() {
                    _manualOpen = !_manualOpen;
                    _error = null;
                  }),
                  child: AppText(_manualOpen ? '收起手动连接' : '手动连接'),
                ),
              ),
              if (_manualOpen) ...[
                const SizedBox(height: 10),
                CupertinoTextField(
                  controller: _manual,
                  enabled: !_manualBusy,
                  placeholder: appText(context, '对方的地址，例如 192.168.1.23:47821'),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  padding: const EdgeInsets.all(14),
                  style: TextStyle(fontSize: 14, color: ink),
                ),
                const SizedBox(height: 8),
                GlassTextButton(
                  compact: true,
                  onPressed: _manualBusy ? null : _connect,
                  child: _manualBusy
                      ? const CupertinoActivityIndicator(radius: 7)
                      : const AppText('连接这台设备'),
                ),
              ],
              if (_message != null) ...[
                const SizedBox(height: 12),
                AppText(
                  _message!,
                  style: TextStyle(fontSize: 12, height: 1.5, color: muted),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                AppText(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 18),
            AppText(
              '只会发送书名和阅读位置，不会在后台同步或上传你的书。',
              style: TextStyle(fontSize: 11, height: 1.5, color: muted),
            ),
          ],
        );
      },
    );
  }
}

class _LanPeerTile extends StatelessWidget {
  const _LanPeerTile({
    required this.name,
    required this.detail,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final String name;
  final String detail;
  final bool busy;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return ContentPanel(
      padding: EdgeInsets.zero,
      backgroundColor:
          theme.brightness == Brightness.dark ? ArchiveDesign.darkMilk.withValues(alpha: 0.04) : null,
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            ArchiveIcon(
              CupertinoIcons.device_phone_portrait,
              size: 20,
              color: enabled ? theme.colorScheme.onSurface : muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  AppText(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ],
              ),
            ),
            if (busy)
              const CupertinoActivityIndicator(radius: 8)
            else
              ArchiveIcon(
                CupertinoIcons.chevron_right,
                size: 15,
                color: muted,
              ),
          ],
        ),
      ),
    );
  }
}

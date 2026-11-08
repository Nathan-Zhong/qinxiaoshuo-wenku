import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_language.dart';
import 'app_ui.dart';
import 'archive_design.dart';
import 'archive_icons.dart';
import 'feature_pages.dart';
import 'lan_reading_sync.dart';

/// 设置里的「局域网续读」页面：看本机地址、附近设备、已配对设备，
/// 以及一条手动输入地址的兜底通道。
class LanReadingPage extends StatefulWidget {
  const LanReadingPage({
    super.key,
    required this.sync,
    required this.reduceMotion,
  });

  final LanReadingSync sync;
  final bool reduceMotion;

  @override
  State<LanReadingPage> createState() => _LanReadingPageState();
}

class _LanReadingPageState extends State<LanReadingPage> {
  late final TextEditingController _name;
  final TextEditingController _manual = TextEditingController();
  bool _savingName = false;
  bool _connecting = false;
  bool _manualOpen = false;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.sync.deviceName);
  }

  @override
  void dispose() {
    _name.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    if (_savingName) return;
    setState(() {
      _savingName = true;
      _error = null;
      _message = null;
    });
    String? failure;
    try {
      await widget.sync.renameDevice(_name.text);
    } catch (_) {
      failure = '名称保存失败，请稍后再试';
    }
    if (!mounted) return;
    setState(() {
      _savingName = false;
      _error = failure;
      _message = failure == null ? '名称已更新' : null;
    });
  }

  Future<void> _connect() async {
    final raw = _manual.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请先输入对方的地址，例如 192.168.1.23:47821');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
      _message = null;
    });
    String? failure;
    String? connectedName;
    try {
      final peer = await widget.sync.connectTo(raw);
      connectedName = peer.name;
    } catch (error) {
      failure = switch (error) {
        FormatException(:final String message) => message,
        _ => '连不上这个地址，请确认端口和 Wi-Fi',
      };
    }
    if (!mounted) return;
    setState(() {
      _connecting = false;
      if (connectedName == null) {
        _error = failure ?? '连不上这个地址，请确认端口和 Wi-Fi';
        return;
      }
      _message = '已连接 $connectedName，去阅读器里点「发送」就能续读';
      _manualOpen = false;
      _manual.clear();
    });
  }

  Future<void> _unpair(LanPairedDevice device) async {
    final confirmed = await confirmNovelAction(
      context,
      title: '解除与「${device.name}」的配对？',
      message: '解除后，这台设备再发续读时需要重新核对数字。你的阅读记录不会被删除。',
      confirmLabel: '解除配对',
      reduceMotion: widget.reduceMotion,
    );
    if (!confirmed) return;
    await widget.sync.unpair(device.id);
    if (!mounted) return;
    setState(() {
      _error = null;
      _message = '已解除与「${device.name}」的配对';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ArchiveFeaturePage(
      title: '局域网续读',
      code: 'DEVICES / HANDOFF',
      actions: [
        GlassIconButton(
          icon: CupertinoIcons.refresh,
          label: '刷新附近设备',
          onPressed: widget.sync.refreshPeers,
        ),
      ],
      child: AnimatedBuilder(
        animation: widget.sync,
        builder: (context, _) {
          final sync = widget.sync;
          final theme = Theme.of(context);
          final muted = theme.colorScheme.onSurfaceVariant;
          final peers = sync.peers;
          final onlineIds = peers.map((peer) => peer.id).toSet();
          final paired = sync.pairedDevices;
          return ListView(
            padding: featurePadding(context),
            children: [
              if (!sync.available) ...[
                FeatureError(
                  sync.unavailableReason ?? '这台设备暂时无法打开局域网端口，局域网续读不可用。',
                ),
                const SizedBox(height: 8),
              ],
              const ArchiveSection(
                title: '这台设备',
                code: '01 / THIS DEVICE',
                subtitle: '另一台设备可以输入下面的地址，手动连过来。',
              ),
              const SizedBox(height: 12),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CupertinoTextField(
                      controller: _name,
                      enabled: !_savingName,
                      placeholder: appText(context, '这台设备的名字'),
                      maxLength: 24,
                      padding: const EdgeInsets.all(14),
                      style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppText(
                                '地址',
                                style: TextStyle(fontSize: 11, letterSpacing: 0.6, color: muted),
                              ),
                              const SizedBox(height: 2),
                              AppText(
                                sync.address.isEmpty ? '正在获取本机地址…' : sync.address,
                                style: TextStyle(
                                  fontSize: 14,
                                  letterSpacing: 0.4,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        GlassTextButton(
                          compact: true,
                          onPressed: _savingName ? null : _saveName,
                          child: _savingName
                              ? const CupertinoActivityIndicator(radius: 7)
                              : const AppText('保存名称'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    AppText(
                      sync.discoveryAvailable
                          ? '同一 Wi-Fi 下会自动出现在对方的设备列表里。'
                          : '自动发现不可用（广播可能被系统限制），请让另一台设备手动输入上面的地址。',
                      style: TextStyle(fontSize: 12, height: 1.5, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const ArchiveSection(
                title: '附近的设备',
                code: '02 / NEARBY',
                subtitle: '只显示同一个 Wi-Fi 下打开了局域网续读的设备。',
              ),
              const SizedBox(height: 12),
              if (peers.isEmpty)
                AppText(
                  '暂时没有发现设备。\n请确认两台设备连着同一个 Wi-Fi，并且都打开了局域网续读；也可以让对方把地址告诉你，在下面手动连接。',
                  style: TextStyle(fontSize: 13, height: 1.6, color: muted),
                )
              else
                for (final peer in peers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ContentPanel(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          ArchiveIcon(
                            CupertinoIcons.device_phone_portrait,
                            size: 20,
                            color: theme.colorScheme.onSurface,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AppText(
                                  sync.isPaired(peer.id) ? '${peer.name} · 已配对' : peer.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                AppText(
                                  '${peer.host}:${peer.port}',
                                  style: TextStyle(fontSize: 12, color: muted),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              const SizedBox(height: 24),
              const ArchiveSection(
                title: '已配对设备',
                code: '03 / TRUSTED',
                subtitle: '首次发送时核对过数字的设备会记在这里，以后不用再核对。',
              ),
              const SizedBox(height: 12),
              if (paired.isEmpty)
                AppText(
                  '还没有已配对的设备。第一次发送时，两台设备会显示同一串 4 位数字，核对后即可。',
                  style: TextStyle(fontSize: 13, height: 1.6, color: muted),
                )
              else
                for (final device in paired)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ContentPanel(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          ArchiveIcon(
                            onlineIds.contains(device.id)
                                ? CupertinoIcons.checkmark_circle
                                : CupertinoIcons.device_phone_portrait,
                            size: 20,
                            color: muted,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AppText(
                                  device.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                AppText(
                                  onlineIds.contains(device.id) ? '在线' : '不在线',
                                  style: TextStyle(fontSize: 12, color: muted),
                                ),
                              ],
                            ),
                          ),
                          GlassTextButton(
                            compact: true,
                            onPressed: () => _unpair(device),
                            child: const AppText('解除配对'),
                          ),
                        ],
                      ),
                    ),
                  ),
              const SizedBox(height: 24),
              const ArchiveSection(
                title: '手动连接',
                code: '04 / MANUAL',
                subtitle: '自动发现用不了时，输入对方的地址和端口。',
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: GlassTextButton(
                  compact: true,
                  onPressed: () => setState(() {
                    _manualOpen = !_manualOpen;
                    _error = null;
                    _message = null;
                  }),
                  child: AppText(_manualOpen ? '收起手动连接' : '输入地址'),
                ),
              ),
              if (_manualOpen) ...[
                const SizedBox(height: 10),
                CupertinoTextField(
                  controller: _manual,
                  enabled: !_connecting,
                  placeholder: appText(context, '对方的地址，例如 192.168.1.23:47821'),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  padding: const EdgeInsets.all(14),
                  style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GlassTextButton(
                    compact: true,
                    onPressed: _connecting ? null : _connect,
                    child: _connecting
                        ? const CupertinoActivityIndicator(radius: 7)
                        : const AppText('连接这台设备'),
                  ),
                ),
              ],
              if (_message != null) ...[
                const SizedBox(height: 14),
                AppText(
                  _message!,
                  style: TextStyle(fontSize: 12, height: 1.5, color: muted),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                AppText(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 28),
              AppText(
                '续读只会传书名和阅读位置，不会在后台同步或上传整本书。解除配对只会让旧连接失效，你的书架和阅读记录都会保留。',
                style: TextStyle(fontSize: 11, height: 1.6, color: muted),
              ),
            ],
          );
        },
      ),
    );
  }
}

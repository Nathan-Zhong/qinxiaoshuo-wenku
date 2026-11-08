import 'package:flutter/material.dart';

import '../app_language.dart';
import '../app_ui.dart';
import '../reader_tools.dart' show ReaderValueSlider;
import 'enhancement.dart';

/// Controls for the optional listening gain.
///
/// The controller saves the preference without notifying listeners (it must
/// stay usable from short-lived audio sessions), so this panel keeps its own
/// copy while the user drags, then reports every committed value through
/// [onChanged].
class ListeningEnhancementSettings extends StatefulWidget {
  const ListeningEnhancementSettings({
    super.key,
    required this.enhancement,
    required this.onChanged,
  });

  final ListeningEnhancement enhancement;
  final ValueChanged<ListeningEnhancementPreference> onChanged;

  @override
  State<ListeningEnhancementSettings> createState() =>
      _ListeningEnhancementSettingsState();
}

class _ListeningEnhancementSettingsState
    extends State<ListeningEnhancementSettings> {
  late ListeningEnhancementPreference _value;

  @override
  void initState() {
    super.initState();
    _value = widget.enhancement.preference;
  }

  @override
  void didUpdateWidget(covariant ListeningEnhancementSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.enhancement, widget.enhancement)) {
      _value = widget.enhancement.preference;
    }
  }

  void _apply(ListeningEnhancementPreference value) {
    if (value == _value) {
      return;
    }
    setState(() {
      _value = value;
    });
    try {
      widget.onChanged(value);
    } catch (_) {
      // The switch and slider are local to this panel. A controller that
      // cannot persist the optional setting must not make them appear broken.
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppText(
          '音量增强',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(child: AppText('播放时提升人声音量')),
            AppControls.toggle(
              context,
              key: const ValueKey('listening-enhancement-enabled'),
              value: _value.enabled,
              onChanged: (enabled) =>
                  _apply(_value.copyWith(enabled: enabled)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ReaderValueSlider(
          sliderKey: const ValueKey('listening-enhancement-gain'),
          label: '增强幅度',
          value: _value.gain,
          min: ListeningEnhancementPreference.minGain,
          max: ListeningEnhancementPreference.maxGain,
          divisions: 30,
          format: (value) => value <= 0
              ? '不增强'
              : '+${value.toStringAsFixed(1)} dB',
          onCommitted: _value.enabled
              ? (value) => _apply(_value.copyWith(gain: value))
              : null,
        ),
        const SizedBox(height: 8),
        Text(
          '数值越高，人声越响；部分平台可能不支持音量增强。',
          style: TextStyle(fontSize: 12, height: 1.5, color: secondary),
        ),
      ],
    );
  }
}

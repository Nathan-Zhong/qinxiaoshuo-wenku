import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'reading_widget_reference.dart';
import 'reading_widget_skin.dart';
import 'reading_widget_snapshot.dart';

/// Picks one desktop skin while previewing it at the current widget size.
///
/// The caller owns the bytes: [previewBuilder] returns the same card the
/// settings page already shows, so a new skin never needs a second renderer.
class ReadingWidgetSkinPicker extends StatelessWidget {
  const ReadingWidgetSkinPicker({
    super.key,
    required this.previewBuilder,
    required this.value,
    required this.size,
    required this.snapshot,
    this.onChanged,
  });

  /// Paints [skin] at [size] for the given snapshot.
  final Widget Function(ReadingWidgetSkin skin) previewBuilder;

  final ReadingWidgetSkin value;
  final ReadingDesktopSize size;
  final ReadingWidgetSnapshot snapshot;

  /// Null while a save is in flight; the picker then stays readable but inert.
  final ValueChanged<ReadingWidgetSkin>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 640 ? 3 : 2;
        const gap = 12.0;
        final width = constraints.maxWidth.isFinite
            ? (constraints.maxWidth - gap * (columns - 1)) / columns
            : 240.0;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final skin in ReadingWidgetSkin.values)
              SizedBox(
                width: width,
                child: _ReadingWidgetSkinTile(
                  skin: skin,
                  selected: skin == value,
                  enabled: enabled,
                  preview: previewBuilder(skin),
                  onTap: !enabled || skin == value
                      ? null
                      : () => onChanged!(skin),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ReadingWidgetSkinTile extends StatelessWidget {
  const _ReadingWidgetSkinTile({
    required this.skin,
    required this.selected,
    required this.enabled,
    required this.preview,
    required this.onTap,
  });

  final ReadingWidgetSkin skin;
  final bool selected;
  final bool enabled;
  final Widget preview;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: '${skin.label}皮肤，${skin.description}',
      child: Opacity(
        opacity: enabled ? 1 : .55,
        child: Material(
          color: selected
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: selected
                  ? scheme.onSurface.withValues(alpha: .72)
                  : scheme.outlineVariant.withValues(alpha: .55),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            child: AnimatedOpacity(
              duration: reduced
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              opacity: selected ? 1 : .92,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: AspectRatio(
                        aspectRatio: readingDesktopCardAspect,
                        child: ColoredBox(
                          color: skin.backgroundFor(Brightness.light),
                          child: preview,
                        ),
                      ),
                    ),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        Expanded(
                          child: AppText(
                            skin.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          size: 15,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant.withValues(alpha: .45),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    AppText(
                      skin.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.25,
                        color: scheme.onSurfaceVariant.withValues(alpha: .8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

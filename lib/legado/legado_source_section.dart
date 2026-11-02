import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_ui.dart';
import '../catalog.dart';
import 'legado_book_registry.dart';

/// The 来源 section shown on the detail page of an engine book that
/// exists on more than one source (PLAN item 7, display half): the
/// current source is marked, every other source is a tappable chip in
/// the same style as the page's tag chips, and switching reopens the
/// detail page on that source so its info and directory refresh.
/// Renders nothing for single-source books and non-engine books.
class LegadoSourceSection extends StatelessWidget {
  const LegadoSourceSection({
    super.key,
    required this.novel,
    required this.registry,
    required this.onSwitch,
  });

  final Novel novel;
  final LegadoBookRegistry registry;
  final void Function(LegadoBookRecord record) onSwitch;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: registry,
    builder: (context, _) {
      final group = registry.groupOf(novel.id);
      if (group.length < 2) return const SizedBox.shrink();
      return Column(
        key: const ValueKey('detail-legado-sources'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionHeader(context, '来源', ''),
          const SizedBox(height: 13),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final record in group)
                _chip(context, record, current: record.id == novel.id),
            ],
          ),
          const SizedBox(height: 24),
        ],
      );
    },
  );

  Widget _chip(
    BuildContext context,
    LegadoBookRecord record, {
    required bool current,
  }) {
    final label = record.originName.isNotEmpty
        ? record.originName
        : record.origin;
    final chip = DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .055),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (current) ...[
              Icon(
                CupertinoIcons.checkmark,
                size: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
            ],
            AppText(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
    if (current) {
      return Semantics(selected: true, label: '当前来源 $label', child: chip);
    }
    return GestureDetector(
      key: ValueKey('detail-source-${record.id}'),
      onTap: () => onSwitch(record),
      child: Semantics(button: true, label: '切换来源到 $label', child: chip),
    );
  }
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';

/// The 感想 (bookmark note) editor, built exactly like the app's existing
/// name-input sheet (`_CategoryNameSheet` in book_categories.dart): a jelly
/// sheet with an [ArchiveSection] header, a [CupertinoTextField] and glass
/// buttons. Returns the entered text when the reader taps 保存感想， or
/// null when the sheet is dismissed / 跳过 is tapped (the 定版 A skip
/// path: a bookmark never requires a note).
Future<String?> showBookmarkNoteSheet(
  BuildContext context, {
  String initial = '',
  bool editing = false,
  bool reduceMotion = false,
}) => showJellySheet<String>(
  context: context,
  reduceMotion: reduceMotion,
  heightFactor: .58,
  builder: (sheet) => _BookmarkNoteSheet(
    sheet: sheet,
    initial: initial,
    editing: editing,
  ),
);

class _BookmarkNoteSheet extends StatefulWidget {
  const _BookmarkNoteSheet({
    required this.sheet,
    required this.initial,
    required this.editing,
  });
  final BuildContext sheet;
  final String initial;
  final bool editing;

  @override
  State<_BookmarkNoteSheet> createState() => _BookmarkNoteSheetState();
}

class _BookmarkNoteSheetState extends State<_BookmarkNoteSheet> {
  late final text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ArchiveSection(
          title: widget.editing ? '修改感想' : '写下感想',
          code: 'PERSONAL / NOTE',
        ),
        const SizedBox(height: 20),
        CupertinoTextField(
          key: const ValueKey('bookmark-note-field'),
          controller: text,
          placeholder: appText(context, '这一段让你想到了什么？'),
          maxLines: 5,
          minLines: 3,
          maxLength: 12000,
          padding: const EdgeInsets.all(16),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            GlassTextButton(
              key: const ValueKey('bookmark-note-skip'),
              onPressed: () => Navigator.pop(widget.sheet),
              child: AppText(widget.editing ? '取消' : '跳过'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GlassPillButton(
                key: const ValueKey('bookmark-note-save'),
                icon: CupertinoIcons.checkmark,
                label: '保存感想',
                onPressed: () => Navigator.pop(widget.sheet, text.text),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

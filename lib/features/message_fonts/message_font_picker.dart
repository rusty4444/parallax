import 'package:flutter/material.dart';

import 'message_fonts.dart';

/// The picker's answer: [id] is null for the default font. A dismissed sheet
/// returns no selection at all.
typedef MessageFontSelection = ({String? id});

/// Bottom sheet listing "Default" and every message font, each name drawn in
/// its own face, with [current] ticked.
Future<MessageFontSelection?> showMessageFontPicker(
  BuildContext context, {
  String? current,
}) => showModalBottomSheet<MessageFontSelection>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => MessageFontSheet(current: messageFontById(current)?.id),
);

class MessageFontSheet extends StatelessWidget {
  const MessageFontSheet({super.key, this.current});

  /// The chosen font ID, or null for the default font.
  final String? current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Widget option(MessageFont? font) {
      final selected = font?.id == current;
      return ListTile(
        key: ValueKey('message-font-${font?.id ?? 'default'}'),
        selected: selected,
        title: Text(
          font?.label ?? 'Default',
          style: TextStyle(
            fontFamily: font?.family,
            fontSize: 18,
            color: selected ? colors.primary : colors.onSurface,
          ),
        ),
        trailing: selected
            ? Icon(Icons.check_rounded, color: colors.primary)
            : null,
        onTap: () =>
            Navigator.pop<MessageFontSelection>(context, (id: font?.id)),
      );
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text('Message font', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Your messages are sent in this font. People using Parallax '
                'see it; other apps show the default.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            option(null),
            for (final font in messageFonts) option(font),
          ],
        ),
      ),
    );
  }
}

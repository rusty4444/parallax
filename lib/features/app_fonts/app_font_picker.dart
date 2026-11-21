import 'package:flutter/material.dart';

import 'app_fonts.dart';

/// Bottom sheet listing every app font, each drawn in its own face, with
/// [current] ticked. Returns the chosen font's ID, or null when dismissed.
Future<String?> showAppFontPicker(
  BuildContext context, {
  required String current,
}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => AppFontSheet(current: current),
);

class AppFontSheet extends StatelessWidget {
  const AppFontSheet({super.key, required this.current});

  /// The ID of the font in use.
  final String current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Widget option(AppFont font) {
      final selected = font.id == current;
      final face = appFontPreviewStyle(font);
      return ListTile(
        key: ValueKey('app-font-${font.id}'),
        selected: selected,
        title: Text(
          font.label,
          style: face.copyWith(
            fontSize: 18,
            color: selected ? colors.primary : colors.onSurface,
          ),
        ),
        subtitle: Text(
          font.description,
          style: face.copyWith(fontSize: 13, color: colors.onSurfaceVariant),
        ),
        trailing: selected
            ? Icon(Icons.check_rounded, color: colors.primary)
            : null,
        onTap: () => Navigator.pop<String>(context, font.id),
      );
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text('Font', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Used on every screen of Parallax. Messages sent in a '
                'message font keep it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            for (final font in appFonts) option(font),
          ],
        ),
      ),
    );
  }
}

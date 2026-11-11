import 'package:flutter/material.dart';

import '../../app_theme.dart';

const maxRemovalReasonLength = 500;

/// Element X "Remove message?" confirmation with an optional reason.
/// Resolves to the trimmed reason ('' for none), or null when cancelled.
Future<String?> confirmMessageRemoval(
  BuildContext context, {
  required AppPalette palette,
}) => showDialog<String>(
  context: context,
  builder: (_) => _RemoveMessageDialog(palette: palette),
);

class _RemoveMessageDialog extends StatefulWidget {
  const _RemoveMessageDialog({required this.palette});
  final AppPalette palette;

  @override
  State<_RemoveMessageDialog> createState() => _RemoveMessageDialogState();
}

class _RemoveMessageDialogState extends State<_RemoveMessageDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('Remove message?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This removes the message for everyone in the room.',
            style: TextStyle(color: p.muted),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('removal-reason'),
            controller: _reason,
            maxLength: maxRemovalReasonLength,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Reason (optional)',
              hintText: 'Enter reason…',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(context, _reason.text.trim()),
          child: const Text('Remove'),
        ),
      ],
    );
  }
}

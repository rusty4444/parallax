import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../chat_backend.dart';
import '../../message_copy_targets.dart';
import 'permalinks.dart';

/// Opens external links. Replaceable in tests.
@visibleForTesting
Future<bool> Function(Uri uri) richTimelineLaunchUrl = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Opens a link tapped in a message. Unsafe schemes are refused; a link
/// whose visible text names a different site asks for confirmation first.
Future<void> openTimelineLink(
  BuildContext context,
  Uri uri, {
  String text = '',
}) async {
  final safe = safeLinkUri(uri.toString());
  if (safe == null) return;
  if (linkTextMisleads(text, safe)) {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Double-check this link'),
        content: Text(
          'The link ${text.trim()} is taking you to another site '
          '${safe.toString()}\n\nAre you sure you want to continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true || !context.mounted) return;
  }
  var opened = false;
  try {
    opened = await richTimelineLaunchUrl(safe);
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Couldn’t open this link.')));
  }
}

/// Whether "Copy text" applies to [entry].
bool canCopyText(ChatEntry entry) =>
    !entry.redacted &&
    entry.body.trim().isNotEmpty &&
    const {
      EntryKind.text,
      EntryKind.emote,
      EntryKind.notice,
    }.contains(entry.kind);

/// Plain text copied by "Copy text" (emotes include the sender, as shown).
String copyableText(ChatEntry entry) => entry.kind == EntryKind.emote
    ? '* ${entry.senderLabel} ${entry.body}'
    : entry.body;

/// Whether the entry has a server event ID (not a local echo).
bool hasServerEventId(ChatEntry entry) => entry.id.startsWith('\$');

Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  required String confirmation,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(confirmation)));
}

String? _phoneCallTarget(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^\d+]'), '');
  final number = cleaned.startsWith('+')
      ? '+${cleaned.substring(1).replaceAll('+', '')}'
      : cleaned.replaceAll('+', '');
  if (number.replaceAll('+', '').length < 3) return null;
  return 'tel:$number';
}

/// Popup for a tappable code, phone number or IP address.
Future<void> showCopyTargetActions(
  BuildContext context,
  MessageCopyTarget target,
) async {
  final action = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(switch (target.kind) {
        MessageCopyKind.oneTimeCode => 'Code',
        MessageCopyKind.phoneNumber => 'Phone number',
        MessageCopyKind.ipAddress => 'IP address',
      }),
      content: Text(target.value),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'copy'),
          child: const Text('Copy'),
        ),
        if (target.kind == MessageCopyKind.phoneNumber)
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'call'),
            child: const Text('Call'),
          ),
      ],
    ),
  );
  if (!context.mounted || action == null) return;
  if (action == 'copy') {
    await copyToClipboard(
      context,
      target.value,
      confirmation: target.confirmation,
    );
    return;
  }
  final tel = _phoneCallTarget(target.value);
  if (tel == null) return;
  var opened = false;
  try {
    opened = await richTimelineLaunchUrl(Uri.parse(tel));
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Couldn\u2019t start the call.')),
    );
  }
}

/// The JSON shown by "View source": identifiers plus the decrypted display
/// content (edits applied).
Map<String, Object?> viewSourceJson(ChatEntry entry, String roomId) => {
  'room_id': roomId,
  'event_id': entry.id,
  'sender': entry.sender,
  'type': entry.eventType,
  'origin_server_ts': entry.time.millisecondsSinceEpoch,
  'state_key': ?entry.stateKey,
  'content': entry.content,
};

String prettySource(ChatEntry entry, String roomId) {
  try {
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(viewSourceJson(entry, roomId));
  } catch (_) {
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(viewSourceJson(entry, roomId)..['content'] = '<unavailable>');
  }
}

Future<void> showViewSource(
  BuildContext context, {
  required ChatEntry entry,
  required String roomId,
  required bool encrypted,
}) {
  final source = prettySource(entry, roomId);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('View source'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (encrypted)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Decrypted content shown. Edits are applied.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    source,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: ['RobotoMono', 'Menlo', 'Courier'],
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: source));
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

import '../../chat_backend.dart';

const _previewLimit = 200;
final _whitespace = RegExp(r'\s+');

/// One-line plain-text preview of a message (pinned banner, forward lists).
String messagePreviewText(ChatEntry entry) {
  final body = entry.body.replaceAll(_whitespace, ' ').trim();
  String withBody(String label) =>
      body.isEmpty || body == label ? label : '$label: $body';
  final text = switch (entry.kind) {
    EntryKind.redacted => 'Message removed',
    EntryKind.undecryptable => 'Unable to decrypt this message',
    EntryKind.image => 'Image',
    EntryKind.video => 'Video',
    EntryKind.audio => withBody('Audio'),
    EntryKind.voice => 'Voice message',
    EntryKind.file => withBody('File'),
    EntryKind.sticker => 'Sticker',
    EntryKind.location => 'Location',
    EntryKind.poll => withBody('Poll'),
    EntryKind.emote => '* ${entry.senderLabel} $body',
    _ => body,
  };
  final runes = text.runes;
  return runes.length > _previewLimit
      ? '${String.fromCharCodes(runes.take(_previewLimit))}…'
      : text;
}

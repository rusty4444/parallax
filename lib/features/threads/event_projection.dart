import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../message_text.dart';
import '../../timeline_kinds.dart';

/// Projects an SDK event that is not part of the active timeline (thread
/// roots, latest thread replies) into a [ChatEntry].
///
/// Mirrors the backend's timeline projection without timeline-only data such
/// as reactions or edits. Reads cached membership only and never triggers
/// member fetches.
ChatEntry projectStandaloneEvent(matrix.Event event) {
  final client = event.room.client;
  final redacted = event.redacted;
  final content = redacted
      ? const <String, Object?>{}
      : Map<String, Object?>.unmodifiable(event.content);
  final msgtype = event.type == matrix.EventTypes.Message
      ? event.messageType
      : null;
  final kind = entryKindFor(
    type: event.type,
    msgtype: msgtype,
    content: content,
    redacted: redacted,
  );
  final replyToId = event.inReplyToEventId(includingFallback: false);
  final member = event.room.getState(
    matrix.EventTypes.RoomMember,
    event.senderId,
  );
  final memberName = member?.content['displayname'];
  final memberAvatar = member?.content['avatar_url'];
  final format = content['format'];
  final formatted = content['formatted_body'];
  final thread = (event.unsigned?['m.relations'] as Map?)?['m.thread'] as Map?;
  final threadLatest = thread?['latest_event'] as Map?;
  final threadLatestContent = threadLatest?['content'] as Map?;
  final rawBody = content['body'];
  final body = redacted
      ? 'Message removed'
      : event.type == matrix.EventTypes.Encrypted
      ? '🔒 Unable to decrypt this message'
      : kind == EntryKind.state || kind == EntryKind.call
      ? _fallback(event)
      : visibleMessageBody(
          rawBody is String ? rawBody : '',
          isReply: replyToId != null,
        );
  return ChatEntry(
    id: event.eventId,
    sender: event.senderId,
    body: body,
    time: event.originServerTs,
    mine: event.senderId == client.userID,
    isImage:
        !redacted &&
        (msgtype == matrix.MessageTypes.Image ||
            event.type == matrix.EventTypes.Sticker),
    isAttachment:
        !redacted &&
        {
          matrix.MessageTypes.File,
          matrix.MessageTypes.Audio,
          matrix.MessageTypes.Video,
        }.contains(msgtype),
    replyToId: replyToId,
    redacted: redacted,
    kind: kind,
    eventType: event.type,
    msgtype: msgtype,
    formattedBody: format == 'org.matrix.custom.html' && formatted is String
        ? formatted
        : null,
    senderName: memberName is String ? memberName : null,
    senderAvatar: memberAvatar is String ? Uri.tryParse(memberAvatar) : null,
    content: content,
    stateKey: event.stateKey,
    threadReplyCount: (thread?['count'] as num?)?.toInt() ?? 0,
    threadLatestBody: threadLatestContent?['body'] is String
        ? threadLatestContent!['body'] as String
        : null,
    pinned: event.room.pinnedEventIds.contains(event.eventId),
  );
}

String _fallback(matrix.Event event) {
  try {
    return event.calcLocalizedBodyFallback(
      const matrix.MatrixDefaultLocalizations(),
      hideReply: true,
    );
  } catch (_) {
    return event.type;
  }
}

/// Short one-line preview of an entry for lists and chips.
String entryPreview(ChatEntry entry) {
  if (entry.redacted) return 'Message removed';
  final body = entry.body.trim().replaceAll(RegExp(r'\s+'), ' ');
  return switch (entry.kind) {
    EntryKind.image => body.isEmpty ? 'Image' : '🖼 $body',
    EntryKind.video => body.isEmpty ? 'Video' : '🎬 $body',
    EntryKind.audio => body.isEmpty ? 'Audio' : '🎵 $body',
    EntryKind.voice => 'Voice message',
    EntryKind.file => body.isEmpty ? 'File' : '📎 $body',
    EntryKind.sticker => 'Sticker',
    EntryKind.location => 'Location',
    EntryKind.poll => body.isEmpty ? 'Poll' : '📊 $body',
    EntryKind.emote => '* ${entry.senderLabel} $body',
    _ => body.isEmpty ? 'Message' : body,
  };
}

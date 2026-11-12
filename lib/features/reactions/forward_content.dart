import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';

/// Rooms per forward. Element X v26.11 allows 5; Parallax allows 10.
const maxForwardRooms = 10;

/// Element X MessageMultiSelect: up to 10 messages per forward.
const maxForwardMessages = 10;

const _forwardableMsgtypes = {
  'm.text',
  'm.notice',
  'm.emote',
  'm.image',
  'm.video',
  'm.audio',
  'm.file',
  'm.location',
};
const _mediaMsgtypes = {'m.image', 'm.video', 'm.audio', 'm.file'};
const _maxForwardJsonBytes = 60 * 1024;
final _mxReply = RegExp(r'<mx-reply>[\s\S]*?</mx-reply>', caseSensitive: false);

/// Event type and content to re-send when forwarding one message.
@immutable
class ForwardPayload {
  const ForwardPayload(this.type, this.content);
  final String type;
  final Map<String, Object?> content;
}

/// Builds the content to forward, or null when [entry] cannot be forwarded
/// (local echo, redacted, state, poll, call, undecryptable …), as in Element X.
///
/// Media is forwarded by re-sending the same content, including encrypted
/// file info, so nothing is downloaded or re-uploaded. Relations (reply,
/// thread, edit) and mentions are dropped so the copy stands alone and does
/// not ping anyone in the target room.
ForwardPayload? forwardPayloadFor(ChatEntry entry) {
  if (entry.redacted || !entry.id.startsWith(r'$')) return null;
  final type = entry.eventType;
  if (type != 'm.room.message' && type != 'm.sticker') return null;
  final source = entry.content;
  final msgtype = source['msgtype'];
  if (type == 'm.room.message' &&
      (msgtype is! String || !_forwardableMsgtypes.contains(msgtype))) {
    return null;
  }
  if (source['body'] is! String) return null;
  final hasMedia = source['url'] is String || source['file'] is Map;
  if ((type == 'm.sticker' || _mediaMsgtypes.contains(msgtype)) && !hasMedia) {
    return null;
  }
  if (msgtype == 'm.location' && source['geo_uri'] is! String) return null;

  final Map<String, Object?> content;
  try {
    final encoded = jsonEncode(source);
    if (utf8.encode(encoded).length > _maxForwardJsonBytes) return null;
    content = (jsonDecode(encoded) as Map).cast<String, Object?>();
  } catch (_) {
    return null;
  }
  content
    ..remove('m.relates_to')
    ..remove('m.new_content')
    ..remove('m.mentions');
  if (entry.replyToId != null && type == 'm.room.message') {
    // The visible body already has the plain-text reply fallback removed.
    content['body'] = entry.body;
    final formatted = content['formatted_body'];
    if (formatted is String) {
      final stripped = formatted.replaceAll(_mxReply, '').trim();
      if (stripped.isEmpty) {
        content
          ..remove('formatted_body')
          ..remove('format');
      } else {
        content['formatted_body'] = stripped;
      }
    }
  }
  return ForwardPayload(type, Map.unmodifiable(content));
}

bool canForward(ChatEntry entry) => forwardPayloadFor(entry) != null;

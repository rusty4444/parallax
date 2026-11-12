// What a push notification says about one Matrix event (Element X:
// DefaultNotifiableEventResolver.descriptionFromMessageContent).
//
// Pure functions over decrypted event JSON: no SDK, plugin or I/O, so the
// main isolate, background isolates and tests share exactly the same wording.
import 'package:flutter/foundation.dart';

/// Longest message text kept for a notification line.
const maxNotificationTextLength = 600;

/// Longest sender or room name kept for a notification.
const maxNotificationNameLength = 80;

/// Largest declared media size we will download for a preview. Encrypted
/// media cannot be thumbnailed by the server, so this bounds the download.
const maxNotificationMediaBytes = 3 * 1024 * 1024;

/// How the notification for an event is presented.
enum NotifiableEventKind {
  /// A timeline message, shown in the room's conversation notification.
  message,

  /// An invitation to a room or chat.
  invite,

  /// A call (ringing in DMs).
  call,
}

/// Media that may be previewed (image, sticker or video thumbnail).
@immutable
class NotificationMediaRef {
  const NotificationMediaRef({
    this.mxc,
    this.encryptedFile,
    this.mimeType,
    this.declaredSize,
    required this.thumbnail,
  }) : assert((mxc == null) != (encryptedFile == null));

  /// Plaintext media: the server can produce a small thumbnail.
  final Uri? mxc;

  /// Encrypted media (`EncryptedFile` JSON: url, key, iv, hashes).
  final Map<String, Object?>? encryptedFile;
  final String? mimeType;
  final int? declaredSize;

  /// True when this is the event's thumbnail rather than the original.
  final bool thumbnail;

  bool get encrypted => encryptedFile != null;

  /// The mxc URI that is downloaded (encrypted files carry it inside).
  Uri? get source {
    if (mxc != null) return mxc;
    final url = encryptedFile?['url'];
    return url is String ? validMxc(url) : null;
  }
}

/// The text (and optional media) describing an event in a notification.
@immutable
class NotificationEventText {
  const NotificationEventText(
    this.text, {
    this.kind = NotifiableEventKind.message,
    this.media,
    this.ringing = false,
  });
  final String text;
  final NotifiableEventKind kind;
  final NotificationMediaRef? media;

  /// A call that is still ringing (shown as a call-category alert).
  final bool ringing;
}

/// Event types that describe calls (legacy VoIP, MSC4075 ring notifications
/// and their unstable prefixes).
const callNotificationEventTypes = {
  'm.call.invite',
  'm.rtc.notification',
  'org.matrix.msc4075.rtc.notification',
  'm.call.notify',
  'org.matrix.msc4075.call.notify',
};

const _pollStartTypes = {'m.poll.start', 'org.matrix.msc3381.poll.start'};
const _pollEndTypes = {'m.poll.end', 'org.matrix.msc3381.poll.end'};
const _beaconInfoTypes = {'m.beacon_info', 'org.matrix.msc3672.beacon_info'};

/// Default ring lifetime when a call event does not carry one.
const defaultRingLifetime = Duration(seconds: 90);

/// Describes a decrypted event for a notification, or returns null when the
/// event cannot be described (still encrypted, unknown type …) so the caller
/// falls back to the generic notification.
NotificationEventText? describeNotificationEvent({
  required String type,
  required Map<String, Object?> content,
  required String senderName,
  String? stateKey,
  String? myUserId,
  String? roomName,
  bool isDirect = false,
  bool redacted = false,
  DateTime? originServerTs,
  DateTime? now,
}) {
  final sender = sanitiseNotificationName(senderName) ?? 'Someone';
  if (type == 'm.room.member') {
    if (content['membership'] != 'invite' ||
        myUserId == null ||
        stateKey != myUserId) {
      return null;
    }
    final room = sanitiseNotificationName(roomName);
    final direct = isDirect || content['is_direct'] == true;
    return NotificationEventText(
      direct || room == null
          ? '$sender invited you to chat'
          : '$sender invited you to $room',
      kind: NotifiableEventKind.invite,
    );
  }
  if (redacted) return const NotificationEventText('Message removed');
  if (type == 'm.room.encrypted') return null;
  if (callNotificationEventTypes.contains(type)) {
    return _describeCall(type, content, originServerTs, now ?? DateTime.now());
  }
  if (type == 'm.sticker') {
    return NotificationEventText(
      'Sticker',
      media: notificationMediaFor(type: type, content: content),
    );
  }
  if (_pollStartTypes.contains(type)) {
    final question = _pollQuestion(content, type);
    return NotificationEventText(question == null ? 'Poll' : 'Poll: $question');
  }
  if (_pollEndTypes.contains(type)) {
    return const NotificationEventText('Poll ended');
  }
  if (_beaconInfoTypes.contains(type)) {
    return content['live'] == true
        ? const NotificationEventText('Started sharing their live location')
        : null;
  }
  if (type == 'm.reaction') {
    final relation = content['m.relates_to'];
    final key = relation is Map ? relation['key'] : null;
    if (key is! String || key.trim().isEmpty) return null;
    return NotificationEventText('Reacted with ${_clip(_singleLine(key), 32)}');
  }
  if (type != 'm.room.message') return null;

  final effective = _editedContent(content);
  final msgtype = effective['msgtype'];
  final body = _string(effective['body']);
  final caption = _caption(effective);
  switch (msgtype) {
    case 'm.text':
    case 'm.notice':
      final text = sanitiseNotificationText(
        _stripReplyFallback(body ?? '', content),
      );
      return text == null ? null : NotificationEventText(text);
    case 'm.emote':
      final text = sanitiseNotificationText(body ?? '');
      return NotificationEventText('* $sender ${text ?? ''}'.trimRight());
    case 'm.image':
      return NotificationEventText(
        caption ?? 'Image',
        media: notificationMediaFor(type: type, content: effective),
      );
    case 'm.video':
      return NotificationEventText(
        caption ?? 'Video',
        media: notificationMediaFor(type: type, content: effective),
      );
    case 'm.audio':
      final voice =
          effective.containsKey('org.matrix.msc3245.voice') ||
          effective.containsKey('m.voice');
      return NotificationEventText(
        voice ? 'Voice message' : (caption ?? 'Audio'),
      );
    case 'm.file':
      final name = sanitiseNotificationName(
        _string(effective['filename']) ?? body ?? '',
      );
      return NotificationEventText('📎 ${name ?? 'File'}');
    case 'm.location':
      return const NotificationEventText('📍 Location');
    case 'm.key.verification.request':
      return const NotificationEventText('Verification request');
    default:
      final text = sanitiseNotificationText(body ?? '');
      return text == null ? null : NotificationEventText(text);
  }
}

NotificationEventText _describeCall(
  String type,
  Map<String, Object?> content,
  DateTime? sentAt,
  DateTime now,
) {
  final ring = switch (type) {
    'm.call.invite' => true,
    'm.rtc.notification' || 'org.matrix.msc4075.rtc.notification' =>
      content['notification_type'] == 'ring',
    _ => content['notify_type'] == 'ring',
  };
  if (!ring) return const NotificationEventText('Call started');
  final lifetimeMs = content['lifetime'];
  final lifetime = lifetimeMs is int && lifetimeMs > 0 && lifetimeMs < 600000
      ? Duration(milliseconds: lifetimeMs)
      : defaultRingLifetime;
  final senderTs = content['sender_ts'];
  final started = senderTs is int
      ? DateTime.fromMillisecondsSinceEpoch(senderTs)
      : sentAt;
  final expired = started != null && now.difference(started) > lifetime;
  return expired
      ? const NotificationEventText(
          'Missed call',
          kind: NotifiableEventKind.call,
        )
      : const NotificationEventText(
          'Incoming call',
          kind: NotifiableEventKind.call,
          ringing: true,
        );
}

/// Picks the media to preview for image, sticker and video events: the
/// thumbnail when there is one, otherwise the (bounded) original image.
/// Videos are only previewed through their thumbnail.
NotificationMediaRef? notificationMediaFor({
  required String type,
  required Map<String, Object?> content,
}) {
  final msgtype = content['msgtype'];
  final image = type == 'm.sticker' || msgtype == 'm.image';
  final video = type == 'm.room.message' && msgtype == 'm.video';
  if (!image && !video) return null;
  final info = content['info'] is Map
      ? Map<String, Object?>.from(content['info'] as Map)
      : const <String, Object?>{};
  final thumbnailInfo = info['thumbnail_info'] is Map
      ? Map<String, Object?>.from(info['thumbnail_info'] as Map)
      : const <String, Object?>{};

  NotificationMediaRef? build({
    required Object? encrypted,
    required Object? plain,
    required Map<String, Object?> info,
    required bool thumbnail,
  }) {
    final mime = _string(info['mimetype'])?.toLowerCase();
    if (mime != null && !_previewableMime(mime)) return null;
    final size = info['size'];
    final declared = size is int ? size : null;
    if (encrypted is Map) {
      final file = Map<String, Object?>.from(encrypted);
      final url = file['url'];
      if (url is! String || validMxc(url) == null) return null;
      if (declared != null && declared > maxNotificationMediaBytes) return null;
      return NotificationMediaRef(
        encryptedFile: file,
        mimeType: mime,
        declaredSize: declared,
        thumbnail: thumbnail,
      );
    }
    if (plain is String) {
      final mxc = validMxc(plain);
      if (mxc == null) return null;
      // The server scales plaintext images, so the original size is no bound.
      return NotificationMediaRef(
        mxc: mxc,
        mimeType: mime,
        declaredSize: declared,
        thumbnail: thumbnail,
      );
    }
    return null;
  }

  final fromThumbnail = build(
    encrypted: info['thumbnail_file'],
    plain: info['thumbnail_url'],
    info: thumbnailInfo,
    thumbnail: true,
  );
  if (fromThumbnail != null || video) return fromThumbnail;
  return build(
    encrypted: content['file'],
    plain: content['url'],
    info: info,
    thumbnail: false,
  );
}

bool _previewableMime(String mime) => const {
  'image/jpeg',
  'image/jpg',
  'image/png',
  'image/webp',
  'image/gif',
}.contains(mime.split(';').first.trim());

/// A strictly validated `mxc://server/media` URI, or null.
Uri? validMxc(String value) {
  // Check the raw text: Uri.parse would normalise `..` segments away.
  if (value.length > 512 ||
      !RegExp(r'^mxc://[^/?#@\s]+/[A-Za-z0-9_-]{1,255}$').hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'mxc' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final segments = uri.pathSegments;
  if (segments.length != 1 ||
      !RegExp(r'^[A-Za-z0-9_-]{1,255}$').hasMatch(segments.single)) {
    return null;
  }
  return uri;
}

Map<String, Object?> _editedContent(Map<String, Object?> content) {
  final relation = content['m.relates_to'];
  final replacement = content['m.new_content'];
  if (relation is Map &&
      relation['rel_type'] == 'm.replace' &&
      replacement is Map) {
    return Map<String, Object?>.from(replacement);
  }
  return content;
}

String? _caption(Map<String, Object?> content) {
  final body = _string(content['body']);
  final filename = _string(content['filename']);
  if (body == null || filename == null || body == filename) return null;
  return sanitiseNotificationText(body);
}

String? _pollQuestion(Map<String, Object?> content, String type) {
  final start = content[type] ?? content['m.poll.start'];
  if (start is! Map) return null;
  final question = start['question'];
  if (question is! Map) return null;
  for (final key in ['m.text', 'org.matrix.msc1767.text', 'body']) {
    final value = question[key];
    if (value is String) return sanitiseNotificationName(value);
    if (value is List) {
      for (final part in value) {
        if (part is Map && part['body'] is String) {
          return sanitiseNotificationName(part['body'] as String);
        }
      }
    }
  }
  return null;
}

/// Drops the Matrix plain-text reply fallback (`> <@user> …` lines) when the
/// event really is a reply.
String _stripReplyFallback(String body, Map<String, Object?> content) {
  final relation = content['m.relates_to'];
  if (relation is! Map || relation['m.in_reply_to'] is! Map) return body;
  if (!body.startsWith('> ')) return body;
  final lines = body.split('\n');
  var index = 0;
  while (index < lines.length && lines[index].startsWith('>')) {
    index++;
  }
  if (index < lines.length && lines[index].trim().isEmpty) index++;
  return lines.skip(index).join('\n');
}

String? _string(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

final _controlCharacters = RegExp(
  '[\u0000-\u0008\u000B-\u001F\u007F\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);

/// Removes control and bidi-override characters, collapses blank lines and
/// bounds the length. Returns null for empty text.
String? sanitiseNotificationText(
  String value, {
  int max = maxNotificationTextLength,
}) {
  final cleaned = value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(_controlCharacters, '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  if (cleaned.isEmpty) return null;
  return _clip(cleaned, max);
}

/// Single-line, bounded name (sender, room, file).
String? sanitiseNotificationName(String? value) {
  if (value == null) return null;
  final cleaned = _singleLine(value.replaceAll(_controlCharacters, '')).trim();
  if (cleaned.isEmpty) return null;
  return _clip(cleaned, maxNotificationNameLength);
}

String _singleLine(String value) => value.replaceAll(RegExp(r'\s+'), ' ');

String _clip(String value, int max) {
  if (value.length <= max) return value;
  final runes = value.runes.toList();
  if (runes.length <= max) return value;
  return '${String.fromCharCodes(runes.take(max - 1))}…';
}

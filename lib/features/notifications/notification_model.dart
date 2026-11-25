// Data shared by the notification renderer, the private history store and the
// main/background isolates. Everything here is plain data with bounded JSON
// (de)serialisation: stored files and isolate messages are treated as
// untrusted input.
import 'package:flutter/foundation.dart';

import 'notification_content.dart';

/// Messages kept per room conversation notification (Element X keeps the
/// recent unread ones; Android shows the last few).
const maxLinesPerRoom = 6;

/// Rooms kept in the notification history.
const maxHistoryRooms = 30;

/// User toggles (Element X: notification settings).
@immutable
class NotificationPreferences {
  const NotificationPreferences({
    this.showContent = true,
    this.showMediaPreviews = true,
  });

  /// Sender, message text and room names. Off restores the generic alert.
  final bool showContent;

  /// Decrypted image/video thumbnails inside notifications.
  final bool showMediaPreviews;

  /// Media previews are only fetched while content is shown.
  bool get mediaEnabled => showContent && showMediaPreviews;

  NotificationPreferences copyWith({
    bool? showContent,
    bool? showMediaPreviews,
  }) => NotificationPreferences(
    showContent: showContent ?? this.showContent,
    showMediaPreviews: showMediaPreviews ?? this.showMediaPreviews,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'show_content': showContent,
    'show_media': showMediaPreviews,
  };

  static NotificationPreferences fromJson(Object? json) {
    if (json is! Map) return const NotificationPreferences();
    final content = json['show_content'];
    final media = json['show_media'];
    return NotificationPreferences(
      showContent: content is bool ? content : true,
      showMediaPreviews: media is bool ? media : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationPreferences &&
      other.showContent == showContent &&
      other.showMediaPreviews == showMediaPreviews;

  @override
  int get hashCode => Object.hash(showContent, showMediaPreviews);
}

/// One message line in a room's MessagingStyle notification.
@immutable
class NotificationLine {
  const NotificationLine({
    required this.eventId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    this.highlight = false,
    this.fromMe = false,
    this.senderAvatarPath,
    this.imagePath,
  });

  final String eventId;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime timestamp;

  /// Mentions and keyword highlights (push rule `highlight` tweak).
  final bool highlight;

  /// A quick reply sent from the notification.
  final bool fromMe;

  /// Private cache file with the sender's avatar (decoded in-app).
  final String? senderAvatarPath;

  /// Private cache file with a JPEG preview of the message's media.
  final String? imagePath;

  NotificationLine copyWith({String? text, String? imagePath}) =>
      NotificationLine(
        eventId: eventId,
        senderId: senderId,
        senderName: senderName,
        text: text ?? this.text,
        timestamp: timestamp,
        highlight: highlight,
        fromMe: fromMe,
        senderAvatarPath: senderAvatarPath,
        imagePath: imagePath ?? this.imagePath,
      );

  Map<String, Object?> toJson() => {
    'event_id': eventId,
    'sender_id': senderId,
    'sender_name': senderName,
    'text': text,
    'ts': timestamp.millisecondsSinceEpoch,
    if (highlight) 'highlight': true,
    if (fromMe) 'me': true,
    if (senderAvatarPath != null) 'avatar': senderAvatarPath,
    if (imagePath != null) 'image': imagePath,
  };

  static NotificationLine? fromJson(Object? json) {
    if (json is! Map) return null;
    final eventId = json['event_id'];
    final senderId = json['sender_id'];
    final senderName = json['sender_name'];
    final text = json['text'];
    final ts = json['ts'];
    final avatar = json['avatar'];
    final image = json['image'];
    if (eventId is! String ||
        eventId.isEmpty ||
        eventId.length > 512 ||
        senderId is! String ||
        senderId.length > 512 ||
        senderName is! String ||
        text is! String ||
        ts is! int ||
        (avatar != null && avatar is! String) ||
        (image != null && image is! String)) {
      return null;
    }
    final name = sanitiseNotificationName(senderName);
    final body = sanitiseNotificationText(text);
    if (name == null || body == null) return null;
    return NotificationLine(
      eventId: eventId,
      senderId: senderId,
      senderName: name,
      text: body,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      highlight: json['highlight'] == true,
      fromMe: json['me'] == true,
      senderAvatarPath: _safePath(avatar as String?),
      imagePath: _safePath(image as String?),
    );
  }
}

String? _safePath(String? path) =>
    path == null || path.length > 1024 || path.contains('..') ? null : path;

/// The accumulated conversation notification for one room.
@immutable
class RoomNotificationThread {
  const RoomNotificationThread({
    required this.roomId,
    required this.roomName,
    required this.isDirect,
    required this.lines,
    this.roomAvatarPath,
    this.latestEventId,
  });

  final String roomId;
  final String roomName;
  final bool isDirect;
  final String? roomAvatarPath;
  final List<NotificationLine> lines;

  /// Newest notified event (for "Mark as read").
  final String? latestEventId;

  DateTime get updatedAt => lines.isEmpty
      ? DateTime.fromMillisecondsSinceEpoch(0)
      : lines.last.timestamp;

  Map<String, Object?> toJson() => {
    'room_id': roomId,
    'room_name': roomName,
    'direct': isDirect,
    if (roomAvatarPath != null) 'avatar': roomAvatarPath,
    if (latestEventId != null) 'latest': latestEventId,
    'lines': [for (final line in lines) line.toJson()],
  };

  static RoomNotificationThread? fromJson(Object? json) {
    if (json is! Map) return null;
    final roomId = json['room_id'];
    final roomName = json['room_name'];
    final lines = json['lines'];
    final avatar = json['avatar'];
    final latest = json['latest'];
    if (roomId is! String ||
        !roomId.startsWith('!') ||
        roomId.length > 512 ||
        roomName is! String ||
        lines is! List ||
        (avatar != null && avatar is! String) ||
        (latest != null && latest is! String)) {
      return null;
    }
    final parsed = [
      for (final line in lines.take(maxLinesPerRoom * 2))
        ?NotificationLine.fromJson(line),
    ];
    if (parsed.isEmpty) return null;
    return RoomNotificationThread(
      roomId: roomId,
      roomName: sanitiseNotificationName(roomName) ?? 'Conversation',
      isDirect: json['direct'] == true,
      roomAvatarPath: _safePath(avatar as String?),
      latestEventId: latest as String?,
      lines: parsed.length > maxLinesPerRoom
          ? parsed.sublist(parsed.length - maxLinesPerRoom)
          : parsed,
    );
  }
}

/// A push event fetched and decrypted on this device, ready to display.
@immutable
class ResolvedPushEvent {
  const ResolvedPushEvent({
    required this.roomId,
    required this.eventId,
    required this.kind,
    required this.roomName,
    required this.isDirect,
    required this.line,
    this.roomAvatarPath,
    this.ringing = false,
  });

  final String roomId;
  final String eventId;
  final NotifiableEventKind kind;
  final String roomName;
  final bool isDirect;
  final String? roomAvatarPath;
  final NotificationLine line;

  /// A call that should ring (call category, high priority).
  final bool ringing;
}

/// A quick reply typed while no main isolate was running. It is sent through
/// the normal guarded send path the next time Parallax is open.
@immutable
class PendingReply {
  const PendingReply({
    required this.userId,
    required this.deviceId,
    required this.roomId,
    required this.text,
    required this.createdAt,
    this.eventId,
  });

  final String userId;
  final String deviceId;
  final String roomId;
  final String? eventId;
  final String text;
  final DateTime createdAt;

  /// Replies older than this are discarded instead of being sent late.
  static const maxAge = Duration(minutes: 30);

  /// Longest reply kept.
  static const maxLength = 4000;

  bool isExpired(DateTime now) =>
      now.isBefore(createdAt.subtract(const Duration(minutes: 1))) ||
      now.difference(createdAt) > maxAge;

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'device_id': deviceId,
    'room_id': roomId,
    if (eventId != null) 'event_id': eventId,
    'text': text,
    'ts': createdAt.millisecondsSinceEpoch,
  };

  static PendingReply? fromJson(Object? json) {
    if (json is! Map) return null;
    final user = json['user_id'];
    final device = json['device_id'];
    final room = json['room_id'];
    final event = json['event_id'];
    final text = json['text'];
    final ts = json['ts'];
    if (user is! String ||
        !user.startsWith('@') ||
        device is! String ||
        device.isEmpty ||
        room is! String ||
        !room.startsWith('!') ||
        (event != null && event is! String) ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > maxLength ||
        ts is! int) {
      return null;
    }
    return PendingReply(
      userId: user,
      deviceId: device,
      roomId: room,
      eventId: event as String?,
      text: text,
      createdAt: DateTime.fromMillisecondsSinceEpoch(ts),
    );
  }
}

/// "Mark as read" pressed (on the phone or in the car) while no main isolate
/// was running. The receipt is sent, up to [eventId], the next time the
/// client runs.
@immutable
class PendingRead {
  const PendingRead({
    required this.userId,
    required this.deviceId,
    required this.roomId,
    required this.eventId,
    required this.createdAt,
  });

  final String userId;
  final String deviceId;
  final String roomId;
  final String eventId;
  final DateTime createdAt;

  /// Older ones are dropped: the user has seen the chat elsewhere by then.
  static const maxAge = Duration(hours: 12);

  bool isExpired(DateTime now) =>
      now.isBefore(createdAt.subtract(const Duration(minutes: 1))) ||
      now.difference(createdAt) > maxAge;

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'device_id': deviceId,
    'room_id': roomId,
    'event_id': eventId,
    'ts': createdAt.millisecondsSinceEpoch,
  };

  static PendingRead? fromJson(Object? json) {
    if (json is! Map) return null;
    final user = json['user_id'];
    final device = json['device_id'];
    final room = json['room_id'];
    final event = json['event_id'];
    final ts = json['ts'];
    if (user is! String ||
        !user.startsWith('@') ||
        device is! String ||
        device.isEmpty ||
        room is! String ||
        !room.startsWith('!') ||
        event is! String ||
        !event.startsWith(r'$') ||
        ts is! int) {
      return null;
    }
    return PendingRead(
      userId: user,
      deviceId: device,
      roomId: room,
      eventId: event,
      createdAt: DateTime.fromMillisecondsSinceEpoch(ts),
    );
  }
}

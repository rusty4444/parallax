// MatrixRTC call membership parsing (MSC3401 legacy arrays and MSC4143
// per-device session events), matching matrix-js-sdk's CallMembership expiry
// rules. Pure functions: no SDK access.

import 'package:flutter/foundation.dart';

/// Default membership lifetime when an event omits `expires` (4 hours, as
/// matrix-js-sdk's DEFAULT_EXPIRE_DURATION).
const defaultCallMembershipLifetime = Duration(hours: 4);

/// One raw `m.call.member` / `org.matrix.msc3401.call.member` state event.
@immutable
class CallMemberStateEvent {
  const CallMemberStateEvent({
    required this.stateKey,
    required this.sender,
    required this.content,
    required this.originServerTs,
  });

  final String stateKey;
  final String sender;
  final Map<String, Object?> content;
  final DateTime originServerTs;
}

/// One device's participation in a MatrixRTC session.
@immutable
class CallMembership {
  const CallMembership({
    required this.userId,
    required this.deviceId,
    required this.callId,
    required this.application,
    required this.expiresAt,
    this.audioOnly = false,
  });

  final String userId;
  final String deviceId;

  /// Empty for the room's main call.
  final String callId;
  final String application;
  final DateTime expiresAt;
  final bool audioOnly;

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  /// The room-wide Element Call session (not a scoped side session).
  bool get isRoomCall => application == 'm.call' && callId.isEmpty;
}

/// Parses every membership in one state event (an empty content means the
/// device left). Malformed entries are skipped.
List<CallMembership> parseCallMemberships(CallMemberStateEvent event) {
  final content = event.content;
  if (content.isEmpty) return const [];
  final legacy = content['memberships'];
  if (legacy is List) {
    return [
      for (final item in legacy.take(64))
        if (item is Map)
          ?_membership(
            Map<String, Object?>.from(item),
            sender: event.sender,
            originServerTs: event.originServerTs,
          ),
    ];
  }
  return [
    ?_membership(
      content,
      sender: event.sender,
      originServerTs: event.originServerTs,
    ),
  ];
}

CallMembership? _membership(
  Map<String, Object?> data, {
  required String sender,
  required DateTime originServerTs,
}) {
  final application = data['application'];
  if (application is! String || application.isEmpty) return null;
  final member = data['member'];
  final deviceId = switch (data['device_id']) {
    final String id when id.isNotEmpty => id,
    _ =>
      member is Map && member['device_id'] is String
          ? member['device_id'] as String
          : '',
  };
  if (deviceId.isEmpty) return null;
  final callId = data['call_id'];
  final createdTs = _int(data['created_ts']);
  final created = createdTs == null
      ? originServerTs
      : DateTime.fromMillisecondsSinceEpoch(createdTs);
  final DateTime expiresAt;
  if (_int(data['expires_ts']) case final absolute?) {
    expiresAt = DateTime.fromMillisecondsSinceEpoch(absolute);
  } else {
    final relative = _int(data['expires']);
    expiresAt = created.add(
      relative == null || relative <= 0
          ? defaultCallMembershipLifetime
          : Duration(milliseconds: relative),
    );
  }
  return CallMembership(
    userId: sender,
    deviceId: deviceId,
    callId: callId is String ? callId : '',
    application: application,
    expiresAt: expiresAt,
    audioOnly: data['m.call.intent'] == 'audio',
  );
}

int? _int(Object? value) => switch (value) {
  final int v => v,
  final double v when v.isFinite => v.round(),
  _ => null,
};

/// The room-wide call as shown by the banner and timeline.
@immutable
class RoomCallSummary {
  const RoomCallSummary({
    this.participants = const [],
    this.devices = 0,
    this.includesMe = false,
    this.audioOnly = false,
    this.nextExpiry,
  });

  static const none = RoomCallSummary();

  /// Distinct user IDs with a live membership, in first-seen order.
  final List<String> participants;
  final int devices;
  final bool includesMe;
  final bool audioOnly;

  /// When the earliest live membership expires (to schedule a refresh).
  final DateTime? nextExpiry;

  bool get active => participants.isNotEmpty;
}

RoomCallSummary summariseRoomCall(
  Iterable<CallMemberStateEvent> events, {
  required DateTime now,
  String? ownUserId,
}) {
  final users = <String>{};
  final devices = <String>{};
  var audioOnly = true;
  DateTime? nextExpiry;
  for (final event in events) {
    for (final membership in parseCallMemberships(event)) {
      if (!membership.isRoomCall || membership.isExpired(now)) continue;
      users.add(membership.userId);
      devices.add('${membership.userId}|${membership.deviceId}');
      audioOnly &= membership.audioOnly;
      if (nextExpiry == null || membership.expiresAt.isBefore(nextExpiry)) {
        nextExpiry = membership.expiresAt;
      }
    }
  }
  if (users.isEmpty) return RoomCallSummary.none;
  return RoomCallSummary(
    participants: List.unmodifiable(users),
    devices: devices.length,
    includesMe: ownUserId != null && users.contains(ownUserId),
    audioOnly: audioOnly,
    nextExpiry: nextExpiry,
  );
}

/// MSC4075 ring timing: the notification is live from its (sanity-checked)
/// sender timestamp for `lifetime`, capped at two minutes.
DateTime rtcNotificationExpiry(
  Map<String, Object?> content, {
  required DateTime originServerTs,
}) {
  final senderTs = _int(content['sender_ts']);
  final lifetimeMs = _int(content['lifetime']) ?? 30000;
  final lifetime = Duration(milliseconds: lifetimeMs.clamp(0, 120000));
  var start = originServerTs;
  if (senderTs != null) {
    final sender = DateTime.fromMillisecondsSinceEpoch(senderTs);
    if (sender.difference(originServerTs).abs() <=
        const Duration(seconds: 20)) {
      start = sender;
    }
  }
  return start.add(lifetime);
}

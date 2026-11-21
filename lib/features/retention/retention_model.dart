import 'package:flutter/foundation.dart';

/// Disappearing messages (MSC1763 `m.room.retention`). The homeserver purges
/// events older than `max_lifetime`; Parallax also hides them locally as soon
/// as they expire. The guarantee is best-effort: other clients, federation
/// copies and screenshots can keep content, which the UI must disclose.
@immutable
class RoomRetention {
  const RoomRetention({this.maxLifetime});

  static const eventType = 'm.room.retention';

  /// Null (or zero) means retention is off.
  final Duration? maxLifetime;

  bool get enabled => maxLifetime != null && maxLifetime! > Duration.zero;

  static const off = RoomRetention();

  factory RoomRetention.fromContent(Object? content) {
    if (content is! Map) return off;
    final ms = content['max_lifetime'];
    if (ms is int && ms > 0) {
      return RoomRetention(maxLifetime: Duration(milliseconds: ms));
    }
    return off;
  }

  Map<String, Object?> toContent() =>
      enabled ? {'max_lifetime': maxLifetime!.inMilliseconds} : const {};

  bool isExpired(DateTime time, DateTime now) =>
      enabled && now.difference(time) > maxLifetime!;

  @override
  bool operator ==(Object other) =>
      other is RoomRetention && other.maxLifetime == maxLifetime;

  @override
  int get hashCode => maxLifetime.hashCode;
}

/// Presets offered in the picker (null = off).
const retentionPresets = <(String, Duration?)>[
  ('Off', null),
  ('1 hour', Duration(hours: 1)),
  ('24 hours', Duration(hours: 24)),
  ('7 days', Duration(days: 7)),
  ('30 days', Duration(days: 30)),
  ('90 days', Duration(days: 90)),
];

String retentionLabel(Duration? lifetime) {
  if (lifetime == null || lifetime <= Duration.zero) return 'Off';
  for (final (label, value) in retentionPresets) {
    if (value == lifetime) return label;
  }
  if (lifetime.inDays >= 1) {
    return '${lifetime.inDays} days';
  }
  if (lifetime.inHours >= 1) {
    return '${lifetime.inHours} hours';
  }
  return '${lifetime.inMinutes} minutes';
}

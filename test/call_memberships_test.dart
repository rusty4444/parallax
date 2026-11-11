import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/call/call_features.dart';
import 'package:parallax/features/call/call_memberships.dart';
import 'package:parallax/features/call/matrix_call_features.dart';

final _now = DateTime.utc(2026, 11, 12, 10);

CallMemberStateEvent _event(
  String sender,
  Map<String, Object?> content, {
  String? stateKey,
  DateTime? at,
}) => CallMemberStateEvent(
  stateKey: stateKey ?? '_${sender}_DEVICE',
  sender: sender,
  content: content,
  originServerTs: at ?? _now.subtract(const Duration(minutes: 5)),
);

Map<String, Object?> _session({
  String device = 'DEVICE',
  String application = 'm.call',
  String callId = '',
  int? expires,
  int? createdTs,
  String? intent,
}) => {
  'application': application,
  'call_id': callId,
  'device_id': device,
  'scope': 'm.room',
  'focus_active': {'type': 'livekit', 'focus_selection': 'oldest_membership'},
  'expires': ?expires,
  'created_ts': ?createdTs,
  'm.call.intent': ?intent,
};

void main() {
  test('session memberships default to a four-hour lifetime', () {
    final memberships = parseCallMemberships(_event('@alice:x', _session()));
    expect(memberships, hasLength(1));
    final m = memberships.single;
    expect(m.userId, '@alice:x');
    expect(m.deviceId, 'DEVICE');
    expect(m.isRoomCall, isTrue);
    expect(
      m.expiresAt,
      _now.subtract(const Duration(minutes: 5)).add(const Duration(hours: 4)),
    );
    expect(m.isExpired(_now), isFalse);
  });

  test('expiry is relative to created_ts when present', () {
    final created = _now.subtract(const Duration(hours: 2));
    final m = parseCallMemberships(
      _event(
        '@alice:x',
        _session(
          expires: const Duration(hours: 1).inMilliseconds,
          createdTs: created.millisecondsSinceEpoch,
        ),
        at: _now,
      ),
    ).single;
    expect(m.isExpired(_now), isTrue);
  });

  test('empty content means the device left', () {
    expect(parseCallMemberships(_event('@alice:x', const {})), isEmpty);
  });

  test('legacy membership arrays use expires_ts or created_ts + expires', () {
    final memberships = parseCallMemberships(
      _event('@bob:x', {
        'memberships': [
          {
            'application': 'm.call',
            'call_id': '',
            'device_id': 'B1',
            'expires_ts': _now
                .add(const Duration(minutes: 1))
                .millisecondsSinceEpoch,
          },
          {
            'application': 'm.call',
            'call_id': '',
            'device_id': 'B2',
            'created_ts': _now
                .subtract(const Duration(hours: 2))
                .millisecondsSinceEpoch,
            'expires': const Duration(hours: 1).inMilliseconds,
          },
          'garbage',
          {'application': 'm.call'}, // no device: skipped
        ],
      }, stateKey: '@bob:x'),
    );
    expect(memberships.map((m) => m.deviceId), ['B1', 'B2']);
    expect(memberships[0].isExpired(_now), isFalse);
    expect(memberships[1].isExpired(_now), isTrue);
  });

  test('summary counts live room-call participants only', () {
    final summary = summariseRoomCall(
      [
        _event('@alice:x', _session(device: 'A1', intent: 'audio')),
        _event('@alice:x', _session(device: 'A2', intent: 'audio')),
        _event('@me:x', _session(device: 'M1', intent: 'audio')),
        _event('@carol:x', _session(application: 'm.other')),
        _event('@dave:x', _session(callId: 'side-session')),
        _event(
          '@erin:x',
          _session(createdTs: 0, expires: 1000),
        ), // long expired
        _event('@frank:x', const {}),
      ],
      now: _now,
      ownUserId: '@me:x',
    );
    expect(summary.active, isTrue);
    expect(summary.participants, ['@alice:x', '@me:x']);
    expect(summary.devices, 3);
    expect(summary.includesMe, isTrue);
    expect(summary.audioOnly, isTrue);
    expect(summary.nextExpiry, isNotNull);

    final none = summariseRoomCall(const [], now: _now);
    expect(none.active, isFalse);
    expect(none.includesMe, isFalse);
  });

  group('MSC4075 ringing', () {
    final origin = _now;

    test('expiry uses sender_ts when close to the server time', () {
      final expiry = rtcNotificationExpiry({
        'sender_ts': origin
            .subtract(const Duration(seconds: 5))
            .millisecondsSinceEpoch,
        'lifetime': 30000,
      }, originServerTs: origin);
      expect(
        expiry.millisecondsSinceEpoch,
        origin.add(const Duration(seconds: 25)).millisecondsSinceEpoch,
      );
    });

    test('a skewed sender clock falls back and lifetime is capped', () {
      final expiry = rtcNotificationExpiry({
        'sender_ts': origin
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        'lifetime': 600000,
      }, originServerTs: origin);
      expect(
        expiry.millisecondsSinceEpoch,
        origin.add(const Duration(minutes: 2)).millisecondsSinceEpoch,
      );
    });

    IncomingCall? ring({
      String sender = '@alice:x',
      String type = 'org.matrix.msc4075.rtc.notification',
      String notificationType = 'ring',
      bool direct = true,
      Map<String, Object?>? mentions,
      DateTime? now,
    }) => incomingCallFromEvent(
      type: type,
      eventId: r'$ring',
      senderId: sender,
      content: {
        'notification_type': notificationType,
        'sender_ts': origin.millisecondsSinceEpoch,
        'lifetime': 30000,
        'm.mentions': ?mentions,
      },
      originServerTs: origin,
      ownUserId: '@me:x',
      roomId: '!dm:x',
      roomIsDirect: direct,
      roomJoined: true,
      roomName: 'Alice',
      senderMember: const {'displayname': 'Alice Example'},
      now: now ?? origin.add(const Duration(seconds: 3)),
    );

    test('rings for a live DM ring from someone else', () {
      final call = ring()!;
      expect(call.senderName, 'Alice Example');
      expect(call.eventId, r'$ring');
      expect(
        call.expiresAt.millisecondsSinceEpoch,
        origin.add(const Duration(seconds: 30)).millisecondsSinceEpoch,
      );
    });

    test(
      'does not ring for own, expired, non-ring or unmentioned group calls',
      () {
        expect(ring(sender: '@me:x'), isNull);
        expect(ring(notificationType: 'notification'), isNull);
        expect(ring(now: origin.add(const Duration(minutes: 1))), isNull);
        expect(ring(type: 'm.room.message'), isNull);
        expect(ring(direct: false), isNull);
        expect(
          ring(
            direct: false,
            mentions: {
              'user_ids': ['@me:x'],
            },
          ),
          isNotNull,
        );
        expect(ring(type: 'm.rtc.notification'), isNotNull);
      },
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/rooms_admin/leave_room.dart';
import 'package:parallax/features/rooms_admin/rooms_admin_models.dart';
import 'package:parallax/room_details.dart';

const roomId = '!room:example.org';
const me = '@me:example.org';
const alice = '@alice:example.org';
const bob = '@bob:example.org';

RoomStateEntry member(String id, String membership, {String? reason}) =>
    RoomStateEntry('m.room.member', id, {
      'membership': membership,
      'reason': ?reason,
    }, id);

RoomDetails details({
  String version = '10',
  Map<String, Object?>? levels,
  String joinRule = 'invite',
  List<RoomStateEntry> extra = const [],
  List<RoomStateEntry>? members,
}) => RoomDetails.fromState(
  roomId: roomId,
  userId: me,
  state: [
    RoomStateEntry('m.room.create', '', {'room_version': version}, me),
    RoomStateEntry(
      'm.room.power_levels',
      '',
      levels ??
          {
            'users': {me: 100, alice: 50},
          },
      me,
    ),
    RoomStateEntry('m.room.join_rules', '', {'join_rule': joinRule}, me),
    ...members ??
        [member(me, 'join'), member(alice, 'join'), member(bob, 'join')],
    ...extra,
  ],
);

void main() {
  group('push rules', () {
    Map<String, Object?> ruleset({
      List<Object?> override = const [],
      List<Object?> room = const [],
      bool groupNotifies = true,
    }) => {
      'override': override,
      'room': room,
      'underride': [
        {
          'rule_id': '.m.rule.message',
          'default': true,
          'enabled': true,
          'actions': groupNotifies ? ['notify'] : <Object>[],
        },
        {
          'rule_id': '.m.rule.encrypted',
          'default': true,
          'enabled': true,
          'actions': <Object>[],
        },
        {
          'rule_id': '.m.rule.room_one_to_one',
          'default': true,
          'enabled': true,
          'actions': ['notify'],
        },
      ],
    };

    test('room-specific rules map to Element X modes', () {
      expect(userDefinedNotificationMode(ruleset(), roomId), isNull);
      expect(
        userDefinedNotificationMode(
          ruleset(
            room: [
              {
                'rule_id': roomId,
                'enabled': true,
                'actions': ['notify'],
              },
            ],
          ),
          roomId,
        ),
        RoomNotificationMode.allMessages,
      );
      expect(
        userDefinedNotificationMode(
          ruleset(
            room: [
              {'rule_id': roomId, 'enabled': true, 'actions': <Object>[]},
            ],
          ),
          roomId,
        ),
        RoomNotificationMode.mentionsAndKeywords,
      );
      final mute = {
        'rule_id': roomId,
        'enabled': true,
        'actions': ['dont_notify'],
        'conditions': [
          {'kind': 'event_match', 'key': 'room_id', 'pattern': roomId},
        ],
      };
      expect(
        userDefinedNotificationMode(
          ruleset(
            override: [mute],
            room: [
              {
                'rule_id': roomId,
                'actions': ['notify'],
              },
            ],
          ),
          roomId,
        ),
        RoomNotificationMode.mute,
      );
      // Disabled or foreign rules are ignored.
      expect(
        userDefinedNotificationMode(
          ruleset(
            override: [
              {...mute, 'enabled': false},
            ],
          ),
          roomId,
        ),
        isNull,
      );
      expect(
        userDefinedNotificationMode(
          ruleset(
            room: [
              {
                'rule_id': '!other:example.org',
                'actions': ['notify'],
              },
            ],
          ),
          roomId,
        ),
        isNull,
      );
    });

    test('defaults follow the underride rule for the room kind', () {
      final rules = ruleset();
      expect(
        defaultNotificationMode(rules, encrypted: false, oneToOne: false),
        RoomNotificationMode.allMessages,
      );
      expect(
        defaultNotificationMode(rules, encrypted: true, oneToOne: false),
        RoomNotificationMode.mentionsAndKeywords,
      );
      expect(
        defaultNotificationMode(rules, encrypted: false, oneToOne: true),
        RoomNotificationMode.allMessages,
      );
      expect(
        defaultNotificationMode(
          ruleset(groupNotifies: false),
          encrypted: false,
          oneToOne: false,
        ),
        RoomNotificationMode.mentionsAndKeywords,
      );
    });
  });

  test('room addresses accept aliases, IDs and links only', () {
    expect(parseRoomAddress('#room:matrix.org')?.idOrAlias, '#room:matrix.org');
    expect(parseRoomAddress('  !abc:example.org ')?.isAlias, isFalse);
    expect(parseRoomAddress('#room:[::1]:8448'), isNotNull);
    final link = parseRoomAddress(
      'https://matrix.to/#/%23room%3Amatrix.org?via=a.org&via=b.org',
    );
    expect(link?.idOrAlias, '#room:matrix.org');
    expect(link?.via, ['a.org', 'b.org']);
    final uri = parseRoomAddress('matrix:r/room:example.org?via=c.org');
    expect(uri?.idOrAlias, '#room:example.org');
    expect(uri?.via, ['c.org']);
    for (final bad in [
      '',
      'room:matrix.org',
      '#room',
      '#:matrix.org',
      '#room:',
      '#ro om:matrix.org',
      '@user:matrix.org',
      'https://evil.example/#/#room:matrix.org',
      'https://matrix.to/#/%E0%A4%A',
      '#room:bad_server!',
    ]) {
      expect(parseRoomAddress(bad), isNull, reason: bad);
    }
  });

  test('alias suggestions and links', () {
    expect(roomAliasLocalpartFor('  My  Great Room! '), 'my-great-room');
    expect(isValidAliasLocalpart('my-room'), isTrue);
    expect(isValidAliasLocalpart('bad:room'), isFalse);
    expect(isValidAliasLocalpart(''), isFalse);
    expect(
      matrixToLink('#room:example.org'),
      'https://matrix.to/#/%23room:example.org',
    );
    expect(
      matrixToLink(roomId, via: ['example.org']),
      'https://matrix.to/#/!room:example.org?via=example.org',
    );
    expect(serverNameOf(me), 'example.org');
  });

  group('power levels', () {
    test('member edits preserve other keys and drop default levels', () {
      final levels = <String, Object?>{
        'users': {me: 100, alice: 50},
        'users_default': 0,
        'kick': 60,
        'events': {'m.room.name': 75},
      };
      final next = withMemberLevels(levels, {alice: 0, bob: 100});
      expect(next['users'], {me: 100, bob: 100});
      expect(next['kick'], 60);
      expect(next['events'], {'m.room.name': 75});
      // The source map is not mutated.
      expect(levels['users'], {me: 100, alice: 50});
    });

    test('permission edits and reset', () {
      const name = PermissionItem(
        null,
        'Change name',
        50,
        state: 'm.room.name',
      );
      const invite = PermissionItem('invite', 'Invite people', 0);
      final levels = <String, Object?>{
        'users': {me: 100},
        'state_default': 50,
        'invite': 50,
        'events': {'m.room.topic': 0, 'm.room.name': 100},
      };
      expect(permissionLevel(levels, name), 100);
      expect(permissionLevel(levels, invite), 50);
      expect(permissionLevel(null, invite), 0);
      expect(permissionLevel(null, name), 0);
      final edited = withPermissionLevel(levels, name, 0);
      expect(edited['events'], {'m.room.topic': 0, 'm.room.name': 0});
      final reset = withDefaultPermissions(levels);
      expect(reset['invite'], 0);
      expect(reset['ban'], 50);
      expect(reset['users'], {me: 100});
      expect((reset['events'] as Map)['m.room.name'], 50);
      expect((reset['events'] as Map)['m.room.avatar'], 50);
      expect(roleLevelLabel(75), 'Custom (75)');
    });

    test('role changes need power above the target', () {
      final room = details();
      final alice0 = room.member(alice)!;
      final self = room.member(me)!;
      expect(room.canChangePowerLevels, isTrue);
      expect(room.canSetPowerLevel(alice0, 100), isTrue);
      expect(room.canSetPowerLevel(alice0, 101), isFalse);
      expect(room.canSetPowerLevel(self, 0), isTrue); // Self-demotion.
      final moderator = details(
        levels: {
          'users': {me: 50, alice: 50},
          'events': {'m.room.power_levels': 100},
        },
      );
      expect(moderator.canChangePowerLevels, isFalse);
      final peers = details(
        levels: {
          'users': {me: 100, alice: 100},
          'events': {'m.room.power_levels': 100},
        },
      );
      expect(peers.canSetPowerLevel(peers.member(alice)!, 0), isFalse);
    });

    test('v12 creators outrank everyone and cannot be re-ranked', () {
      final room = RoomDetails.fromState(
        roomId: roomId,
        userId: me,
        state: [
          RoomStateEntry('m.room.create', '', {
            'room_version': '12',
            'additional_creators': [alice],
          }, me),
          RoomStateEntry('m.room.power_levels', '', {
            'users': {bob: 100},
          }, me),
          member(me, 'join'),
          member(alice, 'join'),
          member(bob, 'join'),
        ],
      );
      expect(room.member(alice)?.role, RoomRole.owner);
      expect(room.member(bob)?.role, RoomRole.admin);
      expect(room.can(RoomAction.kick, room.member(bob)), isTrue);
      expect(room.can(RoomAction.kick, room.member(alice)), isFalse);
      expect(room.canSetPowerLevel(room.member(alice)!, 0), isFalse);
      expect(room.powerOf(alice), RoomDetails.creatorPowerLevel);
    });
  });

  test('settings, knocks and security permissions are projected', () {
    final room = details(
      joinRule: 'knock',
      extra: [
        const RoomStateEntry('m.room.canonical_alias', '', {
          'alias': '#room:example.org',
          'alt_aliases': ['#alt:example.org'],
        }, me),
        const RoomStateEntry('m.room.history_visibility', '', {
          'history_visibility': 'invited',
        }, me),
        const RoomStateEntry('m.room.avatar', '', {
          'url': 'mxc://example.org/avatar',
        }, me),
        member('@knocker:example.org', 'knock', reason: 'Let me in'),
      ],
    );
    expect(room.isKnockable, isTrue);
    expect(room.canonicalAlias, '#room:example.org');
    expect(room.altAliases, ['#alt:example.org']);
    expect(room.historyVisibility, 'invited');
    expect(room.avatarUrl, Uri.parse('mxc://example.org/avatar'));
    expect(room.encrypted, isFalse);
    expect(room.canEnableEncryption, isTrue);
    expect(room.canManageSecurity, isTrue);
    expect(room.knockRequests.single.reason, 'Let me in');
    expect(room.joinedCount, 3);
    expect(room.can(RoomAction.kick, room.knockRequests.single), isTrue);
    final unsafeAvatar = details(
      extra: [
        const RoomStateEntry('m.room.avatar', '', {
          'url': 'https://tracker.example/pixel.png',
        }, me),
      ],
    );
    expect(unsafeAvatar.avatarUrl, isNull);
    final member0 = details(
      levels: {
        'users': {me: 0},
      },
    );
    expect(member0.canManageSecurity, isFalse);
    expect(member0.canRedactOthers, isFalse);
    expect(member0.canManageKnocks, isTrue); // invite defaults to 0
  });

  group('leave warnings', () {
    test('Element X order: DM, empty, last admin, private, public', () {
      expect(
        leaveWarningFor(details(), isDirect: true),
        LeaveWarning.conversation,
      );
      expect(
        leaveWarningFor(
          details(members: [member(me, 'join')]),
          isDirect: false,
        ),
        LeaveWarning.empty,
      );
      expect(
        leaveWarningFor(details(), isDirect: false),
        LeaveWarning.lastAdmin,
      );
      expect(
        leaveWarningFor(
          details(
            levels: {
              'users': {me: 100, alice: 100},
            },
          ),
          isDirect: false,
        ),
        LeaveWarning.private,
      );
      expect(
        leaveWarningFor(
          details(
            joinRule: 'public',
            levels: {
              'users': {me: 50},
            },
          ),
          isDirect: false,
        ),
        LeaveWarning.plain,
      );
    });
  });
}

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/spaces_admin/spaces_admin_models.dart';
import 'package:parallax/room_details.dart';

SpaceChildEntry _child(String id, {String? order, int ts = 0}) =>
    SpaceChildEntry(
      roomId: id,
      via: const ['example.org'],
      order: order,
      timestamp: ts,
    );

/// Applies a move plan and returns the resulting spec order.
List<String> _apply(List<SpaceChildEntry> sorted, Map<String, String> plan) {
  final next = [
    for (final child in sorted)
      SpaceChildEntry(
        roomId: child.roomId,
        via: child.via,
        order: plan[child.roomId] ?? child.order,
        timestamp: child.timestamp,
      ),
  ]..sort(compareSpaceChildren);
  for (final order in plan.values) {
    expect(isValidSpaceChildOrder(order), isTrue, reason: order);
  }
  return next.map((c) => c.roomId).toList();
}

void main() {
  test('order validity follows the spec', () {
    expect(isValidSpaceChildOrder('a'), isTrue);
    expect(isValidSpaceChildOrder(' ~'), isTrue);
    expect(isValidSpaceChildOrder(''), isFalse);
    expect(isValidSpaceChildOrder('x' * 51), isFalse);
    expect(isValidSpaceChildOrder('é'), isFalse);
    expect(isValidSpaceChildOrder('a\n'), isFalse);
    expect(isValidSpaceChildOrder(3), isFalse);
  });

  test('children parse from state: via required, invalid orders ignored', () {
    final children = spaceChildrenFromState(const [
      SpaceStateEvent(
        stateKey: '!late:x.org',
        content: {
          'via': ['x.org'],
        },
        timestamp: 9,
      ),
      SpaceStateEvent(
        stateKey: '!early:x.org',
        content: {
          'via': ['x.org'],
        },
        timestamp: 1,
      ),
      SpaceStateEvent(
        stateKey: '!b:x.org',
        content: {
          'via': ['x.org', 7, '', 'bad/server'],
          'order': 'b',
          'suggested': true,
        },
      ),
      SpaceStateEvent(
        stateKey: '!a:x.org',
        content: {
          'via': ['x.org'],
          'order': 'a',
        },
      ),
      SpaceStateEvent(
        stateKey: '!bad-order:x.org',
        content: {
          'via': ['x.org'],
          'order': 'ü',
        },
        timestamp: 5,
      ),
      SpaceStateEvent(stateKey: '!removed:x.org', content: {}),
      SpaceStateEvent(stateKey: '@user:x.org', content: {'via': 'x.org'}),
    ]);
    expect(children.map((c) => c.roomId), [
      '!a:x.org',
      '!b:x.org',
      '!early:x.org',
      '!bad-order:x.org',
      '!late:x.org',
    ]);
    final b = children[1];
    expect(b.via, ['x.org']);
    expect(b.suggested, isTrue);
    expect(children[3].order, isNull);
  });

  group('order strings', () {
    test('midpoints sit strictly between their bounds', () {
      expect(orderBetween('', null), isNotNull);
      expect(orderBetween('b', 'a'), isNull);
      expect(orderBetween('a', 'a'), isNull);
      // No string sorts between "a" and "a " … except longer ones.
      final tight = orderBetween('a', 'a!');
      expect(tight, isNotNull);
      expect(tight!.compareTo('a'), greaterThan(0));
      expect(tight.compareTo('a!'), lessThan(0));
      // Nothing fits below a single space.
      expect(orderBetween('', ' '), isNull);
      // Nothing fits above the maximum-length top string.
      expect(orderBetween('~' * 50, null), isNull);

      final random = Random(7);
      String randomOrder() => String.fromCharCodes(
        List.generate(1 + random.nextInt(6), (_) => 0x20 + random.nextInt(95)),
      );
      for (var i = 0; i < 500; i++) {
        final a = randomOrder();
        final b = randomOrder();
        if (a == b) continue;
        final low = a.compareTo(b) < 0 ? a : b;
        final high = low == a ? b : a;
        final mid = orderBetween(low, high);
        if (mid == null) continue; // e.g. "x" and "x " have no gap.
        expect(isValidSpaceChildOrder(mid), isTrue);
        expect(mid.compareTo(low), greaterThan(0), reason: '$low < $mid');
        expect(mid.compareTo(high), lessThan(0), reason: '$mid < $high');
      }
    });

    test('evenly spaced orders increase and stay valid', () {
      for (final count in [1, 3, 94, 95, 200]) {
        final orders = evenlySpacedOrders(count);
        expect(orders, hasLength(count));
        for (var i = 1; i < orders.length; i++) {
          expect(orders[i].compareTo(orders[i - 1]), greaterThan(0));
        }
        expect(orders.every(isValidSpaceChildOrder), isTrue);
      }
    });
  });

  group('moving children', () {
    test('one write between ordered neighbours', () {
      final sorted = [
        _child('!a', order: 'b'),
        _child('!b', order: 'd'),
        _child('!c', order: 'f'),
      ];
      final plan = planSpaceChildMove(sorted, '!c', 1);
      expect(plan.keys, ['!c']);
      expect(_apply(sorted, plan), ['!a', '!c', '!b']);
      expect(planSpaceChildMove(sorted, '!a', 0), isEmpty);
      expect(() => planSpaceChildMove(sorted, '!x', 0), throwsArgumentError);
    });

    test('unordered children before the target are numbered', () {
      final sorted = [
        _child('!o', order: 'm'),
        _child('!u1', ts: 1),
        _child('!u2', ts: 2),
        _child('!u3', ts: 3),
      ];
      final plan = planSpaceChildMove(sorted, '!u1', 2);
      expect(_apply(sorted, plan), ['!o', '!u2', '!u1', '!u3']);
      // u3 stays unordered after the renumbered prefix.
      expect(plan.containsKey('!u3'), isFalse);
    });

    test('equal neighbouring orders force a renumbering', () {
      final sorted = [
        _child('!a', order: 'k', ts: 1),
        _child('!b', order: 'k', ts: 2),
        _child('!c', order: 'z'),
      ];
      final plan = planSpaceChildMove(sorted, '!c', 1);
      expect(_apply(sorted, plan), ['!a', '!c', '!b']);
    });

    test('random moves always produce the requested order', () {
      final random = Random(11);
      for (var round = 0; round < 300; round++) {
        final size = 2 + random.nextInt(8);
        final sorted = [
          for (var i = 0; i < size; i++)
            _child(
              '!r$i',
              order: random.nextInt(3) == 0
                  ? null
                  : String.fromCharCode(0x21 + random.nextInt(5)),
              ts: random.nextInt(4),
            ),
        ]..sort(compareSpaceChildren);
        final from = random.nextInt(size);
        final to = random.nextInt(size);
        final id = sorted[from].roomId;
        final expected = [...sorted.map((c) => c.roomId)]
          ..removeAt(from)
          ..insert(to, id);
        expect(
          _apply(sorted, planSpaceChildMove(sorted, id, to)),
          expected,
          reason: 'round $round: move $from → $to',
        );
      }
    });
  });

  test('room versions are chosen only when the default is too old', () {
    final available = {'6': 'stable', '9': 'stable', '10': 'stable'};
    expect(roomVersionFor(8, '10', available), isNull);
    expect(roomVersionFor(10, '9', available), '10');
    expect(roomVersionFor(8, '6', available), '10');
    expect(roomVersionFor(1, '1', available), isNull);
    expect(roomVersionFor(10, null, available), isNull);
    expect(
      () => roomVersionFor(10, '9', {'9': 'stable', '11': 'unstable'}),
      throwsStateError,
    );
  });

  test('access rules map to join rules and versions', () {
    expect(SpaceCreationAccess.spaceMembers.joinRule, 'restricted');
    expect(
      SpaceCreationAccess.askToJoinSpaceMembers.joinRule,
      'knock_restricted',
    );
    expect(SpaceCreationAccess.askToJoinSpaceMembers.minimumRoomVersion, 10);
    expect(SpaceCreationAccess.public.needsAddress, isTrue);
    expect(SpaceCreationAccess.askToJoin.encryptedRoom, isFalse);
    expect(SpaceCreationAccess.spaceMembers.encryptedRoom, isTrue);
    expect(spaceMemberJoinRules(['!s'], askToJoin: true), {
      'join_rule': 'knock_restricted',
      'allow': [
        {'type': 'm.room_membership', 'room_id': '!s'},
      ],
    });
  });

  test('privileged candidates include v12 creators', () {
    RoomDetails details(String version) => RoomDetails.fromState(
      roomId: '!r',
      userId: '@me:x',
      state: [
        RoomStateEntry('m.room.create', '', {
          'room_version': version,
          'additional_creators': ['@co:x'],
        }, '@me:x'),
        const RoomStateEntry('m.room.power_levels', '', {
          'users': {'@admin:x': 100, '@mod:x': 50},
        }, '@me:x'),
      ],
    );
    final v12 = details('12');
    expect(isPrivileged(v12, '@me:x'), isTrue);
    expect(
      otherPrivilegedCandidates(v12, '@me:x'),
      unorderedEquals(['@admin:x', '@co:x']),
    );
    final v11 = details('11');
    expect(isPrivileged(v11, '@me:x'), isFalse);
    expect(otherPrivilegedCandidates(v11, '@me:x'), ['@admin:x']);
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/scheduled/delayed_events.dart';
import 'package:parallax/features/scheduled/scheduled_store.dart';

import 'scheduled_fakes.dart';

const _account = '["https://matrix.example","@sam:matrix.example"]';

ScheduledRecord _record(
  String id, {
  String body = 'Hello',
  bool encrypted = true,
  DateTime? sendAt,
  DateTime? createdAt,
  String roomId = scheduledRoomId,
}) => ScheduledRecord(
  delayId: id,
  roomId: roomId,
  type: 'm.room.message',
  content: {'msgtype': 'm.text', 'body': body},
  sendAt: sendAt ?? DateTime.utc(2026, 11, 13, 9),
  createdAt: createdAt ?? DateTime.utc(2026, 11, 12, 9),
  encrypted: encrypted,
);

ServerDelayedEvent _server(
  String id, {
  String type = 'm.room.encrypted',
  String? stateKey,
  Map<String, Object?> content = const {'ciphertext': 'x'},
  DateTime? sendAt,
}) => ServerDelayedEvent(
  delayId: id,
  roomId: scheduledRoomId,
  type: type,
  stateKey: stateKey,
  content: content,
  sendAt: sendAt ?? DateTime.utc(2026, 11, 13, 9, 1),
);

void main() {
  group('ScheduledMessageStore', () {
    test('round trip, account isolation and hashed keys', () async {
      final storage = MemoryStore();
      final store = ScheduledMessageStore(storage: storage);
      await store.put(_account, _record('syd_a', body: 'Secret plan'));
      await store.put('other-account', _record('syd_b'));
      final read = await store.read(_account);
      expect(read.keys, ['syd_a']);
      expect(read['syd_a']!.preview, 'Secret plan');
      expect(read['syd_a']!.encrypted, isTrue);
      expect((await store.read('other-account')).keys, ['syd_b']);
      expect(storage.values.keys.any((key) => key.contains('@sam')), isFalse);
      await store.remove(_account, ['syd_a']);
      expect(await store.read(_account), isEmpty);
      expect(storage.values, hasLength(1));
    });

    test('a corrupt snapshot is never overwritten', () async {
      final storage = MemoryStore();
      final store = ScheduledMessageStore(storage: storage);
      final key = ScheduledMessageStore.storageKey(_account);
      storage.values[key] = '{"version":1,"accountKey":"someone else"}';
      await expectLater(store.read(_account), throwsFormatException);
      await expectLater(
        store.put(_account, _record('syd_a')),
        throwsFormatException,
      );
      expect(storage.values[key], '{"version":1,"accountKey":"someone else"}');
      storage.failRead = true;
      await expectLater(store.read(_account), throwsStateError);
    });

    test('record count is bounded', () async {
      final store = ScheduledMessageStore(storage: MemoryStore());
      for (var i = 0; i < ScheduledMessageStore.maxRecords; i++) {
        await store.put(_account, _record('syd_$i'));
      }
      await expectLater(
        store.put(_account, _record('syd_overflow')),
        throwsStateError,
      );
      expect(
        await store.read(_account),
        hasLength(ScheduledMessageStore.maxRecords),
      );
    });

    test('previews are bounded and blank bodies have none', () {
      final long = _record('syd_long', body: 'x' * 900);
      expect(long.preview!.length, 501);
      expect(_record('syd_blank', body: '  ').preview, isNull);
      final json = jsonDecode(jsonEncode(long.toJson()));
      expect(ScheduledRecord.fromJson(json).content['body'], 'x' * 900);
    });
  });

  group('reconcileScheduled', () {
    final listedAt = DateTime.utc(2026, 11, 12, 10);

    test('drops records the server no longer has; keeps newer ones', () {
      final result = reconcileScheduled(
        local: {
          'syd_kept': _record('syd_kept', body: 'Kept'),
          'syd_gone': _record('syd_gone'),
          'syd_new': _record(
            'syd_new',
            body: 'Just scheduled',
            createdAt: listedAt.add(const Duration(seconds: 1)),
          ),
        },
        server: ServerDelayedEvents([
          _server('syd_kept'),
          _server(
            'syd_plain',
            type: 'm.room.message',
            content: {'msgtype': 'm.text', 'body': 'From elsewhere'},
          ),
          _server('syd_foreign_encrypted'),
          _server(
            'syd_call',
            type: 'org.matrix.msc3401.call.member',
            stateKey: '_@sam:matrix.example_DEVICE',
            content: {},
          ),
          _server('syd_reaction', type: 'm.reaction', content: {}),
        ], complete: true),
        listedAt: listedAt,
      );
      expect(result.stale, {'syd_gone'});
      expect(result.items.keys.toSet(), {'syd_kept', 'syd_plain', 'syd_new'});
      final kept = result.items['syd_kept']!;
      expect(kept.preview, 'Kept');
      expect(kept.encrypted, isTrue);
      expect(kept.sendAt, DateTime.utc(2026, 11, 13, 9, 1));
      expect(kept.canReschedule, isTrue);
      final plain = result.items['syd_plain']!;
      expect(plain.preview, 'From elsewhere');
      expect(plain.encrypted, isFalse);
    });

    test('an incomplete list proves nothing about absent records', () {
      final result = reconcileScheduled(
        local: {'syd_a': _record('syd_a'), 'syd_b': _record('syd_b')},
        server: ServerDelayedEvents([_server('syd_a')], complete: false),
        listedAt: listedAt,
      );
      expect(result.stale, isEmpty);
      expect(result.items['syd_a']!.confirmed, isTrue);
      expect(result.items['syd_b']!.confirmed, isFalse);
    });

    test('an unavailable list shows local records unconfirmed', () {
      final result = reconcileScheduled(
        local: {'syd_a': _record('syd_a')},
        server: null,
      );
      expect(result.stale, isEmpty);
      expect(result.items['syd_a']!.confirmed, isFalse);
      expect(result.items['syd_a']!.preview, 'Hello');
    });

    test('a local record for another room is not attached', () {
      final result = reconcileScheduled(
        local: {'syd_a': _record('syd_a', roomId: '!other:matrix.example')},
        server: ServerDelayedEvents([_server('syd_a')], complete: true),
        listedAt: listedAt,
      );
      expect(result.items, isEmpty);
      expect(result.stale, isEmpty);
    });
  });
}

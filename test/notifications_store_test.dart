import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/notifications/notification_content.dart';
import 'package:parallax/features/notifications/notification_model.dart';
import 'package:parallax/features/notifications/notification_store.dart';

ResolvedPushEvent event(
  String roomId,
  String eventId, {
  String text = 'Hello',
  DateTime? at,
  String roomName = 'Book club',
}) => ResolvedPushEvent(
  roomId: roomId,
  eventId: eventId,
  kind: NotifiableEventKind.message,
  roomName: roomName,
  isDirect: false,
  line: NotificationLine(
    eventId: eventId,
    senderId: '@alice:example.org',
    senderName: 'Alice',
    text: text,
    timestamp: at ?? DateTime.now(),
  ),
);

void main() {
  late Directory directory;
  late NotificationStore store;
  final account = notificationAccountKey('@me:example.org', 'DEVICE');

  setUp(() {
    directory = Directory.systemTemp.createTempSync('parallax_notifications');
    store = NotificationStore(directory);
  });
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('preferences default on and round-trip', () async {
    expect(await store.readPreferences(), const NotificationPreferences());
    await store.writePreferences(
      const NotificationPreferences(showMediaPreviews: false),
    );
    final read = await NotificationStore(directory).readPreferences();
    expect(read.showContent, isTrue);
    expect(read.showMediaPreviews, isFalse);
    expect(read.mediaEnabled, isFalse);
    expect(
      const NotificationPreferences(showContent: false).mediaEnabled,
      isFalse,
    );
  });

  test('history accumulates per room, deduplicated and bounded', () async {
    final base = DateTime.now().subtract(const Duration(minutes: 30));
    for (var i = 0; i < maxLinesPerRoom + 3; i++) {
      await store.appendEvent(
        account,
        event(
          '!a:x.org',
          '\$e$i',
          text: 'm$i',
          at: base.add(Duration(minutes: i)),
        ),
      );
    }
    // A redelivered push does not duplicate its line.
    final thread = await store.appendEvent(
      account,
      event(
        '!a:x.org',
        '\$e${maxLinesPerRoom + 2}',
        text: 'again',
        at: base.add(Duration(minutes: maxLinesPerRoom + 2)),
      ),
    );
    expect(thread.lines, hasLength(maxLinesPerRoom));
    expect(thread.lines.last.text, 'again');
    expect(thread.latestEventId, '\$e${maxLinesPerRoom + 2}');
    await store.appendEvent(account, event('!b:x.org', r'$b'));
    final threads = await store.threads(account);
    expect(threads.map((t) => t.roomId), ['!b:x.org', '!a:x.org']);
  });

  test('history belongs to one account and device', () async {
    await store.appendEvent(account, event('!a:x.org', r'$1'));
    expect(
      await store.threads(notificationAccountKey('@me:example.org', 'OTHER')),
      isEmpty,
    );
    // Writing for another account replaces, never merges.
    final other = notificationAccountKey('@bob:example.org', 'B');
    await store.appendEvent(other, event('!c:x.org', r'$2'));
    expect(await store.threads(account), isEmpty);
    expect((await store.threads(other)).single.roomId, '!c:x.org');
  });

  test('removing rooms and quick-reply lines', () async {
    await store.appendEvent(account, event('!a:x.org', r'$1'));
    await store.appendEvent(account, event('!b:x.org', r'$2'));
    final reply = ownReplyLine(
      userId: '@me:example.org',
      text: 'On my way',
      now: DateTime.now(),
    )!;
    final updated = await store.appendOwnLine(account, '!a:x.org', reply);
    expect(updated!.lines.last.fromMe, isTrue);
    expect(updated.lines.last.senderName, 'Me');
    expect(await store.appendOwnLine(account, '!zzz:x.org', reply), isNull);
    expect(await store.removeRooms(account, ['!a:x.org', '!none:x.org']), {
      '!a:x.org',
    });
    expect((await store.threads(account)).single.roomId, '!b:x.org');
    await store.clearHistory();
    expect(await store.threads(account), isEmpty);
  });

  test('old history expires', () async {
    final clocked = NotificationStore(
      directory,
      clock: () => DateTime.now().add(const Duration(days: 5)),
    );
    await store.appendEvent(account, event('!a:x.org', r'$1'));
    expect(await clocked.threads(account), isEmpty);
  });

  test('corrupt or hostile files are ignored', () async {
    File('${directory.path}/history.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"account": ${jsonEncode(account)}, "rooms": [1, '
        '{"room_id": "not-a-room", "room_name": "x", "lines": []}]}',
      );
    expect(await store.threads(account), isEmpty);
    File('${directory.path}/preferences.json').writeAsStringSync('nope');
    expect(await store.readPreferences(), const NotificationPreferences());
    final line = NotificationLine.fromJson({
      'event_id': r'$x',
      'sender_id': '@a:x',
      'sender_name': 'A',
      'text': 'hi',
      'ts': 1,
      'image': '/cache/../../etc/passwd',
    });
    expect(line?.imagePath, isNull);
  });

  test('pending replies are kept, bounded and taken once', () async {
    final now = DateTime.now();
    for (var i = 0; i < 12; i++) {
      await store.addPendingReply(
        PendingReply(
          userId: '@me:example.org',
          deviceId: 'DEVICE',
          roomId: '!a:x.org',
          text: 'reply $i',
          createdAt: now,
        ),
      );
    }
    final taken = await store.takePendingReplies();
    expect(taken, hasLength(10));
    expect(taken.last.text, 'reply 11');
    expect(await store.takePendingReplies(), isEmpty);
    final old = PendingReply(
      userId: '@me:example.org',
      deviceId: 'DEVICE',
      roomId: '!a:x.org',
      text: 'late',
      createdAt: now.subtract(const Duration(hours: 1)),
    );
    expect(old.isExpired(now), isTrue);
  });

  test('concurrent writers from two store instances do not corrupt', () async {
    final second = NotificationStore(directory);
    await Future.wait([
      for (var i = 0; i < 8; i++)
        (i.isEven ? store : second).appendEvent(
          account,
          event('!r$i:x.org', '\$e$i'),
        ),
    ]);
    expect(await store.threads(account), hasLength(8));
    expect(File('${directory.path}/.lock').existsSync(), isFalse);
  });
}

import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/notifications/push_handoff.dart';

import 'notifications_fakes.dart';

void main() {
  late FakeDirectory directory;
  setUp(() => directory = FakeDirectory());

  test('no main isolate: the background may handle the push', () async {
    expect(
      await handOffToMainIsolate(handoffKindPush, const {
        'room_id': '!r:x.org',
      }, directory: directory),
      HandoffResult.unavailable,
    );
  });

  test('a live main isolate accepts or rejects synchronously', () async {
    final received = <(String, Map<String, Object?>)>[];
    final server = PushHandoffServer((kind, payload) {
      received.add((kind, payload));
      return payload['ok'] == true;
    }, directory: directory)..start();
    addTearDown(server.stop);
    expect(server.running, isTrue);
    expect(
      await handOffToMainIsolate(handoffKindPush, const {
        'ok': true,
        'room_id': '!r:x.org',
      }, directory: directory),
      HandoffResult.accepted,
    );
    expect(
      await handOffToMainIsolate(handoffKindReply, const {
        'ok': false,
      }, directory: directory),
      HandoffResult.rejected,
    );
    expect(received.map((r) => r.$1), [handoffKindPush, handoffKindReply]);
    expect(received.first.$2['room_id'], '!r:x.org');
  });

  test('a throwing handler counts as rejected', () async {
    final server = PushHandoffServer(
      (_, _) => throw StateError('boom'),
      directory: directory,
    )..start();
    addTearDown(server.stop);
    expect(
      await handOffToMainIsolate(
        handoffKindPush,
        const {},
        directory: directory,
      ),
      HandoffResult.rejected,
    );
  });

  test('a stale port from a dead isolate times out and is removed', () async {
    final dead = ReceivePort()..close();
    directory.ports[pushHandoffPortName] = dead.sendPort;
    expect(
      await handOffToMainIsolate(
        handoffKindPush,
        const {},
        directory: directory,
        ackTimeout: const Duration(milliseconds: 50),
      ),
      HandoffResult.unavailable,
    );
    expect(directory.ports, isEmpty);
  });

  test('a new main isolate replaces a stale registration and unregisters '
      'only its own port', () async {
    final stale = ReceivePort()..close();
    directory.ports[pushHandoffPortName] = stale.sendPort;
    final server = PushHandoffServer((_, _) => true, directory: directory)
      ..start();
    expect(directory.ports[pushHandoffPortName], isNot(stale.sendPort));
    final other = ReceivePort();
    addTearDown(other.close);
    directory.ports[pushHandoffPortName] = other.sendPort;
    server.stop();
    expect(directory.ports[pushHandoffPortName], other.sendPort);
  });
}

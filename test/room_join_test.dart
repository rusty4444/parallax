import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:matrixpress/chat_backend.dart';
import 'package:matrixpress/matrix_backend.dart';
import 'package:matrixpress/room_join.dart';
import 'package:matrixpress/room_join_dialog.dart';
import 'package:matrixpress/send_cancellation.dart';

class _Database implements matrix.DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super('join-test', database: _Database(), httpClient: transport) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'original-token';
  }
  String account = '@alice:matrix.example';
  @override
  String get userID => account;
  @override
  String get deviceID => 'DEVICE';
  @override
  bool isLogged() => true;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

const roomId = '!room:matrix.example';
void _joined(_Client client) => client.rooms.add(
  matrix.Room(id: roomId, client: client, membership: matrix.Membership.join),
);

class _Backend extends ChatBackend implements RecoverableRoomJoining {
  String account = '@alice:example.org';
  @override
  String get userId => account;
  final requests = <Completer<String>>[];
  final cancellations = <SendCancellation>[];
  @override
  Future<String> waitForRoomJoin(String id, SendCancellation cancellation) {
    cancellations.add(cancellation);
    final result = Completer<String>();
    requests.add(result);
    return result.future;
  }

  void replace() {
    account = '@bob:example.org';
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _open(
  WidgetTester tester,
  _Backend backend,
  void Function(String?) selected,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              selected(await showRoomJoin(context, backend, roomId)),
          child: const Text('Join'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Join'));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'acknowledged join waits are bounded and recover without another POST',
    () async {
      var posts = 0;
      final client = _Client(
        MockClient((_) async {
          posts++;
          return http.Response('{"room_id":"$roomId"}', 200);
        }),
      );
      final owner = RoomJoinOwner(client, ownerCurrent: () => true);
      await expectLater(
        owner.join(roomId, deadline: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        owner.join(roomId, deadline: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      expect(posts, 1);
      _joined(client);
      expect(await owner.join(roomId), roomId);
      client.rooms.clear();
      await expectLater(
        owner.join(roomId, deadline: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        posts,
        2,
        reason: 'a confirmed join followed by leave must permit rejoining',
      );
    },
  );

  test(
    'confirmed membership then late transport error permits leave and rejoin',
    () async {
      var posts = 0;
      final started = Completer<void>();
      final acknowledgement = Completer<http.Response>();
      final client = _Client(
        MockClient((_) {
          posts++;
          if (posts == 1) {
            started.complete();
            return acknowledgement.future;
          }
          return Future.value(http.Response('{"room_id":"$roomId"}', 200));
        }),
      );
      final owner = RoomJoinOwner(client, ownerCurrent: () => true);
      final first = owner.join(roomId);
      await started.future;
      _joined(client);
      expect(await first.timeout(const Duration(seconds: 1)), roomId);

      acknowledgement.completeError(StateError('connection lost'));
      await Future<void>.delayed(Duration.zero);
      client.rooms.clear();
      await expectLater(
        owner.join(roomId, deadline: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        posts,
        2,
        reason:
            'confirmed membership settles delivery even if its reply is lost',
      );
      _joined(client);
      expect(await owner.join(roomId), roomId);
      expect(posts, 2);
    },
  );

  test(
    'real SDK Room.join without sync returns acknowledgement only',
    () async {
      final client = _Client(
        MockClient((_) async => http.Response('{"room_id":"$roomId"}', 200)),
      );
      final room = matrix.Room(
        id: roomId,
        client: client,
        membership: matrix.Membership.invite,
      );
      await room.join(waitForSync: false, leaveIfNotFound: false);
      expect(room.membership, matrix.Membership.invite);
    },
  );

  test(
    'backend recovers membership synced before real SDK acknowledgement',
    () async {
      final started = Completer<void>();
      final ack = Completer<http.Response>();
      final client = _Client(
        MockClient((request) {
          expect(request.method, 'POST');
          expect(
            Uri.decodeComponent(request.url.path),
            '/_matrix/client/v3/rooms/$roomId/join',
          );
          expect(request.headers['authorization'], 'Bearer original-token');
          started.complete();
          return ack.future;
        }),
      );
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);
      final joining = backend.joinPublicRoom(roomId);
      await started.future;
      _joined(client);
      ack.complete(http.Response('{"room_id":"$roomId"}', 200));
      expect(await joining.timeout(const Duration(seconds: 1)), roomId);
    },
  );

  test(
    'deadline and cancellation retain held HTTP acknowledgement without duplicate POST',
    () async {
      final ack = Completer<http.Response>();
      var posts = 0;
      final client = _Client(
        MockClient((request) {
          posts++;
          return ack.future;
        }),
      );
      final owner = RoomJoinOwner(client, ownerCurrent: () => true);
      await expectLater(
        owner.join(roomId, deadline: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      final cancellation = SendCancellation();
      final retry = owner.join(roomId, cancellation: cancellation);
      final cancelled = expectLater(retry, throwsA(isA<SendCancelled>()));
      cancellation.cancel();
      await cancelled;
      expect(posts, 1);
      ack.complete(http.Response('{"room_id":"$roomId"}', 200));
      _joined(client);
      expect(await owner.join(roomId), roomId);
      expect(posts, 1);
    },
  );

  for (final definite in [false, true]) {
    test(
      '${definite ? 'definite rejection permits' : 'uncertain delivery blocks'} another POST',
      () async {
        var posts = 0;
        final client = _Client(
          MockClient((_) async {
            posts++;
            if (!definite) throw StateError('connection lost');
            return http.Response(
              '{"errcode":"M_FORBIDDEN","error":"invite required"}',
              403,
            );
          }),
        );
        final owner = RoomJoinOwner(client, ownerCurrent: () => true);
        await expectLater(owner.join(roomId), throwsA(anything));
        await expectLater(owner.join(roomId), throwsA(anything));
        expect(posts, definite ? 2 : 1);
        _joined(client);
        expect(await owner.join(roomId), roomId);
      },
    );
  }

  test(
    'late SDK result cannot cross account ownership or write again',
    () async {
      final ack = Completer<http.Response>();
      var posts = 0;
      var current = true;
      final client = _Client(
        MockClient((_) {
          posts++;
          return ack.future;
        }),
      );
      final owner = RoomJoinOwner(client, ownerCurrent: () => current);
      final joining = owner.join(roomId);
      final assertion = expectLater(joining, throwsStateError);
      current = false;
      client.account = '@bob:matrix.example';
      ack.complete(http.Response('{"room_id":"$roomId"}', 200));
      await assertion;
      expect(client.rooms, isEmpty);
      expect(posts, 1);
      await expectLater(owner.join(roomId), throwsStateError);
      expect(posts, 1);
    },
  );

  testWidgets('visible deadline, check again and stop fence late success', (
    tester,
  ) async {
    final backend = _Backend();
    String? selected;
    await _open(tester, backend, (id) => selected = id);
    expect(find.text('Stop waiting'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Join not confirmed'), findsOneWidget);
    expect(backend.cancellations.single.isCancelled, isTrue);
    await tester.tap(find.text('Check again'));
    await tester.pump();
    backend.requests.first.complete(roomId);
    await tester.pump();
    expect(find.text('Joining room…'), findsOneWidget);
    await tester.tap(find.text('Stop waiting'));
    await tester.pumpAndSettle();
    backend.requests.last.complete(roomId);
    await tester.pump();
    expect(selected, isNull);
    expect(backend.cancellations.last.isCancelled, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  for (final fail in [false, true]) {
    testWidgets(
      'account replacement fences late ${fail ? 'error' : 'success'}',
      (tester) async {
        final backend = _Backend();
        String? selected;
        await _open(tester, backend, (id) => selected = id);
        backend.replace();
        if (fail) {
          backend.requests.single.completeError(StateError('old'));
        } else {
          backend.requests.single.complete(roomId);
        }
        await tester.pump();
        expect(find.text('Account changed'), findsOneWidget);
        expect(find.text('Check again'), findsNothing);
        expect(selected, isNull);
        expect(backend.cancellations.single.isCancelled, isTrue);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('disposal cancels deadline with original request still held', (
    tester,
  ) async {
    final backend = _Backend();
    await _open(tester, backend, (_) {});
    await tester.pumpWidget(const SizedBox());
    expect(backend.cancellations.single.isCancelled, isTrue);
    backend.requests.single.completeError(StateError('late'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

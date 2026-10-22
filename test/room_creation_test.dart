import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:matrixpress/app_theme.dart';
import 'package:matrixpress/chat_backend.dart';
import 'package:matrixpress/created_room_wait.dart';
import 'package:matrixpress/inbox_screen.dart';
import 'package:matrixpress/matrix_backend.dart';

import 'widget_test.dart' show FakeBackend;

const createdId = '!created:example.org';
const createdRoom = ChatRoom(
  id: createdId,
  name: 'Created group',
  preview: '',
  lastActivity: null,
);

void main() {
  for (final encrypted in [true, false]) {
    test(
      'SDK creates explicit encrypted=$encrypted room without waiting for sync',
      () async {
        var creates = 0;
        final client = _Client(
          MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/_matrix/client/v3/createRoom');
            expect(request.headers['authorization'], 'Bearer test-token');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['name'], 'Created group');
            expect(body['preset'], 'private_chat');
            final state = body['initial_state'] as List<dynamic>? ?? [];
            expect(
              state.where((e) => e['type'] == 'm.room.encryption'),
              encrypted ? hasLength(1) : isEmpty,
            );
            creates++;
            return http.Response(jsonEncode({'room_id': createdId}), 200);
          }),
        );
        final backend = MatrixBackend.withClient(client);
        addTearDown(backend.dispose);
        expect(
          await backend
              .createRoom(' Created group ', encrypted: encrypted)
              .timeout(const Duration(seconds: 1)),
          createdId,
        );
        expect(client.rooms, isEmpty); // No sync events have been emitted.
        expect(creates, 1);
      },
    );
  }

  test(
    'encryption unavailable and invalid names fail before the request',
    () async {
      var requests = 0;
      final client = _Client(
        MockClient((_) async {
          requests++;
          return http.Response('{}', 500);
        }),
      )..cryptoAvailable = false;
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);
      await expectLater(
        backend.createRoom('Name', encrypted: true),
        throwsStateError,
      );
      await expectLater(
        backend.createRoom(' ', encrypted: false),
        throwsArgumentError,
      );
      await expectLater(
        backend.createRoom('a' * 256, encrypted: false),
        throwsArgumentError,
      );
      expect(requests, 0);
    },
  );

  for (final change in ['signed out', 'account replaced', 'device replaced']) {
    test('late acknowledgement cannot act after $change', () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final client = _Client(
        MockClient((_) {
          started.complete();
          return response.future;
        }),
      );
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);
      final result = backend.createRoom('Name', encrypted: false);
      final check = expectLater(result, throwsStateError);
      await started.future;
      switch (change) {
        case 'signed out':
          client.accessToken = null;
        case 'account replaced':
          client.currentUser = '@other:matrix.example';
        case 'device replaced':
          client.currentDevice = 'OTHER';
      }
      response.complete(http.Response(jsonEncode({'room_id': createdId}), 200));
      await check;
      expect(backend.activeRoomId, isNull);
    });
  }

  testWidgets('sync wait times out, cancels and does not retain listeners', (
    tester,
  ) async {
    final backend = _ListeningBackend();
    final wait = CreatedRoomWait(
      backend: backend,
      roomId: createdId,
      isCurrent: () => true,
    );
    expect(backend.hasActiveListeners, isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(await wait.result, isFalse);
    expect(backend.hasActiveListeners, isFalse);
    final retry = CreatedRoomWait(
      backend: backend,
      roomId: createdId,
      isCurrent: () => true,
    );
    retry.cancel();
    expect(await retry.result, isFalse);
    expect(backend.hasActiveListeners, isFalse);
  });

  testWidgets('sync wait detects joined room and rejects a changed owner', (
    tester,
  ) async {
    final backend = _ListeningBackend();
    var current = true;
    final first = CreatedRoomWait(
      backend: backend,
      roomId: createdId,
      isCurrent: () => current,
    );
    current = false;
    backend.roomList.add(createdRoom);
    backend.notifyListeners();
    expect(await first.result, isFalse);
    expect(backend.hasActiveListeners, isFalse);
    final next = CreatedRoomWait(
      backend: backend,
      roomId: createdId,
      isCurrent: () => true,
    );
    expect(await next.result, isTrue);
    expect(backend.hasActiveListeners, isFalse);
  });

  testWidgets(
    'delayed sync retries the acknowledged ID without creating a duplicate',
    (tester) async {
      final backend = _DelayedBackend();
      await _startCreation(tester, backend);
      expect(backend.creates, 1);
      expect(find.text(createdId), findsOneWidget);
      expect(backend.activeRoomId, isNull);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.text('Room created'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Create room',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('Open created room'));
      await tester.tap(find.text('Open created room'));
      await tester.pump();
      backend.roomList.add(createdRoom);
      backend.notifyListeners();
      await tester.pumpAndSettle();
      expect(backend.creates, 1);
      expect(backend.activeRoomId, createdId);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposing the inbox cancels its pending sync wait', (
    tester,
  ) async {
    final backend = _DelayedBackend();
    await _startCreation(tester, backend);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(backend.hasActiveListeners, isFalse);
    backend.roomList.add(createdRoom);
    backend.notifyListeners();
    await tester.pump();
    expect(backend.activeRoomId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account replacement never opens the previous account room', (
    tester,
  ) async {
    final backend = _DelayedBackend()..currentUserId = '@alice:example.org';
    await _startCreation(tester, backend);
    backend.currentUserId = '@bob:example.org';
    backend.roomList.add(createdRoom);
    backend.notifyListeners();
    await tester.pumpAndSettle();
    expect(backend.activeRoomId, isNull);
    expect(find.text(createdId), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _startCreation(
  WidgetTester tester,
  _DelayedBackend backend,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: InboxScreen(
        backend: backend,
        palette: paletteFor(VisualTheme.ultraviolet),
        style: VisualTheme.ultraviolet,
        onThemeChanged: (_) {},
      ),
    ),
  );
  await tester.tap(find.byTooltip('Create room'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, 'Created group');
  await tester.pump();
  await tester.tap(find.text('Create'));
  await tester.pumpAndSettle();
}

class _ListeningBackend extends FakeBackend {
  bool get hasActiveListeners => hasListeners;
}

class _DelayedBackend extends _ListeningBackend {
  int creates = 0;
  @override
  Future<String> createRoom(String name, {required bool encrypted}) async {
    creates++;
    return createdId;
  }
}

class _Database extends Fake implements matrix.DatabaseApi {}

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super('room-creation', database: _Database(), httpClient: transport) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
  }
  bool cryptoAvailable = true;
  String currentUser = '@me:matrix.example';
  String currentDevice = 'DEVICE';
  @override
  String get userID => currentUser;
  @override
  String get deviceID => currentDevice;
  @override
  bool get encryptionEnabled => cryptoAvailable;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

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
import 'package:matrixpress/room_creation_request.dart';

import 'widget_test.dart' show FakeBackend;

const createdId = '!created:example.org';
const createdRoom = ChatRoom(
  id: createdId,
  name: 'Created group',
  preview: '',
  lastActivity: null,
);

void main() {
  testWidgets(
    'unavailable default encryption releases admission for corrected unencrypted create',
    (tester) async {
      var posts = 0;
      final client = _Client(
        MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/_matrix/client/v3/createRoom');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['name'], 'Corrected group');
          expect(body['initial_state'] ?? [], isEmpty);
          posts++;
          return http.Response(jsonEncode({'room_id': createdId}), 200);
        }),
      )..cryptoAvailable = false;
      final sdkBackend = MatrixBackend.withClient(client);
      addTearDown(sdkBackend.dispose);
      final backend = _SdkCreationBackend(sdkBackend);
      await _startCreation(tester, backend);
      expect(posts, 0);
      expect(find.text('Room not created'), findsOneWidget);
      expect(find.textContaining('Encryption is unavailable'), findsOneWidget);
      expect(find.text('Room creation not confirmed'), findsNothing);
      expect(_createButton(tester).onPressed, isNotNull);
      final creation = RoomCreationRequest.forBackend(backend);
      expect(creation.active, isFalse);
      expect(creation.originalRequest, isNull);
      expect(creation.uncertain, isFalse);
      expect(creation.failure?.kind, RoomCreationFailureKind.notSubmitted);
      await _submitCreation(tester, name: 'Corrected group', encrypted: false);
      await _settleSdkCreation(tester, backend);
      expect(RoomCreationRequest.forBackend(backend), same(creation));
      expect(posts, 1);
      expect(find.text('Room not created'), findsNothing);
      expect(find.text(createdId), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit Matrix rejection permits a corrected same-session create',
    (tester) async {
      var posts = 0;
      final sdkBackend = MatrixBackend.withClient(
        _Client(
          MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/_matrix/client/v3/createRoom');
            posts++;
            if (posts == 1) {
              return http.Response(
                jsonEncode({
                  'errcode': 'M_FORBIDDEN',
                  'error': 'Server details must not be displayed',
                }),
                403,
              );
            }
            expect(
              (jsonDecode(request.body) as Map)['name'],
              'Corrected group',
            );
            return http.Response(jsonEncode({'room_id': createdId}), 200);
          }),
        ),
      );
      addTearDown(sdkBackend.dispose);
      final backend = _SdkCreationBackend(sdkBackend);
      await _startCreation(tester, backend);
      expect(posts, 1);
      await _settleSdkCreation(tester, backend);
      expect(find.text('Room not created'), findsOneWidget);
      expect(find.textContaining('server rejected'), findsOneWidget);
      expect(find.textContaining('Server details'), findsNothing);
      expect(_createButton(tester).onPressed, isNotNull);
      final creation = RoomCreationRequest.forBackend(backend);
      expect(creation.originalRequest, isNull);
      expect(creation.uncertain, isFalse);
      expect(creation.failure?.kind, RoomCreationFailureKind.rejected);
      await _submitCreation(tester, name: 'Corrected group');
      await _settleSdkCreation(tester, backend);
      expect(RoomCreationRequest.forBackend(backend), same(creation));
      expect(posts, 2);
      expect(find.text(createdId), findsOneWidget);
      expect(find.text('Room not created'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unknown server failure retains the original uncertain request', (
    tester,
  ) async {
    var posts = 0;
    final sdkBackend = MatrixBackend.withClient(
      _Client(
        MockClient((_) async {
          posts++;
          return http.Response(
            jsonEncode({'errcode': 'M_UNKNOWN', 'error': 'failed'}),
            500,
          );
        }),
      ),
    );
    addTearDown(sdkBackend.dispose);
    final backend = _SdkCreationBackend(sdkBackend);
    await _startCreation(tester, backend);
    final creation = RoomCreationRequest.forBackend(backend);
    final original = creation.originalRequest;
    expect(original, isNotNull);
    await _settleSdkCreation(tester, backend);
    expect(creation.active, isTrue);
    expect(creation.uncertain, isTrue);
    expect(find.text('Room creation not confirmed'), findsOneWidget);
    expect(find.text('Room not created'), findsNothing);
    creation.start('Do not resend', encrypted: false);
    await tester.pumpAndSettle();
    expect(creation.originalRequest, same(original));
    expect(_createButton(tester).onPressed, isNull);
    expect(posts, 1);
    expect(tester.takeException(), isNull);
  });

  test(
    'SDK held headers outlive a zero body timeout and acknowledge late',
    () async {
      final transport = _HeldHeadersTransport();
      final backend = MatrixBackend.withClient(
        _Client(transport, timeout: Duration.zero),
      );
      addTearDown(backend.dispose);
      addTearDown(transport.acknowledge);
      var settled = false;
      final request = backend.createRoom('Name', encrypted: false);
      final observed = request.then((id) {
        settled = true;
        return id;
      });
      await transport.started.future;
      // Allow zero-duration timers to fire, without a wall-clock sleep. The SDK's
      // body timeout cannot begin until send() supplies the response headers.
      await Future<void>(() {});
      expect(settled, isFalse);
      expect(transport.creates, 1);
      transport.acknowledge();
      expect(await observed.timeout(const Duration(seconds: 1)), createdId);
      expect(transport.creates, 1);
    },
  );

  testWidgets(
    'held acknowledgement becomes visibly uncertain and late acknowledgement uses one POST',
    (tester) async {
      final backend = _HeldAcknowledgementBackend();
      addTearDown(backend.transport.acknowledge);
      await _startCreation(tester, backend);
      expect(backend.transport.creates, 1);
      final creation = RoomCreationRequest.forBackend(backend);
      final original = creation.originalRequest;
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(creation.originalRequest, same(original));
      expect(find.text('Room creation not confirmed'), findsOneWidget);
      expect(_createButton(tester).onPressed, isNull);
      expect(backend.activeRoomId, isNull);
      backend.transport.acknowledge();
      await tester.pumpAndSettle();
      expect(find.text(createdId), findsOneWidget);
      backend.roomList.add(createdRoom);
      backend.notifyListeners();
      await tester.pumpAndSettle();
      expect(backend.activeRoomId, createdId);
      expect(backend.transport.creates, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending headers survive route disposal without duplicate create',
    (tester) async {
      final backend = _HeldAcknowledgementBackend();
      addTearDown(backend.transport.acknowledge);
      await _startCreation(tester, backend);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      backend.transport.acknowledge();
      await tester.pump();
      expect(backend.activeRoomId, isNull);
      await _mountInbox(tester, backend);
      await tester.pumpAndSettle();
      expect(find.text(createdId), findsOneWidget);
      expect(_createButton(tester).onPressed, isNull);
      backend.roomList.add(createdRoom);
      backend.notifyListeners();
      await tester.pumpAndSettle();
      expect(backend.activeRoomId, createdId);
      expect(backend.transport.creates, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['account replacement', 'same-account logout/login']) {
    testWidgets('late headers are ignored after $change', (tester) async {
      final backend = _HeldAcknowledgementBackend()
        ..currentUserId = '@alice:example.org';
      addTearDown(backend.transport.acknowledge);
      await _startCreation(tester, backend);
      await tester.pump(const Duration(seconds: 11));
      if (change == 'account replacement') {
        backend.currentUserId = '@bob:example.org';
        backend.notifyListeners();
      } else {
        backend.status = SessionStatus.signedOut;
        backend.notifyListeners();
        backend.status = SessionStatus.ready;
        backend.notifyListeners();
      }
      backend.transport.acknowledge();
      backend.roomList.add(createdRoom);
      backend.notifyListeners();
      await tester.pumpAndSettle();
      expect(backend.activeRoomId, isNull);
      expect(find.text(createdId), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ambiguous transport failure never enables another POST', (
    tester,
  ) async {
    final backend = _HeldAcknowledgementBackend();
    await _startCreation(tester, backend);
    final creation = RoomCreationRequest.forBackend(backend);
    final original = creation.originalRequest;
    backend.transport.headers.completeError(StateError('connection lost'));
    await tester.pumpAndSettle();
    expect(creation.originalRequest, same(original));
    expect(creation.failure, isNull);
    creation.start('Do not resend', encrypted: false);
    expect(find.text('Room creation not confirmed'), findsOneWidget);
    expect(_createButton(tester).onPressed, isNull);
    expect(backend.transport.creates, 1);
    expect(tester.takeException(), isNull);
  });

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
      final notSubmitted = throwsA(
        isA<RoomCreationFailure>().having(
          (failure) => failure.kind,
          'kind',
          RoomCreationFailureKind.notSubmitted,
        ),
      );
      await expectLater(
        backend.createRoom('Name', encrypted: true),
        notSubmitted,
      );
      await expectLater(
        backend.createRoom(' ', encrypted: false),
        notSubmitted,
      );
      await expectLater(
        backend.createRoom('a' * 256, encrypted: false),
        notSubmitted,
      );
      client.accessToken = null;
      await expectLater(
        backend.createRoom('Name', encrypted: false),
        notSubmitted,
      );
      final missingClient = MatrixBackend();
      addTearDown(missingClient.dispose);
      await expectLater(
        missingClient.createRoom('Name', encrypted: false),
        notSubmitted,
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

  testWidgets('post-create session StateError does not prove non-creation', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    var posts = 0;
    final client = _Client(
      MockClient((_) {
        posts++;
        return response.future;
      }),
    );
    final sdkBackend = MatrixBackend.withClient(client);
    addTearDown(sdkBackend.dispose);
    final backend = _SdkCreationBackend(sdkBackend);
    await _startCreation(tester, backend);
    final creation = RoomCreationRequest.forBackend(backend);
    final original = creation.originalRequest;
    client.currentDevice = 'OTHER';
    response.complete(http.Response(jsonEncode({'room_id': createdId}), 200));
    await _settleSdkCreation(tester, backend);
    expect(creation.originalRequest, same(original));
    expect(creation.active, isTrue);
    expect(creation.uncertain, isTrue);
    expect(creation.failure, isNull);
    expect(find.text('Room creation not confirmed'), findsOneWidget);
    expect(_createButton(tester).onPressed, isNull);
    creation.start('Do not resend', encrypted: false);
    expect(posts, 1);
    expect(tester.takeException(), isNull);
  });

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
    // Only the session-owned create record remains, not the route/sync wait.
    expect(backend.listenerCount, 1);
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

Future<void> _settleSdkCreation(
  WidgetTester tester,
  ChatBackend backend,
) async {
  final original = RoomCreationRequest.forBackend(backend).originalRequest;
  var settled = original == null;
  original?.then<void>(
    (_) => settled = true,
    onError: (Object _, StackTrace _) => settled = true,
  );
  // Drain both real stream events and the widget scheduler without sleeps.
  for (var i = 0; i < 20 && !settled; i++) {
    await tester.runAsync(() => Future<void>(() {}));
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(settled, isTrue);
  await tester.pumpAndSettle();
}

Future<void> _startCreation(WidgetTester tester, ChatBackend backend) async {
  await _mountInbox(tester, backend);
  await _submitCreation(tester);
}

Future<void> _submitCreation(
  WidgetTester tester, {
  String name = 'Created group',
  bool encrypted = true,
}) async {
  await tester.tap(find.byTooltip('Create room'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, name);
  if (!encrypted) await tester.tap(find.text('Encrypted room'));
  await tester.pump();
  await tester.tap(find.text('Create'));
  await tester.pumpAndSettle();
}

IconButton _createButton(WidgetTester tester) => tester.widget<IconButton>(
  find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == 'Create room',
  ),
);

Future<void> _mountInbox(WidgetTester tester, ChatBackend backend) async {
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
}

class _ListeningBackend extends FakeBackend {
  bool get hasActiveListeners => hasListeners;
  int listenerCount = 0;
  @override
  void addListener(VoidCallback listener) {
    listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listenerCount--;
    super.removeListener(listener);
  }
}

// Keep inbox sync presentation ready while exercising the real SDK create path.
class _SdkCreationBackend extends _ListeningBackend {
  _SdkCreationBackend(this.sdkBackend);
  final MatrixBackend sdkBackend;
  @override
  Future<String> createRoom(String name, {required bool encrypted}) =>
      sdkBackend.createRoom(name, encrypted: encrypted);
}

class _HeldAcknowledgementBackend extends _ListeningBackend {
  final transport = _HeldAcknowledgement();
  SessionStatus status = SessionStatus.ready;
  @override
  SessionStatus get connection => status;
  @override
  Future<String> createRoom(String name, {required bool encrypted}) {
    transport.creates++;
    return transport.headers.future;
  }
}

class _HeldAcknowledgement {
  final headers = Completer<String>();
  int creates = 0;
  void acknowledge() {
    if (!headers.isCompleted) headers.complete(createdId);
  }
}

class _HeldHeadersTransport extends http.BaseClient {
  final headers = Completer<http.StreamedResponse>();
  final started = Completer<void>();
  int creates = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    expect(request.url.path, '/_matrix/client/v3/createRoom');
    creates++;
    started.complete();
    return headers.future; // No headers: SDK body-stream timeout cannot start.
  }

  void acknowledge() {
    if (!headers.isCompleted) {
      headers.complete(
        http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'room_id': createdId}))),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
    }
  }
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
  _Client(
    http.Client transport, {
    Duration timeout = const Duration(seconds: 35),
  }) : super(
         'room-creation',
         database: _Database(),
         httpClient: transport,
         defaultNetworkRequestTimeout: timeout,
       ) {
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

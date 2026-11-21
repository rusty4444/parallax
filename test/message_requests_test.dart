import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/message_requests/message_requests.dart';
import 'package:parallax/features/message_requests/message_requests_screen.dart';
import 'package:parallax/features/rooms_admin/rooms_admin_features.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBackend extends ChatBackend implements RoomsAdminFeatures {
  _FakeBackend(this._rooms, this._userId, this.inviters);
  final List<ChatRoom> _rooms;
  final String? _userId;
  final Map<String, String> inviters;

  @override
  List<ChatRoom> get rooms => _rooms;
  @override
  String? get userId => _userId;
  @override
  SessionStatus get connection => SessionStatus.ready;
  @override
  String? inviterOf(String roomId) => inviters[roomId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatRoom _room(String id, {required bool invited, bool direct = false}) =>
    ChatRoom(
      id: id,
      name: 'Room $id',
      preview: 'hi',
      lastActivity: DateTime(2026, 11, 21),
      invited: invited,
      isDirect: direct,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('classifies unknown-sender invites as requests', () {
    final backend = _FakeBackend(
      [
        _room('!joined:example.org', invited: false),
        _room('!request:example.org', invited: true, direct: true),
        _room('!noinviter:example.org', invited: true),
      ],
      '@me:example.org',
      {'!request:example.org': '@stranger:example.org'},
    );
    final controller = MessageRequestsController()..bindBackend(backend);
    expect(controller.isRequest(backend.rooms[0]), isFalse); // joined
    expect(controller.isRequest(backend.rooms[1]), isTrue); // unknown inviter
    expect(controller.isRequest(backend.rooms[2]), isFalse); // no inviter info
    expect(controller.requestIds(backend.rooms), {'!request:example.org'});
  });

  test('separation preference defaults on and persists', () async {
    final controller = MessageRequestsController();
    await controller.load();
    expect(controller.separate, isTrue);
    await controller.setSeparate(false);
    expect(controller.separate, isFalse);
    final reopened = MessageRequestsController();
    await reopened.load();
    expect(reopened.separate, isFalse);
  });

  testWidgets('requests screen lists requests with safe actions', (
    tester,
  ) async {
    final backend = _FakeBackend(
      [_room('!request:example.org', invited: true, direct: true)],
      '@me:example.org',
      {'!request:example.org': '@stranger:example.org'},
    );
    final controller = MessageRequestsController()..bindBackend(backend);
    await tester.pumpWidget(
      MaterialApp(
        home: MessageRequestsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Message requests'), findsOneWidget);
    expect(find.text('Invited you to chat'), findsOneWidget);
    expect(find.text('From an unknown sender'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('request-accept-!request:example.org')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('request-decline-!request:example.org')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('request-block-!request:example.org')),
      findsOneWidget,
    );
    // The inviter's Matrix ID is hidden until revealed.
    expect(find.textContaining('@stranger'), findsNothing);
  });

  testWidgets('requests screen shows an empty state', (tester) async {
    final backend = _FakeBackend([], '@me:example.org', {});
    final controller = MessageRequestsController()..bindBackend(backend);
    await tester.pumpWidget(
      MaterialApp(
        home: MessageRequestsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('No message requests'), findsOneWidget);
  });
}

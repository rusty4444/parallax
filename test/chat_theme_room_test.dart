import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/appearance/bubble_colours.dart';
import 'package:parallax/room_events.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/timeline_kinds.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scheduled_fakes.dart'
    show RecordingTransport, ScheduledDatabase, jsonResponse;
import 'widget_test.dart' show FakeBackend, FakeBackgroundStore;

const _roomId = '!r:example.org';
final _palette = paletteFor(VisualTheme.parallax);

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super(
        'room-theme',
        database: ScheduledDatabase(),
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://example.org');
    accessToken = 'token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }

  @override
  String? get userID => '@me:example.org';
  @override
  String? get deviceID => 'DEVICE';
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _ThemeBackend extends FakeBackend
    implements MatrixSdkAccess, RoomEventFeatures {
  _ThemeBackend(this.client);
  final matrix.Client client;
  final sent = <Map<String, Object?>>[];

  @override
  matrix.Client? get sdkClient => client;
  @override
  bool isSessionCurrent(matrix.Client client) => identical(client, this.client);

  @override
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    expect(type, chatThemeEventType);
    sent.add(jsonDecode(jsonEncode(content)) as Map<String, Object?>);
    return '\$sent${sent.length}';
  }

  @override
  Future<void> setRoomState(
    String roomId,
    String type,
    Map<String, Object?> content, {
    String stateKey = '',
  }) async {}

  @override
  Future<Map<String, Object?>?> roomState(
    String roomId,
    String type, {
    String stateKey = '',
  }) async => null;

  @override
  Future<void> redactEvent(
    String roomId,
    String eventId, {
    String? reason,
  }) async {}
}

ChatEntry _entry(String id, String body, {required bool mine}) => ChatEntry(
  id: id,
  sender: mine ? '@me:example.org' : '@friend:example.org',
  senderName: mine ? null : 'Friend',
  body: body,
  time: DateTime(2026, 1, 1, 10, mine ? 1 : 0),
  mine: mine,
);

Color? _bubbleColour(WidgetTester tester, String text) {
  final box = tester.widget<DecoratedBox>(
    find
        .ancestor(of: find.text(text), matching: find.byType(DecoratedBox))
        .first,
  );
  return (box.decoration as BoxDecoration).color;
}

void main() {
  testWidgets('sharing colours makes them the chat theme, and a newer theme '
      'from someone else shows', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = RoomBubbleColourStore(preferences: prefs);
    await store.save(_roomId, const BubbleColours(mine: Color(0xFF0A7CFF)));
    final client = _Client(
      RecordingTransport((request) async {
        if (request.url.path.contains('/relations/')) {
          return jsonResponse({'chunk': []});
        }
        if (request.method == 'PUT') return jsonResponse({});
        return jsonResponse({'errcode': 'M_NOT_FOUND', 'error': 'x'}, 404);
      }),
    );
    final room = matrix.Room(
      id: _roomId,
      client: client,
      membership: matrix.Membership.join,
    );
    room.setState(
      matrix.Event.fromJson({
        'type': matrix.EventTypes.RoomCreate,
        'state_key': '',
        'event_id': r'$create',
        'sender': '@me:example.org',
        'origin_server_ts': 1,
        'content': {},
      }, room),
    );
    client.rooms.add(room);
    final backend = _ThemeBackend(client)
      ..entries = [
        _entry('theirs', 'Their message', mine: false),
        _entry('mine', 'My message', mine: true),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: _palette,
          roomId: _roomId,
          backgroundStore: FakeBackgroundStore(),
          bubbleColourStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_bubbleColour(tester, 'My message'), const Color(0xFF0A7CFF));

    await tester.tap(find.byTooltip('Room background'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat theme for everyone…'));
    await tester.pumpAndSettle();
    expect(find.text('Share my bubble colours'), findsOneWidget);
    expect(find.text('Remove the chat theme'), findsNothing);
    await tester.tap(find.text('Share my bubble colours'));
    await tester.pumpAndSettle();

    expect(backend.sent.single['change'], 'colours');
    expect(backend.sent.single['bubbleColours'], {'mine': '#0A7CFF'});
    expect(backend.sent.single['m.relates_to'], {
      'rel_type': chatThemeEventType,
      'event_id': r'$create',
    });
    // Your own copy became the chat theme; the bubbles look the same.
    expect(store.cached(_roomId), BubbleColours.none);
    expect(_bubbleColour(tester, 'My message'), const Color(0xFF0A7CFF));

    // Someone else changes the chat theme later.
    client.onTimelineEvent.add(
      matrix.Event.fromJson({
        'type': chatThemeEventType,
        'event_id': r'$theirs',
        'sender': '@friend:example.org',
        'origin_server_ts': DateTime.now().millisecondsSinceEpoch + 60000,
        'room_id': _roomId,
        'content': {
          'version': 1,
          'change': 'colours',
          'bubbleColours': {'mine': '#27AE60'},
        },
      }, room),
    );
    await tester.pumpAndSettle();
    expect(_bubbleColour(tester, 'My message'), const Color(0xFF27AE60));

    // Your own colours for the chat still win over the chat theme.
    await store.save(_roomId, const BubbleColours(mine: Color(0xFFAA0000)));
    await tester.pumpAndSettle();
    expect(_bubbleColour(tester, 'My message'), const Color(0xFFAA0000));

    // Leave no timers behind (double-tap arena, debounces).
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('"Background on this device only" is a checkbox', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final client = _Client(
      RecordingTransport((request) async {
        if (request.url.path.contains('/relations/')) {
          return jsonResponse({'chunk': []});
        }
        if (request.method == 'PUT') return jsonResponse({});
        return jsonResponse({'errcode': 'M_NOT_FOUND', 'error': 'x'}, 404);
      }),
    );
    client.rooms.add(
      matrix.Room(
        id: _roomId,
        client: client,
        membership: matrix.Membership.join,
      ),
    );
    final backend = _ThemeBackend(client)
      ..entries = [_entry('mine', 'My message', mine: true)];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: _palette,
          roomId: _roomId,
          backgroundStore: FakeBackgroundStore(),
          bubbleColourStore: RoomBubbleColourStore(preferences: prefs),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Checkbox box() => tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(const ValueKey('room-background-device-only')),
        matching: find.byType(Checkbox),
      ),
    );

    await tester.tap(find.byTooltip('Room background'));
    await tester.pumpAndSettle();
    expect(box().value, isFalse);
    await tester.tap(find.text('Background on this device only'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Room background'));
    await tester.pumpAndSettle();
    expect(box().value, isTrue);
    await tester.tapAt(const Offset(5, 5)); // close the menu
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/call/active_call.dart';
import 'package:parallax/features/call/call_features.dart';
import 'package:parallax/features/call/call_hooks.dart';
import 'package:parallax/features/call/call_memberships.dart';
import 'package:parallax/features/call/call_ringer.dart';
import 'package:parallax/features/call/call_screen.dart';
import 'package:parallax/features/call/call_settings_section.dart';
import 'package:parallax/features/call/call_settings_store.dart';
import 'package:parallax/features/call/call_ui.dart';
import 'package:parallax/features/call/call_web_host.dart';
import 'package:parallax/features/call/incoming_call_overlay.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_test_fakes.dart';

final _palette = paletteFor(VisualTheme.parallax);

const _active = RoomCallSummary(
  participants: ['@alice:example.org', '@bob:example.org'],
  devices: 2,
);

Widget _app(Widget child) => MaterialApp(
  theme: themeFor(VisualTheme.parallax),
  home: Scaffold(body: Center(child: child)),
);

class _PlainBackend extends ChatBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ringer implements CallRinger {
  int starts = 0;
  int stops = 0;
  @override
  Future<void> start() async => starts++;
  @override
  Future<void> stop() async => stops++;
}

class _KeepAwake implements CallScreenKeepAwake {
  final values = <bool>[];
  @override
  Future<void> set(bool enabled) async => values.add(enabled);
}

void main() {
  tearDown(() => ActiveCall.roomId.value = null);

  group('timeline', () {
    Widget body(
      FakeCallBackend backend,
      String type,
      Map<String, Object?> content, {
      DateTime? time,
    }) => _app(
      CallTimelineBody(
        eventType: type,
        content: content,
        time: time ?? DateTime.now(),
        mine: false,
        palette: _palette,
        textColor: _palette.foreground,
        backend: backend,
        roomId: testRoom,
        features: backend,
      ),
    );

    testWidgets('legacy m.call.invite is an unsupported call', (tester) async {
      await tester.pumpWidget(body(FakeCallBackend(), 'm.call.invite', {}));
      expect(find.text('Unsupported call'), findsOneWidget);
      expect(find.textContaining('Element Call'), findsOneWidget);
    });

    testWidgets('call notification offers Join while the call is live', (
      tester,
    ) async {
      final backend = FakeCallBackend()..summary = _active;
      await tester.pumpWidget(
        body(backend, 'org.matrix.msc4075.rtc.notification', {
          'notification_type': 'notification',
        }),
      );
      expect(find.text('Call started'), findsOneWidget);
      expect(find.text('Video call'), findsOneWidget);
      expect(find.text('Join · 2 people in the call'), findsOneWidget);

      backend.summary = RoomCallSummary.none;
      backend.changes.add(testRoom);
      await tester.pump();
      expect(find.textContaining('Join'), findsNothing);
    });

    testWidgets('a live ring shows Ringing, then Call started', (tester) async {
      final backend = FakeCallBackend();
      final now = DateTime.now();
      await tester.pumpWidget(
        body(backend, 'org.matrix.msc4075.rtc.notification', {
          'notification_type': 'ring',
          'sender_ts': now.millisecondsSinceEpoch,
          'lifetime': 300,
          'm.call.intent': 'audio',
        }, time: now),
      );
      expect(find.text('Ringing…'), findsOneWidget);
      expect(find.text('Voice call'), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Call started'), findsOneWidget);
    });
  });

  group('room header and banner', () {
    testWidgets('banner appears only for a live call', (tester) async {
      final backend = FakeCallBackend();
      await tester.pumpWidget(
        _app(
          OngoingCallBanner(
            features: backend,
            backend: backend,
            roomId: testRoom,
            palette: _palette,
          ),
        ),
      );
      expect(find.text('Group call in progress'), findsNothing);
      backend.summary = _active;
      backend.changes
        ..add('!other:example.org')
        ..add(testRoom);
      await tester.pump();
      expect(find.text('Group call in progress'), findsOneWidget);
      expect(find.text('2 people in the call'), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);
    });

    testWidgets('header button starts or joins and respects permission', (
      tester,
    ) async {
      final backend = FakeCallBackend();
      Widget button() => _app(
        CallHeaderButton(
          features: backend,
          backend: backend,
          roomId: testRoom,
          palette: _palette,
        ),
      );
      await tester.pumpWidget(button());
      expect(find.byTooltip('Start a call'), findsOneWidget);
      backend.summary = _active;
      backend.changes.add(testRoom);
      await tester.pump();
      expect(find.byTooltip('Join call'), findsOneWidget);

      backend.joinAllowed = false;
      backend.changes.add(testRoom);
      // Stream delivery and the rebuild can straddle one frame.
      await tester.pump();
      await tester.pump();
      final icon = tester.widget<IconButton>(find.byType(IconButton));
      expect(icon.onPressed, isNull);
    });

    testWidgets('hooks stay empty for backends without call support', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final plain = RoomHookContext(
        backend: _PlainBackend(),
        roomId: testRoom,
        palette: _palette,
      );
      expect(callRoomHeaderActions(context, plain), isEmpty);
      expect(callRoomBanners(context, plain), isEmpty);
      expect(
        callSettingsSections(
          context,
          SettingsHookContext(backend: _PlainBackend(), palette: _palette),
        ),
        isEmpty,
      );
      final supported = RoomHookContext(
        backend: FakeCallBackend(),
        roomId: testRoom,
        palette: _palette,
      );
      expect(callRoomHeaderActions(context, supported), hasLength(1));
      final text = EntryHookContext(
        backend: FakeCallBackend(),
        roomId: testRoom,
        palette: _palette,
        entry: ChatEntry(
          id: r'$t',
          sender: '@a:x',
          body: 'hello',
          time: DateTime(2026),
          mine: false,
        ),
      );
      expect(callEntryBody(context, text), isNull);
    });
  });

  group('call screen', () {
    FakeWebHost? host;
    CallWebHost factory({
      required Uri page,
      required Color background,
      required bool allowCamera,
      required bool allowMicrophone,
      required void Function(String) onMessage,
      required void Function(String) onLoadError,
      required void Function() onPageFinished,
    }) => host = FakeWebHost(
      page: page,
      allowCamera: allowCamera,
      allowMicrophone: allowMicrophone,
      onMessage: onMessage,
      onLoadError: onLoadError,
      onPageFinished: onPageFinished,
    );

    Future<void> open(
      WidgetTester tester,
      FakeCallBackend backend, {
      FakePermissions permissions = const FakePermissions(),
      _KeepAwake? keepAwake,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CallScreen(
                      backend: backend,
                      roomId: testRoom,
                      palette: _palette,
                      permissions: permissions,
                      webHostFactory: factory,
                      keepAwake: keepAwake ?? _KeepAwake(),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    setUp(() => host = null);

    testWidgets('refuses to start without microphone permission', (
      tester,
    ) async {
      final backend = FakeCallBackend();
      await open(
        tester,
        backend,
        permissions: const FakePermissions(microphone: false),
      );
      expect(find.text('Call unavailable'), findsOneWidget);
      expect(find.textContaining('microphone access'), findsOneWidget);
      expect(backend.prepared, isEmpty);
      expect(host, isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(ActiveCall.inCall, isFalse);
    });

    testWidgets('loads Element Call and relays the widget API', (tester) async {
      final backend = FakeCallBackend();
      final keepAwake = _KeepAwake();
      await open(
        tester,
        backend,
        permissions: const FakePermissions(camera: false),
        keepAwake: keepAwake,
      );
      expect(backend.prepared, [testRoom]);
      expect(ActiveCall.roomId.value, testRoom);
      expect(keepAwake.values, [true]);
      final web = host!;
      expect(web.allowMicrophone, isTrue);
      expect(web.allowCamera, isFalse);
      expect(web.loads.single.host, 'call.element.io');
      expect(find.text('Connecting to Element Call…'), findsOneWidget);
      expect(find.textContaining('Camera access is off'), findsOneWidget);

      web.onPageFinished();
      await tester.pump();
      expect(find.text('webview'), findsOneWidget);
      expect(find.text('Connecting to Element Call…'), findsNothing);

      web.onMessage(
        jsonEncode({
          'api': 'fromWidget',
          'widgetId': 'widget-1',
          'requestId': 'r1',
          'action': 'content_loaded',
          'data': <String, Object?>{},
        }),
      );
      await tester.pump();
      final posted = web.posted.map(jsonDecode).toList();
      expect(
        posted.any((m) => m['requestId'] == 'r1' && m['response'] != null),
        isTrue,
      );
      expect(posted.any((m) => m['action'] == 'capabilities'), isTrue);

      web.onMessage(
        jsonEncode({
          'api': 'fromWidget',
          'widgetId': 'widget-1',
          'requestId': 'r2',
          'action': 'io.element.close',
          'data': <String, Object?>{},
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(web.disposed, isTrue);
      expect(backend.matrix.disposed, isTrue);
      expect(ActiveCall.inCall, isFalse);
      expect(keepAwake.values, [true, false]);
    });

    testWidgets('signing out closes the call', (tester) async {
      final backend = FakeCallBackend();
      await open(tester, backend);
      expect(host, isNotNull);
      backend.signOut();
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(host!.disposed, isTrue);
    });

    testWidgets('a second call is refused while one is open', (tester) async {
      ActiveCall.enter('!other:example.org');
      final backend = FakeCallBackend();
      await open(tester, backend);
      expect(find.textContaining('already in another call'), findsOneWidget);
      expect(backend.prepared, isEmpty);
    });
  });

  group('incoming call overlay', () {
    final now = DateTime(2026, 11, 12, 10);
    IncomingCall ring({String event = r'$ring'}) => IncomingCall(
      roomId: testRoom,
      eventId: event,
      senderId: '@alice:example.org',
      senderName: 'Alice',
      roomName: 'Alice',
      expiresAt: now.add(const Duration(seconds: 30)),
    );

    Future<_Ringer> mount(
      WidgetTester tester,
      FakeCallBackend backend, {
      List<IncomingCall>? answered,
    }) async {
      final ringer = _Ringer();
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          builder: (context, child) => IncomingCallOverlay(
            backend: backend,
            palette: _palette,
            navigatorKey: GlobalKey<NavigatorState>(),
            ringer: ringer,
            clock: () => now,
            onAnswer: answered?.add,
            child: child!,
          ),
          home: const Scaffold(body: Text('inbox')),
        ),
      );
      return ringer;
    }

    testWidgets('rings, and decline sends an RTC decline', (tester) async {
      final backend = FakeCallBackend();
      final ringer = await mount(tester, backend);
      backend.rings.add(ring());
      await tester.pump();
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Incoming Element Call'), findsOneWidget);
      expect(ringer.starts, 1);

      await tester.tap(find.text('Decline'));
      await tester.pump();
      expect(find.text('Answer'), findsNothing);
      expect(backend.declines, [(testRoom, r'$ring')]);
      expect(ringer.stops, greaterThanOrEqualTo(1));
    });

    testWidgets('answer hands the call over and stops ringing', (tester) async {
      final backend = FakeCallBackend();
      final answered = <IncomingCall>[];
      final ringer = await mount(tester, backend, answered: answered);
      backend.rings.add(ring());
      await tester.pump();
      await tester.tap(find.text('Answer'));
      await tester.pump();
      expect(answered.single.eventId, r'$ring');
      expect(find.text('Decline'), findsNothing);
      expect(ringer.stops, greaterThanOrEqualTo(1));
      expect(backend.declines, isEmpty);
    });

    testWidgets('ring expires, and stops when answered elsewhere', (
      tester,
    ) async {
      final backend = FakeCallBackend();
      await mount(tester, backend);
      backend.rings.add(ring());
      await tester.pump();
      expect(find.text('Answer'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      expect(find.text('Answer'), findsNothing);

      backend.rings.add(ring(event: r'$second'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Answer'), findsOneWidget);
      backend.summary = const RoomCallSummary(
        participants: ['@alice:example.org', testUser],
        includesMe: true,
      );
      backend.changes.add(testRoom);
      await tester.pump();
      await tester.pump();
      expect(find.text('Answer'), findsNothing);
    });

    testWidgets('no ring while already in a call', (tester) async {
      final backend = FakeCallBackend();
      final ringer = await mount(tester, backend);
      ActiveCall.enter('!other:example.org');
      backend.rings.add(ring());
      await tester.pump();
      expect(find.text('Answer'), findsNothing);
      expect(ringer.starts, 0);
    });
  });

  testWidgets('settings section validates and saves the Element Call URL', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = CallSettingsStore();
    final backend = FakeCallBackend();
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CallSettingsSection(
              features: backend,
              palette: _palette,
              store: store,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Using call.element.io (default)'), findsOneWidget);
    expect(
      find.textContaining('doesn’t advertise a MatrixRTC'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'http://call.example.org');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('https://'), findsWidgets);
    expect(store.customBaseUrl, isNull);

    await tester.enterText(find.byType(TextField), 'https://call.example.org');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.customBaseUrl, Uri.parse('https://call.example.org'));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(CallSettingsStore.customUrlKey),
      'https://call.example.org',
    );

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(store.customBaseUrl, isNull);
  });

  test('ring tone is a valid PCM WAV', () {
    final wav = ringToneWav();
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(wav.length, 44 + 3 * 8000 * 2);
  });

  test('callFeaturesOf resolves fakes and rejects plain backends', () {
    final fake = FakeCallBackend();
    expect(callFeaturesOf(fake), same(fake));
    expect(callFeaturesOf(_PlainBackend()), isNull);
  });
}

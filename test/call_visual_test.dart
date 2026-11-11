// Visual QA for the call module. Skipped unless PARALLAX_SCREENSHOT_DIR is
// set:  PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/call_visual_test.dart
// Not a golden test: nothing is asserted on pixels.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/call/call_features.dart';
import 'package:parallax/features/call/call_memberships.dart';
import 'package:parallax/features/call/call_settings_section.dart';
import 'package:parallax/features/call/call_settings_store.dart';
import 'package:parallax/features/call/incoming_call_overlay.dart';
import 'package:parallax/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_test_fakes.dart';
import 'widget_test.dart' show FakeBackend;

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];

/// The core visual fake plus call support.
class _CallRoomBackend extends FakeBackend implements CallFeatures {
  final _calls = FakeCallBackend()
    ..summary = RoomCallSummary(
      participants: const ['@mia:example.org', '@alex:example.org'],
      devices: 2,
      nextExpiry: DateTime.now().add(const Duration(hours: 1)),
    );

  @override
  RoomCallSummary roomCall(String roomId) => _calls.summary;
  @override
  Stream<String> get callChanges => _calls.callChanges;
  @override
  Stream<IncomingCall> get incomingCalls => _calls.incomingCalls;
  @override
  bool canJoinCall(String roomId) => true;
  @override
  Future<CallLaunch> prepareCall(String roomId, CallLaunchOptions options) =>
      _calls.prepareCall(roomId, options);
  @override
  Future<CallServiceInfo> callServiceInfo() async => CallServiceInfo(
    baseUrl: Uri.parse('https://call.element.io'),
    source: CallUrlSource.defaultUrl,
    rtcFocusHosts: const ['livekit-jwt.call.matrix.org'],
  );
  @override
  Future<void> declineCall(String roomId, String eventId) async {}
}

Future<void> _loadFonts() async {
  final grotesk = FontLoader('SpaceGrotesk')
    ..addFont(
      File(
        'assets/fonts/SpaceGrotesk.ttf',
      ).readAsBytes().then((b) => ByteData.sublistView(b)),
    );
  await grotesk.load();
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
  }
}

Future<void> _shoot(WidgetTester tester, String name, Widget child) async {
  final key = GlobalKey();
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(key: key, child: child));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  final skip = _dir == null;

  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });

  for (final style in [VisualTheme.parallax, VisualTheme.parallaxDay]) {
    final p = paletteFor(style);
    testWidgets('call room ${style.name}', skip: skip, (tester) async {
      final now = DateTime.now();
      final backend = _CallRoomBackend()
        ..currentUserId = '@sam:example.org'
        ..roomList = [
          ChatRoom(
            id: '!a:example.org',
            name: 'Weekend crew',
            preview: '',
            lastActivity: now,
            encrypted: true,
          ),
        ]
        ..entries = [
          ChatEntry(
            id: r'$3',
            sender: '@mia:example.org',
            senderName: 'Mia',
            body: 'Call started',
            time: now,
            mine: false,
            kind: EntryKind.call,
            eventType: 'org.matrix.msc4075.rtc.notification',
            content: const {'notification_type': 'notification'},
          ),
          ChatEntry(
            id: r'$2',
            sender: '@alex:example.org',
            senderName: 'Alex',
            body: 'Call',
            time: now.subtract(const Duration(minutes: 3)),
            mine: false,
            kind: EntryKind.call,
            eventType: 'm.call.invite',
          ),
          ChatEntry(
            id: r'$1',
            sender: '@sam:example.org',
            body: 'Jumping on a quick call?',
            time: now.subtract(const Duration(minutes: 9)),
            mine: true,
          ),
        ];
      await _shoot(
        tester,
        'call_room_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: RoomScreen(
            backend: backend,
            palette: p,
            roomId: '!a:example.org',
          ),
        ),
      );
    });

    testWidgets('incoming call ${style.name}', skip: skip, (tester) async {
      await _shoot(
        tester,
        'call_incoming_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: IncomingCallView(
            call: IncomingCall(
              roomId: testRoom,
              eventId: r'$ring',
              senderId: '@alex:example.org',
              senderName: 'Alex Rivera',
              roomName: 'Alex Rivera',
              expiresAt: DateTime.now().add(const Duration(seconds: 30)),
            ),
            palette: p,
            onAnswer: () {},
            onDecline: () {},
          ),
        ),
      );
    });

    testWidgets('call settings ${style.name}', skip: skip, (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _shoot(
        tester,
        'call_settings_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: CallSettingsSection(
                features: _CallRoomBackend(),
                palette: p,
                store: CallSettingsStore(),
              ),
            ),
          ),
        ),
      );
    });
  }
}

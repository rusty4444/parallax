// Visual QA for the scheduled module. Skipped unless PARALLAX_SCREENSHOT_DIR
// is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/scheduled_visual_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/scheduled/scheduled_features.dart';
import 'package:parallax/features/scheduled/scheduled_list.dart';
import 'package:parallax/features/scheduled/send_later_sheet.dart';
import 'package:parallax/features/scheduled/undo_send.dart';
import 'package:parallax/features/scheduled/undo_send_settings.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'messaging_integration_test.dart' show Drafts, FeaturesBackend;
import 'widget_test.dart' show FakeBackgroundStore;

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
const _roomId = '!r:example.org';
final _boundary = GlobalKey();

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

Future<void> _frame(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(key: _boundary, child: child));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

class _Backend extends FeaturesBackend
    implements ScheduledFeatures, UndoSendFeatures {
  final items = <ScheduledMessage>[];
  final deadlines = <String, DateTime>{};

  @override
  Listenable get scheduledUpdates => this;
  @override
  ScheduledLoadState get scheduledState => ScheduledLoadState.ready;
  @override
  bool get localRecordsUnavailable => false;
  @override
  List<ScheduledMessage> scheduledIn(String roomId) => [
    for (final item in items)
      if (item.roomId == roomId) item,
  ];
  @override
  void ensureScheduledLoaded() {}
  @override
  Future<void> refreshScheduled() async {}
  @override
  Future<DelayedEventsCapability> delayedEventsCapability({
    bool refresh = false,
  }) async => const DelayedEventsCapability(
    supported: true,
    maxDelay: Duration(days: 30),
  );
  @override
  Future<ScheduledMessage> scheduleDraft(
    String roomId,
    ComposerDraft draft,
    DateTime sendAt,
  ) => throw UnimplementedError();
  @override
  Future<void> sendScheduledNow(ScheduledMessage message) async {}
  @override
  Future<void> cancelScheduled(ScheduledMessage message) async {}
  @override
  Future<ScheduledMessage> rescheduleScheduled(
    ScheduledMessage message,
    DateTime sendAt,
  ) => throw UnimplementedError();
  @override
  DateTime? undoDeadline(String pendingId) => deadlines[pendingId];
  @override
  Future<UndoneSend?> undoSend(String pendingId) async => null;
}

_Backend _backend() {
  final now = DateTime.now();
  final backend = _Backend()
    ..roomList = [
      ChatRoom(
        id: _roomId,
        name: 'Weekend crew',
        preview: 'Sunset at the pier?',
        lastActivity: now,
        encrypted: true,
      ),
    ]
    ..entries = [
      ChatEntry(
        id: r'$1',
        sender: '@mia:example.org',
        senderName: 'Mia',
        body: 'Sunset at the pier on Saturday?',
        time: now.subtract(const Duration(minutes: 9)),
        mine: false,
      ),
    ]
    ..outbox = [
      PendingSend(
        id: 'tx-held',
        roomId: _roomId,
        body: 'Count me in, I’ll bring snacks',
        state: DeliveryState.queued,
        createdAt: now,
      ),
    ];
  backend.deadlines['tx-held'] = now.add(const Duration(seconds: 5));
  backend.items.addAll([
    ScheduledMessage(
      delayId: 'syd_a',
      roomId: _roomId,
      type: 'm.room.message',
      sendAt: DateTime(now.year, now.month, now.day + 1, 9),
      encrypted: true,
      content: const {
        'msgtype': 'm.text',
        'body': 'Morning all! Don’t forget sunscreen 🌞',
      },
    ),
    ScheduledMessage(
      delayId: 'syd_b',
      roomId: _roomId,
      type: 'm.room.message',
      sendAt: DateTime(now.year, now.month, now.day + 3, 18),
      encrypted: true,
      content: const {'msgtype': 'm.text', 'body': 'Who’s still keen?'},
    ),
  ]);
  return backend;
}

void main() {
  final skip = _dir == null ? 'Set PARALLAX_SCREENSHOT_DIR to render' : null;

  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final style in [VisualTheme.parallax, VisualTheme.parallaxDay]) {
    final p = paletteFor(style);

    testWidgets('room ${style.name}', skip: skip != null, (tester) async {
      final backend = _backend();
      await _frame(
        tester,
        FeatureSettingsScope(
          preferences: AppearancePreferences(),
          draftStore: Drafts(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(style),
            home: RoomScreen(
              backend: backend,
              palette: p,
              roomId: _roomId,
              draftStore: Drafts(),
              backgroundStore: FakeBackgroundStore(),
            ),
          ),
        ),
      );
      await _capture(tester, 'scheduled_room_${style.name}');
      await tester.tap(find.byKey(const ValueKey('scheduled.banner')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await _capture(tester, 'scheduled_list_${style.name}');
    });

    testWidgets('picker ${style.name}', skip: skip != null, (tester) async {
      final backend = _backend();
      late BuildContext host;
      await _frame(
        tester,
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: Scaffold(
            body: GlowBackdrop(
              palette: p,
              child: Builder(
                builder: (context) {
                  host = context;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      final now = DateTime.now();
      sendDraftLater(
        host,
        RoomHookContext(
          backend: backend,
          roomId: _roomId,
          palette: p,
          room: backend.roomList.single,
        ),
        const ComposerDraft(
          text: 'Happy birthday Mia! 🎉 Hope it’s a great one',
        ),
        clock: () => DateTime(now.year, now.month, now.day, 10),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await _capture(tester, 'scheduled_picker_${style.name}');
    });

    testWidgets('settings ${style.name}', skip: skip != null, (tester) async {
      await _frame(
        tester,
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: Scaffold(
            body: GlowBackdrop(
              palette: p,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  UndoSendSettingsSection(
                    palette: p,
                    preferences: UndoSendPreferences(),
                  ),
                  const SizedBox(height: 20),
                  ScheduledMessagesBanner(
                    backend: _backend(),
                    palette: p,
                    roomId: _roomId,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await _capture(tester, 'scheduled_settings_${style.name}');
    });
  }
}

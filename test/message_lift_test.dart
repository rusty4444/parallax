import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/gallery_bubble.dart';
import 'package:parallax/features/media/media_bubbles.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/timeline/double_tap_react.dart';
import 'package:parallax/timeline/message_bubble.dart';
import 'package:parallax/timeline/message_lift.dart';

import 'media_test_support.dart' as media;
import 'widget_test.dart' show FakeBackend, FakeBackgroundStore;

final _lifted = find.byKey(messageLiftSnapshotKey);
final _dim = find.byKey(messageLiftDimKey);

/// Records the routes pushed on the app's navigator.
class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);

  Iterable<MessageLiftRoute> get lifts => pushed.whereType<MessageLiftRoute>();
}

/// One fake message bubble whose long press runs [onLongPress].
Widget _bubble(String label, VoidCallback onLongPress) => DoubleTapReact(
  onDoubleTap: () {},
  onLongPress: onLongPress,
  child: Container(
    key: ValueKey('bubble-$label'),
    width: 200,
    height: 60,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Colors.indigo,
      borderRadius: BorderRadius.circular(19),
    ),
    child: Text(label, style: const TextStyle(color: Colors.white)),
  ),
);

Future<String?> _sheet(BuildContext context) => showMessageActionSheet<String>(
  context: context,
  builder: (sheetContext) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in ['Reply', 'Forward', 'Copy text', 'More'])
          ListTile(
            title: Text(action),
            onTap: () => Navigator.pop(sheetContext, action),
          ),
      ],
    ),
  ),
);

/// A screen with a message at [alignment]; its long press opens the action
/// sheet unless [openSheet] is false.
class _Room extends StatefulWidget {
  const _Room({
    this.alignment = Alignment.center,
    this.openSheet = true,
    this.choices,
    this.pressed,
  });

  final Alignment alignment;
  final bool openSheet;
  final List<String?>? choices;
  final List<String>? pressed;

  @override
  State<_Room> createState() => _RoomState();
}

class _RoomState extends State<_Room> {
  Future<void> _open() async {
    final choice = await _sheet(context);
    widget.choices?.add(choice);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Align(
        alignment: widget.alignment,
        child: _bubble('Hello there', () {
          widget.pressed?.add('Hello there');
          if (widget.openSheet) unawaited(_open());
        }),
      ),
    ),
    floatingActionButton: FloatingActionButton(
      tooltip: 'Open actions',
      onPressed: () => unawaited(_open()),
      child: const Icon(Icons.more_horiz),
    ),
  );
}

Future<_Routes> _pump(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(400, 800),
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final routes = _Routes();
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [routes],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: home,
    ),
  );
  await tester.pumpAndSettle();
  return routes;
}

/// Long press, then let the double-tap arena and both routes settle.
Future<void> _longPress(WidgetTester tester, Finder finder) async {
  await tester.longPress(finder);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

double _sourceOpacity(WidgetTester tester, String label) => tester
    .widget<Opacity>(
      find
          .ancestor(
            of: find.byKey(ValueKey('bubble-$label')),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

ModalBottomSheetRoute<dynamic> _sheetRoute(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.byType(BottomSheet)))!
        as ModalBottomSheetRoute<dynamic>;

void _expectSettled(WidgetTester tester, _Routes routes, String label) {
  expect(_lifted, findsNothing);
  expect(_dim, findsNothing);
  expect(find.byType(BottomSheet), findsNothing);
  expect(routes.lifts, isNotEmpty);
  expect(routes.lifts.every((route) => !route.isActive), isTrue);
  expect(_sourceOpacity(tester, label), 1);
}

void main() {
  testWidgets('a long press lifts the message above a dim behind the sheet', (
    tester,
  ) async {
    final routes = await _pump(tester, const _Room());
    final source = tester.getRect(
      find.byKey(const ValueKey('bubble-Hello there')),
    );

    await _longPress(tester, find.text('Hello there'));

    expect(find.text('Reply'), findsOneWidget);
    expect(_lifted, findsOneWidget);
    expect(find.byKey(messageLiftShadowKey), findsOneWidget);
    expect(_dim, findsOneWidget);
    final dim = tester.widget<ColoredBox>(_dim).color;
    expect(dim.a, closeTo(0.45, 0.001));
    // The room is blurred as well as dimmed.
    expect(
      find.ancestor(of: _dim, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );

    // The lift sits directly below the sheet; the sheet's own barrier is
    // transparent (the lift already dims) but still closes the sheet.
    final lift = routes.lifts.single;
    final sheet = _sheetRoute(tester);
    expect(ModalRoute.of(tester.element(_lifted)), same(lift));
    expect(lift.isActive, isTrue);
    expect(lift.isCurrent, isFalse);
    expect(sheet.isCurrent, isTrue);
    expect(routes.pushed.indexOf(sheet), routes.pushed.indexOf(lift) + 1);
    expect(sheet.barrierColor, Colors.transparent);
    expect(sheet.barrierDismissible, isTrue);

    // It pops out: a little bigger, centred on the message, which is hidden
    // underneath so no double shows.
    final copy = tester.getRect(_lifted);
    expect(copy.width, closeTo(source.width * 1.05, 0.5));
    expect(copy.height, closeTo(source.height * 1.05, 0.5));
    expect(copy.center.dx, closeTo(source.center.dx, 0.5));
    expect(copy.center.dy, closeTo(source.center.dy, 0.5));
    expect(_sourceOpacity(tester, 'Hello there'), 0);
  });

  testWidgets('tapping the dimmed room closes the sheet and the lift', (
    tester,
  ) async {
    final choices = <String?>[];
    final routes = await _pump(tester, _Room(choices: choices));
    await _longPress(tester, find.text('Hello there'));
    expect(_lifted, findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(choices, [null]);
    _expectSettled(tester, routes, 'Hello there');
  });

  testWidgets('choosing an action closes the sheet and the lift', (
    tester,
  ) async {
    final choices = <String?>[];
    final routes = await _pump(tester, _Room(choices: choices));
    await _longPress(tester, find.text('Hello there'));

    await tester.tap(find.text('Forward'));
    await tester.pump();
    // The lift starts settling back as soon as the sheet goes.
    expect(routes.lifts.single.isActive, isFalse);
    await tester.pumpAndSettle();
    expect(choices, ['Forward']);
    _expectSettled(tester, routes, 'Hello there');
  });

  testWidgets('back closes the sheet and the lift in one go', (tester) async {
    final choices = <String?>[];
    final routes = await _pump(tester, _Room(choices: choices));
    await _longPress(tester, find.text('Hello there'));

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(choices, [null]);
    _expectSettled(tester, routes, 'Hello there');
    // Only the sheet and the lift went: the room is still there.
    expect(find.text('Hello there'), findsOneWidget);
  });

  testWidgets('a long press that opens no sheet leaves no lift', (
    tester,
  ) async {
    final pressed = <String>[];
    final routes = await _pump(
      tester,
      _Room(openSheet: false, pressed: pressed),
    );
    await _longPress(tester, find.text('Hello there'));
    expect(pressed, ['Hello there']);
    expect(routes.lifts, isEmpty);
    expect(_lifted, findsNothing);
    expect(_sourceOpacity(tester, 'Hello there'), 1);

    // The dropped capture is not picked up by a later sheet.
    await tester.tap(find.byTooltip('Open actions'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(routes.lifts, isEmpty);
    expect(_sheetRoute(tester).barrierColor, isNot(Colors.transparent));
  });

  testWidgets('a right-click lifts the message too', (tester) async {
    final routes = await _pump(tester, const _Room());
    await tester.tap(find.text('Hello there'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(_lifted, findsOneWidget);
    expect(routes.lifts.single.isActive, isTrue);
    expect(_sheetRoute(tester).barrierColor, Colors.transparent);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    _expectSettled(tester, routes, 'Hello there');
  });

  testWidgets('reduced motion: dim and shadow at once, no scale or blur', (
    tester,
  ) async {
    final routes = await _pump(tester, const _Room(), disableAnimations: true);
    final source = tester.getRect(
      find.byKey(const ValueKey('bubble-Hello there')),
    );
    await tester.longPress(find.text('Hello there'));
    await tester.pump();
    // Fully lifted on the first frame: no fade in.
    expect(_lifted, findsOneWidget);
    expect(tester.widget<ColoredBox>(_dim).color.a, closeTo(0.45, 0.001));
    expect(find.byKey(messageLiftShadowKey), findsOneWidget);
    expect(
      find.ancestor(of: _dim, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    expect(tester.getRect(_lifted), rectMoreOrLessEquals(source));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(tester.getRect(_lifted), rectMoreOrLessEquals(source));

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    _expectSettled(tester, routes, 'Hello there');
  });

  testWidgets('a message the sheet would cover moves up above it', (
    tester,
  ) async {
    final routes = await _pump(
      tester,
      const _Room(alignment: Alignment.bottomLeft),
    );
    final source = tester.getRect(
      find.byKey(const ValueKey('bubble-Hello there')),
    );
    await _longPress(tester, find.text('Hello there'));

    final sheetTop = tester.getTopLeft(find.byType(BottomSheet)).dy;
    expect(sheetTop, lessThan(source.bottom), reason: 'the sheet covers it');
    final copy = tester.getRect(_lifted);
    expect(copy.bottom, lessThanOrEqualTo(sheetTop - 12));
    expect(copy.bottom, greaterThan(sheetTop - 20));
    expect(copy.center.dx, closeTo(source.center.dx, 0.5));

    // It settles back into its place with the sheet.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(_lifted).bottom, greaterThan(copy.bottom));
    await tester.pumpAndSettle();
    _expectSettled(tester, routes, 'Hello there');
  });

  testWidgets('on a wide window a message clear of the sheet stays put', (
    tester,
  ) async {
    await _pump(
      tester,
      const _Room(alignment: Alignment.bottomLeft),
      size: const Size(1400, 900),
    );
    final source = tester.getRect(
      find.byKey(const ValueKey('bubble-Hello there')),
    );
    await _longPress(tester, find.text('Hello there'));
    final sheet = tester.getRect(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(sheet.left, greaterThan(source.right), reason: 'centred sheet');
    expect(tester.getCenter(_lifted).dy, closeTo(source.center.dy, 0.5));
  });

  testWidgets('a gallery photo lifts on its own', (tester) async {
    final backend = FakeBackend();
    final photos = [
      for (final id in [r'$one', r'$two'])
        ChatEntry(
          id: id,
          sender: '@alice:s',
          body: '',
          time: DateTime(2026),
          mine: false,
          isImage: true,
        ),
    ];
    final actions = <String>[];
    final routes = await _pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => GalleryBubble(
            entries: photos,
            backend: backend,
            roomId: '!r:example.org',
            palette: paletteFor(VisualTheme.parallax),
            onHeart: (_) {},
            onAction: (entry) {
              actions.add(entry.id);
              unawaited(_sheet(context));
            },
            onReaction: (_, _) {},
          ),
        ),
      ),
    );
    final photo = find.byKey(const ValueKey(r'$two'));
    final source = tester.getRect(photo);
    await _longPress(tester, photo);
    expect(actions, [r'$two']);
    expect(routes.lifts, hasLength(1));
    final copy = tester.getRect(_lifted);
    expect(copy.width, closeTo(source.width * 1.05, 0.5));
    expect(copy.center.dx, closeTo(source.center.dx, 0.5));

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(_lifted, findsNothing);
    expect(routes.lifts.single.isActive, isFalse);
  });

  testWidgets('a sticker lifts like any other message', (tester) async {
    final actions = <String>[];
    final sticker = media.mediaEntry(
      r'$sticker',
      EntryKind.sticker,
      body: 'Party parrot',
    );
    final routes = await _pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => MessageBubble(
            entry: sticker,
            backend: media.FakeMediaBackend(),
            roomId: media.roomId,
            palette: media.palette,
            group: false,
            onHeart: () {},
            onAction: () {
              actions.add(sticker.id);
              unawaited(_sheet(context));
            },
            onReaction: (_) {},
          ),
        ),
      ),
    );
    expect(find.byType(StandaloneSticker), findsOneWidget);
    await _longPress(tester, find.byType(StandaloneSticker));
    expect(actions, [r'$sticker']);
    expect(_lifted, findsOneWidget);
    expect(routes.lifts.single.isActive, isTrue);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(_lifted, findsNothing);
    expect(routes.lifts.single.isActive, isFalse);
  });

  group('room timeline', () {
    Future<(FakeBackend, _Routes)> openRoom(WidgetTester tester) async {
      final backend = FakeBackend()
        ..entries = [
          ChatEntry(
            id: r'$hello',
            sender: '@friend:example.org',
            body: 'Hello from the room',
            time: DateTime(2026),
            mine: false,
          ),
        ];
      final routes = await _pump(
        tester,
        RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      );
      return (backend, routes);
    }

    final replyLift = find.byKey(messageReplyLiftKey);

    double sourceOpacity(WidgetTester tester) => tester
        .widget<Opacity>(
          find
              .ancestor(
                of: find.text('Hello from the room'),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;

    Future<void> cancelReply(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Cancel reply or edit').first);
      await tester.pump();
      await tester.pumpAndSettle();
    }

    testWidgets('Reply keeps the message popped out until the reply ends', (
      tester,
    ) async {
      final (_, routes) = await openRoom(tester);
      await _longPress(tester, find.text('Hello from the room'));
      expect(find.text('Reply'), findsOneWidget);
      expect(_lifted, findsOneWidget);
      expect(_sheetRoute(tester).barrierColor, Colors.transparent);
      final sheetCopy = tester.getRect(_lifted);

      await tester.tap(find.text('Reply'));
      // The handover frame: the reply lift draws the copy where the sheet's
      // lift left it, so nothing jumps.
      await tester.pump();
      expect(replyLift, findsOneWidget);
      final handed = tester.getRect(
        find.descendant(of: replyLift, matching: find.byType(RawImage)).last,
      );
      expect(handed.center.dy, closeTo(sheetCopy.center.dy, 1));
      await tester.pumpAndSettle();

      // Sheet and its route are gone; the message stays lifted over a dim
      // while the reply is written, and the original stays hidden.
      expect(find.text('Reply'), findsNothing);
      expect(routes.lifts.single.isActive, isFalse);
      // The only copy left is the reply lift's.
      expect(_lifted, findsOneWidget);
      expect(find.descendant(of: replyLift, matching: _lifted), findsOneWidget);
      expect(_dim, findsNothing);
      expect(find.textContaining('Replying to'), findsOneWidget);
      expect(replyLift, findsOneWidget);
      expect(find.byKey(messageReplyLiftDimKey), findsOneWidget);
      expect(sourceOpacity(tester), 0);
      // Settled back beside its own place once the sheet has gone.
      final message = tester.getRect(
        find.descendant(of: replyLift, matching: find.byType(RawImage)).last,
      );
      expect(message.width, greaterThan(0));

      // The composer stays usable under the lift.
      await tester.enterText(find.byType(TextField).last, 'Sounds good');
      await tester.pump();
      expect(replyLift, findsOneWidget);

      await cancelReply(tester);
      expect(replyLift, findsNothing);
      expect(sourceOpacity(tester), 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('other sheet actions still settle the message back', (
      tester,
    ) async {
      final (_, routes) = await openRoom(tester);
      await _longPress(tester, find.text('Hello from the room'));
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(routes.lifts.single.isActive, isFalse);
      expect(_lifted, findsNothing);
      expect(replyLift, findsNothing);
      expect(sourceOpacity(tester), 1);
      expect(find.textContaining('Replying to'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('swipe to reply springs back into the popped-out message', (
      tester,
    ) async {
      await openRoom(tester);
      expect(replyLift, findsNothing);
      final rest = tester.getRect(find.text('Hello from the room'));
      // Others' messages reply with a right swipe past 30% of the width.
      // The message slides away, then the reply starts as it springs back.
      // A timed drag pumps frames as it goes, as a real finger would.
      await tester.timedDrag(
        find.text('Hello from the room'),
        const Offset(300, 0),
        const Duration(milliseconds: 300),
      );
      for (var i = 0; i < 20 && replyLift.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('Replying to'), findsOneWidget);
      expect(replyLift, findsOneWidget);
      expect(sourceOpacity(tester), 0);
      // While the swipe springs back the copy rides along with the message,
      // growing and gaining its shadow, so the two motions are one.
      Rect copy() => tester.getRect(
        find.descendant(of: replyLift, matching: find.byType(RawImage)).last,
      );
      final early = copy();
      expect(early.left, greaterThan(rest.left + 50));
      await tester.pump(const Duration(milliseconds: 60));
      final later = copy();
      expect(later.left, lessThan(early.left));
      await tester.pumpAndSettle();
      // Back home, popped out.
      expect(copy().center.dx, closeTo(rest.center.dx, 8));
      expect(replyLift, findsOneWidget);
      expect(find.byKey(messageReplyLiftDimKey), findsOneWidget);

      await cancelReply(tester);
      expect(replyLift, findsNothing);
      expect(sourceOpacity(tester), 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('reduced motion keeps the reply lift without animating', (
      tester,
    ) async {
      final backend = FakeBackend()
        ..entries = [
          ChatEntry(
            id: r'$hello',
            sender: '@friend:example.org',
            body: 'Hello from the room',
            time: DateTime(2026),
            mine: false,
          ),
        ];
      await _pump(
        tester,
        RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
        disableAnimations: true,
      );
      await _longPress(tester, find.text('Hello from the room'));
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(replyLift, findsOneWidget);
      final copy = find
          .descendant(of: replyLift, matching: find.byType(RawImage))
          .last;
      final scale = tester
          .widget<Transform>(
            find.ancestor(of: copy, matching: find.byType(Transform)).first,
          )
          .transform
          .getMaxScaleOnAxis();
      expect(scale, closeTo(1, 0.001));
      await cancelReply(tester);
      expect(replyLift, findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  // Visual QA (not a golden): renders the lifted state to a PNG when
  // PARALLAX_SCREENSHOT_DIR is set.
  group('preview', () {
    final dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
    setUpAll(() async {
      if (dir == null) return;
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
    });

    testWidgets('lifted message', (tester) async {
      tester.view.physicalSize = const Size(1080, 2280);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final backend = FakeBackend()
        ..entries = [
          for (var i = 0; i < 6; i++)
            ChatEntry(
              id: '\$m$i',
              sender: i.isEven ? '@friend:example.org' : '@me:example.org',
              senderName: i.isEven ? 'Alex' : null,
              body: [
                'Are we still on for Saturday?',
                'Yes! Picnic at the lake 🌞',
                'Bring the frisbee',
                'Already in the car boot',
                'Perfect. I’ll grab snacks on the way and meet you there '
                    'around eleven.',
                'See you then!',
              ][i],
              time: DateTime(2026, 11, 20, 9, i * 3),
              mine: i.isOdd,
            ),
        ];
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(defaultVisualTheme),
            home: RoomScreen(
              backend: backend,
              palette: paletteFor(defaultVisualTheme),
              roomId: '!r:example.org',
              backgroundStore: FakeBackgroundStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> shoot(String name) => tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2.75);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      await shoot('room-preview.png');
      await _longPress(tester, find.textContaining('grab snacks'));
      expect(_lifted, findsOneWidget);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2.75);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/lift-preview.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      // Reply keeps it popped out while the reply is written.
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.byKey(messageReplyLiftKey), findsOneWidget);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2.75);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/reply-lift-preview.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, skip: dir == null);
  });
}

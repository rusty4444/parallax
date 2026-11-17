import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/media/zoomable_picture.dart';
import 'package:parallax/media_viewer.dart' show MediaViewer;

import 'media_test_support.dart' show makeImage, settle;
import 'media_viewer_test.dart' show FakeBackend, FakeFile, FakePlayer, media;

const _viewport = Size(400, 800);

/// A landscape photo: 400 x 300 at rest, with empty bars above and below.
const _photo = Size(800, 600);
const _picture = ValueKey('picture');

Matrix4 _transform(double scale, [double x = 0, double y = 0]) =>
    Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(x, y, 0);

Offset _offset(Matrix4 value) {
  final translation = value.getTranslation();
  return Offset(translation.x, translation.y);
}

/// Two fingers moving apart (or together) along a horizontal line.
Future<void> _pinch(
  WidgetTester tester,
  Offset centre, {
  required double from,
  required double to,
}) async {
  final first = await tester.startGesture(
    centre - Offset(from / 2, 0),
    pointer: 7,
  );
  final second = await tester.startGesture(
    centre + Offset(from / 2, 0),
    pointer: 8,
  );
  await tester.pump();
  const steps = 12;
  for (var step = 1; step <= steps; step++) {
    final half = (from + (to - from) * step / steps) / 2;
    await first.moveTo(centre - Offset(half, 0));
    await second.moveTo(centre + Offset(half, 0));
    await tester.pump();
  }
  await first.up();
  await second.up();
  await tester.pumpAndSettle();
}

void main() {
  group('fitting', () {
    test('a large picture is shrunk to fit, a small one keeps its size', () {
      expect(fittedPictureSize(_photo, _viewport), const Size(400, 300));
      expect(
        fittedPictureSize(const Size(600, 2400), _viewport),
        const Size(200, 800),
      );
      expect(
        fittedPictureSize(const Size(120, 90), _viewport),
        const Size(120, 90),
      );
    });

    test('cover scale is the zoom that fills the space', () {
      expect(
        pictureCoverScale(const Size(400, 300), _viewport),
        closeTo(800 / 300, 1e-9),
      );
      expect(pictureCoverScale(const Size(400, 800), _viewport), 1);
      expect(pictureCoverScale(Size.zero, _viewport), 1);
    });
  });

  group('boundPictureTransform', () {
    const picture = Size(400, 300);
    Matrix4 bound(Matrix4 value) =>
        boundPictureTransform(value, viewport: _viewport, picture: picture);

    test('at rest nothing changes', () {
      final rest = Matrix4.identity();
      expect(identical(bound(rest), rest), isTrue);
    });

    test('an axis the picture does not fill stays centred', () {
      // Twice the size: 800 x 600, still shorter than the 800 high space.
      final value = bound(_transform(2, -100, 75));
      expect(value.getMaxScaleOnAxis(), 2);
      // Kept where it was dragged horizontally; centred vertically, so the
      // picture spans 100..700 rather than staying inside 250..550.
      expect(_offset(value), const Offset(-100, -400));
    });

    test('a filled axis stops at the picture’s edges', () {
      // Four times the size: 1600 x 1200.
      // Dragged far right and down: the left and top edges stop at the
      // viewport's, with no bar showing.
      expect(_offset(bound(_transform(4, 500, 500))), const Offset(0, -1000));
      // Dragged far left and up: the right and bottom edges stop there.
      expect(
        _offset(bound(_transform(4, -9000, -9000))),
        const Offset(-1200, -1400),
      );
      // In between is left alone.
      final inside = _transform(4, -600, -1200);
      expect(identical(bound(inside), inside), isTrue);
    });

    test('the limits meet where the picture just fills the axis', () {
      const scale = 800 / 300;
      final value = bound(_transform(scale, 0, 123));
      expect(_offset(value).dy, closeTo(800 * (1 - scale) / 2, 1e-6));
    });

    test('with nothing measured yet the value is kept', () {
      final value = _transform(3, 40, 40);
      expect(
        identical(
          boundPictureTransform(value, viewport: Size.zero, picture: Size.zero),
          value,
        ),
        isTrue,
      );
    });
  });

  group('ZoomablePicture', () {
    late PictureTransformationController controller;

    setUp(() => controller = PictureTransformationController());
    tearDown(() => controller.dispose());

    Future<void> pump(WidgetTester tester, {Size surface = _viewport}) async {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomablePicture(
              controller: controller,
              naturalSize: _photo,
              child: const ColoredBox(key: _picture, color: Color(0xff336699)),
            ),
          ),
        ),
      );
    }

    Rect picture(WidgetTester tester) => tester.getRect(find.byKey(_picture));

    testWidgets('at rest the picture is letterboxed in a full-size viewer', (
      tester,
    ) async {
      await pump(tester);
      expect(picture(tester), const Rect.fromLTWH(0, 250, 400, 300));
      // The zoomable area is the whole space, not the picture's frame.
      expect(tester.getSize(find.byType(InteractiveViewer)), _viewport);
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.minScale, 1);
      expect(viewer.maxScale, ZoomablePicture.usualMaxScale);
    });

    testWidgets('pinching grows the picture past its frame, centred', (
      tester,
    ) async {
      await pump(tester);
      await _pinch(tester, const Offset(200, 400), from: 100, to: 240);
      final scale = controller.value.getMaxScaleOnAxis();
      expect(scale, greaterThan(1.5));
      expect(scale, lessThan(800 / 300));
      final rect = picture(tester);
      // Taller than the 300 px frame it used to be clipped to, and still
      // centred while it does not fill the height.
      expect(rect.height, closeTo(300 * scale, 0.01));
      expect(rect.center.dy, closeTo(400, 0.01));
      expect(rect.left, lessThanOrEqualTo(0));
      expect(rect.right, greaterThanOrEqualTo(400));
    });

    testWidgets('pinching further fills the whole space', (tester) async {
      await pump(tester);
      await _pinch(tester, const Offset(200, 400), from: 60, to: 360);
      expect(controller.value.getMaxScaleOnAxis(), greaterThan(800 / 300));
      final rect = picture(tester);
      expect(rect.left, lessThanOrEqualTo(0.01));
      expect(rect.top, lessThanOrEqualTo(0.01));
      expect(rect.right, greaterThanOrEqualTo(399.99));
      expect(rect.bottom, greaterThanOrEqualTo(799.99));
    });

    testWidgets('dragging a zoomed picture stops at its edges', (tester) async {
      await pump(tester);
      await _pinch(tester, const Offset(200, 400), from: 60, to: 360);
      // Far down and right: the top-left corner comes to rest in the corner.
      await tester.dragFrom(const Offset(100, 200), const Offset(3000, 3000));
      await tester.pumpAndSettle();
      var rect = picture(tester);
      expect(rect.left, closeTo(0, 0.01));
      expect(rect.top, closeTo(0, 0.01));
      // Far up and left: the bottom-right corner does.
      for (var i = 0; i < 4; i++) {
        await tester.dragFrom(
          const Offset(300, 600),
          const Offset(-3000, -3000),
        );
        await tester.pumpAndSettle();
      }
      rect = picture(tester);
      expect(rect.right, closeTo(400, 0.01));
      expect(rect.bottom, closeTo(800, 0.01));
    });

    testWidgets('a picture that is not yet as tall as the space can’t be '
        'dragged off centre', (tester) async {
      await pump(tester);
      controller.value = _transform(2);
      await tester.pump();
      await tester.dragFrom(const Offset(200, 400), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(picture(tester).center.dy, closeTo(400, 0.01));
    });

    testWidgets('pinching back in returns to the letterboxed picture', (
      tester,
    ) async {
      await pump(tester);
      await _pinch(tester, const Offset(200, 400), from: 60, to: 360);
      await _pinch(tester, const Offset(200, 400), from: 360, to: 20);
      expect(controller.value.getMaxScaleOnAxis(), closeTo(1, 1e-6));
      expect(
        picture(tester),
        rectMoreOrLessEquals(
          const Rect.fromLTWH(0, 250, 400, 300),
          epsilon: 0.01,
        ),
      );
    });

    testWidgets('a long thin picture may zoom far enough to fill the space', (
      tester,
    ) async {
      tester.view.physicalSize = _viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomablePicture(
              controller: controller,
              // A panorama: 400 x 50 at rest, so filling the height is 16x.
              naturalSize: const Size(4000, 500),
              child: const ColoredBox(key: _picture, color: Color(0xff336699)),
            ),
          ),
        ),
      );
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.maxScale, ZoomablePicture.zoomLimit);
    });

    testWidgets('turning the phone keeps a zoomed picture within bounds', (
      tester,
    ) async {
      await pump(tester);
      controller.value = _transform(4, -1200, -1400);
      await tester.pump();
      tester.view.physicalSize = const Size(800, 400);
      await tester.pump();
      await tester.pump();
      const viewport = Size(800, 400);
      final fitted = fittedPictureSize(_photo, viewport);
      final value = controller.value;
      expect(
        identical(
          boundPictureTransform(value, viewport: viewport, picture: fitted),
          value,
        ),
        isTrue,
      );
      final rect = picture(tester);
      expect(rect.right, greaterThanOrEqualTo(799.99));
      expect(rect.bottom, greaterThanOrEqualTo(399.99));
      expect(tester.takeException(), isNull);
    });
  });

  group('MediaViewer', () {
    testWidgets('an image zooms across the page and reports it', (
      tester,
    ) async {
      tester.view.physicalSize = _viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final image = (await tester.runAsync(() => makeImage(800, 600)))!;
      final backend = FakeBackend()..loader = () async => media('image/png');
      final zoom = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaViewer(
              backend: backend,
              roomId: '!r',
              eventId: 'e',
              imageDecoder: (_) async => image,
              embedded: true,
              onZoomChanged: zoom.add,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.getSize(find.byType(InteractiveViewer)), _viewport);
      expect(
        tester.getRect(find.byType(RawImage)),
        const Rect.fromLTWH(0, 250, 400, 300),
      );

      await _pinch(tester, const Offset(200, 400), from: 60, to: 360);
      final rect = tester.getRect(find.byType(RawImage));
      expect(rect.top, lessThanOrEqualTo(0.01));
      expect(rect.bottom, greaterThanOrEqualTo(799.99));
      expect(zoom, [true]);

      await _pinch(tester, const Offset(200, 400), from: 360, to: 20);
      expect(zoom, [true, false]);
      expect(tester.takeException(), isNull);
    });

    void navigationBar(WidgetTester tester) {
      tester.view.physicalSize = _viewport;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 40);
      tester.view.viewPadding = const FakeViewPadding(bottom: 40);
      addTearDown(tester.view.reset);
    }

    testWidgets('a picture may use the strip under the navigation bar', (
      tester,
    ) async {
      navigationBar(tester);
      final image = (await tester.runAsync(() => makeImage(800, 600)))!;
      final backend = FakeBackend()..loader = () async => media('image/png');
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            backend: backend,
            roomId: '!r',
            eventId: 'e',
            imageDecoder: (_) async => image,
          ),
        ),
      );
      await tester.pump();
      final viewer = tester.getRect(find.byType(InteractiveViewer));
      expect(viewer.top, kToolbarHeight);
      expect(viewer.bottom, 800);
      expect(viewer.width, 400);
    });

    testWidgets('playback controls stay above the navigation bar', (
      tester,
    ) async {
      navigationBar(tester);
      final log = <String>[];
      final backend = FakeBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            backend: backend,
            roomId: '!r',
            eventId: 'e',
            fileFactory: (_) async => FakeFile(log),
            playerFactory: (_, _) => FakePlayer(log),
          ),
        ),
      );
      await settle(tester);
      expect(
        tester.getRect(find.byTooltip('Play')).bottom,
        lessThanOrEqualTo(760),
      );
      // Unmount inside the test so the fake player's disposal is joined.
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    });
  });
}

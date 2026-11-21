import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/appearance/bubble_colours.dart';
import 'package:parallax/features/retention/retention_features.dart';
import 'package:parallax/features/retention/retention_model.dart';
import 'package:parallax/features/retention/retention_screen.dart';

class _FakeRetention implements RetentionFeatures {
  RoomRetention current = RoomRetention.off;
  Duration? lastSet;
  int setCalls = 0;
  Object? failWith;

  @override
  Future<RoomRetention> retentionOf(String roomId) async => current;

  @override
  Future<void> setRetention(String roomId, Duration? lifetime) async {
    if (failWith != null) throw failWith!;
    setCalls++;
    lastSet = lifetime;
    current = RoomRetention(maxLifetime: lifetime);
  }

  @override
  RoomRetention? cachedRetention(String roomId) => current;
}

void main() {
  Future<void> tapApply(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Apply'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
  }

  group('RoomRetention model', () {
    test('parses max_lifetime and round-trips', () {
      final r = RoomRetention.fromContent({'max_lifetime': 86400000});
      expect(r.enabled, isTrue);
      expect(r.maxLifetime, const Duration(hours: 24));
      expect(r.toContent(), {'max_lifetime': 86400000});
    });

    test('off for missing, zero, negative or malformed values', () {
      for (final content in [
        null,
        <String, Object?>{},
        {'max_lifetime': 0},
        {'max_lifetime': -5},
        {'max_lifetime': 'soon'},
        'nonsense',
      ]) {
        expect(RoomRetention.fromContent(content).enabled, isFalse);
      }
      expect(RoomRetention.off.toContent(), isEmpty);
    });

    test('expiry is strictly past the lifetime', () {
      const r = RoomRetention(maxLifetime: Duration(hours: 1));
      final now = DateTime(2026, 11, 21, 12);
      expect(
        r.isExpired(now.subtract(const Duration(minutes: 59)), now),
        isFalse,
      );
      expect(
        r.isExpired(now.subtract(const Duration(minutes: 61)), now),
        isTrue,
      );
      expect(RoomRetention.off.isExpired(DateTime(2000), now), isFalse);
    });

    test('labels', () {
      expect(retentionLabel(null), 'Off');
      expect(retentionLabel(const Duration(hours: 24)), '24 hours');
      expect(retentionLabel(const Duration(days: 7)), '7 days');
      expect(retentionLabel(const Duration(hours: 5)), '5 hours');
      expect(retentionLabel(const Duration(minutes: 30)), '30 minutes');
    });
  });

  group('synced room theme record', () {
    test('bubble colours survive the account-data round trip', () {
      const colours = BubbleColours(
        mine: Color(0xFF112233),
        mineText: Color(0xFFFFFFFF),
        theirs: Color(0xFF445566),
      );
      final record = {'version': 1, 'bubbleColours': colours.toJson()};
      final parsed = BubbleColours.fromJson(record['bubbleColours']);
      expect(parsed, colours);
    });

    test('empty theme clears the colours', () {
      expect(
        BubbleColours.fromJson(BubbleColours.none.toJson()).isEmpty,
        isTrue,
      );
    });
  });

  group('RetentionScreen', () {
    Future<void> pumpScreen(WidgetTester tester, _FakeRetention fake) async {
      // Tall surface so the lazy ListView builds every preset and the Apply
      // button without scrolling.
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: RetentionScreen(
            features: fake,
            roomId: '!room:example.org',
            roomName: 'Test room',
            palette: paletteFor(VisualTheme.parallax),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('applies a preset', (tester) async {
      final fake = _FakeRetention();
      await pumpScreen(tester, fake);
      await tester.tap(find.byKey(const ValueKey('retention-24-hours')));
      await tester.pumpAndSettle();
      await tapApply(tester);
      expect(fake.setCalls, 1);
      expect(fake.lastSet, const Duration(hours: 24));
    });

    testWidgets('applies custom hours', (tester) async {
      final fake = _FakeRetention();
      await pumpScreen(tester, fake);
      await tester.tap(find.byKey(const ValueKey('retention-custom')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '12');
      await tapApply(tester);
      expect(fake.lastSet, const Duration(hours: 12));
    });

    testWidgets('turning off clears the policy', (tester) async {
      final fake = _FakeRetention()
        ..current = const RoomRetention(maxLifetime: Duration(days: 7));
      await pumpScreen(tester, fake);
      await tester.tap(find.byKey(const ValueKey('retention-Off')));
      await tester.pumpAndSettle();
      await tapApply(tester);
      expect(fake.lastSet, isNull);
    });

    testWidgets('shows the best-effort disclosure', (tester) async {
      await pumpScreen(tester, _FakeRetention());
      expect(find.textContaining('best-effort'), findsOneWidget);
    });
  });
}

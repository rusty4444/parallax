import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/user_status/user_status.dart';
import 'package:parallax/features/user_status/user_status_screen.dart';

void main() {
  group('UserStatus model', () {
    test('label combines emoji and text', () {
      expect(
        const UserStatus(text: 'On holiday', emoji: '🌴').label,
        '🌴 On holiday',
      );
      expect(const UserStatus(text: 'Busy').label, 'Busy');
      expect(const UserStatus(emoji: '😎').label, '😎');
      expect(UserStatus.none.isEmpty, isTrue);
    });

    test('expiry controls activity', () {
      final now = DateTime(2026, 11, 21, 12);
      final status = UserStatus(
        text: 'Hi',
        expiresAt: now.add(const Duration(hours: 1)),
      );
      expect(status.isActive(now), isTrue);
      expect(status.isActive(now.add(const Duration(hours: 2))), isFalse);
      expect(const UserStatus(text: 'Hi').isActive(now), isTrue);
      expect(UserStatus.none.isActive(now), isFalse);
    });

    test('json round trip', () {
      final status = UserStatus(
        text: 'Working',
        emoji: '💼',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
      );
      final parsed = UserStatus.fromJson(status.toJson());
      expect(parsed.text, 'Working');
      expect(parsed.emoji, '💼');
      expect(parsed.expiresAt, status.expiresAt);
    });
  });

  testWidgets('editor saves a status with emoji and expiry', (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = UserStatusController();
    await tester.pumpWidget(
      MaterialApp(
        home: UserStatusScreen(
          controller: controller,
          palette: paletteFor(VisualTheme.parallax),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('status-text')),
      'On holiday',
    );
    await tester.tap(find.byKey(const ValueKey('status-emoji-🌴')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('status-expiry-1-hour')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('status-save')));
    await tester.pumpAndSettle();
    expect(controller.status.text, 'On holiday');
    expect(controller.status.emoji, '🌴');
    expect(controller.status.expiresAt, isNotNull);
    expect(controller.status.label, '🌴 On holiday');
  });

  testWidgets('editor clears the status', (tester) async {
    final controller = UserStatusController();
    await controller.setStatus('Old', '😎', null);
    await tester.pumpWidget(
      MaterialApp(
        home: UserStatusScreen(
          controller: controller,
          palette: paletteFor(VisualTheme.parallax),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('status-clear')));
    await tester.pumpAndSettle();
    expect(controller.status.isEmpty, isTrue);
  });
}

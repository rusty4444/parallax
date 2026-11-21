import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/stories/post_story_screen.dart';
import 'package:parallax/features/stories/stories.dart';
import 'package:parallax/features/stories/stories_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBackend extends ChatBackend {
  @override
  SessionStatus get connection => SessionStatus.ready;
  @override
  List<ChatRoom> get rooms => const [];
  @override
  String? get userId => '@me:example.org';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stories expire after 24 hours', () {
    final now = DateTime(2026, 11, 21, 12);
    final fresh = Story(
      eventId: r'$a',
      senderId: '@me:example.org',
      senderName: 'Me',
      time: now.subtract(const Duration(hours: 23)),
    );
    final old = Story(
      eventId: r'$b',
      senderId: '@me:example.org',
      senderName: 'Me',
      time: now.subtract(const Duration(hours: 25)),
    );
    expect(fresh.isActive(now), isTrue);
    expect(old.isActive(now), isFalse);
  });

  test('stories preference defaults off and persists', () async {
    final controller = StoriesController();
    await controller.load();
    expect(controller.enabled, isFalse);
    await controller.setEnabled(true);
    final reopened = StoriesController();
    await reopened.load();
    expect(reopened.enabled, isTrue);
  });

  testWidgets('stories bar shows the add-story ring', (tester) async {
    final controller = StoriesController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StoriesBar(
            backend: _FakeBackend(),
            controller: controller,
            palette: paletteFor(VisualTheme.parallax),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('story-add')), findsOneWidget);
    expect(find.text('Add story'), findsOneWidget);
  });

  testWidgets('posting an empty story is rejected', (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = StoriesController();
    await tester.pumpWidget(
      MaterialApp(
        home: PostStoryScreen(
          controller: controller,
          palette: paletteFor(VisualTheme.parallax),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('story-post')));
    await tester.pump();
    expect(find.text('Write a story or add a photo first.'), findsOneWidget);
  });
}

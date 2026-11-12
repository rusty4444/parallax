import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/composer/chat_effect_particles.dart';
import 'package:parallax/features/composer/chat_effects.dart';
import 'package:parallax/features/composer/chat_effects_overlay.dart';
import 'package:parallax/features/composer/chat_effects_preferences.dart';
import 'package:parallax/features/composer/composer_hooks.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

const room = '!room:example.org';
final opened = DateTime(2026, 11, 12, 10);

ChatEntry entry(
  String id,
  String body, {
  DateTime? time,
  String? msgtype,
  String sender = '@alice:example.org',
  bool redacted = false,
  String eventType = 'm.room.message',
  Map<String, Object?> content = const {},
}) => ChatEntry(
  id: id,
  sender: sender,
  body: body,
  time: time ?? opened.add(const Duration(seconds: 30)),
  mine: false,
  redacted: redacted,
  eventType: eventType,
  msgtype: msgtype ?? 'm.text',
  content: content,
);

class _Backend extends ChatBackend {
  List<ChatEntry> entries = [];
  String? active = room;

  @override
  List<ChatEntry> get messages => entries;
  @override
  String? get activeRoomId => active;

  void update(List<ChatEntry> next) {
    entries = next;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<ChatEffectKind> kinds(List<ChatEffect> effects) => [
  for (final effect in effects) effect.kind,
];

void main() {
  group('detection (Element Web rules)', () {
    test('msgtypes and trigger emoji', () {
      expect(
        kinds(chatEffectsFor(msgtype: 'nic.custom.confetti', body: 'yay')),
        [ChatEffectKind.confetti],
      );
      expect(kinds(chatEffectsFor(body: 'party 🎉')), [
        ChatEffectKind.confetti,
      ]);
      expect(kinds(chatEffectsFor(body: '🎊')), [ChatEffectKind.confetti]);
      expect(kinds(chatEffectsFor(body: '🎆')), [ChatEffectKind.fireworks]);
      expect(kinds(chatEffectsFor(body: 'rain ⛈️')), [ChatEffectKind.rainfall]);
      expect(kinds(chatEffectsFor(body: 'snow ❄️')), [ChatEffectKind.snowfall]);
      expect(kinds(chatEffectsFor(body: '🌨️')), [ChatEffectKind.snowfall]);
      expect(kinds(chatEffectsFor(body: '🌌')), [ChatEffectKind.spaceInvaders]);
      expect(kinds(chatEffectsFor(body: '💝')), [ChatEffectKind.hearts]);
      expect(
        kinds(
          chatEffectsFor(
            msgtype: 'io.element.effects.space_invaders',
            body: '',
          ),
        ),
        [ChatEffectKind.spaceInvaders],
      );
      expect(kinds(chatEffectsFor(body: '🎉 ❄')), [
        ChatEffectKind.confetti,
        ChatEffectKind.snowfall,
      ]);
      // Not Element Web triggers.
      expect(chatEffectsFor(body: '☃️ ⛄ ❤️ hello'), isEmpty);
    });

    test('entries: redacted, state, thread replies never play', () {
      expect(chatEffectsForEntry(entry('a', '🎉')), isNotEmpty);
      expect(chatEffectsForEntry(entry('a', '🎉', redacted: true)), isEmpty);
      expect(
        chatEffectsForEntry(entry('a', '🎉', eventType: 'm.room.topic')),
        isEmpty,
      );
      expect(
        chatEffectsForEntry(
          entry(
            'a',
            '🎉',
            content: {
              'm.relates_to': {'rel_type': 'm.thread', 'event_id': r'$root'},
            },
          ),
        ),
        isEmpty,
      );
    });
  });

  group('tracker: new messages only', () {
    final old = opened.subtract(const Duration(hours: 2));

    test('history and the first load never play', () {
      final tracker = ChatEffectTracker(openedAt: opened);
      expect(
        tracker.observe([
          entry('1', '🎉', time: old),
          entry('2', 'hi', time: old),
        ]),
        isEmpty,
      );
      expect(tracker.observe([entry('1', '🎉', time: old)]), isEmpty);
    });

    test('a message newer than the room opening plays once', () {
      final tracker = ChatEffectTracker(openedAt: opened);
      final history = [entry('1', 'hello', time: old)];
      expect(tracker.observe(history), isEmpty);
      final fresh = [...history, entry('2', 'happy birthday 🎉')];
      expect(kinds(tracker.observe(fresh)), [ChatEffectKind.confetti]);
      expect(tracker.observe(fresh), isEmpty);
      // An edit (same ID, new body) does not replay.
      expect(tracker.observe([...history, entry('2', 'edited 🎆')]), isEmpty);
    });

    test('a first batch that already includes a new message plays it', () {
      final tracker = ChatEffectTracker(openedAt: opened);
      expect(
        kinds(
          tracker.observe([
            entry('1', 'hi', time: old),
            entry('2', '', msgtype: 'nic.custom.fireworks'),
          ]),
        ),
        [ChatEffectKind.fireworks],
      );
    });

    test('back-paginated history does not play', () {
      final tracker = ChatEffectTracker(openedAt: opened);
      tracker.observe([entry('5', 'latest', time: old)]);
      expect(
        tracker.observe([
          entry('3', '🎉', time: old.subtract(const Duration(days: 1))),
          entry('4', '❄', time: opened.add(const Duration(minutes: 1))),
          entry('5', 'latest', time: old),
        ]),
        isEmpty,
      );
    });

    test('old messages appended after a gap do not play', () {
      final tracker = ChatEffectTracker(openedAt: opened);
      tracker.observe([entry('1', 'hi', time: old)]);
      expect(
        tracker.observe([
          entry('1', 'hi', time: old),
          entry('2', '🎉', time: old.add(const Duration(minutes: 5))),
        ]),
        isEmpty,
      );
    });

    test('a local echo replaced by its remote echo plays once', () {
      final tracker = ChatEffectTracker(openedAt: opened);
      tracker.observe([entry('1', 'hi', time: old)]);
      final echo = entry('txn-1', '/me 🎉', sender: '@me:example.org');
      expect(kinds(tracker.observe([entry('1', 'hi', time: old), echo])), [
        ChatEffectKind.confetti,
      ]);
      final remote = entry(r'$event', '/me 🎉', sender: '@me:example.org');
      expect(tracker.observe([entry('1', 'hi', time: old), remote]), isEmpty);
      // A genuinely new identical message later still plays.
      expect(
        kinds(
          tracker.observe([
            entry('1', 'hi', time: old),
            remote,
            entry(r'$again', '/me 🎉', sender: '@me:example.org'),
          ]),
        ),
        [ChatEffectKind.confetti],
      );
    });
  });

  group('overlay', () {
    late _Backend backend;
    late ChatEffectsPreferences preferences;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      backend = _Backend()
        ..entries = [entry('old', 'history 🎉', time: DateTime(2020))];
    });

    // Created inside each test body: SharedPreferences futures created in
    // setUp's root zone would never complete under the widget test's fake
    // async zone.
    Future<void> prefs() async => preferences = ChatEffectsPreferences(
      preferences: await SharedPreferences.getInstance(),
    );

    Future<void> mount(WidgetTester tester, {bool reduceMotion = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(400, 700),
                disableAnimations: reduceMotion,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const Text('timeline'),
                  ChatEffectsOverlay(
                    backend: backend,
                    roomId: room,
                    preferences: preferences,
                    random: math.Random(7),
                  ),
                ],
              ),
            ),
          ),
        );

    List<ChatEffectKind> playing(WidgetTester tester) =>
        playingChatEffects(tester.element(find.byType(ChatEffectsOverlay)));

    final canvas = find.byKey(const ValueKey('chat-effects-canvas'));

    testWidgets('plays for a new message, not for history, then clears', (
      tester,
    ) async {
      await prefs();
      await mount(tester);
      await tester.pump();
      expect(canvas, findsNothing);
      backend.update([
        ...backend.entries,
        entry('new', 'Congratulations 🎉', time: DateTime.now()),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(playing(tester), [ChatEffectKind.confetti]);
      expect(canvas, findsOneWidget);
      // Pointer events pass through to the timeline.
      expect(
        find.ancestor(of: canvas, matching: find.byType(IgnorePointer)),
        findsWidgets,
      );
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(canvas, findsNothing);
      expect(playing(tester), isEmpty);
    });

    testWidgets('plays every effect type within the time limit', (
      tester,
    ) async {
      await prefs();
      await mount(tester);
      await tester.pump();
      var i = 0;
      for (final effect in chatEffects) {
        backend.update([
          ...backend.entries,
          entry('e${i++}', 'x', msgtype: effect.msgType, time: DateTime.now()),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(playing(tester), contains(effect.kind));
      }
      expect(playing(tester).length, lessThanOrEqualTo(3));
      await tester.pumpAndSettle();
      expect(playing(tester), isEmpty);
    });

    testWidgets('respects the setting and reduce motion', (tester) async {
      await prefs();
      await preferences.setShowChatEffects(false);
      await mount(tester);
      await tester.pump();
      backend.update([
        ...backend.entries,
        entry('n1', '🎆', time: DateTime.now()),
      ]);
      await tester.pump();
      expect(canvas, findsNothing);

      await preferences.setShowChatEffects(true);
      await mount(tester, reduceMotion: true);
      backend.update([
        ...backend.entries,
        entry('n2', '🎆', time: DateTime.now()),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(canvas, findsNothing);
    });

    testWidgets('ignores another room shown by the backend', (tester) async {
      await prefs();
      backend.active = '!other:example.org';
      await mount(tester);
      backend.update([entry('o', '🎉', time: DateTime.now())]);
      await tester.pump();
      expect(canvas, findsNothing);
    });

    testWidgets('hooks: overlay and settings section', (tester) async {
      late List<Widget> overlays;
      late List<Widget> sections;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              final palette = paletteFor(VisualTheme.parallax);
              overlays = composerRoomOverlays(
                context,
                RoomHookContext(
                  backend: backend,
                  roomId: room,
                  palette: palette,
                ),
              );
              sections = composerSettingsSections(
                context,
                SettingsHookContext(backend: backend, palette: palette),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(overlays.single, isA<ChatEffectsOverlay>());
      expect(sections.single, isA<ChatEffectsSettingsSection>());
    });

    testWidgets('settings switch persists the preference', (tester) async {
      await prefs();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatEffectsSettingsSection(
              palette: paletteFor(VisualTheme.parallax),
              preferences: preferences,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Show chat effects'), findsOneWidget);
      expect(preferences.showChatEffects, isTrue);
      await tester.tap(find.byKey(const ValueKey('show-chat-effects')));
      await tester.pumpAndSettle();
      expect(preferences.showChatEffects, isFalse);
      final stored = await SharedPreferences.getInstance();
      expect(
        stored.getBool(ChatEffectsPreferences.showChatEffectsKey),
        isFalse,
      );
      // A fresh instance reads the saved value.
      final reloaded = ChatEffectsPreferences(preferences: stored);
      await reloaded.ensureLoaded();
      expect(reloaded.showChatEffects, isFalse);
    });
  });

  test('particle systems advance, stop spawning and finish', () {
    const size = Size(360, 640);
    for (final kind in ChatEffectKind.values) {
      final system = EffectParticles.create(kind, math.Random(1))..start(size);
      for (var i = 0; i < 30; i++) {
        system.step(size);
      }
      expect(system.finished, isFalse, reason: '$kind started');
      system.spawning = false;
      var steps = 0;
      while (!system.finished && steps < 5000) {
        system.step(size);
        steps++;
      }
      expect(system.finished, isTrue, reason: '$kind drains');
    }
  });
}

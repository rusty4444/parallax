import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/scheduled/scheduled_features.dart';
import 'package:parallax/features/scheduled/scheduled_hooks.dart';
import 'package:parallax/features/scheduled/send_later_sheet.dart';
import 'package:parallax/features/scheduled/undo_send.dart';
import 'package:parallax/features/scheduled/undo_send_settings.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeBackend;
import 'package:parallax/appearance_settings_screen.dart';
import 'package:parallax/appearance_preferences.dart';

const _roomId = '!room:matrix.example';
final _palette = paletteFor(VisualTheme.parallax);

class _ScheduledBackend extends FakeBackend implements ScheduledFeatures {
  DelayedEventsCapability capability = const DelayedEventsCapability(
    supported: true,
  );
  Object? capabilityError;
  Object? scheduleError;
  Object? manageError;
  final items = <ScheduledMessage>[];
  final scheduled = <(ComposerDraft, DateTime)>[];
  final sentNow = <String>[];
  final cancelled = <String>[];
  final rescheduled = <(String, DateTime)>[];
  int refreshes = 0;

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
  ]..sort((a, b) => a.sendAt.compareTo(b.sendAt));
  @override
  void ensureScheduledLoaded() {}
  @override
  Future<void> refreshScheduled() async => refreshes++;
  @override
  Future<DelayedEventsCapability> delayedEventsCapability({
    bool refresh = false,
  }) async {
    if (capabilityError != null) throw capabilityError!;
    return capability;
  }

  @override
  Future<ScheduledMessage> scheduleDraft(
    String roomId,
    ComposerDraft draft,
    DateTime sendAt,
  ) async {
    if (scheduleError != null) throw scheduleError!;
    scheduled.add((draft, sendAt));
    final message = ScheduledMessage(
      delayId: 'syd_${scheduled.length}',
      roomId: roomId,
      type: 'm.room.message',
      sendAt: sendAt,
      encrypted: false,
      content: {'msgtype': 'm.text', 'body': draft.text},
    );
    items.add(message);
    notifyListeners();
    return message;
  }

  void _remove(String id) {
    items.removeWhere((item) => item.delayId == id);
    notifyListeners();
  }

  @override
  Future<void> sendScheduledNow(ScheduledMessage message) async {
    if (manageError != null) throw manageError!;
    sentNow.add(message.delayId);
    _remove(message.delayId);
  }

  @override
  Future<void> cancelScheduled(ScheduledMessage message) async {
    if (manageError != null) throw manageError!;
    cancelled.add(message.delayId);
    _remove(message.delayId);
  }

  @override
  Future<ScheduledMessage> rescheduleScheduled(
    ScheduledMessage message,
    DateTime sendAt,
  ) async {
    rescheduled.add((message.delayId, sendAt));
    _remove(message.delayId);
    final copy = ScheduledMessage(
      delayId: '${message.delayId}_moved',
      roomId: message.roomId,
      type: message.type,
      sendAt: sendAt,
      encrypted: message.encrypted,
      content: message.content,
    );
    items.add(copy);
    notifyListeners();
    return copy;
  }
}

ScheduledMessage _message(
  String id,
  String body,
  DateTime sendAt, {
  String roomId = _roomId,
  bool encrypted = false,
}) => ScheduledMessage(
  delayId: id,
  roomId: roomId,
  type: 'm.room.message',
  sendAt: sendAt,
  encrypted: encrypted,
  content: {'msgtype': 'm.text', 'body': body},
);

RoomHookContext _ctx(ChatBackend backend, {bool encrypted = false}) =>
    RoomHookContext(
      backend: backend,
      roomId: _roomId,
      palette: _palette,
      room: ChatRoom(
        id: _roomId,
        name: 'Room',
        preview: '',
        lastActivity: null,
        encrypted: encrypted,
      ),
    );

Future<BuildContext> _host(
  WidgetTester tester, {
  List<Widget> Function(BuildContext context)? children,
}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            captured = context;
            return ListView(children: children?.call(context) ?? const []);
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  group('Send later', () {
    testWidgets('option schedules a preset and consumes the draft', (
      tester,
    ) async {
      final backend = _ScheduledBackend();
      final context = await _host(tester);
      final options = scheduledSendOptions(context, _ctx(backend));
      expect(options.single.label, 'Send later…');
      final before = DateTime.now();
      final result = options.single.onSelected(
        context,
        const ComposerDraft(text: '  Hello later  ', replyToId: r'$parent'),
      );
      await tester.pumpAndSettle();
      expect(find.text('SEND LATER'), findsOneWidget);
      expect(find.text('Hello later'), findsOneWidget);
      expect(find.text(encryptedScheduleNote), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('scheduled.preset.in_30_minutes')),
      );
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      final (draft, sendAt) = backend.scheduled.single;
      expect(draft.text, 'Hello later');
      expect(draft.replyToId, r'$parent');
      expect(sendAt.difference(before).inMinutes, inInclusiveRange(29, 31));
      expect(find.textContaining('Scheduled for'), findsOneWidget);
    });

    testWidgets('a custom date and time can be picked', (tester) async {
      final backend = _ScheduledBackend();
      final context = await _host(tester);
      final now = DateTime(2026, 11, 12, 10, 20);
      final result = sendDraftLater(
        context,
        _ctx(backend),
        const ComposerDraft(text: 'Custom'),
        clock: () => now,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scheduled.preset.custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(backend.scheduled.single.$2, DateTime(2026, 11, 12, 11));
    });

    testWidgets('encrypted rooms explain who can read it; limits disable '
        'presets', (tester) async {
      final backend = _ScheduledBackend()
        ..capability = const DelayedEventsCapability(
          supported: true,
          maxDelay: Duration(hours: 1),
        );
      final context = await _host(tester);
      final result = sendDraftLater(
        context,
        _ctx(backend, encrypted: true),
        const ComposerDraft(text: 'Secret'),
        clock: () => DateTime(2026, 11, 11, 10),
      );
      await tester.pumpAndSettle();
      expect(find.text(encryptedScheduleNote), findsOneWidget);
      final tomorrow = tester.widget<ListTile>(
        find.byKey(const ValueKey('scheduled.preset.tomorrow_morning')),
      );
      expect(tomorrow.enabled, isFalse);
      expect(
        find.text('Further ahead than your homeserver allows'),
        findsWidgets,
      );
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('scheduled.preset.in_30_minutes')),
            )
            .enabled,
        isTrue,
      );
      Navigator.of(tester.element(find.text('Secret'))).pop();
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      expect(backend.scheduled, isEmpty);
    });

    testWidgets('unsupported homeservers, probe failures and edits keep the '
        'draft', (tester) async {
      final backend = _ScheduledBackend()
        ..capability = const DelayedEventsCapability.unsupported();
      final context = await _host(tester);
      final unsupported = sendDraftLater(
        context,
        _ctx(backend),
        const ComposerDraft(text: 'Hi'),
      );
      await tester.pump();
      expect(await unsupported, isFalse);
      await tester.pump();
      expect(
        find.text('Your homeserver doesn’t support scheduled messages.'),
        findsOneWidget,
      );

      backend.capabilityError = StateError('offline');
      final failed = sendDraftLater(
        context,
        _ctx(backend),
        const ComposerDraft(text: 'Hi'),
      );
      await tester.pump();
      expect(await failed, isFalse);

      final edit = sendDraftLater(
        context,
        _ctx(backend),
        const ComposerDraft(text: 'Hi', editing: true),
      );
      expect(await edit, isFalse);
      expect(backend.scheduled, isEmpty);
      await tester.pumpAndSettle();
    });

    testWidgets('server errors keep the draft unless it was sent', (
      tester,
    ) async {
      final backend = _ScheduledBackend()
        ..scheduleError = const DelayedEventException(
          DelayedEventFailure.limited,
        );
      final context = await _host(tester);
      Future<bool> attempt() async {
        final result = sendDraftLater(
          context,
          _ctx(backend),
          const ComposerDraft(text: 'Hi'),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('scheduled.preset.in_30_minutes')),
        );
        await tester.pumpAndSettle();
        return result;
      }

      expect(await attempt(), isFalse);
      expect(
        find.textContaining('isn’t accepting more scheduled messages'),
        findsOneWidget,
      );
      backend.scheduleError = const DelayedEventException(
        DelayedEventFailure.sentImmediately,
      );
      expect(await attempt(), isTrue);
    });

    testWidgets('backends without delayed events add nothing', (tester) async {
      final backend = FakeBackend();
      final context = await _host(tester);
      expect(scheduledSendOptions(context, _ctx(backend)), isEmpty);
      expect(scheduledRoomBanners(context, _ctx(backend)), isEmpty);
    });
  });

  group('scheduled list', () {
    testWidgets('banner counts this room and is hidden when empty', (
      tester,
    ) async {
      final backend = _ScheduledBackend();
      final soon = DateTime.now().add(const Duration(hours: 2));
      await _host(
        tester,
        children: (context) => scheduledRoomBanners(context, _ctx(backend)),
      );
      expect(find.byKey(const ValueKey('scheduled.banner')), findsNothing);
      backend.items
        ..add(_message('syd_a', 'First', soon))
        ..add(_message('syd_other', 'Elsewhere', soon, roomId: '!other:s'));
      backend.notifyListeners();
      await tester.pump();
      expect(find.text('1 scheduled message'), findsOneWidget);
      backend.items.add(
        _message('syd_b', 'Second', soon.add(const Duration(days: 1))),
      );
      backend.notifyListeners();
      await tester.pump();
      expect(find.text('2 scheduled messages'), findsOneWidget);
      expect(find.textContaining('Next: '), findsOneWidget);
    });

    testWidgets('sheet sends now, cancels and reschedules', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = _ScheduledBackend();
      final soon = DateTime.now().add(const Duration(hours: 2));
      backend.items
        ..add(_message('syd_a', 'First message', soon))
        ..add(
          _message(
            'syd_b',
            'Second message',
            soon.add(const Duration(hours: 1)),
            encrypted: true,
          ),
        )
        ..add(
          _message(
            'syd_c',
            'Third message',
            soon.add(const Duration(hours: 2)),
          ),
        );
      await _host(
        tester,
        children: (context) => scheduledRoomBanners(context, _ctx(backend)),
      );
      await tester.tap(find.byKey(const ValueKey('scheduled.banner')));
      await tester.pumpAndSettle();
      expect(backend.refreshes, 1);
      expect(find.text('First message'), findsOneWidget);
      expect(find.text('Second message'), findsOneWidget);
      expect(
        find.textContaining('People who joined after that'),
        findsOneWidget,
      );

      Finder inItem(String id, String text) => find.descendant(
        of: find.byKey(ValueKey('scheduled.item.$id')),
        matching: find.text(text),
      );

      await tester.tap(inItem('syd_a', 'Send now'));
      await tester.pumpAndSettle();
      expect(backend.sentNow, ['syd_a']);
      expect(find.text('Message sent.'), findsOneWidget);

      await tester.tap(inItem('syd_b', 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel this scheduled message?'), findsOneWidget);
      await tester.tap(find.text('Cancel message'));
      await tester.pumpAndSettle();
      expect(backend.cancelled, ['syd_b']);
      expect(find.text('Scheduled message cancelled.'), findsOneWidget);

      await tester.tap(inItem('syd_c', 'Reschedule'));
      await tester.pumpAndSettle();
      expect(find.text('RESCHEDULE'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('scheduled.preset.in_30_minutes')),
      );
      await tester.pumpAndSettle();
      expect(backend.rescheduled.single.$1, 'syd_c');
      expect(find.textContaining('Rescheduled for'), findsOneWidget);
      expect(find.text('Third message'), findsOneWidget);
    });

    testWidgets('a failed action explains and refreshes', (tester) async {
      final backend = _ScheduledBackend()
        ..manageError = const DelayedEventException(
          DelayedEventFailure.notFound,
        );
      backend.items.add(
        _message('syd_a', 'Gone', DateTime.now().add(const Duration(hours: 1))),
      );
      await _host(
        tester,
        children: (context) => scheduledRoomBanners(context, _ctx(backend)),
      );
      await tester.tap(find.byKey(const ValueKey('scheduled.banner')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send now'));
      await tester.pumpAndSettle();
      expect(
        find.text('This message was already sent or cancelled.'),
        findsOneWidget,
      );
      expect(backend.refreshes, 2);
    });
  });

  group('Undo send setting', () {
    testWidgets('persists the chosen grace period', (tester) async {
      SharedPreferences.setMockInitialValues({
        UndoSendPreferences.secondsKey: 10,
      });
      final prefs = UndoSendPreferences(
        preferences: await SharedPreferences.getInstance(),
      );
      await _host(
        tester,
        children: (_) => [
          UndoSendSettingsSection(palette: _palette, preferences: prefs),
        ],
      );
      await tester.pumpAndSettle();
      expect(prefs.seconds, 10);
      expect(find.text('Undo send'), findsOneWidget);
      expect(find.textContaining('wait 10 seconds'), findsOneWidget);
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      expect(prefs.seconds, 0);
      expect(
        (await SharedPreferences.getInstance()).getInt(
          UndoSendPreferences.secondsKey,
        ),
        0,
      );
      expect(find.text('Messages are sent straight away.'), findsOneWidget);
      await tester.tap(find.text('20 s'));
      await tester.pumpAndSettle();
      expect(prefs.delay, const Duration(seconds: 20));
    });

    test('defaults to 5 s and ignores unsupported saved values', () async {
      SharedPreferences.setMockInitialValues({
        UndoSendPreferences.secondsKey: 7,
      });
      final prefs = UndoSendPreferences(
        preferences: await SharedPreferences.getInstance(),
      );
      expect(await prefs.resolveDelay(), const Duration(seconds: 5));
      expect(() => prefs.setSeconds(7), throwsArgumentError);
    });

    testWidgets('Settings → Appearance can turn undo send off', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: AppearanceSettingsScreen(preferences: AppearancePreferences()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Undo send'), findsOneWidget);
      expect(find.text('5 s'), findsOneWidget);
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(UndoSendPreferences.secondsKey), 0);
      expect(find.text('Messages are sent straight away.'), findsOneWidget);
      // Back to the default for other tests sharing the instance.
      await UndoSendPreferences.shared.setSeconds(
        UndoSendPreferences.defaultSeconds,
      );
    });
  });
}

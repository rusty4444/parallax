// Hook implementations for the reminders module.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../threads/timeline_navigation.dart';
import 'reminders.dart';
import 'reminders_screen.dart';

/// Wraps the signed-in app: binds the reminder store to the account and routes
/// reminder notification taps to the message.
Widget wrapWithReminders(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => _RemindersHost(backend: ctx.backend, child: child);

class _RemindersHost extends StatefulWidget {
  const _RemindersHost({required this.backend, required this.child});
  final ChatBackend backend;
  final Widget child;

  @override
  State<_RemindersHost> createState() => _RemindersHostState();
}

class _RemindersHostState extends State<_RemindersHost> {
  final _store = ReminderStore.shared;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(_RemindersHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) _bind();
  }

  void _bind() {
    unawaited(_store.bindAccount(BackendSessionOwner.keyFor(widget.backend)));
    final backend = widget.backend;
    ReminderScheduler.instance.onOpen = (roomId, eventId) {
      timelineNavigationOf(backend)?.openRoomAt(roomId, eventId);
    };
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Long-press message action: "Remind me…".
List<MessageActionItem> reminderMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final entry = ctx.entry;
  if (entry.kind == EntryKind.state ||
      entry.redacted ||
      !entry.id.startsWith(r'$') ||
      !ctx.roomId.startsWith('!')) {
    return const [];
  }
  return [
    MessageActionItem(
      id: 'reminders.remind',
      icon: Icons.alarm_add_outlined,
      label: 'Remind me…',
      onSelected: (context) => showReminderSheet(
        context,
        backend: ctx.backend,
        palette: ctx.palette,
        roomId: ctx.roomId,
        eventId: entry.id,
        snippet: entry.body,
      ),
    ),
  ];
}

/// Settings → Chats → Reminders.
List<Widget> remindersChatsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final store = ReminderStore.shared;
  return [
    ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final count = store.reminders.length;
        return ListTile(
          key: const ValueKey('reminders-row'),
          leading: const Icon(Icons.alarm_outlined),
          title: const Text('Reminders'),
          subtitle: Text(
            count == 0 ? 'No pending reminders' : '$count pending',
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => RemindersScreen(
                backend: ctx.backend,
                palette: ctx.palette,
                store: store,
              ),
            ),
          ),
        );
      },
    ),
  ];
}

/// Preset picker for a reminder, then schedules it.
Future<void> showReminderSheet(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required String roomId,
  required String eventId,
  required String snippet,
}) async {
  final choice = await showModalBottomSheet<Duration?>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      Widget option(String label, Duration? value, {IconData? icon}) =>
          ListTile(
            leading: Icon(icon ?? Icons.schedule_rounded),
            title: Text(label),
            onTap: () => Navigator.pop(sheetContext, value),
          );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Remind me about this message',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            option('In 20 minutes', const Duration(minutes: 20)),
            option('In 1 hour', const Duration(hours: 1)),
            option('In 3 hours', const Duration(hours: 3)),
            option('Tomorrow morning', _untilTomorrowMorning()),
            option(
              'Pick date & time…',
              const Duration(days: -1),
              icon: Icons.event_outlined,
            ),
          ],
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return;
  DateTime fireAt;
  if (choice == const Duration(days: -1)) {
    final picked = await _pickCustom(context);
    if (picked == null || !context.mounted) return;
    fireAt = picked;
  } else {
    fireAt = DateTime.now().add(choice);
  }
  final reminder = Reminder(
    id: '$eventId-${Random.secure().nextInt(0x7fffffff)}',
    roomId: roomId,
    eventId: eventId,
    snippet: snippet.length > 120 ? snippet.substring(0, 120) : snippet,
    fireAt: fireAt,
  );
  await ReminderStore.shared.add(reminder);
  await ReminderScheduler.instance.schedule(reminder);
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Reminder set.')));
  }
}

Duration _untilTomorrowMorning() {
  final now = DateTime.now();
  final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
  return tomorrow.difference(now);
}

Future<DateTime?> _pickCustom(BuildContext context) async {
  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: now,
    firstDate: now,
    lastDate: now.add(const Duration(days: 365)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

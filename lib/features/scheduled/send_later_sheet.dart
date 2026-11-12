import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../hooks/hook_types.dart';
import '../../widgets.dart';
import 'delayed_events.dart';
import 'schedule_presets.dart';
import 'scheduled_features.dart';

const _customChoice = Object();

/// Copy shown wherever an encrypted message is scheduled.
const encryptedScheduleNote =
    'Encrypted now. People who join the room after you schedule it won’t be '
    'able to read it.';

/// Lets the user pick when to send: presets or a custom date and time.
/// Returns a local wall-clock time, or null when dismissed.
Future<DateTime?> showSendLaterPicker(
  BuildContext context, {
  required AppPalette palette,
  required String preview,
  required bool encrypted,
  Duration? maxDelay,
  String title = 'Send later',
  DateTime Function() clock = DateTime.now,
}) async {
  final now = clock();
  final limit = maxDelay == null || maxDelay > maxScheduleDelay
      ? maxScheduleDelay
      : maxDelay;
  final presets = schedulePresets(now);
  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: palette.surface,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Eyebrow(title, palette: palette),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.muted),
            ),
          ),
          if (encrypted)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline, size: 16, color: palette.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      encryptedScheduleNote,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          for (final preset in presets)
            ListTile(
              key: ValueKey('scheduled.preset.${preset.id}'),
              enabled:
                  !preset.at.difference(now).isNegative &&
                  preset.at.difference(now) <= limit,
              leading: Icon(_iconFor(preset.id), color: palette.secondary),
              title: Text(preset.label),
              subtitle: Text(
                preset.at.difference(now) <= limit
                    ? describeSendTime(preset.at, now: now)
                    : 'Further ahead than your homeserver allows',
              ),
              onTap: () => Navigator.pop(sheetContext, preset.at),
            ),
          ListTile(
            key: const ValueKey('scheduled.preset.custom'),
            leading: Icon(
              Icons.edit_calendar_outlined,
              color: palette.secondary,
            ),
            title: const Text('Pick date and time…'),
            onTap: () => Navigator.pop(sheetContext, _customChoice),
          ),
        ],
      ),
    ),
  );
  if (choice is DateTime) return choice;
  if (!identical(choice, _customChoice) || !context.mounted) return null;
  final today = DateTime(now.year, now.month, now.day);
  final latest = now.add(limit);
  final date = await showDatePicker(
    context: context,
    initialDate: today,
    firstDate: today,
    lastDate: DateTime(latest.year, latest.month, latest.day),
    helpText: 'Send on',
  );
  if (date == null || !context.mounted) return null;
  final suggested = now.add(const Duration(hours: 1));
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: suggested.hour, minute: 0),
    helpText: 'Send at',
  );
  if (time == null) return null;
  return combineDateAndTime(date, time.hour, time.minute);
}

IconData _iconFor(String id) => switch (id) {
  'in_30_minutes' => Icons.timer_outlined,
  'tonight' => Icons.nights_stay_outlined,
  'tomorrow_morning' => Icons.wb_sunny_outlined,
  _ => Icons.event_outlined,
};

/// The composer's "Send later…" option: checks support, asks when, then
/// schedules the draft. Returns true when the draft was consumed.
Future<bool> sendDraftLater(
  BuildContext context,
  RoomHookContext ctx,
  ComposerDraft draft, {
  DateTime Function() clock = DateTime.now,
}) async {
  final features = scheduledFeaturesOf(ctx.backend);
  final messenger = ScaffoldMessenger.maybeOf(context);
  void show(String text) =>
      messenger?.showSnackBar(SnackBar(content: Text(text)));
  if (features == null) return false;
  if (draft.editing) {
    show('Edits can’t be scheduled.');
    return false;
  }
  final text = draft.text.trim();
  if (text.isEmpty) {
    show('Write a message first.');
    return false;
  }
  final DelayedEventsCapability capability;
  try {
    capability = await features.delayedEventsCapability();
  } catch (error) {
    show(
      scheduledErrorMessage(
        error is DelayedEventException
            ? error
            : const DelayedEventException(DelayedEventFailure.probeFailed),
      ),
    );
    return false;
  }
  if (!capability.supported) {
    show(
      scheduledErrorMessage(
        const DelayedEventException(DelayedEventFailure.unsupported),
      ),
    );
    return false;
  }
  if (!context.mounted) return false;
  final when = await showSendLaterPicker(
    context,
    palette: ctx.palette,
    preview: text,
    encrypted: ctx.encrypted,
    maxDelay: capability.maxDelay,
    clock: clock,
  );
  if (when == null) return false;
  try {
    final message = await features.scheduleDraft(
      ctx.roomId,
      ComposerDraft(
        text: text,
        replyToId: draft.replyToId,
        threadRootId: draft.threadRootId,
      ),
      when,
    );
    show('Scheduled for ${describeSendTime(message.sendAt, now: clock())}.');
    return true;
  } on DelayedEventException catch (error) {
    show(scheduledErrorMessage(error));
    // The server sent it: the draft was consumed.
    return error.kind == DelayedEventFailure.sentImmediately;
  } catch (error) {
    show(scheduledErrorMessage(error));
    return false;
  }
}

import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import '../../room_events.dart';
import 'delayed_events.dart';
import 'matrix_scheduled.dart';
import 'schedule_presets.dart';
import 'scheduled_store.dart';

export 'delayed_events.dart'
    show
        DelayedEventException,
        DelayedEventFailure,
        DelayedEventsCapability,
        DelayedRoomEventSender;
export 'scheduled_store.dart' show ScheduledMessage;

enum ScheduledLoadState { idle, loading, ready, failed }

/// "Send later" (MSC4140 delayed events) for the scheduled module.
///
/// The live implementation is [MatrixScheduledMessages]; tests implement
/// this directly on a fake backend.
abstract interface class ScheduledFeatures {
  /// Notifies when the scheduled list or its load state changes.
  Listenable get scheduledUpdates;

  ScheduledLoadState get scheduledState;

  /// True when the last refresh could not read local records (previews of
  /// encrypted messages may be missing).
  bool get localRecordsUnavailable;

  /// Scheduled messages in [roomId], earliest first (cached).
  List<ScheduledMessage> scheduledIn(String roomId);

  /// Starts the first load (idempotent, never notifies synchronously).
  void ensureScheduledLoaded();

  /// Re-reads local records and the server list (single-flight).
  Future<void> refreshScheduled();

  /// Homeserver support and limits (cached briefly).
  Future<DelayedEventsCapability> delayedEventsCapability({
    bool refresh = false,
  });

  /// Schedules [draft] (composed exactly like a normal send) for [sendAt].
  Future<ScheduledMessage> scheduleDraft(
    String roomId,
    ComposerDraft draft,
    DateTime sendAt,
  );

  Future<void> sendScheduledNow(ScheduledMessage message);
  Future<void> cancelScheduled(ScheduledMessage message);

  /// Schedules the same content at [sendAt], then cancels the original.
  Future<ScheduledMessage> rescheduleScheduled(
    ScheduledMessage message,
    DateTime sendAt,
  );
}

final Expando<MatrixScheduledMessages> _matrixScheduled = Expando(
  'parallax.scheduled',
);

/// Scheduled messages for [backend], or null when unsupported.
ScheduledFeatures? scheduledFeaturesOf(ChatBackend backend) {
  if (backend is ScheduledFeatures) return backend as ScheduledFeatures;
  if (backend is MatrixSdkAccess && backend is DelayedRoomEventSender) {
    return _matrixScheduled[backend] ??= MatrixScheduledMessages(
      backend,
      backend as MatrixSdkAccess,
      backend as DelayedRoomEventSender,
    );
  }
  return null;
}

/// User-facing text for a scheduling failure.
String scheduledErrorMessage(Object error) {
  if (error is DelayedEventException) {
    return switch (error.kind) {
      DelayedEventFailure.unsupported =>
        'Your homeserver doesn’t support scheduled messages.',
      DelayedEventFailure.delayTooLarge =>
        error.maxDelay == null
            ? 'That’s further ahead than your homeserver allows. '
                  'Choose an earlier time.'
            : 'Your homeserver only lets you schedule messages up to '
                  '${describeDuration(error.maxDelay!)} ahead.',
      DelayedEventFailure.limited =>
        'Your homeserver isn’t accepting more scheduled messages right now. '
            'Try again later, or cancel one you no longer need.',
      DelayedEventFailure.notFound =>
        'This message was already sent or cancelled.',
      DelayedEventFailure.sentImmediately =>
        'Your homeserver sent this message straight away instead of '
            'scheduling it.',
      DelayedEventFailure.encryptionUnavailable =>
        'Encryption isn’t available right now, so nothing was scheduled.',
      DelayedEventFailure.probeFailed =>
        'Couldn’t check whether your homeserver supports scheduled messages.',
      DelayedEventFailure.invalidResponse =>
        'Your homeserver gave an unexpected answer. Check the scheduled '
            'messages list before trying again.',
    };
  }
  if (error is ScheduleInputError) return error.message;
  return 'Couldn’t schedule this message. Try again.';
}

/// A user-facing reason a schedule request was refused or only partly done.
class ScheduleInputError implements Exception {
  const ScheduleInputError(this.message);
  final String message;

  @override
  String toString() => 'ScheduleInputError: $message';
}

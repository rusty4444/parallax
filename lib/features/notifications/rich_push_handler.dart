// Turns a verified push envelope into a rich notification (Element X:
// DefaultNotificationDrawerManager), falling back to the generic alert
// whenever the event cannot be fetched, decrypted or rendered in time.
// Used identically by the main isolate (live client) and background isolates
// (short-lived read-only client).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../push_notifications.dart';
import 'notification_content.dart';
import 'notification_model.dart';
import 'notification_renderer.dart';
import 'notification_store.dart';
import 'matrix_push_projection.dart' show SilentPushEvent;

/// Fetches and decrypts the envelope's event. Returns null when the event
/// was already read (nothing to show); throws when it cannot be resolved.
typedef PushEventResolver =
    Future<ResolvedPushEvent?> Function(
      PushEnvelope envelope,
      NotificationPreferences preferences,
    );

enum RichPushOutcome {
  /// Sender, text and (optionally) media were shown.
  rich,

  /// The generic "New message" alert was shown.
  generic,

  /// The event was already read; the room's notification was cleared.
  seen,

  /// The session or registration changed; nothing was posted.
  skipped,
}

class RichPushHandler {
  RichPushHandler({
    required this.store,
    required this.surface,
    required this.resolve,
    required this.userId,
    required this.deviceId,
    this.contentUriFor,
    this.resolveTimeout = const Duration(seconds: 15),
    bool Function()? isCurrent,
    this.confirm,
    this.suppressRoom,
    this.carProjecting,
    DateTime Function()? clock,
    bool? showSummary,
    bool? clearAllWhenRead,
  }) : _isCurrent = isCurrent ?? _always,
       _clock = clock ?? DateTime.now,
       showSummary =
           showSummary ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
       clearAllWhenRead =
           clearAllWhenRead ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows);

  static bool _always() => true;

  /// Whether rooms are grouped under a summary notification. Only Android
  /// groups notifications that way; elsewhere a summary would be one more
  /// alert (a second toast on Windows, an extra entry on Apple platforms).
  final bool showSummary;

  /// Windows cannot take back a single toast of an app installed outside
  /// the Store (they carry no group, and the plugin removes by tag only with
  /// package identity), so a read chat's toast would stay in the
  /// notification centre. Clearing all of Parallax's toasts once no notified
  /// chat is left unread covers the usual case: reading everything.
  final bool clearAllWhenRead;

  /// Asynchronous ownership check run right before posting (background
  /// isolates re-read the stored push binding).
  final Future<bool> Function()? confirm;

  Future<bool> _stillCurrent() async {
    if (!_isCurrent()) return false;
    final confirm = this.confirm;
    if (confirm == null) return true;
    try {
      return await confirm() && _isCurrent();
    } catch (_) {
      return false;
    }
  }

  final NotificationStore? store;
  final NotificationSurface surface;
  final PushEventResolver resolve;
  final String userId;
  final String deviceId;

  /// Maps a preview file to its FileProvider URI; null disables images.
  final String? Function(String path)? contentUriFor;
  final Duration resolveTimeout;
  final bool Function() _isCurrent;

  /// True for a room the user is looking at (no notification, as Element X).
  final bool Function(String roomId)? suppressRoom;

  /// Whether the phone is connected to Android Auto, which reads only
  /// MessagingStyle notifications (null: never).
  final Future<bool> Function()? carProjecting;

  Future<bool> _carProjecting() async {
    final projecting = carProjecting;
    if (projecting == null) return false;
    try {
      return await projecting();
    } catch (_) {
      // Unknown: the car layout is safe on the phone too.
      return true;
    }
  }

  final DateTime Function() _clock;

  String get account => notificationAccountKey(userId, deviceId);

  Future<RichPushOutcome> handle(PushEnvelope envelope) async {
    if (!_isCurrent()) return RichPushOutcome.skipped;
    try {
      final preferences = store == null
          ? const NotificationPreferences()
          : await store!.readPreferences();
      if (!preferences.showContent || envelope.eventId == null) {
        return await _generic(envelope);
      }
      final resolved = await resolve(
        envelope,
        preferences,
      ).timeout(resolveTimeout);
      if (!await _stillCurrent()) return RichPushOutcome.skipped;
      if (resolved == null) {
        await clearRooms([envelope.roomId]);
        return RichPushOutcome.seen;
      }
      if (resolved.roomId != envelope.roomId ||
          resolved.eventId != envelope.eventId) {
        return await _generic(envelope);
      }
      if (suppressRoom?.call(resolved.roomId) == true) {
        return RichPushOutcome.skipped;
      }
      final registration = envelope.registrationId;
      if (resolved.kind == NotifiableEventKind.call && resolved.ringing) {
        await surface.show(renderCall(resolved, registrationId: registration));
        return RichPushOutcome.rich;
      }
      if (resolved.kind == NotifiableEventKind.invite) {
        await surface.show(
          renderInvite(resolved, registrationId: registration),
        );
        return RichPushOutcome.rich;
      }
      final thread = await _append(resolved);
      final car = await _carProjecting();
      if (!await _stillCurrent()) return RichPushOutcome.skipped;
      await surface.show(
        renderRoomThread(
          thread,
          myUserId: userId,
          registrationId: registration,
          contentUriFor: preferences.mediaEnabled ? contentUriFor : null,
          carProjecting: car,
        ),
      );
      await _refreshSummary(fallback: [thread]);
      return RichPushOutcome.rich;
    } on SilentPushEvent {
      // Live-location beacons and call membership never notify.
      return RichPushOutcome.skipped;
    } catch (_) {
      if (!_isCurrent()) return RichPushOutcome.skipped;
      return _generic(envelope);
    }
  }

  Future<RoomNotificationThread> _append(ResolvedPushEvent event) async {
    final store = this.store;
    if (store != null) {
      try {
        return await store.appendEvent(account, event);
      } catch (_) {
        // History is a nicety: show the single message instead.
      }
    }
    return RoomNotificationThread(
      roomId: event.roomId,
      roomName: event.roomName,
      isDirect: event.isDirect,
      roomAvatarPath: event.roomAvatarPath,
      latestEventId: event.eventId,
      lines: [event.line],
    );
  }

  Future<RichPushOutcome> _generic(PushEnvelope envelope) async {
    if (!await _stillCurrent()) return RichPushOutcome.skipped;
    try {
      await surface.showGeneric(envelope);
    } catch (_) {
      // Nothing else can be shown.
    }
    return RichPushOutcome.generic;
  }

  Future<void> _refreshSummary({
    List<RoomNotificationThread> fallback = const [],
  }) async {
    if (!showSummary) return;
    var threads = fallback;
    try {
      if (store != null) threads = await store!.threads(account);
    } catch (_) {
      // Keep the fallback.
    }
    try {
      if (threads.isEmpty) {
        await surface.cancel(notificationSummaryId);
      } else {
        await surface.show(renderSummary(threads));
      }
    } catch (_) {
      // The summary is cosmetic.
    }
  }

  /// Clears the notifications of rooms that were opened or read.
  Future<void> clearRooms(Iterable<String> roomIds) async {
    final ids = roomIds.toSet();
    if (ids.isEmpty) return;
    for (final roomId in ids) {
      try {
        await surface.cancel(roomNotificationId(roomId));
        await surface.cancel(callNotificationId(roomId));
        await surface.cancel(inviteNotificationId(roomId));
      } catch (_) {
        // Best effort.
      }
    }
    try {
      await store?.removeRooms(account, ids);
    } catch (_) {
      // Best effort.
    }
    if (clearAllWhenRead && store != null) {
      try {
        if ((await store!.threads(account)).isEmpty) await surface.cancelAll();
      } catch (_) {
        // Best effort.
      }
    }
    await _refreshSummary();
  }

  /// Clears every rich notification and the history (content turned off,
  /// sign-out).
  Future<void> clearAll() async {
    try {
      final threads = await store?.threads(account) ?? const [];
      for (final thread in threads) {
        await surface.cancel(roomNotificationId(thread.roomId));
      }
      await surface.cancel(notificationSummaryId);
    } catch (_) {
      // Best effort.
    }
    try {
      await store?.clearHistory();
    } catch (_) {
      // Best effort.
    }
  }

  /// Updates a room's notification after a quick reply: appends the typed
  /// text as "Me" (no new alert) and an optional [statusLine] (failure or
  /// waiting for the app). Re-posting also clears the reply spinner Android
  /// shows until the notification is updated.
  Future<void> showReplyResult(
    String roomId,
    String text, {
    required String registrationId,
    String? statusLine,
    bool appendReply = true,
  }) async {
    try {
      RoomNotificationThread? thread;
      final line = appendReply
          ? ownReplyLine(userId: userId, text: text, now: _clock())
          : null;
      final store = this.store;
      if (store != null && userId.isNotEmpty) {
        thread = line == null
            ? await store.thread(account, roomId)
            : await store.appendOwnLine(account, roomId, line);
      }
      if (thread == null) {
        if (statusLine == null) {
          await surface.cancel(roomNotificationId(roomId));
        } else {
          await surface.show(
            renderReplyStatus(
              roomId,
              statusLine,
              registrationId: registrationId,
            ),
          );
        }
        return;
      }
      final preferences = store == null
          ? const NotificationPreferences()
          : await store.readPreferences();
      final car = await _carProjecting();
      await surface.show(
        renderRoomThread(
          thread,
          myUserId: userId,
          registrationId: registrationId,
          contentUriFor: preferences.mediaEnabled ? contentUriFor : null,
          alert: false,
          statusLine: statusLine,
          carProjecting: car,
        ),
      );
    } catch (_) {
      try {
        await surface.cancel(roomNotificationId(roomId));
      } catch (_) {
        // Nothing else to do.
      }
    }
  }
}

/// Failure line appended when a quick reply could not be sent.
const quickReplyFailedLine =
    'Couldn’t send your reply. Open the room to try again.';

/// Line appended when a quick reply waits for Parallax to open.
const quickReplyPendingLine = 'Reply not sent yet. Open Parallax to send it.';

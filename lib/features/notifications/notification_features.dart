// Module interface for the notifications feature and its live Matrix
// implementation (main isolate). The live client fetches and decrypts push
// events; quick replies go through the backend's normal guarded text send.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../push_notifications.dart';
import '../../room_events.dart';
import 'matrix_push_projection.dart';
import 'notification_media.dart';
import 'notification_model.dart';

/// An event this device's sync received that should notify.
typedef SyncedNotification = ({String roomId, String eventId});

/// Maps an SDK `onNotification` event to what the built-in delivery shows.
/// Null for events that never notify (beacons, call membership) or carry no
/// usable ID. The SDK reports a new invite with a synthetic event ID, which
/// becomes a stable `$`-prefixed one per room.
SyncedNotification? syncedNotificationFor({
  required String roomId,
  required String eventId,
  required String type,
}) {
  if (silentPushEventTypes.contains(type)) return null;
  if (type == matrix.EventTypes.RoomMember && eventId == 'invite_for_$roomId') {
    return (roomId: roomId, eventId: '\$invite:$roomId');
  }
  if (!eventId.startsWith(r'$') || eventId.length > 1024) return null;
  return (roomId: roomId, eventId: eventId);
}

abstract interface class NotificationFeatures {
  /// The signed-in account and device, or null when signed out.
  String? get userId;
  String? get deviceId;

  /// Events the account's push rules say should notify, as this device's own
  /// sync receives them (built-in delivery). Never the initial sync or your
  /// own messages.
  Stream<SyncedNotification> get syncNotifications;

  /// Fetches and decrypts [envelope]'s event with the live client. Returns
  /// null when it was already read; throws when it cannot be resolved.
  /// Media and avatars are cached under [cacheRoot] (null: no media).
  Future<ResolvedPushEvent?> resolvePush(
    PushEnvelope envelope,
    NotificationPreferences preferences, {
    Directory? cacheRoot,
  });

  /// Sends [text] to [roomId] through the guarded send path (recipient
  /// trust, fail-closed encryption, final HTTP guard).
  Future<void> sendQuickReply(String roomId, String text);
}

final _cache = Expando<NotificationFeatures>('notificationFeatures');

NotificationFeatures? notificationFeaturesOf(ChatBackend backend) {
  if (backend is NotificationFeatures) return backend as NotificationFeatures;
  if (backend is MatrixSdkAccess) {
    return _cache[backend] ??= MatrixNotificationFeatures(backend);
  }
  return null;
}

class NotificationSessionChanged implements Exception {
  const NotificationSessionChanged();
  @override
  String toString() => 'The account changed before the notification resolved.';
}

class MatrixNotificationFeatures implements NotificationFeatures {
  MatrixNotificationFeatures(this._backend)
    : assert(_backend is MatrixSdkAccess);

  final ChatBackend _backend;
  MatrixSdkAccess get _access => _backend as MatrixSdkAccess;

  static const serverTimeout = Duration(seconds: 8);
  static const sendWait = Duration(seconds: 20);

  /// Member names checked with the server by this session's notifications,
  /// and the session (client, account, device) they belong to.
  MemberRefreshLedger? _memberRefreshes;
  (matrix.Client, String?, String?)? _memberRefreshesOwner;

  /// This session's ledger; a new one after sign-out or an account change.
  @visibleForTesting
  MemberRefreshLedger memberRefreshesFor(matrix.Client client) {
    final owner = (client, client.userID, client.deviceID);
    if (_memberRefreshesOwner != owner) {
      _memberRefreshes = MemberRefreshLedger();
      _memberRefreshesOwner = owner;
    }
    return _memberRefreshes!;
  }

  /// The signed-in session's client, or null. Forgets the member ledger as
  /// soon as the session ends, rather than at the next notification.
  matrix.Client? _currentClient() {
    final client = _access.sdkClient;
    if (client != null && _access.isSessionCurrent(client)) return client;
    _memberRefreshes = null;
    _memberRefreshesOwner = null;
    return null;
  }

  matrix.Client _client() {
    final client = _currentClient();
    if (client == null || client.userID == null || client.deviceID == null) {
      throw const NotificationSessionChanged();
    }
    return client;
  }

  void _check(matrix.Client client) {
    if (!_access.isSessionCurrent(client)) {
      throw const NotificationSessionChanged();
    }
  }

  @override
  String? get userId => _currentClient()?.userID;

  @override
  String? get deviceId => _currentClient()?.deviceID;

  @override
  Stream<SyncedNotification> get syncNotifications {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) {
      return const Stream.empty();
    }
    return client.onNotification.stream
        .where((_) => _access.isSessionCurrent(client))
        .map(
          (event) => syncedNotificationFor(
            roomId: event.room.id,
            eventId: event.eventId,
            type: event.type,
          ),
        )
        .where((notification) => notification != null)
        .cast<SyncedNotification>();
  }

  @override
  Future<ResolvedPushEvent?> resolvePush(
    PushEnvelope envelope,
    NotificationPreferences preferences, {
    Directory? cacheRoot,
  }) async {
    final client = _client();
    final me = client.userID!;
    final eventId = envelope.eventId;
    if (eventId == null) throw const UndescribablePushEvent();
    final homeserver = client.homeserver;
    final token = client.accessToken;
    final media =
        cacheRoot != null &&
            preferences.showContent &&
            homeserver != null &&
            token != null
        ? NotificationMediaLoader(
            httpClient: client.httpClient,
            homeserver: homeserver,
            accessToken: token,
            cacheRoot: cacheRoot,
          )
        : null;
    final known = client.getRoomById(envelope.roomId);
    if (known != null && known.membership == matrix.Membership.invite) {
      final invite = await projectInvite(
        room: known,
        myUserId: me,
        eventId: eventId,
        media: media,
      );
      _check(client);
      return invite;
    }
    // Content never comes from the push: only the IDs are passed in.
    final event = await client.getEventByPushNotification(
      matrix.PushNotification(roomId: envelope.roomId, eventId: eventId),
      storeInDatabase: false,
      timeoutForServerRequests: serverTimeout,
      returnNullIfSeen: true,
    );
    _check(client);
    if (event == null) return null;
    if (event.type == matrix.EventTypes.Encrypted) {
      throw const UndescribablePushEvent();
    }
    final room = event.room;
    final resolved = await projectPushEvent(
      event: event,
      room: room,
      myUserId: me,
      isDirect: room.isDirectChat,
      highlight: pushEventHighlights(client.pushruleEvaluator, event),
      media: media,
      loadMediaPreview: preferences.mediaEnabled,
      memberRefreshes: memberRefreshesFor(client),
    );
    _check(client);
    return resolved;
  }

  @override
  Future<void> sendQuickReply(String roomId, String text) async {
    final client = _client();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    // The backend allows one send at a time; wait for the composer's.
    final deadline = DateTime.now().add(sendWait);
    while (_backend.isRoomSending(roomId)) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Another message is still sending');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _check(client);
    }
    _check(client);
    await _backend.sendText(roomId, text);
    _check(client);
  }
}

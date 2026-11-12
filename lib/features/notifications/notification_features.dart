// Module interface for the notifications feature and its live Matrix
// implementation (main isolate). The live client fetches and decrypts push
// events; quick replies go through the backend's normal guarded text send.
import 'dart:async';
import 'dart:io';

import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../push_notifications.dart';
import '../../room_events.dart';
import 'matrix_push_projection.dart';
import 'notification_media.dart';
import 'notification_model.dart';

abstract interface class NotificationFeatures {
  /// The signed-in account and device, or null when signed out.
  String? get userId;
  String? get deviceId;

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

  matrix.Client _client() {
    final client = _access.sdkClient;
    if (client == null ||
        !_access.isSessionCurrent(client) ||
        client.userID == null ||
        client.deviceID == null) {
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
  String? get userId {
    final client = _access.sdkClient;
    return client != null && _access.isSessionCurrent(client)
        ? client.userID
        : null;
  }

  @override
  String? get deviceId {
    final client = _access.sdkClient;
    return client != null && _access.isSessionCurrent(client)
        ? client.deviceID
        : null;
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
    while (_backend.sending) {
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

// Backend surface for the platform module: link resolution, room previews,
// joins with `via` routing and notification mark-as-read.
//
// Resolved through [platformFeaturesOf]; test fakes implement
// [PlatformFeatures] directly.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';

enum LinkedRoomMembership { joined, invited, none }

@immutable
class ResolvedRoom {
  const ResolvedRoom({required this.roomId, this.via = const []});
  final String roomId;
  final List<String> via;
}

/// Preview of a room the user is not in (MSC3266 room summary).
@immutable
class RoomLinkPreview {
  const RoomLinkPreview({
    required this.roomId,
    this.name,
    this.topic,
    this.alias,
    this.members,
    this.joinRule,
    this.isSpace = false,
    this.encrypted = false,
  });
  final String roomId;
  final String? name;
  final String? topic;
  final String? alias;
  final int? members;
  final String? joinRule;
  final bool isSpace;
  final bool encrypted;
}

@immutable
class LinkedUserProfile {
  const LinkedUserProfile({required this.userId, this.displayName});
  final String userId;
  final String? displayName;
  String get label =>
      (displayName?.trim().isNotEmpty ?? false) ? displayName!.trim() : userId;
}

abstract interface class PlatformFeatures {
  /// Resolves an alias to a room ID (room IDs pass through). Merges the
  /// directory's routing servers with [via].
  Future<ResolvedRoom> resolveRoom(
    String roomIdOrAlias, {
    List<String> via = const [],
  });

  LinkedRoomMembership membership(String roomId);

  /// Best-effort preview; null when the server cannot summarise the room.
  Future<RoomLinkPreview?> previewRoom(
    String roomIdOrAlias, {
    List<String> via = const [],
  });

  /// Joins through [via] and waits (bounded) until sync shows membership.
  /// Joining an already-joined room is a no-op on Matrix.
  Future<String> joinRoom(String roomIdOrAlias, {List<String> via = const []});

  Future<LinkedUserProfile> userProfile(String userId);

  /// Marks a joined room read up to its latest event (falls back to
  /// [eventId]). [publicReceipt] false sends only a private receipt.
  Future<void> markRead(
    String roomId,
    String eventId, {
    required bool publicReceipt,
  });
}

final _cache = Expando<PlatformFeatures>('platformFeatures');

PlatformFeatures? platformFeaturesOf(ChatBackend backend) {
  if (backend is PlatformFeatures) return backend as PlatformFeatures;
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _cache[backend] ??= MatrixPlatformFeatures(
      backend as MatrixSdkAccess,
    );
  }
  return null;
}

class LinkSessionChanged implements Exception {
  const LinkSessionChanged();
  @override
  String toString() => 'The account changed before the link finished opening.';
}

/// Live implementation over the SDK. Never sends timeline events.
class MatrixPlatformFeatures implements PlatformFeatures {
  MatrixPlatformFeatures(this._access);
  final MatrixSdkAccess _access;

  static const joinDeadline = Duration(seconds: 30);
  static const requestDeadline = Duration(seconds: 20);

  matrix.Client _client() {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) {
      throw const LinkSessionChanged();
    }
    return client;
  }

  void _check(matrix.Client client) {
    if (!_access.isSessionCurrent(client)) throw const LinkSessionChanged();
  }

  @override
  Future<ResolvedRoom> resolveRoom(
    String roomIdOrAlias, {
    List<String> via = const [],
  }) async {
    if (!roomIdOrAlias.startsWith('#')) {
      return ResolvedRoom(roomId: roomIdOrAlias, via: via);
    }
    final client = _client();
    // A joined room with this canonical alias needs no directory lookup.
    for (final room in client.rooms) {
      if (room.canonicalAlias == roomIdOrAlias &&
          room.membership == matrix.Membership.join) {
        return ResolvedRoom(roomId: room.id, via: via);
      }
    }
    final response = await client
        .getRoomIdByAlias(roomIdOrAlias)
        .timeout(requestDeadline);
    _check(client);
    final roomId = response.roomId;
    if (roomId == null || !roomId.startsWith('!')) {
      throw StateError('Alias did not resolve');
    }
    final servers = <String>[...via];
    for (final server in response.servers ?? const <String>[]) {
      if (servers.length >= 10) break;
      if (!servers.contains(server)) servers.add(server);
    }
    return ResolvedRoom(roomId: roomId, via: List.unmodifiable(servers));
  }

  @override
  LinkedRoomMembership membership(String roomId) {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) {
      return LinkedRoomMembership.none;
    }
    return switch (client.getRoomById(roomId)?.membership) {
      matrix.Membership.join => LinkedRoomMembership.joined,
      matrix.Membership.invite => LinkedRoomMembership.invited,
      _ => LinkedRoomMembership.none,
    };
  }

  @override
  Future<RoomLinkPreview?> previewRoom(
    String roomIdOrAlias, {
    List<String> via = const [],
  }) async {
    final client = _client();
    try {
      final summary = await client
          .getRoomSummary(roomIdOrAlias, via: via.isEmpty ? null : via)
          .timeout(requestDeadline);
      _check(client);
      return RoomLinkPreview(
        roomId: summary.roomId,
        name: _bounded(summary.name, 255),
        topic: _bounded(summary.topic, 1000),
        alias: _bounded(summary.canonicalAlias, 255),
        members: summary.numJoinedMembers,
        joinRule: _bounded(summary.joinRule, 64),
        isSpace: summary.roomType == 'm.space',
        encrypted: summary.encryption != null,
      );
    } on LinkSessionChanged {
      rethrow;
    } catch (_) {
      // Room summaries are optional server support; a missing preview must
      // not block joining.
      return null;
    }
  }

  @override
  Future<String> joinRoom(
    String roomIdOrAlias, {
    List<String> via = const [],
  }) async {
    final client = _client();
    final roomId = await client
        .joinRoom(roomIdOrAlias, via: via.isEmpty ? null : via)
        .timeout(joinDeadline);
    _check(client);
    await _waitForJoin(client, roomId);
    return roomId;
  }

  Future<void> _waitForJoin(matrix.Client client, String roomId) async {
    bool joined() =>
        client.getRoomById(roomId)?.membership == matrix.Membership.join;
    if (joined()) return;
    final done = Completer<void>();
    void inspect() {
      if (done.isCompleted) return;
      if (!_access.isSessionCurrent(client)) {
        done.completeError(const LinkSessionChanged());
      } else if (joined()) {
        done.complete();
      }
    }

    final sync = client.onSyncStatus.stream.listen((_) => inspect());
    final poll = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => inspect(),
    );
    final deadline = Timer(joinDeadline, () {
      if (!done.isCompleted) {
        done.completeError(
          TimeoutException('Joined, but the room has not synced yet'),
        );
      }
    });
    try {
      inspect();
      await done.future;
    } finally {
      poll.cancel();
      deadline.cancel();
      await sync.cancel();
    }
  }

  @override
  Future<LinkedUserProfile> userProfile(String userId) async {
    final client = _client();
    try {
      final profile = await client
          .getUserProfile(userId)
          .timeout(requestDeadline);
      _check(client);
      return LinkedUserProfile(
        userId: userId,
        displayName: _bounded(profile.displayname, 255),
      );
    } on LinkSessionChanged {
      rethrow;
    } catch (_) {
      _check(client);
      return LinkedUserProfile(userId: userId);
    }
  }

  @override
  Future<void> markRead(
    String roomId,
    String eventId, {
    required bool publicReceipt,
  }) async {
    final client = _client();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    final latest = room.lastEvent;
    final target =
        latest != null &&
            latest.status == matrix.EventStatus.synced &&
            latest.eventId.startsWith('\$')
        ? latest.eventId
        : eventId;
    await room
        .setReadMarker(target, mRead: target, public: publicReceipt)
        .timeout(requestDeadline);
    _check(client);
  }
}

String? _bounded(String? value, int max) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text.length > max ? '${text.substring(0, max)}…' : text;
}

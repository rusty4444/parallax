import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';

/// A user whose latest read receipt points at an event.
@immutable
class ReceiptReader {
  const ReceiptReader({
    required this.userId,
    required this.name,
    this.avatar,
    this.time,
  });
  final String userId;
  final String name;
  final Uri? avatar;
  final DateTime? time;
}

/// A room member from cached membership state.
@immutable
class MemberProfile {
  const MemberProfile({
    required this.userId,
    this.displayName,
    this.avatar,
    this.membership = 'join',
  });
  final String userId;
  final String? displayName;
  final Uri? avatar;
  final String membership;

  String get label =>
      (displayName?.trim().isNotEmpty ?? false) ? displayName!.trim() : userId;
}

/// Previous content of a state event. [content] is null when the event had
/// no previous state (for example a first join).
@immutable
class PreviousState {
  const PreviousState(this.content);
  final Map<String, Object?>? content;
}

/// Read-only room data used by the rich timeline. Implementations must only
/// read cached state (no member fetches), except [previousState], which may
/// read the local event store.
abstract interface class RichTimelineFeatures {
  /// Latest main-timeline receipt per other user, grouped by event ID and
  /// sorted newest first. When [eventIds] is given, only those events are
  /// returned (cheaper in large rooms).
  Map<String, List<ReceiptReader>> latestReceipts(
    String roomId, {
    Set<String>? eventIds,
  });

  /// Cached membership profile, or null when unknown.
  MemberProfile? member(String roomId, String userId);

  /// Joined and invited members whose display name or ID matches [query].
  List<MemberProfile> searchMembers(
    String roomId,
    String query, {
    int limit = 8,
  });

  /// Whether the current user may notify the whole room with `@room`.
  bool canMentionRoom(String roomId);

  /// Servers to include in `via` for permalinks to this room.
  List<String> viaServers(String roomId);

  /// Already known previous state of [eventId], or null when not yet loaded.
  PreviousState? cachedPreviousState(String roomId, String eventId);

  /// Loads the previous state of a state event (`unsigned.prev_content`).
  Future<PreviousState?> previousState(String roomId, String eventId);
}

final _features = Expando<RichTimelineFeatures>('richTimelineFeatures');

/// Resolves the rich-timeline module for [backend]. Test fakes implement
/// [RichTimelineFeatures] directly; the live backend is wrapped once.
RichTimelineFeatures? richTimelineFeaturesOf(ChatBackend backend) =>
    backend is RichTimelineFeatures
    ? backend as RichTimelineFeatures
    : backend is MatrixSdkAccess && backend is RoomEventFeatures
    ? _features[backend] ??= MatrixRichTimeline(backend as MatrixSdkAccess)
    : null;

/// [RichTimelineFeatures] over the live Matrix SDK client.
class MatrixRichTimeline implements RichTimelineFeatures {
  MatrixRichTimeline(this._access);

  final MatrixSdkAccess _access;
  static const _maxCachedStates = 400;
  final _previous = <String, PreviousState>{};
  final _loading = <String, Future<PreviousState?>>{};
  matrix.Client? _cacheOwner;

  matrix.Client? get _client {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) return null;
    if (!identical(client, _cacheOwner)) {
      _cacheOwner = client;
      _previous.clear();
      _loading.clear();
    }
    return client;
  }

  matrix.Room? _room(String roomId) => _client?.getRoomById(roomId);

  MemberProfile? _profile(matrix.Room room, String userId) {
    final state = room.getState(matrix.EventTypes.RoomMember, userId);
    if (state == null) return null;
    final name = state.content['displayname'];
    final avatar = state.content['avatar_url'];
    final membership = state.content['membership'];
    return MemberProfile(
      userId: userId,
      displayName: name is String && name.trim().isNotEmpty ? name : null,
      avatar: avatar is String && avatar.startsWith('mxc://')
          ? Uri.tryParse(avatar)
          : null,
      membership: membership is String ? membership : 'leave',
    );
  }

  @override
  Map<String, List<ReceiptReader>> latestReceipts(
    String roomId, {
    Set<String>? eventIds,
  }) {
    final room = _room(roomId);
    if (room == null) return const {};
    final own = room.client.userID;
    final state = room.receiptState;
    final latest = <String, matrix.LatestReceiptStateData>{};
    for (final timeline in [state.global, ?state.mainThread]) {
      for (final entry in timeline.otherUsers.entries) {
        if (entry.key == own) continue;
        final previous = latest[entry.key];
        if (previous == null || entry.value.ts > previous.ts) {
          latest[entry.key] = entry.value;
        }
      }
    }
    final byEvent = <String, List<ReceiptReader>>{};
    for (final entry in latest.entries) {
      if (eventIds != null && !eventIds.contains(entry.value.eventId)) {
        continue;
      }
      final profile = _profile(room, entry.key);
      byEvent
          .putIfAbsent(entry.value.eventId, () => [])
          .add(
            ReceiptReader(
              userId: entry.key,
              name: profile?.label ?? entry.key,
              avatar: profile?.avatar,
              time: entry.value.timestamp,
            ),
          );
    }
    for (final readers in byEvent.values) {
      readers.sort(
        (a, b) => (b.time ?? DateTime(0)).compareTo(a.time ?? DateTime(0)),
      );
    }
    return byEvent;
  }

  @override
  MemberProfile? member(String roomId, String userId) {
    final room = _room(roomId);
    return room == null ? null : _profile(room, userId);
  }

  @override
  List<MemberProfile> searchMembers(
    String roomId,
    String query, {
    int limit = 8,
  }) {
    final room = _room(roomId);
    if (room == null) return const [];
    final own = room.client.userID;
    final members = room.states[matrix.EventTypes.RoomMember]?.keys ?? [];
    final profiles = [
      for (final userId in members)
        if (userId != own) ?_profile(room, userId),
    ].where((p) => p.membership == 'join' || p.membership == 'invite');
    return rankMembers(profiles, query, limit: limit);
  }

  @override
  bool canMentionRoom(String roomId) {
    final room = _room(roomId);
    if (room == null) return false;
    final levels = room.getState(matrix.EventTypes.RoomPowerLevels)?.content;
    final notifications = levels?['notifications'];
    final required = notifications is Map && notifications['room'] is int
        ? notifications['room'] as int
        : 50;
    return room.ownPowerLevel.level >= required;
  }

  @override
  List<String> viaServers(String roomId) {
    final room = _room(roomId);
    if (room == null) return const [];
    final counts = <String, int>{};
    for (final entry
        in (room.states[matrix.EventTypes.RoomMember] ?? const {}).entries) {
      if (entry.value.content['membership'] != 'join') continue;
      final colon = entry.key.indexOf(':');
      if (colon < 0) continue;
      final server = entry.key.substring(colon + 1);
      counts[server] = (counts[server] ?? 0) + 1;
    }
    final servers = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount == 0 ? a.compareTo(b) : byCount;
      });
    return servers.take(3).toList();
  }

  @override
  PreviousState? cachedPreviousState(String roomId, String eventId) {
    if (_client == null) return null;
    return _previous['$roomId|$eventId'];
  }

  @override
  Future<PreviousState?> previousState(String roomId, String eventId) {
    final client = _client;
    if (client == null) return Future.value();
    final key = '$roomId|$eventId';
    final cached = _previous[key];
    if (cached != null) return Future.value(cached);
    return _loading[key] ??= () async {
      try {
        final room = client.getRoomById(roomId);
        if (room == null) return null;
        // Local store first; the SDK only asks the server for missing events.
        final event = await room.getEventById(eventId);
        if (!_access.isSessionCurrent(client) ||
            !identical(_cacheOwner, client) ||
            event == null) {
          return null;
        }
        final result = PreviousState(
          event.prevContent == null
              ? null
              : Map<String, Object?>.unmodifiable(event.prevContent!),
        );
        _previous[key] = result;
        while (_previous.length > _maxCachedStates) {
          _previous.remove(_previous.keys.first);
        }
        return result;
      } catch (_) {
        return null;
      } finally {
        if (identical(_cacheOwner, client)) _loading.remove(key);
      }
    }();
  }
}

/// Orders members for mention autocomplete: display-name prefix matches,
/// then ID prefix matches, then other substring matches.
List<MemberProfile> rankMembers(
  Iterable<MemberProfile> members,
  String query, {
  int limit = 8,
}) {
  final needle = query.trim().toLowerCase().replaceFirst(RegExp('^@'), '');
  int score(MemberProfile member) {
    if (needle.isEmpty) return 3;
    final name = member.label.toLowerCase();
    final id = member.userId.toLowerCase().substring(1);
    if (name.startsWith(needle)) return 0;
    if (name.split(RegExp(r'\s+')).any((word) => word.startsWith(needle))) {
      return 1;
    }
    if (id.startsWith(needle)) return 2;
    if (name.contains(needle) || id.contains(needle)) return 3;
    return -1;
  }

  final scored = [
    for (final member in members)
      if (score(member) case final s when s >= 0) (s, member),
  ];
  scored.sort((a, b) {
    final byScore = a.$1.compareTo(b.$1);
    if (byScore != 0) return byScore;
    return a.$2.label.toLowerCase().compareTo(b.$2.label.toLowerCase());
  });
  return [for (final item in scored.take(limit)) item.$2];
}

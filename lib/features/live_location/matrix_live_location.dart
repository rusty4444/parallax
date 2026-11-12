import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../room_events.dart';
import 'live_location_features.dart';
import 'live_location_model.dart';
import 'live_location_sharer.dart';
import 'live_share_store.dart';
import 'position_source.dart';

/// Matrix implementation of [LiveLocationFeatures].
///
/// * Writes go through [RoomEventFeatures]: `beacon_info` with
///   `setRoomState` (state events are cleartext in every room, as in
///   Element), beacons with `sendRoomEvent`, which applies session
///   ownership, recipient trust, fail-closed encryption and the final HTTP
///   guard. A beacon's location and timestamp make its payload non-empty, so
///   SDK 14.1 encrypts it in encrypted rooms (only `m.relates_to` stays in
///   the cleartext envelope, as Matrix requires).
/// * `RoomEventFeatures.setRoomState` does not return the event ID, so a new
///   share waits for its own `beacon_info` to come back through sync (as
///   Element X waits for the remote echo) before sending beacons that
///   reference it.
/// * Live shares are read from local room state (fully loaded while a room's
///   timeline is open). The latest beacon per share is aggregated without
///   core changes, like the polls module: one bounded `/relations` page
///   (newest first, decrypted read-only) when a share is first shown, then
///   `client.onTimelineEvent`/`onHistoryEvent`.
/// * Everything belongs to one SDK client; a session change drops it.
class MatrixLiveLocation extends ChangeNotifier
    implements LiveLocationFeatures, LiveLocationLifecycle {
  MatrixLiveLocation(
    this._access,
    this._events, {
    this.positions = const GeolocatorLivePositionSource(),
    this.store = const PreferencesLiveShareStore(),
    this.clock = const SystemLiveClock(),
    this.echoTimeout = const Duration(seconds: 30),
  });

  final MatrixSdkAccess _access;
  final RoomEventFeatures _events;
  @override
  final LivePositionSource positions;
  final LiveShareStore store;
  final LiveClock clock;

  /// How long a new share waits for its `beacon_info` echo.
  final Duration echoTimeout;

  /// Newest-first beacons fetched per share when it is first shown.
  static const relationPageSize = 20;

  /// Bounds the beacon cache for pathological rooms.
  static const maxAggregates = 500;

  matrix.Client? _client;
  int _generation = 0;
  LiveLocationSharer? _sharer;
  final _aggregates = <String, _AggregateRecord>{};
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Shares of a session that ended before [stopAllShares] ran (sign-out
  /// invalidates the session before the pre-logout hook).
  ({String accountKey, String userId, List<PersistedShare> shares})? _retired;

  static String _key(String roomId, String eventId) => '$roomId\u0000$eventId';

  @override
  Listenable get updates => this;

  @override
  String? get myUserId => _currentClient()?.userID;

  /// The current SDK client, resetting everything when the session changed.
  /// Never notifies (may run during build).
  matrix.Client? _currentClient() {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) {
      if (_client != null) _reset();
      return null;
    }
    if (!identical(client, _client)) {
      _reset();
      final userId = client.userID;
      if (userId == null) return null;
      _client = client;
      _retired = null;
      final generation = _generation;
      _subscriptions
        ..add(client.onTimelineEvent.stream.listen(_onEvent))
        ..add(client.onHistoryEvent.stream.listen(_onEvent))
        ..add(client.onRoomState.stream.listen(_onRoomState));
      _sharer = LiveLocationSharer(
        transport: _MatrixTransport(this, client, userId, generation),
        positions: positions,
        store: store,
        accountKey: '$userId|${client.deviceID ?? ''}',
        clock: clock,
      )..addListener(_sharerChanged);
    }
    return client;
  }

  void _sharerChanged() => notifyListeners();

  void _reset() {
    _generation++;
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    _aggregates.clear();
    final sharer = _sharer;
    _sharer = null;
    if (sharer != null) {
      final records = sharer.activeRecords;
      final userId = _client?.userID;
      _retired = records.isEmpty || userId == null
          ? null
          : (accountKey: sharer.accountKey, userId: userId, shares: records);
      sharer
        ..removeListener(_sharerChanged)
        ..dispose();
    }
    _client = null;
  }

  bool _owns(matrix.Client client, int generation) =>
      identical(client, _client) &&
      generation == _generation &&
      _access.isSessionCurrent(client);

  // --- Lifecycle ----------------------------------------------------------

  @override
  Future<void> resumeShares() async {
    if (_currentClient() == null) return;
    await _sharer?.resume();
  }

  @override
  Future<void> stopAllShares() async {
    // Do not resolve the client here: during sign-out the session is no
    // longer "current", but the homeserver still accepts writes.
    final sharer = _sharer;
    if (sharer != null && !sharer.disposed) {
      await sharer.stopAll();
      return;
    }
    final retired = _retired;
    _retired = null;
    if (retired == null) return;
    final writes = [
      for (final share in retired.shares)
        _events
            .setRoomState(
              share.roomId,
              beaconInfoUnstableType,
              beaconInfoStopContent(share.content),
              stateKey: retired.userId,
            )
            .catchError((Object _) {}),
    ];
    try {
      await Future.wait(writes).timeout(LiveLocationSharer.stopAllTimeout);
    } catch (_) {}
    try {
      await store.clear(retired.accountKey);
    } catch (_) {}
  }

  // --- Reading shares -------------------------------------------------------

  BeaconInfo? _infoOf(matrix.Room room, matrix.StrippedStateEvent state) {
    if (state is! matrix.Event) return null;
    if (!state.eventId.startsWith(r'$')) return null;
    return BeaconInfo.fromEvent(
      eventId: state.eventId,
      type: state.type,
      stateKey: state.stateKey,
      sender: state.senderId,
      content: state.content,
      originServerTs: state.originServerTs,
    );
  }

  /// Current `beacon_info` per state key in [room].
  Map<String, BeaconInfo> _currentInfos(matrix.Room room) {
    final byKey = <String, List<BeaconInfo>>{};
    for (final type in beaconInfoEventTypes) {
      final states = room.states[type];
      if (states == null) continue;
      for (final state in states.values) {
        final info = _infoOf(room, state);
        if (info != null) (byKey[info.stateKey] ??= []).add(info);
      }
    }
    return {
      for (final entry in byKey.entries)
        entry.key: currentBeaconInfo(entry.value)!,
    };
  }

  String _nameOf(matrix.Room room, String userId) {
    final name = room
        .getState(matrix.EventTypes.RoomMember, userId)
        ?.content['displayname'];
    return name is String && name.trim().isNotEmpty ? name.trim() : userId;
  }

  Uri? _avatarOf(matrix.Room room, String userId) {
    final url = room
        .getState(matrix.EventTypes.RoomMember, userId)
        ?.content['avatar_url'];
    if (url is! String || !url.startsWith('mxc://')) return null;
    return Uri.tryParse(url);
  }

  LiveShareSnapshot _snapshot(
    matrix.Client client,
    matrix.Room? room,
    BeaconInfo info, {
    required bool live,
  }) {
    final record = _aggregates[_key(room?.id ?? '', info.eventId)];
    return LiveShareSnapshot(
      info: info,
      latest: record?.aggregate.latest,
      live: live,
      displayName: room == null ? info.sender : _nameOf(room, info.sender),
      avatarUrl: room == null ? null : _avatarOf(room, info.sender),
      mine: info.sender == client.userID,
      loading: record?.state == _LoadState.loading,
    );
  }

  @override
  List<LiveShareSnapshot> liveShares(String roomId) {
    final client = _currentClient();
    final room = client?.getRoomById(roomId);
    if (client == null || room == null) return const [];
    final now = clock.now();
    final shares = [
      for (final info in _currentInfos(room).values)
        if (info.isLiveAt(now)) _snapshot(client, room, info, live: true),
    ];
    final me = client.userID;
    shares.sort((a, b) {
      final mine = (b.userId == me ? 1 : 0) - (a.userId == me ? 1 : 0);
      return mine != 0 ? mine : b.info.start.compareTo(a.info.start);
    });
    return shares;
  }

  @override
  LiveShareSnapshot shareSnapshot(String roomId, BeaconInfo info) {
    final client = _currentClient();
    if (client == null) {
      return LiveShareSnapshot(
        info: info,
        live: false,
        displayName: info.sender,
        mine: false,
      );
    }
    final room = client.getRoomById(roomId);
    var replaced = false;
    if (room != null) {
      final current = _currentInfos(room)[info.stateKey];
      // A newer beacon_info for the same state key ended this share. (An
      // older "current" means room state is still loading.)
      replaced =
          current != null &&
          current.eventId != info.eventId &&
          !current.sentAt.isBefore(info.sentAt);
    }
    return _snapshot(
      client,
      room,
      info,
      live: !replaced && info.isLiveAt(clock.now()),
    );
  }

  @override
  OwnShare? deviceShare(String roomId) {
    if (_currentClient() == null) return null;
    return _sharer?.shareIn(roomId);
  }

  @override
  bool canShareIn(String roomId) {
    final room = _currentClient()?.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      return false;
    }
    return room.canChangeStateEvent(beaconInfoUnstableType) &&
        room.canSendEvent(beaconUnstableType);
  }

  // --- Sharing ---------------------------------------------------------------

  LiveLocationSharer _requireSharer() {
    final sharer = _currentClient() == null ? null : _sharer;
    if (sharer == null) throw StateError('Matrix is not available');
    return sharer;
  }

  @override
  Future<void> startSharing(String roomId, Duration duration) async =>
      _requireSharer().start(roomId, duration);

  @override
  Future<void> stopSharing(String roomId) async =>
      _requireSharer().stop(roomId);

  // --- Beacon aggregation ---------------------------------------------------

  @override
  void ensureBeaconsLoaded(String roomId, BeaconInfo info) {
    final client = _currentClient();
    if (client == null || !info.eventId.startsWith(r'$')) return;
    final key = _key(roomId, info.eventId);
    if (_aggregates.containsKey(key)) return;
    if (_aggregates.length >= maxAggregates) {
      _aggregates.remove(_aggregates.keys.first);
    }
    final record = _aggregates[key] = _AggregateRecord(BeaconAggregate(info));
    unawaited(_fetch(client, _generation, roomId, record));
  }

  Future<void> _fetch(
    matrix.Client client,
    int generation,
    String roomId,
    _AggregateRecord record,
  ) async {
    var ok = false;
    try {
      // Yield first so callers in build/initState never see a notification.
      await Future<void>.value();
      final room = client.getRoomById(roomId);
      if (room == null) throw StateError('Unknown room');
      final page = await client.getRelatingEventsWithRelType(
        roomId,
        record.aggregate.info.eventId,
        referenceRelation,
        limit: relationPageSize,
        dir: matrix.Direction.b,
      );
      if (!_owns(client, generation)) return;
      for (final raw in page.chunk) {
        var event = matrix.Event.fromMatrixEvent(raw, room);
        if (event.type == matrix.EventTypes.Encrypted) {
          final encryption = client.encryption;
          if (!client.encryptionEnabled || encryption == null) continue;
          event = await encryption.decryptRoomEvent(event);
          if (!_owns(client, generation)) return;
        }
        final beacon = _beaconOf(event);
        if (beacon != null) record.aggregate.offer(beacon);
      }
      ok = true;
    } catch (_) {
      ok = false;
    } finally {
      if (_owns(client, generation) &&
          identical(
            _aggregates[_key(roomId, record.aggregate.info.eventId)],
            record,
          )) {
        record.state = ok ? _LoadState.ready : _LoadState.failed;
        notifyListeners();
      }
    }
  }

  BeaconLocation? _beaconOf(matrix.Event event) {
    if (event.redacted) return null;
    return BeaconLocation.fromEvent(
      eventId: event.eventId,
      type: event.type,
      sender: event.senderId,
      content: event.content,
      originServerTs: event.originServerTs,
    );
  }

  void _onEvent(matrix.Event event) {
    final client = _client;
    if (client == null ||
        !identical(event.room.client, client) ||
        !_access.isSessionCurrent(client)) {
      return;
    }
    if (event.type == matrix.EventTypes.Redaction) {
      final redacts = event.redacts ?? event.content['redacts'];
      if (redacts is! String) return;
      var changed = false;
      for (final entry in _aggregates.entries) {
        if (entry.key.startsWith('${event.room.id}\u0000')) {
          changed = entry.value.aggregate.remove(redacts) || changed;
        }
      }
      if (changed) notifyListeners();
      return;
    }
    if (!beaconEventTypes.contains(event.type)) return;
    // Local echoes carry transaction IDs; wait for the synced copy.
    if (!event.status.isSent) return;
    final target = event.relationshipEventId;
    if (target == null) return;
    final record = _aggregates[_key(event.room.id, target)];
    if (record == null) return;
    final beacon = _beaconOf(event);
    if (beacon != null && record.aggregate.offer(beacon)) notifyListeners();
  }

  void _onRoomState(({String roomId, matrix.StrippedStateEvent state}) update) {
    final client = _client;
    final state = update.state;
    if (client == null ||
        !beaconInfoEventTypes.contains(state.type) ||
        !_access.isSessionCurrent(client)) {
      return;
    }
    final room = client.getRoomById(update.roomId);
    if (room == null) return;
    final info = _infoOf(room, state);
    if (info != null && info.sender == client.userID) {
      _sharer?.ownBeaconInfoChanged(update.roomId, info);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }
}

enum _LoadState { loading, ready, failed }

class _AggregateRecord {
  _AggregateRecord(this.aggregate);
  final BeaconAggregate aggregate;
  _LoadState state = _LoadState.loading;
}

/// [LiveLocationTransport] over [RoomEventFeatures], bound to one client.
class _MatrixTransport implements LiveLocationTransport {
  _MatrixTransport(this._owner, this._client, this._userId, this._generation);

  final MatrixLiveLocation _owner;
  final matrix.Client _client;
  final String _userId;
  final int _generation;

  /// The `beacon_info` type last read per room (another client may use the
  /// stable type); stops are written with the same type.
  final _ownTypes = <String, String>{};

  RoomEventFeatures get _events => _owner._events;

  /// Writes may run after the session stopped being current only for the
  /// sign-out stop, which uses [writeBeaconInfo]; everything else checks.
  void _checkSession() {
    if (!_owner._access.isSessionCurrent(_client) ||
        _owner._generation != _generation) {
      throw const LiveLocationSendException(
        'This session is no longer current',
        fatal: true,
      );
    }
  }

  /// SDK 14.1 applies synced non-important state (such as `beacon_info`)
  /// only to fully loaded rooms, so load the room before relying on the
  /// echo or on another device's stop arriving through sync.
  Future<void> _ensureFullState(matrix.Room room) async {
    if (!room.partial) return;
    try {
      await room.postLoad();
    } catch (_) {}
  }

  /// The joined room. A room this client does not know (yet) is a
  /// transient failure for beacons; a known room we are no longer joined to
  /// ends the share.
  matrix.Room _joinedRoom(String roomId, {bool unknownIsFatal = true}) {
    final room = _client.getRoomById(roomId);
    if (room == null) {
      throw LiveLocationSendException(
        'Room is not available',
        fatal: unknownIsFatal,
      );
    }
    if (room.membership != matrix.Membership.join) {
      throw const LiveLocationSendException('Room is not joined', fatal: true);
    }
    return room;
  }

  static LiveLocationSendException _classify(Object error) {
    if (error is LiveLocationSendException) return error;
    if (error is matrix.MatrixException) {
      return LiveLocationSendException(
        error.errorMessage,
        fatal: error.error == matrix.MatrixError.M_FORBIDDEN,
      );
    }
    if (error is StateError) {
      final message = error.message;
      // The user declined the recipient-trust prompt, or the room/session
      // or encryption preconditions failed: retrying cannot help and would
      // prompt again.
      final fatal =
          message.contains('cancelled') ||
          message.contains('not joined') ||
          message.contains('old session') ||
          message.contains('unavailable') ||
          message.contains('plaintext');
      return LiveLocationSendException(message, fatal: fatal);
    }
    if (error is ArgumentError) {
      return LiveLocationSendException('$error', fatal: true);
    }
    return LiveLocationSendException('$error', fatal: false);
  }

  bool _isEcho(
    ({String roomId, matrix.StrippedStateEvent state}) update,
    String roomId,
    int? startMillis,
  ) {
    final state = update.state;
    return update.roomId == roomId &&
        state is matrix.Event &&
        state.eventId.startsWith(r'$') &&
        beaconInfoEventTypes.contains(state.type) &&
        state.stateKey == _userId &&
        state.senderId == _userId &&
        state.content['live'] == true &&
        beaconInfoStartMillis(state.content) == startMillis;
  }

  @override
  Future<String> startBeaconInfo(
    String roomId,
    Map<String, Object?> content,
  ) async {
    _checkSession();
    final room = _joinedRoom(roomId);
    await _ensureFullState(room);
    _checkSession();
    final startMillis = beaconInfoStartMillis(content);
    final echo = Completer<String>();
    final subscription = _client.onRoomState.stream.listen((update) {
      if (!echo.isCompleted && _isEcho(update, roomId, startMillis)) {
        echo.complete((update.state as matrix.Event).eventId);
      }
    });
    var written = false;
    try {
      try {
        await _events.setRoomState(
          roomId,
          beaconInfoUnstableType,
          content,
          stateKey: _userId,
        );
        written = true;
      } catch (error) {
        throw _classify(error);
      }
      _checkSession();
      _ownTypes[roomId] = beaconInfoUnstableType;
      // Sync may have applied the echo before the PUT returned.
      for (final type in beaconInfoEventTypes) {
        final local = room.getState(type, _userId);
        if (!echo.isCompleted &&
            local != null &&
            _isEcho((roomId: roomId, state: local), roomId, startMillis)) {
          echo.complete((local as matrix.Event).eventId);
        }
      }
      final eventId = await echo.future.timeout(_owner.echoTimeout);
      _checkSession();
      return eventId;
    } on TimeoutException {
      // Written but never confirmed: end it so it cannot linger as a live
      // share without updates.
      if (written) {
        try {
          await _events.setRoomState(
            roomId,
            beaconInfoUnstableType,
            beaconInfoStopContent(content),
            stateKey: _userId,
          );
        } catch (_) {}
      }
      throw const LiveLocationSendException(
        'The homeserver did not confirm the live location share',
        fatal: false,
      );
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> writeBeaconInfo(
    String roomId,
    Map<String, Object?> content,
  ) async {
    try {
      await _events.setRoomState(
        roomId,
        _ownTypes[roomId] ?? beaconInfoUnstableType,
        content,
        stateKey: _userId,
      );
    } catch (error) {
      throw _classify(error);
    }
  }

  @override
  Future<String> sendBeacon(String roomId, Map<String, Object?> content) async {
    _checkSession();
    final room = _joinedRoom(roomId, unknownIsFatal: false);
    if (room.encrypted && !_client.encryptionEnabled) {
      // Fail closed; sendRoomEvent would refuse as well.
      throw const LiveLocationSendException(
        'Encryption is unavailable',
        fatal: true,
      );
    }
    try {
      return await _events.sendRoomEvent(roomId, beaconUnstableType, content);
    } catch (error) {
      throw _classify(error);
    }
  }

  @override
  Future<Map<String, Object?>?> ownBeaconInfo(String roomId) async {
    _checkSession();
    final room = _client.getRoomById(roomId);
    if (room != null) {
      await _ensureFullState(room);
      _checkSession();
    }
    try {
      for (final type in const [beaconInfoUnstableType, beaconInfoStableType]) {
        final content = await _events.roomState(
          roomId,
          type,
          stateKey: _userId,
        );
        _checkSession();
        if (content != null && content.isNotEmpty) {
          _ownTypes[roomId] = type;
          return content;
        }
      }
      return null;
    } catch (error) {
      throw _classify(error);
    }
  }
}

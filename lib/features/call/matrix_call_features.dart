// Matrix SDK implementation of the call module.
//
// Timeline sends go through RoomEventFeatures.sendRoomEvent (session,
// recipient-trust and fail-closed encryption guards). MatrixRTC membership
// state, delayed state (MSC4140), OpenID and Olm-encrypted to-device traffic
// are not timeline sends and use the SDK directly, re-checking session
// ownership after every await.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'call_features.dart';
import 'call_memberships.dart';
import 'call_settings_store.dart';
import 'call_widget_url.dart';
import 'widget_capabilities.dart';
import 'widget_driver.dart';
import '../../matrix_room_names.dart';

class MatrixCallFeatures implements CallFeatures {
  MatrixCallFeatures(
    this._backend, {
    CallSettingsStore? settings,
    DateTime Function()? clock,
  }) : _settings = settings ?? CallSettingsStore.instance,
       _clock = clock ?? DateTime.now {
    assert(_backend is MatrixSdkAccess && _backend is RoomEventFeatures);
  }

  final ChatBackend _backend;
  final CallSettingsStore _settings;
  final DateTime Function() _clock;

  MatrixSdkAccess get _access => _backend as MatrixSdkAccess;
  RoomEventFeatures get _events => _backend as RoomEventFeatures;

  matrix.Client? get _client {
    final client = _access.sdkClient;
    return client != null && _access.isSessionCurrent(client) ? client : null;
  }

  matrix.Client _requireClient() =>
      _client ?? (throw StateError('You are not signed in.'));

  // --- room call state -----------------------------------------------------

  @override
  RoomCallSummary roomCall(String roomId) {
    final client = _client;
    final room = client?.getRoomById(roomId);
    if (client == null || room == null) return RoomCallSummary.none;
    return summariseRoomCall(
      callMemberStates(room),
      now: _clock(),
      ownUserId: client.userID,
    );
  }

  @override
  bool canJoinCall(String roomId) {
    final room = _client?.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      return false;
    }
    return callMemberTypes.any(room.canChangeStateEvent);
  }

  // --- live streams (bound to whichever client is current) ----------------

  late final _changes = StreamController<String>.broadcast(
    onListen: _bind,
    onCancel: _maybeUnbind,
  );
  late final _rings = StreamController<IncomingCall>.broadcast(
    onListen: _bind,
    onCancel: _maybeUnbind,
  );
  matrix.Client? _boundClient;
  StreamSubscription<Object?>? _stateSubscription;
  StreamSubscription<Object?>? _timelineSubscription;
  bool _watchingBackend = false;

  @override
  Stream<String> get callChanges => _changes.stream;

  @override
  Stream<IncomingCall> get incomingCalls => _rings.stream;

  void _bind() {
    if (!_watchingBackend) {
      _watchingBackend = true;
      _backend.addListener(_rebind);
    }
    _rebind();
  }

  void _rebind() {
    final client = _client;
    if (identical(client, _boundClient)) return;
    unawaited(_stateSubscription?.cancel());
    unawaited(_timelineSubscription?.cancel());
    _stateSubscription = null;
    _timelineSubscription = null;
    _boundClient = client;
    if (client == null) return;
    _stateSubscription = client.onRoomState.stream.listen((update) {
      if (callMemberTypes.contains(update.state.type) &&
          _access.isSessionCurrent(client)) {
        _changes.add(update.roomId);
      }
    });
    _timelineSubscription = client.onTimelineEvent.stream.listen(
      (event) => _onTimelineEvent(client, event),
    );
  }

  void _maybeUnbind() {
    if (_changes.hasListener || _rings.hasListener) return;
    if (_watchingBackend) {
      _watchingBackend = false;
      _backend.removeListener(_rebind);
    }
    unawaited(_stateSubscription?.cancel());
    unawaited(_timelineSubscription?.cancel());
    _stateSubscription = null;
    _timelineSubscription = null;
    _boundClient = null;
  }

  void _onTimelineEvent(matrix.Client client, matrix.Event event) {
    if (!rtcNotificationTypes.contains(event.type) ||
        !_access.isSessionCurrent(client)) {
      return;
    }
    final ring = incomingCallFromEvent(
      type: event.type,
      eventId: event.eventId,
      senderId: event.senderId,
      content: event.content,
      originServerTs: event.originServerTs,
      ownUserId: client.userID,
      roomId: event.room.id,
      roomIsDirect: event.room.isDirectChat,
      roomJoined: event.room.membership == matrix.Membership.join,
      roomName: event.room.parallaxName,
      senderMember: event.room
          .getState(matrix.EventTypes.RoomMember, event.senderId)
          ?.content,
      now: _clock(),
    );
    if (ring != null) _rings.add(ring);
  }

  // --- launching -----------------------------------------------------------

  @override
  Future<CallServiceInfo> callServiceInfo() async {
    final custom = await _settings.load();
    final client = _requireClient();
    var discovery = const CallDiscovery();
    var failed = false;
    try {
      final wellKnown = await client.getWellknown();
      discovery = parseCallDiscovery(wellKnown.additionalProperties);
    } catch (_) {
      failed = true;
    }
    if (!_access.isSessionCurrent(client)) {
      throw StateError('This account session is no longer current.');
    }
    final (url, source) = custom != null
        ? (custom, CallUrlSource.custom)
        : discovery.elementCallUrl != null
        ? (discovery.elementCallUrl!, CallUrlSource.homeserver)
        : (Uri.parse(defaultElementCallUrl), CallUrlSource.defaultUrl);
    return CallServiceInfo(
      baseUrl: url,
      source: source,
      rtcFocusHosts: discovery.rtcFocusHosts,
      discoveryFailed: failed,
    );
  }

  @override
  Future<CallLaunch> prepareCall(
    String roomId,
    CallLaunchOptions options,
  ) async {
    final client = _requireClient();
    final info = await callServiceInfo();
    if (!_access.isSessionCurrent(client)) {
      throw StateError('This account session is no longer current.');
    }
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Join the room before starting a call.');
    }
    final userId = client.userID;
    final deviceId = client.deviceID;
    final homeserver = client.homeserver;
    if (userId == null || deviceId == null || homeserver == null) {
      throw StateError('You are not signed in.');
    }
    final intent = callIntentFor(
      direct: room.isDirectChat,
      hasActiveCall: roomCall(roomId).active,
      audioOnly: options.audioOnly,
    );
    final displayName = room
        .getState(matrix.EventTypes.RoomMember, userId)
        ?.content['displayname'];
    final widgetId = newCallWidgetId();
    return CallLaunch(
      url: buildElementCallUrl(
        ElementCallUrlParams(
          baseUrl: info.baseUrl,
          widgetId: widgetId,
          userId: userId,
          deviceId: deviceId,
          roomId: roomId,
          homeserver: homeserver,
          encrypted: room.encrypted,
          intent: intent,
          displayName: displayName is String ? displayName : '',
          language: options.language,
          theme: options.theme,
          fontScale: options.fontScale,
          screenSharing: _settings.screenSharingEnabled,
        ),
      ),
      widgetId: widgetId,
      intent: intent,
      allowedCapabilities: elementCallAllowedCapabilities(
        userId: userId,
        deviceId: deviceId,
        roomId: roomId,
      ),
      matrix: MatrixCallWidgetMatrix(
        access: _access,
        events: _events,
        client: client,
        roomId: roomId,
      ),
    );
  }

  @override
  Future<void> declineCall(String roomId, String notificationEventId) async {
    await _events.sendRoomEvent(roomId, rtcDeclineTypes.first, {
      'm.relates_to': {
        'rel_type': 'm.reference',
        'event_id': notificationEventId,
      },
    });
  }
}

/// Cached MatrixRTC membership state of [room].
List<CallMemberStateEvent> callMemberStates(matrix.Room room) => [
  for (final type in callMemberTypes)
    for (final state in room.states[type]?.values ?? const <Never>[])
      if (state is matrix.MatrixEvent)
        CallMemberStateEvent(
          stateKey: state.stateKey ?? '',
          sender: state.senderId,
          content: Map<String, Object?>.from(state.content),
          originServerTs: state.originServerTs,
        ),
];

/// Decides whether an MSC4075 notification should ring this device.
/// Pure (no SDK types) so the rules are unit-testable.
IncomingCall? incomingCallFromEvent({
  required String type,
  required String eventId,
  required String senderId,
  required Map<String, Object?> content,
  required DateTime originServerTs,
  required String? ownUserId,
  required String roomId,
  required bool roomIsDirect,
  required bool roomJoined,
  required String roomName,
  required DateTime now,
  Map<String, Object?>? senderMember,
}) {
  if (!rtcNotificationTypes.contains(type) ||
      ownUserId == null ||
      senderId == ownUserId ||
      !roomJoined ||
      content['notification_type'] != 'ring') {
    return null;
  }
  final mentions = content['m.mentions'];
  final mentioned =
      mentions is Map &&
      (mentions['room'] == true ||
          (mentions['user_ids'] is List &&
              (mentions['user_ids'] as List).contains(ownUserId)));
  // Element Call rings in DMs; elsewhere only an explicit mention rings.
  if (!roomIsDirect && !mentioned) return null;
  final expiresAt = rtcNotificationExpiry(
    content,
    originServerTs: originServerTs,
  );
  if (!now.isBefore(expiresAt)) return null;
  final name = senderMember?['displayname'];
  final avatar = senderMember?['avatar_url'];
  return IncomingCall(
    roomId: roomId,
    eventId: eventId,
    senderId: senderId,
    senderName: name is String && name.trim().isNotEmpty ? name : senderId,
    roomName: roomName,
    expiresAt: expiresAt,
    audioOnly: content['m.call.intent'] == 'audio',
    senderAvatar: avatar is String ? Uri.tryParse(avatar) : null,
  );
}

/// What `.well-known/matrix/client` says about calls.
@immutable
class CallDiscovery {
  const CallDiscovery({this.elementCallUrl, this.rtcFocusHosts = const []});
  final Uri? elementCallUrl;
  final List<String> rtcFocusHosts;
}

CallDiscovery parseCallDiscovery(Map<String, Object?> wellKnown) {
  final call = wellKnown['io.element.call'];
  final url = switch (call) {
    final Map<Object?, Object?> map => parseElementCallBaseUrl(
      map['url'] is String ? map['url'] as String : null,
    ),
    final String text => parseElementCallBaseUrl(text),
    _ => null,
  };
  final foci = wellKnown['org.matrix.msc4143.rtc_foci'];
  final hosts = <String>[
    if (foci is List)
      for (final focus in foci.take(16))
        if (focus is Map && focus['type'] == 'livekit')
          if (Uri.tryParse('${focus['livekit_service_url']}') case final uri?
              when uri.scheme == 'https' && uri.host.isNotEmpty)
            uri.host,
  ];
  return CallDiscovery(elementCallUrl: url, rtcFocusHosts: hosts);
}

/// [CallWidgetMatrix] for one room of one signed-in session.
class MatrixCallWidgetMatrix implements CallWidgetMatrix {
  MatrixCallWidgetMatrix({
    required this._access,
    required this._events,
    required this._client,
    required this.roomId,
  });

  final MatrixSdkAccess _access;
  final RoomEventFeatures _events;
  final matrix.Client _client;
  @override
  final String roomId;
  bool _disposed = false;

  bool get _current => !_disposed && _access.isSessionCurrent(_client);

  void _check() {
    if (!_current) {
      throw StateError('This call belongs to an old session.');
    }
  }

  matrix.Room _room() {
    _check();
    final room = _client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined.');
    }
    return room;
  }

  @override
  bool get roomEncrypted => _client.getRoomById(roomId)?.encrypted ?? true;

  @override
  Future<Map<String, Object?>> requestOpenId() async {
    _check();
    final credentials = await _client.requestOpenIdToken(_client.userID!, {});
    _check();
    return credentials.toJson();
  }

  @override
  Future<String> sendRoomEvent(
    String type,
    Map<String, Object?> content,
  ) async {
    _room();
    final id = await _events.sendRoomEvent(roomId, type, content);
    _check();
    return id;
  }

  @override
  Future<String?> redactOwnEvent(String eventId) async {
    final room = _room();
    final event = await room.getEventById(eventId);
    _check();
    if (event == null || event.senderId != _client.userID) {
      throw StateError('Only your own call events can be removed.');
    }
    await _events.redactEvent(roomId, eventId);
    _check();
    return null;
  }

  @override
  Future<String> sendStateEvent(
    String type,
    String stateKey,
    Map<String, Object?> content,
  ) async {
    _room();
    final id = await _client.setRoomStateWithKey(
      roomId,
      type,
      stateKey,
      content,
    );
    _check();
    return id;
  }

  @override
  Future<String> sendDelayedStateEvent(
    String type,
    String stateKey,
    Map<String, Object?> content, {
    required int delayMs,
  }) async {
    _room();
    final id = await _client.setRoomStateWithKeyWithDelay(
      roomId,
      type,
      stateKey,
      delayMs,
      content,
    );
    _check();
    return id;
  }

  @override
  Future<void> updateDelayedEvent(String delayId, String action) async {
    _check();
    await _client.manageDelayedEvent(
      delayId,
      matrix.DelayedEventAction.values.byName(action),
    );
    _check();
  }

  @override
  Future<Map<String, List<String>>> sendToDevice(
    String type,
    Map<String, Map<String, Map<String, Object?>>> messages, {
    required bool encrypted,
  }) async {
    _check();
    if (!encrypted) {
      await _client.sendToDevice(
        type,
        _client.generateUniqueTransactionId(),
        messages,
      );
      _check();
      return const {};
    }
    if (!_client.encryptionEnabled || _client.encryption == null) {
      throw StateError('Encryption is unavailable on this device.');
    }
    final unknown = {
      for (final user in messages.keys)
        if (_client.userDeviceKeys[user] == null) user,
    };
    if (unknown.isNotEmpty) {
      await _client.updateUserDeviceKeys(additionalUsers: unknown);
      _check();
    }
    final failures = <String, List<String>>{};
    final groups = <String, (Map<String, Object?>, List<matrix.DeviceKeys>)>{};
    for (final MapEntry(key: user, value: devices) in messages.entries) {
      final known = _client.userDeviceKeys[user]?.deviceKeys ?? const {};
      for (final MapEntry(key: deviceId, value: content) in devices.entries) {
        final targets = deviceId == '*'
            ? known.values.toList()
            : [?known[deviceId]];
        if (targets.isEmpty) {
          (failures[user] ??= []).add(deviceId);
          continue;
        }
        groups
            .putIfAbsent(jsonEncode(content), () => (content, []))
            .$2
            .addAll(targets);
      }
    }
    for (final (content, devices) in groups.values) {
      if (devices.isEmpty) continue;
      // The SDK removes blocked devices and this device, and serialises Olm
      // encryption per recipient. Failed encrypted sends are never queued
      // (SafeMatrixDatabase), so an error surfaces to the widget.
      await _client.sendToDeviceEncrypted(
        List.of(devices),
        type,
        Map<String, dynamic>.of(content),
      );
      _check();
    }
    return failures;
  }

  @override
  Future<List<Map<String, Object?>>> readState(
    String type, {
    String? stateKey,
  }) async {
    final room = _room();
    final states = room.states[type] ?? const {};
    return [
      for (final MapEntry(key: key, value: state) in states.entries)
        if ((stateKey == null || key == stateKey) &&
            state is matrix.MatrixEvent)
          cleanEventJson(state, roomId),
    ];
  }

  @override
  Future<List<Map<String, Object?>>> readEvents(
    String type, {
    required int limit,
  }) async {
    _room();
    final response = await _client.getRoomEvents(
      roomId,
      matrix.Direction.b,
      limit: limit,
      filter: jsonEncode({
        'types': [type],
      }),
    );
    _check();
    return [for (final event in response.chunk) cleanEventJson(event, roomId)];
  }

  @override
  Stream<Map<String, Object?>> get roomEvents => _client.onTimelineEvent.stream
      .where(
        (event) =>
            _current &&
            event.room.id == roomId &&
            event.eventId.startsWith(r'$'),
      )
      .map((event) => cleanEventJson(event, roomId));

  @override
  Stream<Map<String, Object?>> get stateUpdates => _client.onRoomState.stream
      .where(
        (update) =>
            _current &&
            update.roomId == roomId &&
            update.state is matrix.MatrixEvent,
      )
      .map(
        (update) => cleanEventJson(update.state as matrix.MatrixEvent, roomId),
      );

  @override
  Stream<Map<String, Object?>> get toDeviceEvents => _client
      .onToDeviceEvent
      .stream
      .where(
        (event) => _current && event is! matrix.ToDeviceEventDecryptionError,
      )
      .map(
        (event) => {
          'type': event.type,
          'sender': event.senderId,
          'content': Map<String, Object?>.from(event.content),
          // Set by the SDK only after Olm decryption; never from the wire.
          'encrypted': event.encryptedContent != null,
        },
      );

  @override
  void dispose() => _disposed = true;
}

/// Widget-facing event JSON without SDK-local fields (status, original
/// source) and with the room ID attached, like the Rust driver.
Map<String, Object?> cleanEventJson(matrix.MatrixEvent event, String roomId) {
  final unsigned = event.unsigned;
  final keptUnsigned = <String, Object?>{
    if (unsigned != null)
      for (final key in const [
        'age',
        'prev_content',
        'transaction_id',
        'redacted_because',
      ])
        if (unsigned.containsKey(key)) key: unsigned[key],
  };
  return {
    'type': event.type,
    'sender': event.senderId,
    'event_id': event.eventId,
    'room_id': roomId,
    'origin_server_ts': event.originServerTs.millisecondsSinceEpoch,
    'content': Map<String, Object?>.from(event.content),
    if (event.stateKey != null) 'state_key': event.stateKey,
    if (event.redacts != null) 'redacts': event.redacts,
    if (keptUnsigned.isNotEmpty) 'unsigned': keptUnsigned,
  };
}

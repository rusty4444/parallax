// Matrix widget API capability policy for Element Call.
//
// Capability strings follow MSC2762 (events/state), MSC3819 (to-device),
// MSC4157 (delayed events) and the matrix-rust-sdk serialisation used by
// Element X (`get_element_call_required_permissions`). Parallax grants only
// the intersection of what the widget requests and this allow-list.

const capRequiresClient = 'io.element.requires_client';
const capSendDelayedEvent = 'org.matrix.msc4157.send.delayed_event';
const capUpdateDelayedEvent = 'org.matrix.msc4157.update_delayed_event';

const _sendEvent = 'org.matrix.msc2762.send.event';
const _readEvent = 'org.matrix.msc2762.receive.event';
const _sendState = 'org.matrix.msc2762.send.state_event';
const _readState = 'org.matrix.msc2762.receive.state_event';
const _sendToDevice = 'org.matrix.msc3819.send.to_device';
const _readToDevice = 'org.matrix.msc3819.receive.to_device';
const _timeline = 'org.matrix.msc2762.timeline';

/// MatrixRTC membership state types (unstable prefix and stable name).
const callMemberTypes = {'org.matrix.msc3401.call.member', 'm.call.member'};

/// MatrixRTC ring/notification event types.
const rtcNotificationTypes = {
  'org.matrix.msc4075.rtc.notification',
  'm.rtc.notification',
};

/// MatrixRTC decline event types (MSC4310).
const rtcDeclineTypes = {'org.matrix.msc4310.rtc.decline', 'm.rtc.decline'};

/// Element Call's per-participant media keys.
const callEncryptionKeysType = 'io.element.call.encryption_keys';

String readEventCapability(String type) => '$_readEvent:$type';
String sendEventCapability(String type) => '$_sendEvent:$type';
String readStateCapability(String type, [String? stateKey]) =>
    stateKey == null ? '$_readState:$type' : '$_readState:$type#$stateKey';
String sendStateCapability(String type, [String? stateKey]) =>
    stateKey == null ? '$_sendState:$type' : '$_sendState:$type#$stateKey';
String readToDeviceCapability(String type) => '$_readToDevice:$type';
String sendToDeviceCapability(String type) => '$_sendToDevice:$type';
String timelineCapability(String roomId) => '$_timeline:$roomId';

/// Every capability Parallax is prepared to grant Element Call in [roomId].
///
/// Matches Element X's list: read call/room state, read+send call side
/// channels (keys, reactions, redactions, declines, rageshake requests),
/// send ring notifications, and write only this device's own call
/// membership state keys. Nothing here lets the widget read messages.
Set<String> elementCallAllowedCapabilities({
  required String userId,
  required String deviceId,
  required String roomId,
}) {
  const readSendEvents = [
    'org.matrix.rageshake_request',
    callEncryptionKeysType,
    'io.element.call.reaction',
    'm.reaction',
    'm.room.redaction',
    ...rtcDeclineTypes,
  ];
  const readStates = [
    ...callMemberTypes,
    'm.room.name',
    'm.room.member',
    'm.room.encryption',
    'm.room.create',
    'io.element.functional_members',
  ];
  final ownMembershipKeys = [
    userId,
    '${userId}_$deviceId',
    '${userId}_${deviceId}_m.call',
    '_${userId}_$deviceId',
    '_${userId}_${deviceId}_m.call',
  ];
  return {
    capRequiresClient,
    capSendDelayedEvent,
    capUpdateDelayedEvent,
    timelineCapability(roomId),
    for (final type in readStates) readStateCapability(type),
    for (final type in readSendEvents) ...[
      readEventCapability(type),
      sendEventCapability(type),
    ],
    for (final type in [...rtcNotificationTypes, ..._legacyNotifyTypes])
      sendEventCapability(type),
    for (final type in callMemberTypes)
      for (final key in ownMembershipKeys) sendStateCapability(type, key),
    readToDeviceCapability(callEncryptionKeysType),
    sendToDeviceCapability(callEncryptionKeysType),
  };
}

const _legacyNotifyTypes = ['org.matrix.msc4075.call.notify'];

/// Grants exactly the requested capabilities that are on the allow-list.
Set<String> negotiateCapabilities(
  Iterable<Object?> requested,
  Set<String> allowed,
) => {
  for (final capability in requested)
    if (capability is String && allowed.contains(capability)) capability,
};

/// The negotiated capability set with MSC2762 filter semantics.
class ApprovedCapabilities {
  ApprovedCapabilities(Iterable<String> capabilities)
    : all = Set.unmodifiable(capabilities);

  static final none = ApprovedCapabilities(const []);

  final Set<String> all;

  bool get canSendDelayed => all.contains(capSendDelayedEvent);
  bool get canUpdateDelayed => all.contains(capUpdateDelayedEvent);

  /// Whether a room event may be delivered to the widget.
  bool canRead(String type, {String? stateKey, String? msgtype}) =>
      _matches(_readEvent, _readState, type, stateKey, msgtype);

  /// Whether the widget may send this room event.
  bool canSend(String type, {String? stateKey, String? msgtype}) =>
      _matches(_sendEvent, _sendState, type, stateKey, msgtype);

  bool canReadToDevice(String type) =>
      all.contains(readToDeviceCapability(type));
  bool canSendToDevice(String type) =>
      all.contains(sendToDeviceCapability(type));

  /// Whether any read filter exists for state of [type] (any state key).
  bool hasStateReadFilterFor(String type) =>
      stateReadFilters.any((filter) => filter.type == type);

  /// Whether any read filter exists for message-like events of [type].
  bool hasEventReadFilterFor(String type) =>
      all.contains(readEventCapability(type)) ||
      (type == 'm.room.message' &&
          all.any((c) => c.startsWith('$_readEvent:m.room.message#')));

  /// State read filters, for pushing the initial room state.
  List<({String type, String? stateKey})> get stateReadFilters => [
    for (final capability in all)
      if (capability.startsWith('$_readState:'))
        _splitStateFilter(capability.substring(_readState.length + 1)),
  ];

  bool get readsAnything => all.any(
    (c) =>
        c.startsWith('$_readEvent:') ||
        c.startsWith('$_readState:') ||
        c.startsWith('$_readToDevice:'),
  );

  bool _matches(
    String eventPrefix,
    String statePrefix,
    String type,
    String? stateKey,
    String? msgtype,
  ) {
    if (stateKey != null) {
      return all.contains('$statePrefix:$type') ||
          all.contains('$statePrefix:$type#$stateKey');
    }
    if (all.contains('$eventPrefix:$type')) return true;
    return type == 'm.room.message' &&
        msgtype != null &&
        all.contains('$eventPrefix:m.room.message#$msgtype');
  }

  static ({String type, String? stateKey}) _splitStateFilter(String value) {
    final hash = value.indexOf('#');
    return hash < 0
        ? (type: value, stateKey: null)
        : (type: value.substring(0, hash), stateKey: value.substring(hash + 1));
  }
}

// MSC4140 (cancellable delayed events) protocol helpers for "Send later".
//
// Only the request/response shapes live here; the guarded send path (session
// ownership, recipient trust, fail-closed encryption and the final HTTP
// guard) is MatrixBackend.sendRoomEventDelayed, which calls
// [putDelayedRoomEvent] inside those guards.
import 'dart:convert';

import 'package:matrix/matrix.dart' as matrix;

/// Unstable query parameter that turns a room send into a delayed event.
const delayQueryParameter = 'org.matrix.msc4140.delay';

/// Unstable management/listing endpoint (relative to `/_matrix`).
const delayedEventsPath = '/client/unstable/org.matrix.msc4140/delayed_events';

/// Upper bound we ever request, whatever the server allows (one year).
const maxScheduleDelay = Duration(days: 366);

/// Matrix limits an event to 65 536 bytes; the SDK refuses bodies above this.
const maxDelayedEventBytes = 60000;

/// Sends a timeline event later through the guarded backend path.
///
/// Implemented by `MatrixBackend` next to `sendRoomEvent`: it applies the
/// same session ownership, recipient trust approval, fail-closed encryption
/// and final HTTP guard, encrypts *now* (so only members who receive the
/// room key at scheduling time can read it) and returns the server's
/// `delay_id`.
abstract interface class DelayedRoomEventSender {
  Future<String> sendRoomEventDelayed(
    String roomId,
    String type,
    Map<String, Object?> content,
    Duration delay,
  );
}

enum DelayedEventFailure {
  /// The homeserver does not offer delayed events.
  unsupported,

  /// The requested delay is beyond the homeserver's maximum.
  delayTooLarge,

  /// Too many scheduled events, or rate limited.
  limited,

  /// The delayed event no longer exists (already sent or cancelled).
  notFound,

  /// The server ignored the delay and sent the event immediately.
  sentImmediately,

  /// Encryption was unavailable, so nothing was sent.
  encryptionUnavailable,

  /// Capability discovery failed (network or server error).
  probeFailed,

  /// The server answered with something we could not interpret.
  invalidResponse,
}

class DelayedEventException implements Exception {
  const DelayedEventException(this.kind, {this.maxDelay});
  final DelayedEventFailure kind;

  /// The server's maximum delay, when it told us.
  final Duration? maxDelay;

  @override
  String toString() => 'DelayedEventException(${kind.name})';
}

const _delayTooLargeCodes = {
  'M_DELAY_TOO_LARGE',
  'ORG.MATRIX.MSC4140_DELAY_TOO_LARGE',
  // Synapse before 1.157 and the earlier MSC text.
  'M_MAX_DELAY_EXCEEDED',
  'ORG.MATRIX.MSC4140_MAX_DELAY_EXCEEDED',
};

int? _positiveInt(Object? value) =>
    value is num && value.isFinite && value > 0 ? value.toInt() : null;

/// Maps a homeserver error from a delayed-event request, or null when it is
/// not specific to delayed events.
DelayedEventException? delayedEventErrorFrom(Object error) {
  if (error is DelayedEventException) return error;
  if (error is! matrix.MatrixException) return null;
  final raw = error.raw;
  final code = error.errcode.toUpperCase();
  final unstable = raw['org.matrix.msc4140.errcode'];
  final unstableCode = unstable is String ? unstable.toUpperCase() : null;
  if (_delayTooLargeCodes.contains(code) ||
      _delayTooLargeCodes.contains(unstableCode)) {
    final max =
        _positiveInt(raw['max_delay']) ??
        _positiveInt(raw['org.matrix.msc4140.max_delay']);
    return DelayedEventException(
      DelayedEventFailure.delayTooLarge,
      maxDelay: max == null ? null : Duration(milliseconds: max),
    );
  }
  if (code == 'M_UNRECOGNIZED') {
    return const DelayedEventException(DelayedEventFailure.unsupported);
  }
  if (code == 'M_LIMIT_EXCEEDED' ||
      unstableCode == 'M_MAX_DELAYED_EVENTS_EXCEEDED') {
    return const DelayedEventException(DelayedEventFailure.limited);
  }
  if (code == 'M_NOT_FOUND') {
    return const DelayedEventException(DelayedEventFailure.notFound);
  }
  return null;
}

/// Issues `PUT /rooms/{roomId}/send/{type}/{txnId}?org.matrix.msc4140.delay=`
/// and returns the `delay_id`.
///
/// For [encrypted] rooms [encrypt] must return a Megolm payload; anything
/// else (the SDK returns plaintext when encryption is off) fails closed
/// before any request. Callers run this inside the backend's send guards.
Future<String> putDelayedRoomEvent(
  matrix.Client client, {
  required String roomId,
  required String type,
  required Map<String, Object?> content,
  required Duration delay,
  required bool encrypted,
  Future<Map<String, dynamic>> Function(Map<String, dynamic> content)? encrypt,
  String? transactionId,
}) async {
  if (roomId.isEmpty || type.isEmpty || type == matrix.EventTypes.Encrypted) {
    throw ArgumentError('Invalid delayed event target');
  }
  if (delay <= Duration.zero || delay > maxScheduleDelay) {
    throw ArgumentError.value(delay, 'delay', 'Invalid schedule delay');
  }
  // Deep copy through JSON: rejects non-JSON values and detaches the caller's
  // map from the SDK's in-place edits.
  var payload = Map<String, dynamic>.from(
    jsonDecode(jsonEncode(content)) as Map,
  );
  var eventType = type;
  if (encrypted) {
    if (encrypt == null) {
      throw const DelayedEventException(
        DelayedEventFailure.encryptionUnavailable,
      );
    }
    final sealed = await encrypt(payload);
    final ciphertext = sealed['ciphertext'];
    if (sealed['algorithm'] != matrix.AlgorithmTypes.megolmV1AesSha2 ||
        ciphertext is! String ||
        ciphertext.isEmpty) {
      throw const DelayedEventException(
        DelayedEventFailure.encryptionUnavailable,
      );
    }
    payload = sealed;
    eventType = matrix.EventTypes.Encrypted;
  }
  if (utf8.encode(jsonEncode(payload)).length > maxDelayedEventBytes) {
    throw ArgumentError('This message is too large to schedule');
  }
  final txnId = transactionId ?? client.generateUniqueTransactionId();
  final Map<String, Object?> response;
  try {
    response = await client.request(
      matrix.RequestType.PUT,
      '/client/v3/rooms/${Uri.encodeComponent(roomId)}'
      '/send/${Uri.encodeComponent(eventType)}/${Uri.encodeComponent(txnId)}',
      data: payload,
      query: {delayQueryParameter: delay.inMilliseconds.toString()},
    );
  } catch (error) {
    throw delayedEventErrorFrom(error) ?? error;
  }
  final delayId = response['delay_id'];
  if (delayId is String && delayId.isNotEmpty && delayId.length <= 255) {
    return delayId;
  }
  if (response['event_id'] is String) {
    throw const DelayedEventException(DelayedEventFailure.sentImmediately);
  }
  throw const DelayedEventException(DelayedEventFailure.invalidResponse);
}

/// What the homeserver says about delayed events.
class DelayedEventsCapability {
  const DelayedEventsCapability({
    required this.supported,
    this.maxDelay,
    this.maxScheduled,
  });
  const DelayedEventsCapability.unsupported()
    : supported = false,
      maxDelay = null,
      maxScheduled = null;

  final bool supported;

  /// Longest delay the server accepts, when advertised.
  final Duration? maxDelay;
  final int? maxScheduled;
}

int? _nonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

/// Detects MSC4140 support: the `m.delayed_events` capability (or its
/// unstable name), then `/versions` `unstable_features["org.matrix.msc4140"]`
/// (Synapse before 1.157 advertises only that). Throws
/// [DelayedEventFailure.probeFailed] when neither could be read.
Future<DelayedEventsCapability> probeDelayedEvents(matrix.Client client) async {
  try {
    final response = await client.request(
      matrix.RequestType.GET,
      '/client/v3/capabilities',
    );
    final capabilities = response['capabilities'];
    if (capabilities is Map) {
      final entry =
          capabilities['m.delayed_events'] ??
          capabilities['org.matrix.msc4140.delayed_events'];
      if (entry is Map) {
        final maxDelay = _nonNegativeInt(entry['max_delay_ms']);
        final maxScheduled = _nonNegativeInt(entry['max_scheduled']);
        // Only an explicit 0 (or enabled: false) disables delayed events.
        if (maxDelay == 0 || maxScheduled == 0 || entry['enabled'] == false) {
          return const DelayedEventsCapability.unsupported();
        }
        return DelayedEventsCapability(
          supported: true,
          maxDelay: maxDelay == null ? null : Duration(milliseconds: maxDelay),
          maxScheduled: maxScheduled,
        );
      }
    }
  } catch (_) {
    // Fall back to /versions below.
  }
  try {
    final versions = await client.request(
      matrix.RequestType.GET,
      '/client/versions',
    );
    final features = versions['unstable_features'];
    final supported = features is Map && features['org.matrix.msc4140'] == true;
    return supported
        ? const DelayedEventsCapability(supported: true)
        : const DelayedEventsCapability.unsupported();
  } catch (_) {
    throw const DelayedEventException(DelayedEventFailure.probeFailed);
  }
}

/// One of the user's scheduled delayed events as listed by the server.
class ServerDelayedEvent {
  const ServerDelayedEvent({
    required this.delayId,
    required this.roomId,
    required this.type,
    required this.content,
    this.stateKey,
    this.sendAt,
  });
  final String delayId;
  final String roomId;
  final String type;
  final String? stateKey;

  /// `running_since + delay`, when the server reported both.
  final DateTime? sendAt;

  /// Event content as scheduled (ciphertext for encrypted rooms).
  final Map<String, Object?> content;

  /// Timeline (non-state) events only: state events are used by others, for
  /// example Element Call's delayed "leave" membership events.
  bool get isTimelineEvent => stateKey == null;
}

/// All pages of the server list. [complete] is false when paging stopped
/// early, in which case absence from [events] proves nothing.
class ServerDelayedEvents {
  const ServerDelayedEvents(this.events, {required this.complete});
  final List<ServerDelayedEvent> events;
  final bool complete;
}

const _maxIdLength = 255;

/// Leniently parses one page; malformed items are skipped, never fatal.
List<ServerDelayedEvent> parseDelayedEvents(Map<String, Object?> json) {
  final list = json['delayed_events'] ?? json['scheduled'];
  if (list is! List) return const [];
  final result = <ServerDelayedEvent>[];
  for (final item in list.take(1000)) {
    if (item is! Map) continue;
    final delayId = item['delay_id'];
    final roomId = item['room_id'];
    final type = item['type'];
    if (delayId is! String ||
        delayId.isEmpty ||
        delayId.length > _maxIdLength ||
        roomId is! String ||
        roomId.isEmpty ||
        roomId.length > _maxIdLength ||
        type is! String ||
        type.isEmpty ||
        type.length > _maxIdLength) {
      continue;
    }
    final stateKey = item['state_key'];
    final delay = _nonNegativeInt(item['delay'] ?? item['delay_ms']);
    final since = _nonNegativeInt(item['running_since']);
    final content = item['content'];
    result.add(
      ServerDelayedEvent(
        delayId: delayId,
        roomId: roomId,
        type: type,
        stateKey: stateKey is String ? stateKey : null,
        sendAt: delay == null || since == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(since + delay, isUtc: true),
        content: content is Map
            ? Map<String, Object?>.from(content)
            : const <String, Object?>{},
      ),
    );
  }
  return result;
}

/// Fetches the user's scheduled delayed events (bounded paging).
Future<ServerDelayedEvents> fetchScheduledDelayedEvents(
  matrix.Client client, {
  int maxPages = 10,
}) async {
  final events = <ServerDelayedEvent>[];
  final seen = <String>{};
  String? from;
  for (var page = 0; page < maxPages; page++) {
    final json = await client.request(
      matrix.RequestType.GET,
      delayedEventsPath,
      query: {'from': ?from},
    );
    for (final event in parseDelayedEvents(json)) {
      if (seen.add(event.delayId)) events.add(event);
    }
    final next = json['next_batch'];
    if (next is! String || next.isEmpty || next == from) {
      return ServerDelayedEvents(events, complete: true);
    }
    from = next;
  }
  return ServerDelayedEvents(events, complete: false);
}

enum DelayedEventCommand { send, cancel }

final _safeDelayId = RegExp(r'^[A-Za-z0-9._~-]{1,255}$');

/// Sends now or cancels a scheduled delayed event (SDK
/// `manageDelayedEvent`, which inserts the ID into the path unencoded, so
/// IDs outside the unreserved URL alphabet are refused).
Future<void> manageScheduledEvent(
  matrix.Client client,
  String delayId,
  DelayedEventCommand command,
) async {
  if (!_safeDelayId.hasMatch(delayId)) {
    throw ArgumentError.value(delayId, 'delayId', 'Unsupported delay ID');
  }
  try {
    await client.manageDelayedEvent(delayId, switch (command) {
      DelayedEventCommand.send => matrix.DelayedEventAction.send,
      DelayedEventCommand.cancel => matrix.DelayedEventAction.cancel,
    });
  } catch (error) {
    throw delayedEventErrorFrom(error) ?? error;
  }
}

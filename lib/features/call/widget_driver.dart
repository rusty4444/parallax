// Matrix widget API host ("client widget API") for Element Call.
//
// Element X runs the matrix-rust-sdk widget machine; this is the Dart
// equivalent, scoped to the one room the widget was opened for. The WebView
// side is a plain string sink plus [CallWidgetDriver.handleMessage], so the
// whole protocol is unit-testable with a fake bridge.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:matrix/matrix.dart' show MatrixException;

import 'widget_capabilities.dart';

/// Matrix operations the widget may perform, bound to one room and session.
/// The Matrix implementation lives in `matrix_call_features.dart`; tests use
/// fakes.
abstract interface class CallWidgetMatrix {
  String get roomId;

  /// Whether the room is end-to-end encrypted (to-device traffic is then
  /// always Olm-encrypted and cleartext to-device input is dropped).
  bool get roomEncrypted;

  /// OpenID credentials: `access_token`, `expires_in`,
  /// `matrix_server_name`, `token_type`.
  Future<Map<String, Object?>> requestOpenId();

  /// Sends a message-like room event through the app's guarded send path.
  Future<String> sendRoomEvent(String type, Map<String, Object?> content);

  /// Redacts one of this user's own events. Returns the redaction event ID
  /// when known.
  Future<String?> redactOwnEvent(String eventId);

  Future<String> sendStateEvent(
    String type,
    String stateKey,
    Map<String, Object?> content,
  );

  /// MSC4140 delayed state event. Returns the delay ID.
  Future<String> sendDelayedStateEvent(
    String type,
    String stateKey,
    Map<String, Object?> content, {
    required int delayMs,
  });

  /// [action] is `cancel`, `restart` or `send`.
  Future<void> updateDelayedEvent(String delayId, String action);

  /// Sends to-device messages (`user → device or * → content`). Returns
  /// failed recipients (`user → devices`).
  Future<Map<String, List<String>>> sendToDevice(
    String type,
    Map<String, Map<String, Map<String, Object?>>> messages, {
    required bool encrypted,
  });

  /// Current room state of [type] (one key, or every key when null).
  Future<List<Map<String, Object?>>> readState(String type, {String? stateKey});

  /// Recent room events of [type], newest first.
  Future<List<Map<String, Object?>>> readEvents(
    String type, {
    required int limit,
  });

  /// Live timeline events of this room (decrypted), as Matrix event JSON.
  Stream<Map<String, Object?>> get roomEvents;

  /// Live room state changes of this room, as Matrix event JSON.
  Stream<Map<String, Object?>> get stateUpdates;

  /// Live to-device events: `{type, sender, content, encrypted}`.
  Stream<Map<String, Object?>> get toDeviceEvents;

  void dispose();
}

/// Widget API versions this driver implements (the matrix-rust-sdk set minus
/// MSC4039 file transfer and the MSC4515/MSC4533 RTC endpoints).
const supportedWidgetApiVersions = [
  '0.0.1',
  '0.0.2',
  'org.matrix.msc2762',
  'org.matrix.msc2762_update_state',
  'org.matrix.msc2871',
  'org.matrix.msc3819',
];

enum _Negotiation { unset, negotiating, negotiated }

class CallWidgetDriver {
  CallWidgetDriver({
    required this.widgetId,
    required this.matrix,
    required this._send,
    required this.allowedCapabilities,
    this.onContentLoaded,
    this.onJoined,
    this.onHangup,
    this.onClose,
    this.onAlwaysOnScreen,
    this.requestTimeout = const Duration(seconds: 10),
    this.maxPendingRequests = 100,
  });

  final String widgetId;
  final CallWidgetMatrix matrix;
  final Set<String> allowedCapabilities;
  final void Function(String json) _send;
  final void Function()? onContentLoaded;
  final void Function()? onJoined;
  final void Function()? onHangup;
  final void Function()? onClose;
  final void Function(bool value)? onAlwaysOnScreen;
  final Duration requestTimeout;
  final int maxPendingRequests;

  static const maxMessageLength = 1024 * 1024;
  static const maxEventContentLength = 64 * 1024;
  static const maxToDeviceRecipients = 1000;

  var _negotiation = _Negotiation.unset;
  var _capabilities = ApprovedCapabilities.none;
  final _pending = <String, _PendingRequest>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _ownDelayIds = <String>{};
  final _random = Random.secure();
  var _counter = 0;
  var _disposed = false;
  var _contentLoaded = false;
  var _joined = false;

  ApprovedCapabilities get capabilities => _capabilities;
  bool get contentLoaded => _contentLoaded;
  bool get joined => _joined;
  bool get negotiated => _negotiation == _Negotiation.negotiated;
  bool get disposed => _disposed;

  /// Entry point for every message the WebView bridge forwards.
  void handleMessage(String raw) {
    if (_disposed || raw.length > maxMessageLength) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final message = Map<String, Object?>.from(decoded);
    if (message['widgetId'] != widgetId) return;
    final requestId = message['requestId'];
    final action = message['action'];
    if (requestId is! String || requestId.isEmpty || action is! String) {
      return;
    }
    switch (message['api']) {
      case 'fromWidget' when !message.containsKey('response'):
        _handleFromWidget(message, requestId, action);
      case 'toWidget' when message.containsKey('response'):
        _handleToWidgetResponse(message, requestId, action);
    }
  }

  /// Fallback for a missed `content_loaded` (it can race the injection of
  /// the page listener): start capability negotiation from the client side,
  /// as the Rust driver does for widgets not initialised on content load.
  void startIfIdle() {
    if (_disposed || _negotiation != _Negotiation.unset) return;
    unawaited(_negotiate());
  }

  /// Asks Element Call to hang up (Element X's back/hang-up path).
  Future<void> hangUp() async {
    if (_disposed) return;
    try {
      await _request('im.vector.hangup', const {});
    } catch (_) {
      // The caller closes the screen after a short grace period anyway.
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    for (final pending in _pending.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError('Widget closed'));
        // Nobody may be awaiting fire-and-forget requests.
        pending.completer.future.ignore();
      }
    }
    _pending.clear();
    matrix.dispose();
  }

  // --- fromWidget requests -------------------------------------------------

  void _handleFromWidget(
    Map<String, Object?> request,
    String requestId,
    String action,
  ) {
    final data = request['data'] is Map
        ? Map<String, Object?>.from(request['data'] as Map)
        : const <String, Object?>{};
    switch (action) {
      case 'supported_api_versions':
        _reply(request, {'supported_versions': supportedWidgetApiVersions});
      case 'content_loaded':
        _reply(request, const {});
        if (!_contentLoaded) {
          _contentLoaded = true;
          onContentLoaded?.call();
        }
        if (_negotiation == _Negotiation.unset) unawaited(_negotiate());
      case 'get_openid':
        unawaited(_getOpenId(request, requestId));
      case 'org.matrix.msc2876.read_events':
        _guarded(request, () => _readEvents(data));
      case 'send_event':
        _guarded(request, () => _sendEvent(data));
      case 'send_to_device':
        _guarded(request, () => _sendToDevice(data));
      case 'org.matrix.msc4157.update_delayed_event':
        _guarded(request, () => _updateDelayedEvent(data));
      case 'io.element.join':
        _reply(request, const {});
        _joined = true;
        onJoined?.call();
      case 'im.vector.hangup':
        _reply(request, const {});
        _joined = false;
        onHangup?.call();
      case 'io.element.close':
        _reply(request, const {});
        onClose?.call();
      case 'set_always_on_screen':
        _reply(request, const {});
        onAlwaysOnScreen?.call(data['value'] == true);
      case 'io.element.device_mute' ||
          'io.element.tile_layout' ||
          'io.element.spotlight_layout':
        _reply(request, const {});
      default:
        final name = action.length > 80 ? action.substring(0, 80) : action;
        _replyError(request, 'Unsupported action: $name');
    }
  }

  void _guarded(
    Map<String, Object?> request,
    Future<Object?> Function() handler,
  ) {
    if (_negotiation != _Negotiation.negotiated) {
      _replyError(
        request,
        'Received ${request['action']} before capabilities were negotiated',
      );
      return;
    }
    unawaited(() async {
      try {
        final response = await handler();
        _reply(request, response ?? const <String, Object?>{});
      } on _WidgetError catch (error) {
        _replyError(request, error.message);
      } on MatrixException catch (error) {
        _replyMatrixError(request, error);
      } on StateError catch (error) {
        _replyError(request, error.message);
      } catch (_) {
        _replyError(request, 'The request failed');
      }
    }());
  }

  Future<void> _getOpenId(Map<String, Object?> request, String id) async {
    try {
      final credentials = await matrix.requestOpenId();
      _reply(request, {
        'state': 'allowed',
        'original_request_id': id,
        ...credentials,
      });
    } catch (_) {
      _reply(request, {'state': 'blocked', 'original_request_id': id});
    }
  }

  Future<Map<String, Object?>> _sendEvent(Map<String, Object?> data) async {
    final type = data['type'];
    if (type is! String || type.isEmpty || type.length > 255) {
      throw const _WidgetError('Invalid event type');
    }
    final targetRoom = data['room_id'];
    if (targetRoom != null && targetRoom != matrix.roomId) {
      throw const _WidgetError('This widget can only send to its own room');
    }
    final rawContent = data['content'] ?? const <String, Object?>{};
    if (rawContent is! Map) throw const _WidgetError('Invalid event content');
    final content = Map<String, Object?>.from(rawContent);
    if (jsonEncode(content).length > maxEventContentLength) {
      throw const _WidgetError('Event content is too large');
    }
    final stateKey = data['state_key'];
    if (stateKey != null && stateKey is! String) {
      throw const _WidgetError('Invalid state key');
    }
    final delay = data['delay'];
    if (delay != null) {
      if (!_capabilities.canSendDelayed) {
        throw const _WidgetError(
          'Not allowed: missing the $capSendDelayedEvent capability.',
        );
      }
      if (delay is! int || delay < 0 || delay > 24 * 60 * 60 * 1000) {
        throw const _WidgetError('Invalid delay');
      }
    }
    if (data['parent_delay_id'] != null) {
      throw const _WidgetError('Delayed event groups are not supported');
    }
    final msgtype = content['msgtype'];
    if (!_capabilities.canSend(
      type,
      stateKey: stateKey as String?,
      msgtype: msgtype is String ? msgtype : null,
    )) {
      throw const _WidgetError('Not allowed to send event');
    }
    if (stateKey != null) {
      if (delay is int) {
        final delayId = await matrix.sendDelayedStateEvent(
          type,
          stateKey,
          content,
          delayMs: delay,
        );
        _ownDelayIds.add(delayId);
        return {'room_id': matrix.roomId, 'delay_id': delayId};
      }
      final eventId = await matrix.sendStateEvent(type, stateKey, content);
      return {'room_id': matrix.roomId, 'event_id': eventId};
    }
    if (delay != null) {
      // Only state events can be delayed without bypassing the app's
      // guarded (encrypting) timeline send path.
      throw const _WidgetError('Delayed message events are not supported');
    }
    if (type == 'm.room.redaction') {
      final redacts = content['redacts'] ?? data['redacts'];
      if (redacts is! String || !redacts.startsWith(r'$')) {
        throw const _WidgetError('Invalid redaction target');
      }
      final eventId = await matrix.redactOwnEvent(redacts);
      return {'room_id': matrix.roomId, 'event_id': ?eventId};
    }
    final eventId = await matrix.sendRoomEvent(type, content);
    return {'room_id': matrix.roomId, 'event_id': eventId};
  }

  Future<Map<String, Object?>> _updateDelayedEvent(
    Map<String, Object?> data,
  ) async {
    if (!_capabilities.canUpdateDelayed) {
      throw const _WidgetError(
        'Not allowed: missing the $capUpdateDelayedEvent capability.',
      );
    }
    final action = data['action'];
    final delayId = data['delay_id'];
    if (action is! String ||
        !const {'cancel', 'restart', 'send'}.contains(action)) {
      throw const _WidgetError('Invalid delayed event action');
    }
    if (delayId is! String || !_ownDelayIds.contains(delayId)) {
      throw const _WidgetError('Unknown delayed event');
    }
    await matrix.updateDelayedEvent(delayId, action);
    if (action != 'restart') _ownDelayIds.remove(delayId);
    return const {};
  }

  Future<Map<String, Object?>> _sendToDevice(Map<String, Object?> data) async {
    final type = data['type'];
    if (type is! String || type.isEmpty) {
      throw const _WidgetError('Invalid to-device type');
    }
    if (!_capabilities.canSendToDevice(type)) {
      throw _WidgetError(
        'Not allowed to send to-device message of type: $type',
      );
    }
    final rawMessages = data['messages'];
    if (rawMessages is! Map) throw const _WidgetError('Invalid messages');
    final messages = <String, Map<String, Map<String, Object?>>>{};
    var recipients = 0;
    for (final MapEntry(key: user, value: devices) in rawMessages.entries) {
      if (user is! String || !user.startsWith('@') || devices is! Map) {
        throw const _WidgetError('Invalid recipient');
      }
      final byDevice = <String, Map<String, Object?>>{};
      for (final MapEntry(key: device, value: content) in devices.entries) {
        if (device is! String || device.isEmpty || content is! Map) {
          throw const _WidgetError('Invalid recipient device');
        }
        final payload = Map<String, Object?>.from(content);
        if (jsonEncode(payload).length > maxEventContentLength) {
          throw const _WidgetError('To-device content is too large');
        }
        byDevice[device] = payload;
        if (++recipients > maxToDeviceRecipients) {
          throw const _WidgetError('Too many to-device recipients');
        }
      }
      messages[user] = byDevice;
    }
    // Encrypted rooms always encrypt; elsewhere honour the widget's request.
    final encrypted = matrix.roomEncrypted || data['encrypted'] == true;
    final failures = await matrix.sendToDevice(
      type,
      messages,
      encrypted: encrypted,
    );
    return failures.isEmpty ? const {} : {'failures': failures};
  }

  Future<Map<String, Object?>> _readEvents(Map<String, Object?> data) async {
    final type = data['type'];
    if (type is! String || type.isEmpty) {
      throw const _WidgetError('Invalid event type');
    }
    final stateKey = data['state_key'];
    final limit = switch (data['limit']) {
      final int value => value.clamp(1, 100),
      _ => 50,
    };
    final List<Map<String, Object?>> events;
    if (stateKey == null) {
      if (!_capabilities.hasEventReadFilterFor(type)) {
        throw const _WidgetError('Not allowed to read message-like event');
      }
      events = await matrix.readEvents(type, limit: limit);
    } else {
      final key = stateKey is String ? stateKey : null;
      if (stateKey is! String && stateKey != true) {
        throw const _WidgetError('Invalid state key');
      }
      final allowed = key == null
          ? _capabilities.hasStateReadFilterFor(type)
          : _capabilities.canRead(type, stateKey: key);
      if (!allowed) throw const _WidgetError('Not allowed to read state event');
      events = await matrix.readState(type, stateKey: key);
    }
    return {
      'events': [
        for (final event in events.take(limit))
          if (_canDeliver(event)) event,
      ],
    };
  }

  // --- negotiation and subscriptions ---------------------------------------

  Future<void> _negotiate() async {
    _negotiation = _Negotiation.negotiating;
    final Map<String, Object?> response;
    try {
      response = await _request('capabilities', const {});
    } catch (_) {
      // No answer: the widget gets nothing (fail closed).
      if (!_disposed) {
        _negotiation = _Negotiation.negotiated;
        _capabilities = ApprovedCapabilities.none;
      }
      return;
    }
    if (_disposed) return;
    final requested = response['capabilities'] is List
        ? (response['capabilities'] as List).whereType<String>().toList()
        : const <String>[];
    final approved = negotiateCapabilities(requested, allowedCapabilities);
    _capabilities = ApprovedCapabilities(approved);
    _negotiation = _Negotiation.negotiated;
    unawaited(
      _request('notify_capabilities', {
        'requested': requested,
        'approved': approved.toList(),
      }).then<void>((_) {}, onError: (Object _) {}),
    );
    if (_capabilities.readsAnything) _subscribe();
    await _pushInitialState();
  }

  void _subscribe() {
    _subscriptions
      ..add(
        matrix.roomEvents.listen((event) {
          if (_canDeliver(event)) _notify('send_event', event);
        }, onError: (Object _) {}),
      )
      ..add(
        matrix.stateUpdates.listen((event) {
          if (_canDeliver(event)) {
            _notify('update_state', {
              'state': [event],
            });
          }
        }, onError: (Object _) {}),
      )
      ..add(
        matrix.toDeviceEvents.listen((event) {
          if (_canDeliverToDevice(event)) _notify('send_to_device', event);
        }, onError: (Object _) {}),
      );
  }

  Future<void> _pushInitialState() async {
    final filters = _capabilities.stateReadFilters;
    if (filters.isEmpty) return;
    final state = <String, Map<String, Object?>>{};
    for (final filter in filters) {
      try {
        final events = await matrix.readState(
          filter.type,
          stateKey: filter.stateKey,
        );
        if (_disposed) return;
        for (final event in events) {
          if (!_canDeliver(event)) continue;
          state['${event['type']}\u0000${event['state_key']}'] = event;
        }
      } catch (_) {
        // As the Rust SDK: a failed read must not block the whole update.
      }
    }
    if (_disposed) return;
    _notify('update_state', {'state': state.values.toList()});
  }

  bool _canDeliver(Map<String, Object?> event) {
    final type = event['type'];
    if (type is! String) return false;
    final stateKey = event['state_key'];
    final content = event['content'];
    final msgtype = content is Map ? content['msgtype'] : null;
    return _capabilities.canRead(
      type,
      stateKey: stateKey is String ? stateKey : null,
      msgtype: msgtype is String ? msgtype : null,
    );
  }

  bool _canDeliverToDevice(Map<String, Object?> event) {
    final type = event['type'];
    if (type is! String || !_capabilities.canReadToDevice(type)) return false;
    final encrypted = event['encrypted'] == true;
    // In an encrypted room, call keys must arrive Olm-encrypted.
    if (matrix.roomEncrypted && !encrypted) return false;
    final content = event['content'];
    if (content is! Map) return false;
    final room = content['room_id'];
    return room == null || room == matrix.roomId;
  }

  // --- toWidget requests ---------------------------------------------------

  void _notify(String action, Map<String, Object?> data) {
    unawaited(_request(action, data).then<void>((_) {}, onError: (_) {}));
  }

  Future<Map<String, Object?>> _request(
    String action,
    Map<String, Object?> data,
  ) {
    if (_disposed) return Future.error(StateError('Widget closed'));
    if (_pending.length >= maxPendingRequests) {
      return Future.error(StateError('Too many pending widget requests'));
    }
    final requestId =
        'parallax-${++_counter}-${_random.nextInt(1 << 32).toRadixString(16)}';
    final completer = Completer<Map<String, Object?>>();
    final timer = Timer(requestTimeout, () {
      final pending = _pending.remove(requestId);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          TimeoutException('Widget did not answer $action'),
        );
      }
    });
    _pending[requestId] = _PendingRequest(action, completer, timer);
    _emit({
      'api': 'toWidget',
      'widgetId': widgetId,
      'requestId': requestId,
      'action': action,
      'data': data,
    });
    return completer.future;
  }

  void _handleToWidgetResponse(
    Map<String, Object?> message,
    String requestId,
    String action,
  ) {
    final pending = _pending[requestId];
    if (pending == null || pending.action != action) return;
    _pending.remove(requestId);
    pending.timer.cancel();
    final response = message['response'];
    pending.completer.complete(
      response is Map
          ? Map<String, Object?>.from(response)
          : const <String, Object?>{},
    );
  }

  // --- output --------------------------------------------------------------

  void _reply(Map<String, Object?> request, Object response) {
    if (_disposed) return;
    _emit({...request, 'response': response});
  }

  void _replyError(Map<String, Object?> request, String message) =>
      _reply(request, {
        'error': {'message': message},
      });

  /// Matrix errors carry `matrix_api_error` (as the Rust driver does) so
  /// Element Call can react to e.g. M_UNRECOGNIZED or
  /// M_MAX_DELAY_EXCEEDED for delayed events.
  void _replyMatrixError(Map<String, Object?> request, MatrixException error) {
    final raw = error.raw;
    final errcode = raw['errcode'];
    _reply(request, {
      'error': {
        'message': error.errorMessage,
        if (errcode is String)
          'matrix_api_error': {
            'http_status': error.response?.statusCode ?? 400,
            'response': {
              for (final entry in raw.entries)
                // Bounded: only the standard error body and scalar hints.
                if (entry.value is String ||
                    entry.value is num ||
                    entry.value is bool)
                  entry.key: entry.value,
            },
          },
      },
    });
  }

  void _emit(Map<String, Object?> message) {
    if (_disposed) return;
    _send(jsonEncode(message));
  }
}

class _PendingRequest {
  _PendingRequest(this.action, this.completer, this.timer);
  final String action;
  final Completer<Map<String, Object?>> completer;
  final Timer timer;
}

class _WidgetError implements Exception {
  const _WidgetError(this.message);
  final String message;
}

/// Random widget ID for one call screen.
String newCallWidgetId([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(
    16,
    (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Color;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart' as matrix;

/// Client identifiers only. Never put gateway service-account/private keys here.
@immutable
class PushConfiguration {
  const PushConfiguration({
    this.gatewayUrl,
    this.appId = '',
    this.firebaseOptions,
  });

  factory PushConfiguration.fromEnvironment() {
    const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
    return PushConfiguration(
      gatewayUrl: Uri.tryParse(
        const String.fromEnvironment('MATRIX_PUSH_GATEWAY'),
      ),
      appId: const String.fromEnvironment('MATRIX_PUSH_APP_ID'),
      firebaseOptions: firebaseAppId.isEmpty
          ? null
          : const FirebaseOptions(
              apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
              appId: firebaseAppId,
              messagingSenderId: String.fromEnvironment(
                'FIREBASE_MESSAGING_SENDER_ID',
              ),
              projectId: String.fromEnvironment('FIREBASE_PROJECT_ID'),
            ),
    );
  }

  final Uri? gatewayUrl;

  /// Matrix reverse-DNS pusher app_id, configured identically on your gateway.
  final String appId;
  final FirebaseOptions? firebaseOptions;

  List<String> get issues {
    final issues = <String>[];
    final url = gatewayUrl;
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment) {
      issues.add(
        'Set your own HTTPS Matrix push gateway URL (no credentials, query or fragment).',
      );
    } else if (url.path != '/_matrix/push/v1/notify' &&
        !url.path.endsWith('/_matrix/push/v1/notify')) {
      issues.add('Gateway URL must end in /_matrix/push/v1/notify.');
    }
    if (appId.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$').hasMatch(appId)) {
      issues.add(
        'Set a reverse-DNS Matrix pusher app ID matching your gateway (maximum 64 characters).',
      );
    }
    final options = firebaseOptions;
    if (options == null ||
        options.apiKey.trim().isEmpty ||
        options.projectId.trim().isEmpty ||
        options.messagingSenderId.trim().isEmpty ||
        options.appId.trim().isEmpty) {
      issues.add(
        'Supply your own FirebaseOptions: API key, Android app ID, messaging sender ID and project ID.',
      );
    } else if (!RegExp(r'^\d+$').hasMatch(options.messagingSenderId) ||
        !RegExp(
          '^1:${RegExp.escape(options.messagingSenderId)}:android:[a-fA-F0-9]+\$',
        ).hasMatch(options.appId)) {
      issues.add(
        'Firebase Android app ID must belong to the supplied messaging sender ID. Use the same Firebase project as your gateway.',
      );
    }
    return List.unmodifiable(issues);
  }

  bool get isComplete => issues.isEmpty;

  Map<String, dynamic> toJson() => {
    'gateway_url': gatewayUrl?.toString(),
    'app_id': appId,
    if (firebaseOptions case final options?)
      'firebase': {
        'api_key': options.apiKey,
        'app_id': options.appId,
        'sender_id': options.messagingSenderId,
        'project_id': options.projectId,
      },
  };

  static PushConfiguration? fromJson(Map<String, dynamic> json) {
    try {
      final firebase = json['firebase'] as Map<String, dynamic>;
      return PushConfiguration(
        gatewayUrl: Uri.tryParse(json['gateway_url'] as String),
        appId: json['app_id'] as String,
        firebaseOptions: FirebaseOptions(
          apiKey: firebase['api_key'] as String,
          appId: firebase['app_id'] as String,
          messagingSenderId: firebase['sender_id'] as String,
          projectId: firebase['project_id'] as String,
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

enum PushStatus {
  disabled,
  configurationRequired,
  signedOut,
  starting,
  permissionDenied,
  active,
  error,
}

enum PushPermission { authorized, denied }

/// Callbacks MUST capture the exact SDK client/session, not a mutable getter.
/// Create a new instance after each login, including re-login to the same account.
class PushSession {
  PushSession({
    required this.userId,
    required this.deviceId,
    required this.registerPusher,
    required this.removePusher,
    required this.onNavigate,
  }) {
    if (!userId.startsWith('@') || !userId.contains(':') || deviceId.isEmpty) {
      throw ArgumentError(
        'PushSession requires an authenticated account and device.',
      );
    }
  }
  final String userId;
  final String deviceId;
  final Future<void> Function(PushRegistration) registerPusher;
  final Future<void> Function(PushRegistration) removePusher;
  final Future<void> Function(PushNavigationRequest) onNavigate;
}

@immutable
class PushRegistration {
  const PushRegistration({
    required this.configuration,
    required this.userId,
    required this.deviceId,
    required this.token,
    required this.registrationId,
  });
  final PushConfiguration configuration;
  final String userId;
  final String deviceId;
  final String token;

  /// Fresh 192-bit nonce for this account/device/token registration generation.
  final String registrationId;
  matrix.Pusher get pusher => matrix.Pusher(
    appId: configuration.appId,
    pushkey: token,
    appDisplayName: 'Parallax',
    deviceDisplayName: 'Parallax Android',
    kind: 'http',
    lang: 'en',
    data: matrix.PusherData(
      url: configuration.gatewayUrl,
      format: 'event_id_only',
      additionalProperties: {'registration_id': registrationId},
    ),
  );
  matrix.PusherId get pusherId =>
      matrix.PusherId(appId: configuration.appId, pushkey: token);
}

/// Only these routing fields survive untrusted remote data. No message content.
@immutable
class PushEnvelope {
  const PushEnvelope({
    required this.registrationId,
    required this.roomId,
    this.eventId,
  });
  static const notificationTitle = 'New message';
  static const notificationBody = 'Open Parallax to read your messages.';
  final String registrationId;
  final String roomId;
  final String? eventId;
  Map<String, dynamic> toJson() => {
    'registration_id': registrationId,
    'room_id': roomId,
    if (eventId != null) 'event_id': eventId,
  };
  static PushEnvelope? parse(Map<String, dynamic> data, String registrationId) {
    final room = data['room_id'];
    final event = data['event_id'];
    if (!RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(registrationId) ||
        data['registration_id'] != registrationId ||
        room is! String ||
        !room.startsWith('!') ||
        !room.contains(':') ||
        room.length > 1024 ||
        room.contains(RegExp(r'\s')) ||
        (event != null &&
            (event is! String ||
                !event.startsWith(r'$') ||
                event.length > 1024))) {
      return null;
    }
    return PushEnvelope(
      registrationId: registrationId,
      roomId: room,
      eventId: event as String?,
    );
  }
}

/// Durable background approval is separate from foreground session ownership.
/// Parsing is pure and fails closed; it never initializes a service or plugin.
@immutable
class PushBackgroundBinding {
  const PushBackgroundBinding._(
    this.configuration,
    this.userId,
    this.deviceId,
    this.registrationId,
  );
  final PushConfiguration configuration;
  final String userId;
  final String deviceId;
  final String registrationId;

  static PushBackgroundBinding? parse(String? raw) {
    final state = _decodeMap(raw);
    if (state == null || state['consent'] != true) return null;
    final user = state['user_id'];
    final device = state['device_id'];
    final registration = state['registration_id'];
    final config = state['configuration'];
    if (user is! String ||
        !user.startsWith('@') ||
        !user.contains(':') ||
        device is! String ||
        device.isEmpty ||
        registration is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(registration) ||
        config is! Map<String, dynamic>) {
      return null;
    }
    final configuration = PushConfiguration.fromJson(config);
    if (configuration == null || !configuration.isComplete) return null;
    return PushBackgroundBinding._(configuration, user, device, registration);
  }

  PushEnvelope? envelope(Map<String, dynamic> data) =>
      PushEnvelope.parse(data, registrationId);
}

/// Navigation is cooperatively cancelled. Recheck isCurrent after EVERY await,
/// especially after resolving/fetching a room, before UI or backend mutation.
class PushNavigationRequest {
  PushNavigationRequest._(
    this.envelope,
    this.userId,
    this.deviceId,
    this._isCurrent,
  );
  final PushEnvelope envelope;
  final String userId;
  final String deviceId;
  final bool Function() _isCurrent;
  String get roomId => envelope.roomId;
  String? get eventId => envelope.eventId;
  bool get isCurrent => _isCurrent();
}

abstract interface class PushStateStore {
  Future<String?> read();

  /// null deletes the active background binding before revoking remote push.
  Future<void> write(String? value);
}

class SecurePushStateStore implements PushStateStore {
  const SecurePushStateStore();
  static const _key = 'parallax.push.active.v1';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
  );
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String? value) => value == null
      ? _storage.delete(key: _key)
      : _storage.write(key: _key, value: value);
}

abstract interface class PushDriver {
  Future<void> initialize(PushConfiguration configuration);
  Future<PushPermission> requestPermission();
  Future<String?> getToken();
  Stream<String> get tokenChanges;
  Stream<Map<String, dynamic>> get messages;
  Stream<Map<String, dynamic>> get openedMessages;
  Future<void> showNotification(PushEnvelope envelope);

  /// Stop auto-init, delete the token and clear visible local notifications.
  Future<void> deactivate();
}

class PushCleanupException implements Exception {
  const PushCleanupException();
  @override
  String toString() =>
      'Push is locally disabled, but cleanup failed. Retry before signing out; remove this device pusher in your homeserver settings if necessary.';
}

class _OwnedRegistration {
  const _OwnedRegistration(this.session, this.registration);
  final PushSession session;
  final PushRegistration registration;
}

/// Opt-in owner. Construction/configuration/session binding never starts FCM.
/// All platform calls, registrations and navigation are serialized and joined.
class PushNotifications extends ChangeNotifier {
  PushNotifications({
    PushConfiguration? configuration,
    PushDriver? driver,
    PushStateStore? store,
  }) : _configuration = configuration ?? PushConfiguration.fromEnvironment(),
       _driver = driver ?? FirebasePushDriver(),
       _store = store ?? const SecurePushStateStore();

  PushConfiguration _configuration;
  final PushDriver _driver;
  final PushStateStore _store;
  PushSession? _session;
  PushRegistration? _activeRegistration;
  final _pendingRemovals = <_OwnedRegistration>[];
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Future<void> _tail = Future<void>.value();
  PushStatus _status = PushStatus.disabled;
  String _message =
      'Push is off. Use only your own gateway and Firebase project.';
  bool _enabled = false;
  bool _disposed = false;
  bool _driverTouched = false;
  bool _storedBinding = false;
  int _generation = 0;
  int _tokenRevision = 0;
  int _jobs = 0;
  String? _latestToken;

  PushConfiguration get configuration => _configuration;
  PushStatus get status => _status;
  String get message => _message;
  bool get enabled => _enabled;
  bool get active =>
      _enabled && _activeRegistration != null && _status == PushStatus.active;
  bool get busy => _jobs > 0;
  bool get hasSession => _session != null;

  /// Snapshot around consent UI; a changed account/config invalidates the dialog.
  int get consentRevision => _generation;
  List<String> get configurationIssues => _configuration.issues;

  void _emit(PushStatus status, String message) {
    _status = status;
    _message = message;
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation) =>
      !_disposed && _enabled && generation == _generation && _session != null;

  Future<void> _enqueue(Future<void> Function() operation) {
    _jobs++;
    final result = _tail.then((_) => operation()).whenComplete(() {
      _jobs--;
      if (!_disposed) notifyListeners();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Call once at foreground startup BEFORE binding/restoring a Matrix session.
  /// Local storage only: revokes previous-process routing, never initializes FCM.
  /// Consent is deliberately not automatically restored on foreground launches.
  Future<void> initialize() => _enqueue(() async {
    if (_driverTouched || _enabled) {
      throw StateError('Initialize push before enabling.');
    }
    await _store.write(null);
  });

  Future<void> configure(PushConfiguration configuration) {
    if (_disposed) return Future<void>.value();
    // Replace synchronously, before any caller can enable with the old config.
    _configuration = configuration;
    final stopping = disable();
    final generation = _generation;
    return stopping.then((_) {
      if (_disposed || generation != _generation || _enabled) return;
      _emit(
        configuration.isComplete
            ? PushStatus.disabled
            : PushStatus.configurationRequired,
        configuration.isComplete
            ? 'Configured but off. Review consent to enable push.'
            : configuration.issues.join('\n'),
      );
    });
  }

  /// Invalidates the old account synchronously, then joins old work and cleanup.
  /// Await before changing/clearing the captured SDK client's credentials.
  Future<void> setSession(PushSession? session) {
    if (_disposed || identical(_session, session)) return Future<void>.value();
    _session = session;
    return disable();
  }

  Future<void> enable({required bool consent}) {
    if (_disposed) return Future<void>.value();
    if (!consent) {
      return disable();
    }
    if (_enabled) return _tail;
    if (!_configuration.isComplete) {
      _emit(PushStatus.configurationRequired, _configuration.issues.join('\n'));
      return Future<void>.value();
    }
    if (_session == null) {
      _emit(
        PushStatus.signedOut,
        'Sign in to a Matrix account before enabling push.',
      );
      return Future<void>.value();
    }
    _enabled = true;
    final generation = ++_generation;
    _emit(
      PushStatus.starting,
      'Requesting notification permission and registering your device…',
    );
    return _enqueue(() async {
      if (!_current(generation)) return;
      try {
        // Failed cleanup is a hard barrier to sending a new registration.
        if (_pendingRemovals.isNotEmpty || _driverTouched || _storedBinding) {
          await _cleanup();
        }
        if (!_current(generation)) return;
        _driverTouched = true;
        await _driver.initialize(_configuration);
        if (!_current(generation)) return;
        final permission = await _driver.requestPermission();
        if (!_current(generation)) return;
        if (permission != PushPermission.authorized) {
          _enabled = false;
          await _cleanup();
          if (generation == _generation) {
            _emit(
              PushStatus.permissionDenied,
              'Notifications are blocked. Allow them in Android app settings, then enable push again.',
            );
          }
          return;
        }
        _subscribe(generation);
        final token = await _driver.getToken();
        if (!_current(generation)) return;
        final latest = _latestToken ?? token;
        if (latest == null || latest.isEmpty) throw StateError('No push token');
        await _registerToken(latest, generation, _tokenRevision);
      } catch (_) {
        if (generation != _generation || _disposed) return;
        _enabled = false;
        _activeRegistration = null;
        try {
          await _cleanup();
        } catch (_) {
          _emit(PushStatus.error, const PushCleanupException().toString());
          return;
        }
        if (generation == _generation) {
          _emit(
            PushStatus.error,
            'Push could not start. Check your Firebase Android app, gateway/project pairing, permission and homeserver connectivity. No delivery is confirmed.',
          );
        }
      }
    });
  }

  void _subscribe(int generation) {
    _subscriptions.add(
      _driver.tokenChanges.listen((token) {
        if (!_current(generation) || token == _latestToken || token.isEmpty) {
          return;
        }
        _latestToken = token;
        final revision = ++_tokenRevision;
        _activeRegistration = null;
        _emit(PushStatus.starting, 'Updating your push registration…');
        _backgroundJob(
          () => _registerToken(token, generation, revision),
          generation,
        );
      }, onError: (Object _) => _streamFailure(generation)),
    );
    _subscriptions.add(
      _driver.messages.listen((data) {
        _backgroundJob(() async {
          final envelope = _envelope(data, generation);
          if (envelope != null) await _driver.showNotification(envelope);
        }, generation);
      }, onError: (Object _) => _streamFailure(generation)),
    );
    _subscriptions.add(
      _driver.openedMessages.listen((data) {
        _backgroundJob(() async {
          final envelope = _envelope(data, generation);
          final session = _session;
          if (envelope == null || session == null) return;
          final request = PushNavigationRequest._(
            envelope,
            session.userId,
            session.deviceId,
            () =>
                _current(generation) &&
                identical(session, _session) &&
                _activeRegistration?.registrationId == envelope.registrationId,
          );
          if (request.isCurrent) await session.onNavigate(request);
        }, generation);
      }, onError: (Object _) => _streamFailure(generation)),
    );
  }

  PushEnvelope? _envelope(Map<String, dynamic> data, int generation) {
    final registration = _activeRegistration;
    if (!_current(generation) || registration == null || !active) return null;
    return PushEnvelope.parse(data, registration.registrationId);
  }

  void _backgroundJob(Future<void> Function() job, int generation) {
    unawaited(
      _enqueue(() async {
        if (!_current(generation)) return;
        try {
          await job();
        } catch (_) {
          if (!_current(generation)) return;
          _enabled = false;
          _activeRegistration = null;
          try {
            await _cleanup();
          } catch (_) {
            /* Report an explicit cleanup failure below. */
          }
          if (generation == _generation) {
            _emit(
              PushStatus.error,
              'Push stopped after a registration or notification failure. Retry cleanup, check your configuration and enable again.',
            );
          }
        }
      }),
    );
  }

  void _streamFailure(int generation) => _backgroundJob(() async {
    throw StateError('Push stream failed');
  }, generation);

  Future<void> _registerToken(
    String token,
    int generation,
    int revision,
  ) async {
    if (!_current(generation) || revision != _tokenRevision) return;
    if (utf8.encode(token).length > 512) {
      throw StateError('Push token too long');
    }
    if (_activeRegistration?.token == token) return;
    _activeRegistration = null;
    await _clearBinding();
    await _removeRegistrations();
    if (!_current(generation) || revision != _tokenRevision) return;
    final session = _session!;
    final random = Random.secure();
    final registration = PushRegistration(
      configuration: _configuration,
      userId: session.userId,
      deviceId: session.deviceId,
      token: token,
      registrationId: base64Url.encode(
        List<int>.generate(24, (_) => random.nextInt(256)),
      ),
    );
    // Record BEFORE the network await: an ambiguous/late success needs removal.
    _pendingRemovals.add(_OwnedRegistration(session, registration));
    await session.registerPusher(registration);
    if (!_current(generation) || revision != _tokenRevision) return;
    _storedBinding = true;
    await _store.write(
      jsonEncode({
        'consent': true,
        'user_id': session.userId,
        'device_id': session.deviceId,
        'registration_id': registration.registrationId,
        'configuration': _configuration.toJson(),
      }),
    );
    if (!_current(generation) || revision != _tokenRevision) return;
    _latestToken = token;
    _activeRegistration = registration;
    _emit(
      PushStatus.active,
      'Device registered. Live push delivery has not been verified.',
    );
  }

  Future<void> _clearBinding() async {
    if (!_storedBinding) return;
    await _store.write(null);
    _storedBinding = false;
  }

  Future<void> _removeRegistrations() async {
    var failed = false;
    for (final owned in List<_OwnedRegistration>.of(_pendingRemovals)) {
      try {
        await owned.session.removePusher(owned.registration);
        _pendingRemovals.remove(owned);
      } catch (_) {
        failed = true;
      }
    }
    if (failed) throw const PushCleanupException();
  }

  Future<void> _cleanup() async {
    var failed = false;
    _activeRegistration = null;
    try {
      await _clearBinding();
    } catch (_) {
      failed = true;
    }
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      try {
        await subscription.cancel();
      } catch (_) {
        failed = true;
      }
    }
    try {
      await _removeRegistrations();
    } catch (_) {
      failed = true;
    }
    if (_driverTouched) {
      try {
        await _driver.deactivate();
        _driverTouched = false;
      } catch (_) {
        failed = true;
      }
    }
    _latestToken = null;
    if (failed) throw const PushCleanupException();
  }

  /// Local cancellation is immediate; returned future joins all prior work,
  /// removes exact old pushers and deactivates the token. Throws on cleanup error.
  Future<void> disable() {
    _enabled = false;
    _activeRegistration = null;
    ++_generation;
    ++_tokenRevision;
    final generation = _generation;
    _emit(
      PushStatus.disabled,
      'Push is off. No new registration or navigation is allowed.',
    );
    return _enqueue(() async {
      try {
        await _cleanup();
      } catch (_) {
        if (!_disposed && generation == _generation) {
          _emit(PushStatus.error, const PushCleanupException().toString());
        }
        throw const PushCleanupException();
      }
    });
  }

  Future<void> logout() {
    _session = null;
    return disable();
  }

  /// Joins already queued callbacks (including token rotations) in tests/owners.
  Future<void> settle() async {
    while (true) {
      final current = _tail;
      await current;
      if (identical(current, _tail)) return;
    }
  }

  /// Prefer this async lifecycle API; dispose alone cannot await platform I/O.
  Future<void> shutdown() async {
    if (_disposed) return;
    try {
      await logout();
    } finally {
      dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _enabled = false;
    _activeRegistration = null;
    _session = null;
    ++_generation;
    unawaited(_enqueue(_cleanup).catchError((Object _) {}));
    super.dispose();
  }
}

/// Android production adapter. No plugin/native interaction in its constructor.
class FirebasePushDriver implements PushDriver {
  FirebasePushDriver();
  FirebaseMessaging? _messaging;
  FlutterLocalNotificationsPlugin? _local;
  StreamSubscription<RemoteMessage>? _receivedSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  final _messages = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final _opened = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  @override
  Stream<Map<String, dynamic>> get openedMessages => _opened.stream;
  @override
  Stream<String> get tokenChanges => _messaging!.onTokenRefresh;

  @override
  Future<void> initialize(PushConfiguration configuration) async {
    if (!configuration.isComplete) {
      throw StateError('Push configuration incomplete');
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError(
        'This push driver currently supports Android only.',
      );
    }
    final options = configuration.firebaseOptions!;
    final app = await Firebase.initializeApp(options: options);
    // Messaging only supports the default app. Never reuse an unrelated project.
    if (app.options.appId != options.appId ||
        app.options.projectId != options.projectId ||
        app.options.messagingSenderId != options.messagingSenderId ||
        app.options.apiKey != options.apiKey) {
      throw StateError(
        'Existing Firebase default app does not match push configuration',
      );
    }
    _messaging = FirebaseMessaging.instance;
    await _messaging!.setAutoInitEnabled(false);
    await _messaging!.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: false,
      sound: false,
    );
    _local = FlutterLocalNotificationsPlugin();
    await _initializeLocal(_local!, (response) {
      final data = _decodeMap(response.payload);
      if (data != null) _opened.add(data);
    });
    // Register only after explicit consent + validated config, never in main().
    FirebaseMessaging.onBackgroundMessage(matrixPushBackgroundHandler);
    _receivedSubscription = FirebaseMessaging.onMessage.listen(
      (message) {
        if (message.notification == null) _messages.add(message.data);
      },
      onError: (Object error, StackTrace stack) =>
          _messages.addError(error, stack),
    );
    _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) {
        if (message.notification == null) _opened.add(message.data);
      },
      onError: (Object error, StackTrace stack) =>
          _opened.addError(error, stack),
    );
    // Launch payloads from a previous process are intentionally discarded: they
    // cannot prove ownership of this process's authenticated registration.
  }

  @override
  Future<PushPermission> requestPermission() async {
    final settings = await _messaging!.requestPermission(
      alert: true,
      badge: false,
      sound: true,
      provisional: false,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized
        ? PushPermission.authorized
        : PushPermission.denied;
  }

  @override
  Future<String?> getToken() async {
    // Explicit getToken works with auto-init disabled. Never persist auto-init
    // true: the next process must not create tokens before its own opt-in gate.
    return _messaging!.getToken();
  }

  @override
  Future<void> showNotification(PushEnvelope envelope) =>
      _showGeneric(_local!, envelope);

  @override
  Future<void> deactivate() async {
    var failed = false;
    for (final subscription in [_receivedSubscription, _openedSubscription]) {
      try {
        await subscription?.cancel();
      } catch (_) {
        failed = true;
      }
    }
    _receivedSubscription = null;
    _openedSubscription = null;
    final messaging = _messaging;
    if (messaging != null) {
      try {
        await messaging.setAutoInitEnabled(false);
      } catch (_) {
        failed = true;
      }
      try {
        await messaging.deleteToken();
      } catch (_) {
        failed = true;
      }
    }
    try {
      await _local?.cancelAll();
    } catch (_) {
      failed = true;
    }
    if (failed) throw const PushCleanupException();
  }
}

Map<String, dynamic>? _decodeMap(String? value) {
  try {
    final json = jsonDecode(value ?? '');
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}

Future<void> _initializeLocal(
  FlutterLocalNotificationsPlugin local,
  DidReceiveNotificationResponseCallback? onResponse,
) async {
  final initialized = await local.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_parallax'),
    ),
    onDidReceiveNotificationResponse: onResponse,
  );
  if (initialized != true) throw StateError('Local notifications unavailable');
}

Future<void> _showGeneric(
  FlutterLocalNotificationsPlugin local,
  PushEnvelope envelope,
) => local.show(
  id: 1001, // One generic notification; no private per-room metadata on lockscreen.
  title: PushEnvelope.notificationTitle,
  body: PushEnvelope.notificationBody,
  notificationDetails: const NotificationDetails(
    android: AndroidNotificationDetails(
      'parallax_messages_v1',
      'Messages',
      channelDescription: 'Generic Parallax message alerts',
      importance: Importance.high,
      priority: Priority.high,
      visibility: NotificationVisibility.private,
      category: AndroidNotificationCategory.message,
      color: Color(0xFFFF5A36),
    ),
  ),
  payload: jsonEncode(envelope.toJson()),
);

/// Data-only gateway contract; no Firebase initialization or Matrix network here.
/// Fails closed if secure storage is locked, consent/config is absent, the
/// account/device binding is missing, or the registration nonce is stale.
@pragma('vm:entry-point')
Future<void> matrixPushBackgroundHandler(RemoteMessage message) async {
  if (message.notification != null) return;
  try {
    const store = SecurePushStateStore();
    final raw = await store.read();
    final binding = PushBackgroundBinding.parse(raw);
    if (binding == null) return;
    final envelope = binding.envelope(message.data);
    if (envelope == null) return;
    final local = FlutterLocalNotificationsPlugin();
    await _initializeLocal(local, null);
    if (await store.read() != raw) return;
    await _showGeneric(local, envelope);
  } catch (_) {
    // Never log payloads/account identifiers or synthesize an unbound alert.
  }
}

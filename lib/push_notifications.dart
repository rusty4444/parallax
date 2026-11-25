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

import 'features/notifications/background_push.dart';
import 'features/notifications/notification_renderer.dart'
    show darwinGenericMarkReadCategory, darwinNotificationCategories;
import 'features/platform/background_connection.dart';
import 'features/platform/unified_push.dart';

/// How push messages reach this device.
enum PushProvider {
  /// Built in (the default): Parallax keeps its own sync connection running
  /// in the background. No Firebase, gateway or distributor app.
  inApp,

  /// Google FCM via your own Firebase project and Matrix push gateway.
  firebase,

  /// A UnifiedPush distributor app (for example ntfy) and its Matrix gateway.
  unifiedPush,
}

extension PushProviderLabel on PushProvider {
  String get label => switch (this) {
    PushProvider.inApp => 'Built in',
    PushProvider.firebase => 'Firebase',
    PushProvider.unifiedPush => 'UnifiedPush',
  };
}

/// Matrix pusher app_id for UnifiedPush registrations (Element X uses one
/// app ID per provider too). Gateways relay it unchanged.
const unifiedPushAppId = 'net.samrussell.parallax.up';

/// UnifiedPush registration instance for this app (single account).
const unifiedPushInstance = 'parallax';

/// Notification action that marks the notified room as read.
const pushMarkReadActionId = 'parallax.mark_read';

/// Inline quick-reply action on rich room notifications. It never opens the
/// app: flutter_local_notifications delivers it to a background isolate,
/// which hands it to the main isolate (lib/features/notifications).
const pushReplyActionId = 'parallax.reply';

/// Copy the exact code or phone number shown by a rich notification. These
/// actions run in the notification-action isolate and never open the app.
const pushCopyCodeActionId = 'parallax.copy_code';
const pushCopyPhoneActionId = 'parallax.copy_phone';

/// ID of the quick-reply text box on Windows toasts.
const windowsReplyInputId = 'parallax_reply';

const _windowsActionKey = 'parallax_action';
const _windowsPayloadKey = 'payload';

/// `arguments` of a Windows toast button. Windows hands an activation only
/// the pressed button's arguments (or the toast's launch string for a click
/// on the toast itself), never both, so each button carries its action ID
/// and the toast's routing payload.
String windowsActionArguments(String actionId, String? payload) =>
    jsonEncode({_windowsActionKey: actionId, _windowsPayloadKey: ?payload});

/// Renders a verified envelope with sender, text and media. Implemented by
/// the notifications module while the signed-in app is mounted. [isCurrent]
/// turns false when push is disabled or re-registered meanwhile.
typedef PushRichRenderer =
    Future<void> Function(PushEnvelope envelope, bool Function() isCurrent);

/// Client identifiers only. Never put gateway service-account/private keys here.
@immutable
class PushConfiguration {
  const PushConfiguration({
    this.gatewayUrl,
    this.appId = '',
    this.firebaseOptions,
  }) : provider = PushProvider.firebase,
       distributor = null;

  /// UnifiedPush needs no client secrets. [gatewayUrl] is optional: when it
  /// is null the gateway is discovered from the distributor's endpoint, as in
  /// Element X. [distributor] is the distributor's Android package name.
  const PushConfiguration.unifiedPush({this.gatewayUrl, this.distributor})
    : provider = PushProvider.unifiedPush,
      appId = unifiedPushAppId,
      firebaseOptions = null;

  /// Built-in delivery through Parallax's own background sync connection.
  const PushConfiguration.inApp()
    : provider = PushProvider.inApp,
      gatewayUrl = null,
      appId = '',
      firebaseOptions = null,
      distributor = null;

  /// Firebase when a build supplies it, otherwise the built-in delivery.
  factory PushConfiguration.fromEnvironment() {
    const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
    const gateway = String.fromEnvironment('MATRIX_PUSH_GATEWAY');
    if (firebaseAppId.isEmpty && gateway.isEmpty) {
      return const PushConfiguration.inApp();
    }
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
  final PushProvider provider;

  /// UnifiedPush distributor package; null uses the saved or only one.
  final String? distributor;

  bool get isUnifiedPush => provider == PushProvider.unifiedPush;
  bool get isInApp => provider == PushProvider.inApp;

  /// The same UnifiedPush choice with a resolved gateway.
  PushConfiguration withGateway(Uri gateway) => isInApp
      ? this
      : isUnifiedPush
      ? PushConfiguration.unifiedPush(
          gatewayUrl: gateway,
          distributor: distributor,
        )
      : PushConfiguration(
          gatewayUrl: gateway,
          appId: appId,
          firebaseOptions: firebaseOptions,
        );

  static String? _gatewayIssue(Uri? url) {
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment) {
      return 'Set your own HTTPS Matrix push gateway URL (no credentials, query or fragment).';
    }
    if (url.path != '/_matrix/push/v1/notify' &&
        !url.path.endsWith('/_matrix/push/v1/notify')) {
      return 'Gateway URL must end in /_matrix/push/v1/notify.';
    }
    return null;
  }

  List<String> get issues {
    if (isInApp) return const [];
    if (isUnifiedPush) {
      final issues = <String>[];
      if (gatewayUrl != null) {
        final issue = _gatewayIssue(gatewayUrl);
        if (issue != null) issues.add(issue);
      }
      final value = distributor;
      if (value != null &&
          (value.length > 255 ||
              !RegExp(
                r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$',
              ).hasMatch(value))) {
        issues.add('Choose an installed UnifiedPush distributor.');
      }
      return List.unmodifiable(issues);
    }
    final issues = <String>[];
    final gatewayIssue = _gatewayIssue(gatewayUrl);
    if (gatewayIssue != null) issues.add(gatewayIssue);
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

  Map<String, dynamic> toJson() => isInApp
      ? const {'provider': 'in_app'}
      : {
          'gateway_url': gatewayUrl?.toString(),
          'app_id': appId,
          if (isUnifiedPush) 'provider': 'unifiedpush',
          if (isUnifiedPush && distributor != null) 'distributor': distributor,
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
      if (json['provider'] == 'in_app') return const PushConfiguration.inApp();
      if (json['provider'] == 'unifiedpush') {
        final gateway = json['gateway_url'];
        final distributor = json['distributor'];
        if (json['app_id'] != unifiedPushAppId ||
            (gateway != null && gateway is! String) ||
            (distributor != null && distributor is! String)) {
          return null;
        }
        return PushConfiguration.unifiedPush(
          gatewayUrl: gateway == null ? null : Uri.tryParse(gateway as String),
          distributor: distributor as String?,
        );
      }
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
    deviceDisplayName: configuration.isUnifiedPush
        ? 'Parallax Android (UnifiedPush)'
        : 'Parallax Android',
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
        // Room version 12 IDs have no server part ("!<hash>"), so only the
        // sigil is required, not ":server".
        !room.startsWith('!') ||
        room.length < 2 ||
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
    // See secure_store.dart: ad-hoc local builds cannot use the macOS
    // data-protection keychain (-34018); use the login keychain instead.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
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

/// Drivers whose gateway depends on the token (UnifiedPush endpoints).
abstract interface class PushGatewayResolver {
  /// Returns [configuration] with a complete gateway for [token]. Throws a
  /// [PushSetupException] when no Matrix gateway can be used.
  Future<PushConfiguration> resolveGateway(
    String token,
    PushConfiguration configuration,
  );
}

/// Drivers that surface notification actions besides a plain tap.
abstract interface class PushActionSource {
  /// Payloads (same shape as [PushDriver.openedMessages]) for "Mark as read".
  Stream<Map<String, dynamic>> get markReadMessages;
}

/// Drivers that let the user pick a delivery app (UnifiedPush distributors).
abstract interface class PushDistributorSource {
  /// Installed distributor package names. Empty when none or unsupported.
  Future<List<String>> distributors();
}

/// Setup failure with a user-facing explanation.
class PushSetupException implements Exception {
  const PushSetupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The delivery service withdrew this app's registration.
class PushRegistrationRevoked implements Exception {
  const PushRegistrationRevoked(this.message);
  final String message;
  @override
  String toString() => message;
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

/// A rich render waiting for (or holding) one of the render slots.
class _QueuedRender {
  _QueuedRender(this.envelope, this.driver, this.generation);
  final PushEnvelope envelope;
  final PushDriver driver;
  final int generation;

  String get roomId => envelope.roomId;

  bool sameEvent(PushEnvelope other) =>
      envelope.roomId == other.roomId &&
      envelope.eventId == other.eventId &&
      envelope.registrationId == other.registrationId;
}

/// Opt-in owner. Construction/configuration/session binding never starts FCM.
/// All platform calls, registrations and navigation are serialized and joined.
class PushNotifications extends ChangeNotifier {
  PushNotifications({
    PushConfiguration? configuration,
    PushDriver? driver,
    PushDriver? unifiedPushDriver,
    PushDriver? inAppDriver,
    PushStateStore? store,
  }) : _configuration = configuration ?? PushConfiguration.fromEnvironment(),
       _driver = driver ?? FirebasePushDriver(),
       _unifiedPushDriver = unifiedPushDriver ?? UnifiedPushDriver(),
       _inAppDriver = inAppDriver ?? InAppPushDriver(),
       _store = store ?? const SecurePushStateStore();

  PushConfiguration _configuration;
  final PushDriver _driver;
  final PushDriver _unifiedPushDriver;
  final PushDriver _inAppDriver;
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

  /// The driver that was initialised and still needs deactivation.
  PushDriver? _touched;
  bool _storedBinding = false;
  int _generation = 0;
  int _tokenRevision = 0;
  int _jobs = 0;
  String? _latestToken;

  bool get _driverTouched => _touched != null;

  /// Handles the notification "Mark as read" action for the current session.
  /// When unset, the action opens the room instead. Callers must recheck
  /// [PushNavigationRequest.isCurrent] after every await.
  Future<void> Function(PushNavigationRequest request)? markReadHandler;

  /// Rich notifications (sender, text, media) for verified pushes. When
  /// unset, or when it throws, the driver's generic notification is shown.
  PushRichRenderer? richRenderer;

  /// Rich renders running at once. Each one reads the notification store,
  /// fetches the event (database, sometimes the server) and may check names
  /// with the server, so the catch-up sync after resuming would otherwise
  /// start dozens together and starve the UI of sqflite's single worker.
  static const maxConcurrentRenders = 2;

  /// Waiting renders kept per room; the oldest are dropped. Each render adds
  /// one line to the room's notification, which keeps only its newest few
  /// (maxLinesPerRoom in the notifications feature), so older ones would be
  /// pushed out anyway. The margin covers events that add no line
  /// (undescribable or silent).
  static const maxQueuedRendersPerRoom = 12;

  /// Waiting renders kept overall. Past this the busiest room loses its
  /// oldest first, so every room keeps its newest event as long as possible;
  /// Android shows at most 50 notifications per app anyway.
  static const maxQueuedRenders = 200;

  /// Renders in flight, joined by [settle].
  final _renders = <_QueuedRender, Future<void>>{};

  /// Renders waiting for a slot, oldest first.
  final _renderQueue = <_QueuedRender>[];
  final _queuedPerRoom = <String, int>{};

  PushConfiguration get configuration => _configuration;
  PushProvider get provider => _configuration.provider;
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

  PushDriver _driverFor(PushConfiguration configuration) =>
      switch (configuration.provider) {
        PushProvider.inApp => _inAppDriver,
        PushProvider.unifiedPush => _unifiedPushDriver,
        PushProvider.firebase => _driver,
      };

  /// Installed UnifiedPush distributors (Android package names). Never
  /// registers or initialises push.
  Future<List<String>> unifiedPushDistributors() async {
    final driver = _unifiedPushDriver;
    if (driver is! PushDistributorSource) return const [];
    try {
      return await (driver as PushDistributorSource).distributors();
    } catch (_) {
      return const [];
    }
  }

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
    _clearQueuedRenders();
    final unifiedPush = _configuration.isUnifiedPush;
    final inApp = _configuration.isInApp;
    _emit(
      PushStatus.starting,
      inApp
          ? 'Turning on notifications…'
          : unifiedPush
          ? 'Requesting notification permission and registering with your UnifiedPush distributor…'
          : 'Requesting notification permission and registering your device…',
    );
    return _enqueue(() async {
      if (!_current(generation)) return;
      try {
        // Failed cleanup is a hard barrier to sending a new registration.
        if (_pendingRemovals.isNotEmpty || _driverTouched || _storedBinding) {
          await _cleanup();
        }
        if (!_current(generation)) return;
        final driver = _driverFor(_configuration);
        _touched = driver;
        await driver.initialize(_configuration);
        if (!_current(generation)) return;
        final permission = await driver.requestPermission();
        if (!_current(generation)) return;
        if (permission != PushPermission.authorized) {
          _enabled = false;
          await _cleanup();
          if (generation == _generation) {
            _emit(
              PushStatus.permissionDenied,
              inApp
                  ? 'Notifications are blocked. Allow them for Parallax in $_systemSettingsName, then turn them on again.'
                  : 'Notifications are blocked. Allow them in Android app settings, then enable push again.',
            );
          }
          return;
        }
        _subscribe(generation, driver);
        final token = await driver.getToken();
        if (!_current(generation)) return;
        final latest = _latestToken ?? token;
        if (latest == null || latest.isEmpty) throw StateError('No push token');
        await _registerToken(latest, generation, _tokenRevision, driver);
      } catch (error) {
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
            error is PushSetupException
                ? '${error.message} No delivery is confirmed.'
                : inApp
                ? 'Notifications could not start. Allow notifications for Parallax in $_systemSettingsName, then try again.'
                : unifiedPush
                ? 'UnifiedPush could not start. Check your distributor app (for example ntfy), its Matrix gateway, notification permission and homeserver connectivity. No delivery is confirmed.'
                : 'Push could not start. Check your Firebase Android app, gateway/project pairing, permission and homeserver connectivity. No delivery is confirmed.',
          );
        }
      }
    });
  }

  PushNavigationRequest _request(
    PushEnvelope envelope,
    PushSession session,
    int generation,
  ) => PushNavigationRequest._(
    envelope,
    session.userId,
    session.deviceId,
    () =>
        _current(generation) &&
        identical(session, _session) &&
        _activeRegistration?.registrationId == envelope.registrationId,
  );

  void _subscribe(int generation, PushDriver driver) {
    _subscriptions.add(
      driver.tokenChanges.listen((token) {
        if (!_current(generation) || token == _latestToken || token.isEmpty) {
          return;
        }
        _latestToken = token;
        final revision = ++_tokenRevision;
        _activeRegistration = null;
        _emit(PushStatus.starting, 'Updating your push registration…');
        _backgroundJob(
          () => _registerToken(token, generation, revision, driver),
          generation,
        );
      }, onError: (Object error) => _streamFailure(generation, error)),
    );
    _subscriptions.add(
      driver.messages.listen((data) {
        _backgroundJob(() async {
          final envelope = _envelope(data, generation);
          if (envelope != null) await _present(envelope, driver, generation);
        }, generation);
      }, onError: (Object error) => _streamFailure(generation, error)),
    );
    _subscriptions.add(
      driver.openedMessages.listen((data) {
        _backgroundJob(() async {
          final envelope = _envelope(data, generation);
          final session = _session;
          if (envelope == null || session == null) return;
          final request = _request(envelope, session, generation);
          if (request.isCurrent) await session.onNavigate(request);
        }, generation);
      }, onError: (Object error) => _streamFailure(generation, error)),
    );
    if (driver is PushActionSource) {
      _subscriptions.add(
        (driver as PushActionSource).markReadMessages.listen((data) {
          _backgroundJob(() async {
            final envelope = _envelope(data, generation);
            final session = _session;
            if (envelope == null ||
                envelope.eventId == null ||
                session == null) {
              return;
            }
            final request = _request(envelope, session, generation);
            if (!request.isCurrent) return;
            final handler = markReadHandler;
            if (handler == null) {
              await session.onNavigate(request);
              return;
            }
            try {
              await handler(request);
            } catch (_) {
              // A failed receipt must not tear down push delivery.
            }
          }, generation);
        }, onError: (Object error) => _streamFailure(generation, error)),
      );
    }
  }

  PushEnvelope? _envelope(Map<String, dynamic> data, int generation) {
    final registration = _activeRegistration;
    if (!_current(generation) || registration == null || !active) return null;
    return PushEnvelope.parse(data, registration.registrationId);
  }

  /// Shows [envelope]: rich when a renderer is attached (detached from the
  /// serial queue so a slow fetch cannot hold up registration or disable),
  /// generic otherwise or when rich rendering fails.
  ///
  /// Rich renders wait in a FIFO queue for one of [maxConcurrentRenders]
  /// slots. Every queued event is still rendered rather than merged with
  /// others of its room: each one appends a line to the room's
  /// conversation, so merging would lose messages from it.
  Future<void> _present(
    PushEnvelope envelope,
    PushDriver driver,
    int generation,
  ) async {
    if (richRenderer == null) {
      await driver.showNotification(envelope);
      return;
    }
    _queueRender(_QueuedRender(envelope, driver, generation));
  }

  void _queueRender(_QueuedRender render) {
    if (render.generation != _generation) return;
    // The same event already waiting (a hand-off and this device's sync,
    // for example) would only post the same notification again.
    if (_renderQueue.any((queued) => queued.sameEvent(render.envelope))) {
      return;
    }
    _renderQueue.add(render);
    final count = (_queuedPerRoom[render.roomId] ?? 0) + 1;
    _queuedPerRoom[render.roomId] = count;
    if (count > maxQueuedRendersPerRoom) _dropQueuedRender(render.roomId);
    if (_renderQueue.length > maxQueuedRenders) {
      String? busiest;
      var most = 1;
      _queuedPerRoom.forEach((room, queued) {
        if (queued > most) {
          busiest = room;
          most = queued;
        }
      });
      _dropQueuedRender(busiest);
    }
    _pumpRenders();
  }

  /// Drops the oldest waiting render of [roomId], or of any room.
  void _dropQueuedRender([String? roomId]) {
    final index = roomId == null
        ? 0
        : _renderQueue.indexWhere((queued) => queued.roomId == roomId);
    if (index >= 0) _unqueue(index);
  }

  _QueuedRender _unqueue(int index) {
    final render = _renderQueue.removeAt(index);
    final left = (_queuedPerRoom[render.roomId] ?? 1) - 1;
    if (left > 0) {
      _queuedPerRoom[render.roomId] = left;
    } else {
      _queuedPerRoom.remove(render.roomId);
    }
    return render;
  }

  /// Forgets waiting renders (push off, account changed, re-enabled): they
  /// belong to a generation that may no longer post anything.
  void _clearQueuedRenders() {
    _renderQueue.clear();
    _queuedPerRoom.clear();
  }

  /// Starts waiting renders while a slot is free. A room renders one event
  /// at a time, so its notification is never re-posted with an older
  /// conversation after a newer one. Renders left over from an earlier
  /// generation post nothing, so they hold no slot.
  void _pumpRenders() {
    bool live(_QueuedRender render) => render.generation == _generation;
    while (_renders.keys.where(live).length < maxConcurrentRenders) {
      final busy = {
        for (final render in _renders.keys.where(live)) render.roomId,
      };
      final index = _renderQueue.indexWhere(
        (queued) => !busy.contains(queued.roomId),
      );
      if (index < 0) return;
      _startRender(_unqueue(index));
    }
  }

  void _startRender(_QueuedRender queued) {
    final envelope = queued.envelope;
    bool current() =>
        _current(queued.generation) &&
        _activeRegistration?.registrationId == envelope.registrationId;
    _renders[queued] =
        Future<void>.microtask(() async {
          // Waited while push was turned off or re-registered.
          if (!current()) return;
          try {
            // The renderer attached now: the one present when this was queued
            // may belong to a host that has since gone.
            final renderer = richRenderer;
            if (renderer == null) throw StateError('No rich renderer');
            await renderer(envelope, current);
          } catch (_) {
            if (!current()) return;
            try {
              await queued.driver.showNotification(envelope);
            } catch (_) {
              // A failed alert must not tear down push delivery.
            }
          }
        }).whenComplete(() {
          _renders.remove(queued);
          _pumpRenders();
        });
  }

  /// A push handed over by a background isolate of this process (FCM
  /// background handler, UnifiedPush service). Validated synchronously
  /// against the live registration exactly like foreground messages; returns
  /// false (rejected) when it does not belong to it.
  bool acceptHandedOffPush(Map<String, dynamic> data) {
    final generation = _generation;
    final driver = _touched;
    final envelope = _envelope(data, generation);
    if (envelope == null || driver == null) return false;
    _backgroundJob(() async {
      if (_envelope(data, generation) == null) return;
      await _present(envelope, driver, generation);
    }, generation);
    return true;
  }

  /// An event this device's own sync received that the push rules say should
  /// notify (built-in delivery). Shown like a verified push; ignored unless
  /// the built-in delivery is active. Returns whether it was accepted.
  bool presentInApp({required String roomId, required String eventId}) {
    final generation = _generation;
    final driver = _touched;
    final registration = _activeRegistration;
    if (!_configuration.isInApp ||
        !active ||
        driver == null ||
        registration == null ||
        !_current(generation)) {
      return false;
    }
    final envelope = PushEnvelope.parse({
      'registration_id': registration.registrationId,
      'room_id': roomId,
      'event_id': eventId,
    }, registration.registrationId);
    if (envelope == null) return false;
    _backgroundJob(() async {
      if (_activeRegistration?.registrationId != envelope.registrationId) {
        return;
      }
      await _present(envelope, driver, generation);
    }, generation);
    return true;
  }

  /// Verifies a locally generated notification payload (for example a quick
  /// reply handed over from the notification-action isolate) against the
  /// live registration and session. Null when stale.
  PushNavigationRequest? verifiedRequest(Map<String, dynamic> data) {
    final generation = _generation;
    final envelope = _envelope(data, generation);
    final session = _session;
    if (envelope == null || session == null) return null;
    final request = _request(envelope, session, generation);
    return request.isCurrent ? request : null;
  }

  void _backgroundJob(
    Future<void> Function() job,
    int generation, {
    String? failureMessage,
  }) {
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
              failureMessage ??
                  'Push stopped after a registration or notification failure. Retry cleanup, check your configuration and enable again.',
            );
          }
        }
      }),
    );
  }

  void _streamFailure(int generation, [Object? error]) => _backgroundJob(
    () async {
      throw StateError('Push stream failed');
    },
    generation,
    failureMessage: switch (error) {
      PushRegistrationRevoked(:final message) => message,
      PushSetupException(:final message) => message,
      _ => null,
    },
  );

  Future<void> _registerToken(
    String token,
    int generation,
    int revision,
    PushDriver driver,
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
    var configuration = _configuration;
    if (driver is PushGatewayResolver && !configuration.isInApp) {
      // UnifiedPush: the gateway belongs to the distributor's endpoint.
      configuration = await (driver as PushGatewayResolver).resolveGateway(
        token,
        configuration,
      );
      if (!_current(generation) || revision != _tokenRevision) return;
      if (configuration.gatewayUrl == null || !configuration.isComplete) {
        throw const PushSetupException(
          'No usable Matrix push gateway was found for this endpoint.',
        );
      }
    }
    final session = _session!;
    final random = Random.secure();
    final registration = PushRegistration(
      configuration: configuration,
      userId: session.userId,
      deviceId: session.deviceId,
      token: token,
      registrationId: base64Url.encode(
        List<int>.generate(24, (_) => random.nextInt(256)),
      ),
    );
    if (!configuration.isInApp) {
      // Record BEFORE the network await: an ambiguous/late success needs removal.
      _pendingRemovals.add(_OwnedRegistration(session, registration));
      await session.registerPusher(registration);
      if (!_current(generation) || revision != _tokenRevision) return;
    }
    // Built in: no pusher. This device's own sync is the delivery, and the
    // registration ID only authenticates its local notification payloads.
    _storedBinding = true;
    await _store.write(
      jsonEncode({
        'consent': true,
        'user_id': session.userId,
        'device_id': session.deviceId,
        'registration_id': registration.registrationId,
        'configuration': configuration.toJson(),
      }),
    );
    if (!_current(generation) || revision != _tokenRevision) return;
    _latestToken = token;
    _activeRegistration = registration;
    _emit(
      PushStatus.active,
      configuration.isInApp
          ? (driver is InAppPushDriver && !driver.connected
                ? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android
                      ? 'Notifications are on, but Android did not allow the background connection, so they arrive only while Parallax is running.'
                      : 'Notifications are on. They arrive while Parallax is running; iPhone, iPad and Mac do not allow the persistent background connection Android uses.')
                : 'Notifications are on. Parallax stays connected to your homeserver in the background.')
          : configuration.isUnifiedPush
          ? 'Notifications are on through UnifiedPush via ${configuration.gatewayUrl!.host}.'
          : 'Device registered. Live push delivery has not been verified.',
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
    final touched = _touched;
    if (touched != null) {
      try {
        await touched.deactivate();
        _touched = null;
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
    // Waiting renders never start; ones in flight see isCurrent turn false.
    _clearQueuedRenders();
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
      if (_renders.isNotEmpty) {
        await Future.wait(List.of(_renders.values));
        continue;
      }
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
    _clearQueuedRenders();
    unawaited(_enqueue(_cleanup).catchError((Object _) {}));
    super.dispose();
  }
}

/// Android production adapter. No plugin/native interaction in its constructor.
class FirebasePushDriver implements PushDriver, PushActionSource {
  FirebasePushDriver();
  FirebaseMessaging? _messaging;
  FlutterLocalNotificationsPlugin? _local;
  StreamSubscription<RemoteMessage>? _receivedSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  final _messages = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final _opened = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _markRead = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  @override
  Stream<Map<String, dynamic>> get openedMessages => _opened.stream;
  @override
  Stream<Map<String, dynamic>> get markReadMessages => _markRead.stream;
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
    await initializePushLocalNotifications(
      _local!,
      onOpen: _opened.add,
      onMarkRead: _markRead.add,
    );
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
      showGenericPushNotification(_local!, envelope);

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
    if (value == null || value.length > 16 * 1024) return null;
    final json = jsonDecode(value);
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}

/// Decodes a local notification payload (routing data only).
Map<String, dynamic>? decodeNotificationPayload(String? value) =>
    _decodeMap(value);

/// Routes local notification taps. Only the locally generated payload is
/// trusted for shape; ownership is still verified against the live
/// registration before anything happens.
@visibleForTesting
void routePushNotificationResponse(
  NotificationResponse response, {
  required void Function(Map<String, dynamic>) onOpen,
  void Function(Map<String, dynamic>)? onMarkRead,
  void Function(NotificationResponse)? onAction,
}) {
  final normalised = normalisePushNotificationResponse(response);
  final actionId = normalised.actionId;
  if (actionId == pushReplyActionId ||
      actionId == pushCopyCodeActionId ||
      actionId == pushCopyPhoneActionId) {
    // Android and iOS run these in the notification-action isolate; on
    // Windows and macOS they arrive here, in the running app.
    if (onAction != null) onAction(normalised);
    return;
  }
  final data = _decodeMap(normalised.payload);
  if (data == null) return;
  if (actionId == pushMarkReadActionId) {
    if (onMarkRead != null) onMarkRead(data);
    return;
  }
  if (actionId == null || actionId.isEmpty) onOpen(data);
}

/// [response] with the Windows toast conventions undone, so every platform
/// routes the same way: a click on the toast itself has no action ID (Windows
/// reports its launch string as both payload and action), and a button's
/// wrapped arguments (see [windowsActionArguments]) become its action ID,
/// the toast's payload and, for Reply, the typed text.
@visibleForTesting
NotificationResponse normalisePushNotificationResponse(
  NotificationResponse response,
) {
  final wrapped = _decodeMap(response.actionId);
  final action = wrapped?[_windowsActionKey];
  if (action is String) {
    final payload = wrapped![_windowsPayloadKey];
    final typed = response.data[windowsReplyInputId];
    return NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      id: response.id,
      actionId: action,
      payload: payload is String ? payload : null,
      input: typed is String ? typed : response.input,
      data: response.data,
    );
  }
  final actionId = response.actionId;
  if (actionId != null && actionId.isNotEmpty && actionId == response.payload) {
    return NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotification,
      id: response.id,
      payload: response.payload,
      data: response.data,
    );
  }
  return response;
}

/// Where this platform's user allows Parallax's notifications.
String get _systemSettingsName => kIsWeb
    ? 'your browser settings'
    : switch (defaultTargetPlatform) {
        TargetPlatform.windows => 'Windows Settings',
        TargetPlatform.macOS => 'System Settings',
        TargetPlatform.iOS => 'the Settings app',
        _ => 'Android settings',
      };

/// Windows and macOS deliver every notification action to the running app
/// instead of a background isolate.
bool get _desktopNotificationActions =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

Future<void> _runDesktopNotificationAction(
  NotificationResponse response,
) async {
  try {
    await handleBackgroundNotificationAction(response);
  } catch (_) {
    // Never log payloads or message text.
  }
}

/// Initialises local notifications for generic alerts. [onOpen] receives tap
/// payloads and [onMarkRead] "Mark as read" action payloads.
Future<void> initializePushLocalNotifications(
  FlutterLocalNotificationsPlugin local, {
  void Function(Map<String, dynamic>)? onOpen,
  void Function(Map<String, dynamic>)? onMarkRead,
}) async {
  final initialized = await local.initialize(
    settings: InitializationSettings(
      android: const AndroidInitializationSettings(
        '@drawable/ic_stat_parallax',
      ),
      windows: const WindowsInitializationSettings(
        appName: 'Parallax',
        appUserModelId: 'net.samrussell.parallax',
        guid: 'b7f3c9d2-4e8a-4f1b-9c6d-2a5e8f0b3d71',
      ),
      // iOS/macOS: the system permission prompt appears here (notifications
      // are on by default, as on Android). Categories carry the same Reply /
      // Mark as read / copy actions the Android notifications use.
      iOS: DarwinInitializationSettings(
        notificationCategories: darwinNotificationCategories,
      ),
      macOS: DarwinInitializationSettings(
        notificationCategories: darwinNotificationCategories,
      ),
    ),
    onDidReceiveNotificationResponse: onOpen == null
        ? null
        : (response) => routePushNotificationResponse(
            response,
            onOpen: onOpen,
            onMarkRead: onMarkRead,
            onAction: _desktopNotificationActions
                ? (action) => unawaited(_runDesktopNotificationAction(action))
                : null,
          ),
    // Every initialisation must register this: the plugin stores the
    // callback handle used for actions that do not open the app (Reply).
    onDidReceiveBackgroundNotificationResponse:
        parallaxNotificationActionBackground,
  );
  if (initialized != true) throw StateError('Local notifications unavailable');
}

const _genericAndroidDetails = AndroidNotificationDetails(
  'parallax_messages_v1',
  'Messages',
  channelDescription: 'Generic Parallax message alerts',
  importance: Importance.high,
  priority: Priority.high,
  visibility: NotificationVisibility.private,
  category: AndroidNotificationCategory.message,
  color: Color(0xFFFF5A36),
);

/// "Mark as read" brings Parallax forward: receipts need the live, verified
/// Matrix session, which a background isolate does not have.
const _markReadAndroidDetails = AndroidNotificationDetails(
  'parallax_messages_v1',
  'Messages',
  channelDescription: 'Generic Parallax message alerts',
  importance: Importance.high,
  priority: Priority.high,
  visibility: NotificationVisibility.private,
  category: AndroidNotificationCategory.message,
  color: Color(0xFFFF5A36),
  actions: [
    AndroidNotificationAction(
      pushMarkReadActionId,
      'Mark as read',
      showsUserInterface: true,
      cancelNotification: true,
    ),
  ],
);

/// Generic content only: the room/event IDs ride in the private payload so a
/// tap or "Mark as read" can be verified, but are never displayed.
@visibleForTesting
NotificationDetails genericPushNotificationDetails(PushEnvelope envelope) =>
    NotificationDetails(
      android: envelope.eventId == null
          ? _genericAndroidDetails
          : _markReadAndroidDetails,
      windows: envelope.eventId == null
          ? const WindowsNotificationDetails()
          : WindowsNotificationDetails(
              actions: [
                WindowsAction(
                  content: 'Mark as read',
                  arguments: windowsActionArguments(
                    pushMarkReadActionId,
                    jsonEncode(envelope.toJson()),
                  ),
                ),
              ],
            ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: envelope.eventId == null
            ? null
            : darwinGenericMarkReadCategory,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: envelope.eventId == null
            ? null
            : darwinGenericMarkReadCategory,
      ),
    );

Future<void> showGenericPushNotification(
  FlutterLocalNotificationsPlugin local,
  PushEnvelope envelope,
) => local.show(
  id: 1001, // One generic notification; no private per-room metadata on lockscreen.
  title: PushEnvelope.notificationTitle,
  body: PushEnvelope.notificationBody,
  notificationDetails: genericPushNotificationDetails(envelope),
  payload: jsonEncode(envelope.toJson()),
);

/// Data-only gateway contract; no Firebase initialization here. Fails closed
/// if secure storage is locked, consent/config is absent, the account/device
/// binding is missing, or the registration nonce is stale.
///
/// A verified push is handed to the main isolate when it is running;
/// otherwise its event is fetched and decrypted on this device by a
/// short-lived read-only client (lib/features/notifications/background_push
/// .dart), falling back to the generic notification. The push itself only
/// carries room and event IDs.
@pragma('vm:entry-point')
Future<void> matrixPushBackgroundHandler(RemoteMessage message) async {
  if (message.notification != null) return;
  try {
    const store = SecurePushStateStore();
    final raw = await store.read();
    final binding = PushBackgroundBinding.parse(raw);
    if (binding == null || binding.configuration.isUnifiedPush) return;
    final envelope = binding.envelope(message.data);
    if (envelope == null) return;
    await handleBackgroundPushEnvelope(
      binding: binding,
      envelope: envelope,
      stillBound: () async => await store.read() == raw,
    );
  } catch (_) {
    // Never log payloads/account identifiers or synthesize an unbound alert.
  }
}

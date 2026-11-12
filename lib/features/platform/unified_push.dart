// UnifiedPush provider (Element X: libraries/pushproviders/unifiedpush).
//
// The user's distributor app (for example ntfy) hands us an endpoint URL. The
// Matrix pusher uses that endpoint as its pushkey and the distributor
// server's Matrix gateway (`<endpoint origin>/_matrix/push/v1/notify`,
// discovered with a GET as Element X does, or entered manually) as its URL.
// The gateway relays the homeserver's notification JSON to the endpoint and
// the distributor delivers it here. Notifications stay generic; the payload's
// pusher data must echo this registration's nonce.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:unifiedpush/unifiedpush.dart';

import '../../push_notifications.dart';

/// Largest relayed notification body accepted (the Matrix push payload is
/// small; this bounds hostile distributors).
const maxUnifiedPushMessageBytes = 64 * 1024;

/// Path of the Matrix push gateway API on a distributor server.
const matrixGatewayPath = '/_matrix/push/v1/notify';

/// Where users can find a distributor (same page Element X links to).
final unifiedPushDistributorsUrl = Uri.parse(
  'https://unifiedpush.org/users/distributors/',
);

/// Friendly names for common distributors; others show their package name.
String unifiedPushDistributorLabel(String packageName) => switch (packageName) {
  'io.heckel.ntfy' => 'ntfy',
  'org.unifiedpush.distributor.nextpush' => 'NextPush',
  'org.unifiedpush.distributor.fcm' => 'FCM distributor',
  'org.unifiedpush.distributor.sunup' => 'Sunup',
  'com.github.gotify' => 'Gotify',
  'org.unifiedpush.distributor.noprovider2push' => 'NoProvider2Push',
  _ => packageName,
};

/// The UnifiedPush connector, behind an interface for tests.
abstract interface class UnifiedPushApi {
  Future<void> initialize({
    required void Function(String endpoint, String instance) onNewEndpoint,
    required void Function(String reason, String instance) onRegistrationFailed,
    required void Function(String instance) onUnregistered,
    required void Function(Uint8List content, String instance) onMessage,
  });
  Future<List<String>> distributors();
  Future<String?> savedDistributor();
  Future<void> saveDistributor(String distributor);
  Future<void> register(String instance);
  Future<void> unregister(String instance);
}

/// Production connector (Android only).
class PluginUnifiedPushApi implements UnifiedPushApi {
  const PluginUnifiedPushApi();

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void _requireSupported() {
    if (!_supported) {
      throw const PushSetupException(
        'UnifiedPush is available on Android only.',
      );
    }
  }

  @override
  Future<void> initialize({
    required void Function(String endpoint, String instance) onNewEndpoint,
    required void Function(String reason, String instance) onRegistrationFailed,
    required void Function(String instance) onUnregistered,
    required void Function(Uint8List content, String instance) onMessage,
  }) async {
    _requireSupported();
    await UnifiedPush.initialize(
      onNewEndpoint: (endpoint, instance) =>
          onNewEndpoint(endpoint.url, instance),
      onRegistrationFailed: (reason, instance) =>
          onRegistrationFailed(reason.name, instance),
      onUnregistered: onUnregistered,
      onMessage: (message, instance) => onMessage(message.content, instance),
    );
  }

  @override
  Future<List<String>> distributors() async =>
      _supported ? await UnifiedPush.getDistributors() : const [];

  @override
  Future<String?> savedDistributor() async =>
      _supported ? await UnifiedPush.getDistributor() : null;

  @override
  Future<void> saveDistributor(String distributor) {
    _requireSupported();
    return UnifiedPush.saveDistributor(distributor);
  }

  @override
  Future<void> register(String instance) {
    _requireSupported();
    return UnifiedPush.register(instance: instance);
  }

  @override
  Future<void> unregister(String instance) {
    _requireSupported();
    return UnifiedPush.unregister(instance);
  }
}

/// Local generic alerts, behind an interface for tests.
abstract interface class PushAlertSurface {
  Future<void> initialize({
    required void Function(Map<String, dynamic>) onOpen,
    required void Function(Map<String, dynamic>) onMarkRead,
  });
  Future<bool> requestPermission();
  Future<void> show(PushEnvelope envelope);
  Future<void> cancelAll();
}

class LocalPushAlertSurface implements PushAlertSurface {
  FlutterLocalNotificationsPlugin? _local;

  FlutterLocalNotificationsPlugin get _plugin =>
      _local ??= FlutterLocalNotificationsPlugin();

  @override
  Future<void> initialize({
    required void Function(Map<String, dynamic>) onOpen,
    required void Function(Map<String, dynamic>) onMarkRead,
  }) => initializePushLocalNotifications(
    _plugin,
    onOpen: onOpen,
    onMarkRead: onMarkRead,
  );

  @override
  Future<bool> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return false;
    final granted = await android.requestNotificationsPermission();
    return granted ?? await android.areNotificationsEnabled() ?? false;
  }

  @override
  Future<void> show(PushEnvelope envelope) =>
      showGenericPushNotification(_plugin, envelope);

  @override
  Future<void> cancelAll() async => _local?.cancelAll();
}

/// Extracts routing fields from a Matrix push-gateway notification relayed
/// by a UnifiedPush Matrix gateway (`{"notification": {...}}`). Returns the
/// same map shape as the FCM data payload, or null when the body is not a
/// notification for [appId]. Never returns message content.
Map<String, dynamic>? parseUnifiedPushMessage(
  Uint8List content, {
  String appId = unifiedPushAppId,
}) {
  if (content.isEmpty || content.length > maxUnifiedPushMessageBytes) {
    return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(content));
    if (decoded is! Map) return null;
    final notification = decoded['notification'];
    if (notification is! Map) return null;
    final devices = notification['devices'];
    if (devices is! List) return null;
    String? registrationId;
    for (final device in devices.take(16)) {
      if (device is! Map || device['app_id'] != appId) continue;
      final data = device['data'];
      if (data is! Map) continue;
      final value = data['registration_id'];
      if (value is String) {
        registrationId = value;
        break;
      }
    }
    if (registrationId == null) return null;
    final roomId = notification['room_id'];
    final eventId = notification['event_id'];
    final counts = notification['counts'];
    final unread = counts is Map ? counts['unread'] : null;
    return {
      'registration_id': registrationId,
      if (roomId is String) 'room_id': roomId,
      if (eventId is String) 'event_id': eventId,
      if (unread is int) 'unread': unread,
    };
  } on FormatException {
    return null;
  }
}

/// Discovers the Matrix gateway for a distributor endpoint, as Element X
/// does: GET `<origin>/_matrix/push/v1/notify` and require
/// `{"unifiedpush": {"gateway": "matrix"}}`. HTTPS only; no redirects.
Future<Uri> discoverUnifiedPushGateway(
  String endpoint, {
  required http.Client client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final uri = Uri.tryParse(endpoint);
  if (uri == null ||
      !uri.isAbsolute ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const PushSetupException(
      'Your distributor gave a non-HTTPS endpoint. Enter an HTTPS Matrix '
      'gateway URL manually.',
    );
  }
  final gateway = Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: matrixGatewayPath,
  );
  const unavailable = PushSetupException(
    'Your distributor’s server does not offer a Matrix gateway. Enter a '
    'Matrix gateway URL (for example '
    'https://matrix.gateway.unifiedpush.org/_matrix/push/v1/notify) and '
    'try again.',
  );
  final http.StreamedResponse response;
  try {
    final request = http.Request('GET', gateway)
      ..followRedirects = false
      ..headers['accept'] = 'application/json';
    response = await client.send(request).timeout(timeout);
  } on PushSetupException {
    rethrow;
  } catch (_) {
    throw PushSetupException(
      'Couldn’t reach ${gateway.host} to check its Matrix gateway. Check your '
      'connection, or enter a gateway URL manually.',
    );
  }
  Future<Uint8List> readBounded() async {
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (body.length + chunk.length > 16 * 1024) throw unavailable;
      body.add(chunk);
    }
    return body.takeBytes();
  }

  final Uint8List bytes;
  try {
    bytes = await readBounded().timeout(timeout);
  } catch (_) {
    throw unavailable;
  }
  if (response.statusCode != 200) throw unavailable;
  try {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is Map &&
        json['unifiedpush'] is Map &&
        (json['unifiedpush'] as Map)['gateway'] == 'matrix') {
      return gateway;
    }
  } on FormatException {
    // Fall through.
  }
  throw unavailable;
}

/// Android UnifiedPush adapter. Inert until [initialize]; never touches the
/// connector in its constructor.
class UnifiedPushDriver
    implements
        PushDriver,
        PushGatewayResolver,
        PushActionSource,
        PushDistributorSource {
  UnifiedPushDriver({
    UnifiedPushApi? api,
    PushAlertSurface? alerts,
    http.Client Function()? httpClient,
    this.endpointTimeout = const Duration(seconds: 30),
  }) : _api = api ?? const PluginUnifiedPushApi(),
       _alerts = alerts ?? LocalPushAlertSurface(),
       _httpClient = httpClient ?? http.Client.new;

  final UnifiedPushApi _api;
  final PushAlertSurface _alerts;
  final http.Client Function() _httpClient;
  final Duration endpointTimeout;

  final _tokens = StreamController<String>.broadcast(sync: true);
  final _messages = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final _opened = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _markRead = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  PushConfiguration? _configuration;
  Completer<String>? _pendingEndpoint;
  String? _endpoint;
  bool _active = false;
  bool _registered = false;

  @override
  Stream<String> get tokenChanges => _tokens.stream;
  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  @override
  Stream<Map<String, dynamic>> get openedMessages => _opened.stream;
  @override
  Stream<Map<String, dynamic>> get markReadMessages => _markRead.stream;

  @override
  Future<List<String>> distributors() => _api.distributors();

  @override
  Future<void> initialize(PushConfiguration configuration) async {
    if (!configuration.isUnifiedPush || !configuration.isComplete) {
      throw StateError('UnifiedPush configuration incomplete');
    }
    _configuration = configuration;
    await _alerts.initialize(onOpen: _opened.add, onMarkRead: _markRead.add);
    await _api.initialize(
      onNewEndpoint: _onNewEndpoint,
      onRegistrationFailed: _onRegistrationFailed,
      onUnregistered: _onUnregistered,
      onMessage: _onMessage,
    );
    _active = true;
  }

  @override
  Future<PushPermission> requestPermission() async =>
      await _alerts.requestPermission()
      ? PushPermission.authorized
      : PushPermission.denied;

  @override
  Future<String?> getToken() async {
    final configuration = _configuration;
    if (!_active || configuration == null) throw StateError('Not initialised');
    final installed = await _api.distributors();
    var distributor = configuration.distributor;
    if (distributor == null || !installed.contains(distributor)) {
      if (configuration.distributor != null) {
        throw const PushSetupException(
          'The chosen UnifiedPush distributor is no longer installed. '
          'Choose another one.',
        );
      }
      final saved = await _api.savedDistributor();
      if (saved != null && installed.contains(saved)) {
        distributor = saved;
      } else if (installed.length == 1) {
        distributor = installed.single;
      } else if (installed.isEmpty) {
        throw const PushSetupException(
          'No UnifiedPush distributor is installed. Install one such as '
          'ntfy, then try again.',
        );
      } else {
        throw const PushSetupException(
          'Choose which UnifiedPush distributor to use, then enable push '
          'again.',
        );
      }
    }
    await _api.saveDistributor(distributor);
    final pending = _pendingEndpoint = Completer<String>();
    try {
      _registered = true;
      await _api.register(unifiedPushInstance);
      return await pending.future.timeout(
        endpointTimeout,
        onTimeout: () => throw const PushSetupException(
          'Your distributor did not provide a push endpoint within 30 '
          'seconds. Open it, make sure it is connected, then try again.',
        ),
      );
    } finally {
      if (identical(_pendingEndpoint, pending)) _pendingEndpoint = null;
    }
  }

  static bool _validEndpoint(String url) {
    if (url.length > 512) return false;
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.isAbsolute &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  void _onNewEndpoint(String endpoint, String instance) {
    if (instance != unifiedPushInstance || !_active) return;
    final pending = _pendingEndpoint;
    if (!_validEndpoint(endpoint)) {
      if (pending != null && !pending.isCompleted) {
        pending.completeError(
          const PushSetupException(
            'Your distributor returned an invalid endpoint.',
          ),
        );
      }
      return;
    }
    if (pending != null && !pending.isCompleted) {
      _endpoint = endpoint;
      pending.complete(endpoint);
      return;
    }
    if (endpoint != _endpoint) {
      // The distributor rotated the endpoint: re-register the pusher.
      _endpoint = endpoint;
      _tokens.add(endpoint);
    }
  }

  void _onRegistrationFailed(String reason, String instance) {
    if (instance != unifiedPushInstance || !_active) return;
    final pending = _pendingEndpoint;
    if (pending == null || pending.isCompleted) return;
    pending.completeError(
      PushSetupException(switch (reason) {
        'network' =>
          'Your distributor could not register: it has no network '
              'connection. Try again when you are online.',
        'actionRequired' =>
          'Your distributor needs attention (for example signing in). Open '
              'it, then try again.',
        'vapidRequired' =>
          'This distributor requires VAPID keys, which Matrix gateways do '
              'not use. Choose another distributor.',
        _ => 'Your distributor could not register Parallax. Try again.',
      }),
    );
  }

  void _onUnregistered(String instance) {
    if (instance != unifiedPushInstance || !_active) return;
    _messages.addError(
      const PushRegistrationRevoked(
        'Your UnifiedPush distributor removed Parallax’s registration. '
        'Enable push again to re-register.',
      ),
    );
  }

  void _onMessage(Uint8List content, String instance) {
    if (instance != unifiedPushInstance || !_active) return;
    final data = parseUnifiedPushMessage(content);
    if (data != null) _messages.add(data);
  }

  @override
  Future<PushConfiguration> resolveGateway(
    String token,
    PushConfiguration configuration,
  ) async {
    if (configuration.gatewayUrl != null) return configuration;
    final client = _httpClient();
    try {
      return configuration.withGateway(
        await discoverUnifiedPushGateway(token, client: client),
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<void> showNotification(PushEnvelope envelope) =>
      _alerts.show(envelope);

  @override
  Future<void> deactivate() async {
    _active = false;
    final pending = _pendingEndpoint;
    _pendingEndpoint = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const PushSetupException('Push was turned off.'));
    }
    var failed = false;
    if (_registered) {
      try {
        await _api.unregister(unifiedPushInstance);
        _registered = false;
      } catch (_) {
        failed = true;
      }
    }
    try {
      await _alerts.cancelAll();
    } catch (_) {
      failed = true;
    }
    _endpoint = null;
    _configuration = null;
    if (failed) throw const PushCleanupException();
  }
}

/// Shows a generic alert for a relayed UnifiedPush message when the process
/// has no foreground push owner. Fails closed like the FCM background
/// handler: the stored binding must be UnifiedPush, current and echoed.
Future<void> handleUnifiedPushBackgroundMessage(
  Uint8List content,
  String instance, {
  PushStateStore store = const SecurePushStateStore(),
  Future<void> Function(PushEnvelope envelope)? show,
}) async {
  if (instance != unifiedPushInstance) return;
  try {
    final raw = await store.read();
    final binding = PushBackgroundBinding.parse(raw);
    if (binding == null || !binding.configuration.isUnifiedPush) return;
    final data = parseUnifiedPushMessage(content);
    if (data == null) return;
    final envelope = binding.envelope(data);
    if (envelope == null) return;
    if (show != null) {
      if (await store.read() != raw) return;
      await show(envelope);
      return;
    }
    final local = FlutterLocalNotificationsPlugin();
    await initializePushLocalNotifications(local);
    if (await store.read() != raw) return;
    await showGenericPushNotification(local, envelope);
  } catch (_) {
    // Never log payloads/account identifiers or synthesise an unbound alert.
  }
}

/// The distributor withdrew the registration while no foreground owner was
/// running: stop showing alerts for it.
Future<void> handleUnifiedPushBackgroundUnregistered(
  String instance, {
  PushStateStore store = const SecurePushStateStore(),
}) async {
  if (instance != unifiedPushInstance) return;
  try {
    final binding = PushBackgroundBinding.parse(await store.read());
    if (binding != null && binding.configuration.isUnifiedPush) {
      await store.write(null);
    }
  } catch (_) {
    // Secure storage unavailable: the next foreground start revokes it.
  }
}

/// Dart entrypoint for MainActivity.kt's ParallaxUnifiedPushService. Runs in
/// a headless engine when a push arrives and Parallax has no UI engine: it
/// must not start the Matrix client or the app UI.
@pragma('vm:entry-point')
Future<void> unifiedPushBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await UnifiedPush.initialize(
    onMessage: (message, instance) => unawaited(
      handleUnifiedPushBackgroundMessage(message.content, instance),
    ),
    onUnregistered: (instance) =>
        unawaited(handleUnifiedPushBackgroundUnregistered(instance)),
    // Endpoint rotation needs the signed-in session to update the pusher;
    // the next foreground enable re-registers.
    onNewEndpoint: (_, _) {},
  );
}

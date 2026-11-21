// Built-in notification delivery (the default): Parallax keeps its own Matrix
// sync running and turns synced events that the account's push rules mark as
// notifying into notifications. No Firebase project, push gateway or
// distributor app is involved.
//
// Android side (android/app/src/main/kotlin/.../BackgroundConnection.kt): the
// Flutter engine is cached for the whole process so the Matrix client
// outlives MainActivity, and a foreground service with a low-priority ongoing
// notification keeps the process alive. The service is restarted after a
// reboot or an app update, and brings the engine back headless when Android
// restarts the process.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../push_notifications.dart';

/// Pusher-less "token" of the built-in delivery. Never sent anywhere.
const inAppPushToken = 'parallax-in-app';

/// Platform half of the background connection (fakes in tests).
abstract interface class BackgroundConnectionPlatform {
  /// Starts (or keeps) the foreground service. False when Android refused.
  Future<bool> start();

  /// Stops the service and keeps it stopped after reboots and updates.
  Future<void> stop();

  Future<bool> isIgnoringBatteryOptimizations();

  /// Shows Android's "Let Parallax always run in the background?" prompt.
  Future<bool> requestIgnoreBatteryOptimizations();
}

class MethodChannelBackgroundConnection
    implements BackgroundConnectionPlatform {
  const MethodChannelBackgroundConnection();

  static const _channel = MethodChannel('parallax/background_connection');

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _windows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  Future<bool> _bool(String method) async {
    if (_windows) {
      // Desktop: the connection runs while the app runs (tray keep-alive),
      // and there is no battery optimisation to exempt from.
      if (method != 'start') return true;
    } else if (!_android) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> start() => _bool('start');

  /// Whether the background connection service is currently running.
  Future<bool> isRunning() => _bool('isRunning');

  @override
  Future<void> stop() async {
    if (!_android && !_windows) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Not running in the Android app (tests, other platforms).
    }
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() =>
      _bool('isIgnoringBatteryOptimizations');

  @override
  Future<bool> requestIgnoreBatteryOptimizations() =>
      _bool('requestIgnoreBatteryOptimizations');
}

/// How this device receives notifications by default.
enum NotificationDelivery {
  /// UnifiedPush when a distributor app (such as ntfy) is installed,
  /// otherwise the built-in connection. Used until the user picks one.
  automatic,

  /// Always the built-in connection.
  builtIn,

  /// UnifiedPush; the built-in connection only if it cannot start.
  unifiedPush,
}

/// Device-local choices for notifications (no opt-in: on by default).
class InAppNotificationPreferences {
  const InAppNotificationPreferences._();

  static const _offKey = 'notifications.in_app_off';
  static const _batteryAskedKey = 'notifications.battery_asked';
  static const _deliveryKey = 'notifications.delivery';

  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  /// The user turned notifications off on this device. On by default.
  static Future<bool> turnedOff() async =>
      (await _prefs())?.getBool(_offKey) ?? false;

  static Future<void> setTurnedOff(bool off) async {
    final prefs = await _prefs();
    if (off) {
      await prefs?.setBool(_offKey, true);
    } else {
      await prefs?.remove(_offKey);
    }
  }

  static Future<NotificationDelivery> delivery() async {
    final saved = (await _prefs())?.getString(_deliveryKey);
    return NotificationDelivery.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => NotificationDelivery.automatic,
    );
  }

  static Future<void> setDelivery(NotificationDelivery delivery) async {
    final prefs = await _prefs();
    if (delivery == NotificationDelivery.automatic) {
      await prefs?.remove(_deliveryKey);
    } else {
      await prefs?.setString(_deliveryKey, delivery.name);
    }
  }

  static Future<bool> batteryAsked() async =>
      (await _prefs())?.getBool(_batteryAskedKey) ?? false;

  static Future<void> markBatteryAsked() async =>
      (await _prefs())?.setBool(_batteryAskedKey, true);
}

/// Starts notifications for the signed-in account with no opt-in, unless the
/// user turned them off on this device: UnifiedPush when a distributor app is
/// installed (and [unifiedPushFailed] is false) or chosen, otherwise the
/// built-in connection. Firebase (built in or set up by hand) is left alone. Returns true when UnifiedPush was tried and failed, so callers
/// can avoid retrying it on every resume.
Future<bool> startDefaultNotifications(
  PushNotifications notifications, {
  required bool Function() isCurrent,
  bool unifiedPushFailed = false,
}) async {
  if (!isCurrent() || !notifications.hasSession || notifications.busy) {
    return false;
  }
  // Firebase is only present when built in or set up by hand: leave it, and
  // its consent flow, to the user.
  if (notifications.configuration.provider == PushProvider.firebase) {
    return false;
  }
  if (await InAppNotificationPreferences.turnedOff()) return false;
  final delivery = await InAppNotificationPreferences.delivery();
  var wantUnifiedPush = false;
  // UnifiedPush distributors are an Android concept; Windows always uses
  // the built-in connection.
  if (delivery != NotificationDelivery.builtIn &&
      !unifiedPushFailed &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android) {
    final installed = await notifications.unifiedPushDistributors();
    wantUnifiedPush = installed.isNotEmpty;
  }
  if (!isCurrent()) return false;
  final current = notifications.configuration.provider;
  if (notifications.enabled &&
      current ==
          (wantUnifiedPush ? PushProvider.unifiedPush : PushProvider.inApp)) {
    return false;
  }
  var failed = false;
  if (wantUnifiedPush) {
    if (!notifications.configuration.isUnifiedPush) {
      await notifications.configure(const PushConfiguration.unifiedPush());
    }
    if (!isCurrent()) return false;
    await notifications.enable(consent: true);
    if (notifications.active || !isCurrent()) return false;
    // No usable distributor, endpoint or gateway: keep notifications working.
    failed = true;
  }
  if (!notifications.configuration.isInApp) {
    await notifications.configure(const PushConfiguration.inApp());
  }
  if (!isCurrent()) return failed;
  if (!notifications.enabled) await notifications.enable(consent: true);
  if (notifications.active &&
      isCurrent() &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android) {
    await askBatteryExemptionOnce();
  }
  return failed;
}

/// Asks once, while Parallax is on screen, to be exempt from battery
/// optimisation so Android doesn't stop the background connection.
Future<void> askBatteryExemptionOnce({
  BackgroundConnectionPlatform platform =
      const MethodChannelBackgroundConnection(),
}) async {
  try {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (await InAppNotificationPreferences.batteryAsked()) return;
    if (await platform.isIgnoringBatteryOptimizations()) return;
    await InAppNotificationPreferences.markBatteryAsked();
    await platform.requestIgnoreBatteryOptimizations();
  } catch (_) {
    // Optional; the connection still runs, Android may just stop it sooner.
  }
}

/// [PushDriver] for the built-in delivery. There is no token or pusher:
/// [PushNotifications.presentInApp] receives events from this device's own
/// sync, and this driver shows/clears local notifications and runs the
/// background connection.
class InAppPushDriver implements PushDriver, PushActionSource {
  InAppPushDriver({
    this.platform = const MethodChannelBackgroundConnection(),
    this.localNotifications,
  });

  final BackgroundConnectionPlatform platform;

  /// Created on [initialize] unless injected.
  FlutterLocalNotificationsPlugin? localNotifications;
  bool _connected = false;

  final _opened = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _markRead = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );

  /// False when Android refused to start the background connection: then
  /// notifications only arrive while Parallax is running.
  bool get connected => _connected;

  @override
  Stream<Map<String, dynamic>> get messages => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get openedMessages => _opened.stream;

  @override
  Stream<Map<String, dynamic>> get markReadMessages => _markRead.stream;

  @override
  Stream<String> get tokenChanges => const Stream.empty();

  @override
  Future<void> initialize(PushConfiguration configuration) async {
    if (!configuration.isInApp) {
      throw StateError('Not the built-in delivery');
    }
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.windows &&
            defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.macOS)) {
      throw UnsupportedError(
        'Built-in notifications support Android, Windows, iOS and macOS only.',
      );
    }
    // Android runs the foreground-service background connection; Apple
    // platforms deliver from the live sync while Parallax is running (the
    // platform guards in MethodChannelBackgroundConnection make start() a
    // no-op there, so [connected] stays false and the status says so).
    final local = localNotifications ??= FlutterLocalNotificationsPlugin();
    await initializePushLocalNotifications(
      local,
      onOpen: _opened.add,
      onMarkRead: _markRead.add,
    );
  }

  @override
  Future<PushPermission> requestPermission() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      // Windows toasts need no runtime permission.
      return PushPermission.authorized;
    }
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      final darwin = localNotifications
          ?.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final macos = localNotifications
          ?.resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      try {
        final granted = darwin != null
            ? await darwin.requestPermissions(
                alert: true,
                badge: true,
                sound: true,
              )
            : macos != null
            ? await macos.requestPermissions(
                alert: true,
                badge: true,
                sound: true,
              )
            : null;
        return granted == true
            ? PushPermission.authorized
            : PushPermission.denied;
      } catch (_) {
        return PushPermission.denied;
      }
    }
    final android = localNotifications
        ?.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return PushPermission.denied;
    try {
      if (await android.areNotificationsEnabled() == true) {
        return PushPermission.authorized;
      }
      // Needs the activity; without one (a headless restart) this fails and
      // the next time Parallax is opened asks again.
      return await android.requestNotificationsPermission() == true
          ? PushPermission.authorized
          : PushPermission.denied;
    } catch (_) {
      return PushPermission.denied;
    }
  }

  /// Starts the background connection once notifications are allowed.
  @override
  Future<String?> getToken() async {
    _connected = await platform.start();
    return inAppPushToken;
  }

  @override
  Future<void> showNotification(PushEnvelope envelope) =>
      showGenericPushNotification(localNotifications!, envelope);

  /// Best effort: there is no pusher or remote registration to remove, so a
  /// failure here must not block turning notifications off or signing out.
  @override
  Future<void> deactivate() async {
    _connected = false;
    try {
      await platform.stop();
    } catch (_) {
      // The service also stops itself once it is marked off.
    }
    try {
      await localNotifications?.cancelAll();
    } catch (_) {
      // Nothing was shown.
    }
  }
}

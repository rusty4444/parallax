import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../polls/location_model.dart';

/// Device location access, as far as live sharing is concerned.
enum LocationAccess {
  granted,
  denied,
  deniedForever,
  serviceDisabled,
  unavailable,
}

/// One position from the device.
@immutable
class PositionFix {
  const PositionFix(this.point, {required this.receivedAt});
  final GeoPoint point;

  /// When Parallax received the fix (device clock).
  final DateTime receivedAt;
}

/// A position stream failure, mapped from the platform.
class PositionStreamException implements Exception {
  const PositionStreamException(this.access);
  final LocationAccess access;

  @override
  String toString() => 'PositionStreamException($access)';
}

/// Continuous device location for live sharing; fakes implement this in
/// tests.
abstract interface class LivePositionSource {
  /// Current access without prompting.
  Future<LocationAccess> check();

  /// Requests permission if needed (prompting the user). Call only from a
  /// user action.
  Future<LocationAccess> request();

  /// Position updates. On Android this runs geolocator's foreground service
  /// with a persistent notification so updates continue in the background.
  /// Errors are [PositionStreamException]s.
  Stream<PositionFix> watch();

  Future<void> openAppSettings();
  Future<void> openLocationSettings();
}

/// Notification shown by the Android foreground service while sharing.
const liveLocationNotificationTitle = 'Parallax is sharing your live location';
const liveLocationNotificationText = 'Open Parallax to stop sharing.';
const liveLocationNotificationChannel = 'Live location sharing';

/// geolocator implementation.
///
/// Android: `AndroidSettings.foregroundNotificationConfig` makes the plugin's
/// `GeolocatorLocationService` (declared by geolocator_android with
/// `foregroundServiceType="location"`) run as a foreground service, so
/// sharing continues while Parallax is in the background. The service is
/// started from the foreground (the user tapped Share, or Parallax was
/// reopened), which Android allows with while-in-use permission; background
/// location (`ACCESS_BACKGROUND_LOCATION`) is therefore not needed. A
/// partial wake lock keeps updates flowing with the screen off; it is held
/// only while a share is active. geolocator's notification has no action
/// buttons, so stopping happens in the app (tapping the notification opens
/// Parallax, where the room banner offers Stop).
class GeolocatorLivePositionSource implements LivePositionSource {
  const GeolocatorLivePositionSource();

  static bool _granted(LocationPermission permission) =>
      permission == LocationPermission.always ||
      permission == LocationPermission.whileInUse;

  static LocationAccess _accessOf(LocationPermission permission) =>
      switch (permission) {
        LocationPermission.always ||
        LocationPermission.whileInUse => LocationAccess.granted,
        LocationPermission.deniedForever => LocationAccess.deniedForever,
        LocationPermission.denied => LocationAccess.denied,
        LocationPermission.unableToDetermine => LocationAccess.unavailable,
      };

  @override
  Future<LocationAccess> check() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return LocationAccess.serviceDisabled;
      }
      return _accessOf(await Geolocator.checkPermission());
    } catch (_) {
      return LocationAccess.unavailable;
    }
  }

  @override
  Future<LocationAccess> request() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return LocationAccess.serviceDisabled;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return _granted(permission)
          ? LocationAccess.granted
          : _accessOf(permission);
    } catch (_) {
      return LocationAccess.unavailable;
    }
  }

  static LocationSettings _settings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: liveLocationNotificationTitle,
          notificationText: liveLocationNotificationText,
          notificationChannelName: liveLocationNotificationChannel,
          notificationIcon: AndroidResource(
            name: 'ic_stat_parallax',
            defType: 'drawable',
          ),
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.high);
  }

  static Object _mapError(Object error) => switch (error) {
    PermissionDeniedException() => const PositionStreamException(
      LocationAccess.denied,
    ),
    LocationServiceDisabledException() => const PositionStreamException(
      LocationAccess.serviceDisabled,
    ),
    _ => const PositionStreamException(LocationAccess.unavailable),
  };

  @override
  Stream<PositionFix> watch() {
    final Stream<Position> source;
    try {
      source = Geolocator.getPositionStream(locationSettings: _settings());
    } catch (error) {
      return Stream.error(_mapError(error));
    }
    return source
        .handleError((Object error) => throw _mapError(error))
        .where((p) => p.latitude.isFinite && p.longitude.isFinite)
        .map(
          (p) => PositionFix(
            GeoPoint(
              p.latitude,
              p.longitude,
              uncertainty: p.accuracy.isFinite && p.accuracy > 0
                  ? p.accuracy
                  : null,
            ),
            receivedAt: DateTime.now(),
          ),
        )
        .where((fix) => fix.point.isValid);
  }

  @override
  Future<void> openAppSettings() async {
    try {
      await Geolocator.openAppSettings();
    } catch (_) {}
  }

  @override
  Future<void> openLocationSettings() async {
    try {
      await Geolocator.openLocationSettings();
    } catch (_) {}
  }
}

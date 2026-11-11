import 'package:flutter/services.dart';

/// Android runtime permissions via the app's own channel (see MainActivity).
///
/// Location uses geolocator's own permission API; this covers the rest
/// (camera and microphone for calls).
class PlatformPermissions {
  const PlatformPermissions();

  static const camera = 'android.permission.CAMERA';
  static const microphone = 'android.permission.RECORD_AUDIO';
  static const _channel = MethodChannel('parallax/permissions');

  /// Current grant state, without prompting.
  Future<Map<String, bool>> check(List<String> permissions) =>
      _invoke('check', permissions);

  /// Prompts for any missing permissions and returns the final grant state.
  Future<Map<String, bool>> request(List<String> permissions) =>
      _invoke('request', permissions);

  Future<Map<String, bool>> _invoke(
    String method,
    List<String> permissions,
  ) async {
    final result = await _channel.invokeMapMethod<String, bool>(method, {
      'permissions': permissions,
    });
    return result ?? {for (final permission in permissions) permission: false};
  }
}

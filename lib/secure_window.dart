import 'package:flutter/services.dart';

/// Prevent Android screenshots and recent-app previews while a recovery secret
/// is displayed. The native activity clears the flag when the flow exits.
class SecureWindow {
  static const _channel = MethodChannel('parallax/secure_window');

  static Future<void> setEnabled(bool enabled) =>
      _channel.invokeMethod<void>('setSecure', {'enabled': enabled});
}

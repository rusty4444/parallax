import 'package:flutter/services.dart';

/// Prevent Android screenshots and recent-app previews while a recovery secret
/// is displayed. The native activity clears the flag when the flow exits.
class SecureWindow {
  static const _channel = MethodChannel('parallax/secure_window');
  static int _holders = 0;
  static Future<void> _queue = Future<void>.value();

  /// Counted lease: every successful `true` must be paired with one `false`.
  /// The native flag is cleared only when the last holder releases it, so a
  /// recovery dialog over a reset/rotation screen cannot unprotect the screen
  /// beneath it. Calls are serialised; an unmatched `false` is a no-op.
  static Future<void> setEnabled(bool enabled) {
    final result = _queue.then((_) async {
      if (enabled) {
        if (_holders == 0) await _invoke(true);
        _holders++;
      } else if (_holders > 0) {
        _holders--;
        if (_holders == 0) await _invoke(false);
      }
    });
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static Future<void> _invoke(bool enabled) =>
      _channel.invokeMethod<void>('setSecure', {'enabled': enabled});
}

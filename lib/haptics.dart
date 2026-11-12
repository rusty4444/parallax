import 'dart:async';

import 'package:flutter/services.dart';

/// App haptics, switched by Settings → Chats → Haptic feedback.
///
/// Android maps these to the view's haptic constants, so they also follow
/// the phone's own "Touch feedback" setting. Material long presses on
/// `InkWell`/`ListTile` already vibrate; use [longPress] only for plain
/// `GestureDetector` long presses so they are not doubled.
abstract final class Haptics {
  /// Mirrors `AppearancePreferences.haptics`; set by the app root.
  static bool enabled = true;

  /// Choosing something: a filter, tab, Space, reaction or menu toggle.
  static void selection() => _play(HapticFeedback.lightImpact);

  /// A long press that opens actions (message, media, reaction details).
  static void longPress() => _play(HapticFeedback.vibrate);

  /// A committed action: sending a message, starting or stopping a recording.
  static void confirm() => _play(HapticFeedback.mediumImpact);

  static void _play(Future<void> Function() effect) {
    if (!enabled) return;
    // Haptics are best effort; a missing platform handler must not throw.
    unawaited(effect().catchError((Object _) {}));
  }
}

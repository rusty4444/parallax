import 'package:flutter/foundation.dart';

/// The one call screen that may be open at a time (Element X also allows a
/// single ongoing call). Used to suppress rings for, and duplicate launches
/// of, a call that is already on screen.
abstract final class ActiveCall {
  static final roomId = ValueNotifier<String?>(null);

  static bool get inCall => roomId.value != null;

  /// Claims the active call slot. Returns false when another call holds it.
  static bool enter(String room) {
    if (roomId.value != null && roomId.value != room) return false;
    roomId.value = room;
    return true;
  }

  static void leave(String room) {
    if (roomId.value == room) roomId.value = null;
  }
}

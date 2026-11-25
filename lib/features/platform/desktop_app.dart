// Desktop app chrome that goes with notifications: the unread badge (the
// taskbar button overlay and tray icon on Windows, the Dock icon on macOS)
// and bringing the window forward when a notification is opened.
//
// Native halves: ParallaxPlatform (windows/runner/parallax_platform.cpp) and
// ParallaxAppleChannels (apple/ParallaxApple.swift), channel
// `parallax/desktop`. Elsewhere every call is a no-op.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../chat_backend.dart';

/// True for the Windows and macOS desktop apps.
bool get isDesktopApp =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// The app badge's number: unread messages in rooms that notify for them,
/// mentions in muted rooms, one per chat marked unread and one per pending
/// invite. Spaces never count.
int unreadBadgeCount(Iterable<ChatRoom> rooms) {
  var count = 0;
  for (final room in rooms) {
    if (room.isSpace) continue;
    if (room.invited) {
      count++;
      continue;
    }
    final unread = room.muted ? room.highlightCount : room.unread;
    if (unread > 0) {
      count += unread;
    } else if (room.manuallyUnread && !room.muted) {
      count++;
    }
  }
  return count;
}

/// The `parallax/desktop` channel.
class DesktopAppChannel {
  const DesktopAppChannel();

  static const _channel = MethodChannel('parallax/desktop');

  /// Shows [count] on the taskbar button and tray icon (Windows) or the
  /// Dock icon (macOS); zero clears it.
  Future<void> setBadgeCount(int count) =>
      _invoke('setBadgeCount', {'count': count < 0 ? 0 : count});

  /// Shows, restores and focuses the main window, which may be hidden in
  /// the tray (Windows) or closed to the Dock (macOS).
  Future<void> showWindow() => _invoke('showWindow');

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (!isDesktopApp) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Not running in the desktop app (tests).
    } on PlatformException {
      // Cosmetic; never break notifications over it.
    }
  }
}

/// Keeps the desktop app badge in step with the room list while signed in,
/// and clears it on sign-out.
class AppBadgeHost extends StatefulWidget {
  const AppBadgeHost({
    super.key,
    required this.backend,
    required this.child,
    this.channel = const DesktopAppChannel(),
    this.enabled,
  });

  final ChatBackend backend;
  final Widget child;
  final DesktopAppChannel channel;

  /// Defaults to [isDesktopApp].
  final bool? enabled;

  @override
  State<AppBadgeHost> createState() => _AppBadgeHostState();
}

class _AppBadgeHostState extends State<AppBadgeHost> {
  late final bool _enabled = widget.enabled ?? isDesktopApp;
  List<ChatRoom>? _lastRooms;
  int? _sent;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    widget.backend.addListener(_changed);
    _changed();
  }

  void _changed() {
    // The backend notifies for every sync and timeline update; the room
    // list keeps its identity until a room changes.
    final rooms = widget.backend.rooms;
    if (identical(rooms, _lastRooms)) return;
    _lastRooms = rooms;
    final count = unreadBadgeCount(rooms);
    if (count == _sent) return;
    _sent = count;
    unawaited(widget.channel.setBadgeCount(count));
  }

  @override
  void dispose() {
    if (_enabled) {
      widget.backend.removeListener(_changed);
      if ((_sent ?? 0) != 0) unawaited(widget.channel.setBadgeCount(0));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

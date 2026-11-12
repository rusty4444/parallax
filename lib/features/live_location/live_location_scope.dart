import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../chat_backend.dart';
import 'live_location_features.dart';

/// Wraps the signed-in app: resumes this device's shares once per session
/// while Parallax is in the foreground (Android only lets the location
/// foreground service start from the foreground), and ends them when the
/// session signs out.
///
/// Sign-out: the session normally ends inside `ChatBackend.logout`, after
/// which writes fail. Call [liveLocationBeforeLogout] from the backend's
/// pre-logout hook so shares end on the server first; the sign-out seen here
/// is a fallback that stops local sharing and clears the local records (the
/// homeserver then ends the share at its timeout).
class LiveLocationScope extends StatefulWidget {
  const LiveLocationScope({
    super.key,
    required this.backend,
    required this.lifecycle,
    required this.child,
  });

  final ChatBackend backend;
  final LiveLocationLifecycle lifecycle;
  final Widget child;

  @override
  State<LiveLocationScope> createState() => _LiveLocationScopeState();
}

class _LiveLocationScopeState extends State<LiveLocationScope>
    with WidgetsBindingObserver {
  String? _resumedFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.backend.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _check();
    });
  }

  @override
  void didUpdateWidget(LiveLocationScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      oldWidget.backend.removeListener(_check);
      widget.backend.addListener(_check);
      _resumedFor = null;
      _check();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _check() {
    if (!mounted) return;
    final backend = widget.backend;
    final user = backend.userId;
    if (backend.connection == SessionStatus.signedOut) {
      if (_resumedFor != null) {
        _resumedFor = null;
        unawaited(_guard(widget.lifecycle.stopAllShares()));
      }
      return;
    }
    if (backend.connection != SessionStatus.ready || user == null) return;
    if (_resumedFor == user || !_foreground) return;
    _resumedFor = user;
    unawaited(_guard(widget.lifecycle.resumeShares()));
  }

  static Future<void> _guard(Future<void> work) async {
    try {
      await work;
    } catch (_) {}
  }

  @override
  void dispose() {
    widget.backend.removeListener(_check);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Ends every own live share while the session can still write. Wire into
/// the backend's pre-logout hook (`MatrixBackend(beforeLogout: …)`).
Future<void> liveLocationBeforeLogout(ChatBackend backend) async {
  try {
    await liveLocationLifecycleOf(backend)?.stopAllShares();
  } catch (_) {}
}

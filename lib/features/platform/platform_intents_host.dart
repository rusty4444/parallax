// Signed-in host for Android intents and notification actions. Mounted by
// wrapWithPlatformIntents above the signed-in Navigator: it handles one
// intent at a time on that navigator and wires "Mark as read" for push.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../../push_notifications.dart';
import 'matrix_link_opener.dart';
import 'platform_features.dart';
import 'platform_intents.dart';
import 'share_screen.dart';

class PlatformIntentsHost extends StatefulWidget {
  const PlatformIntentsHost({
    super.key,
    required this.app,
    required this.child,
    this.source,
    this.readSharedFile,
  });
  final AppHookContext app;
  final Widget child;

  /// Defaults to MainActivity's channel.
  final PlatformIntentSource? source;
  final SharedFileReader? readSharedFile;

  @override
  State<PlatformIntentsHost> createState() => _PlatformIntentsHostState();
}

class _PlatformIntentsHostState extends State<PlatformIntentsHost> {
  late final PlatformIntentSource _source =
      widget.source ?? MethodChannelPlatformIntents.instance;
  late final BackendSessionOwner _owner = BackendSessionOwner(
    widget.app.backend,
  );
  StreamSubscription<PlatformIntent>? _subscription;
  final _queue = Queue<PlatformIntent>();

  /// The share whose route is open; its route future never completes if the
  /// signed-in navigator is torn down, so dispose discards it too.
  ShareIntent? _activeShare;
  bool _draining = false;
  bool _disposed = false;
  PushNotifications? _notifications;
  Future<void> Function(PushNavigationRequest)? _markReadHandler;

  @override
  void initState() {
    super.initState();
    _subscription = _source.intents.listen(_enqueue);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifications = FeatureSettingsScope.maybeOf(context)?.notifications;
    if (!identical(notifications, _notifications)) {
      _detachPush();
      _notifications = notifications;
      if (notifications != null) {
        final handler = _markRead;
        _markReadHandler = handler;
        notifications.markReadHandler = handler;
      }
    }
  }

  void _detachPush() {
    final notifications = _notifications;
    if (notifications != null &&
        identical(notifications.markReadHandler, _markReadHandler)) {
      notifications.markReadHandler = null;
    }
    _notifications = null;
    _markReadHandler = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _detachPush();
    unawaited(_subscription?.cancel());
    final abandoned = [
      ...?_activeShare?.files,
      for (final intent in _queue)
        if (intent is ShareIntent) ...intent.files,
    ];
    _activeShare = null;
    _queue.clear();
    unawaited(_source.discard(abandoned));
    _owner.release();
    super.dispose();
  }

  bool get _current => mounted && !_disposed && _owner.isCurrent;

  void _enqueue(PlatformIntent intent) {
    if (!_current) {
      if (intent is ShareIntent) unawaited(_source.discard(intent.files));
      return;
    }
    _queue.add(intent);
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && _current) {
        final intent = _queue.removeFirst();
        try {
          await _handle(intent);
        } catch (_) {
          if (intent is ShareIntent) await _source.discard(intent.files);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<NavigatorState?> _navigator() async {
    for (var attempt = 0; attempt < 30; attempt++) {
      if (!_current) return null;
      final navigator = widget.app.navigatorKey.currentState;
      if (navigator != null && navigator.mounted) return navigator;
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
    return null;
  }

  void _snack(NavigatorState navigator, String message) {
    final context = navigator.overlay?.context ?? navigator.context;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handle(PlatformIntent intent) async {
    final navigator = await _navigator();
    if (navigator == null || !_current) {
      if (intent is ShareIntent) await _source.discard(intent.files);
      return;
    }
    final app = widget.app;
    switch (intent) {
      case LinkIntent(:final uri):
        final linkContext = navigator.overlay?.context ?? navigator.context;
        if (!linkContext.mounted) return;
        final opened = await openMatrixLink(
          linkContext,
          app.backend,
          app.palette,
          uri,
        );
        if (!opened && _current) {
          _snack(navigator, 'Parallax can’t open that link.');
        }
      case ShareIntent():
        await _share(navigator, intent);
    }
  }

  Future<void> _share(NavigatorState navigator, ShareIntent share) async {
    final app = widget.app;
    _activeShare = share;
    try {
      if (share.isEmpty) {
        _snack(
          navigator,
          share.tooLarge > 0
              ? 'Files must be 20 MB or smaller to share.'
              : 'Nothing that was shared could be read.',
        );
        return;
      }
      final read = widget.readSharedFile;
      final roomId = await navigator.push<String>(
        MaterialPageRoute<String>(
          builder: (_) => read == null
              ? ShareTargetScreen(
                  backend: app.backend,
                  palette: app.palette,
                  share: share,
                )
              : ShareTargetScreen(
                  backend: app.backend,
                  palette: app.palette,
                  share: share,
                  read: read,
                ),
        ),
      );
      if (roomId == null || !_current || !navigator.mounted) return;
      openRoomRoute(
        navigator.overlay?.context ?? navigator.context,
        app.backend,
        app.palette,
        roomId,
      );
    } finally {
      if (identical(_activeShare, share)) _activeShare = null;
      // Queued media holds its own (encrypted) copy; the cache copy goes now.
      await _source.discard(share.files);
    }
  }

  Future<void> _markRead(PushNavigationRequest request) async {
    final backend = widget.app.backend;
    final eventId = request.eventId;
    if (!_current ||
        !request.isCurrent ||
        eventId == null ||
        backend.userId != request.userId) {
      return;
    }
    final features = platformFeaturesOf(backend);
    if (features == null) return;
    final publicReceipt =
        FeatureSettingsScope.maybeOf(context)?.preferences.sendReadReceipts ??
        true;
    final navigator = widget.app.navigatorKey.currentState;
    try {
      await features.markRead(
        request.roomId,
        eventId,
        publicReceipt: publicReceipt,
      );
      if (!_current || !request.isCurrent || navigator == null) return;
      _snack(navigator, 'Marked as read.');
    } catch (_) {
      if (!_current || !request.isCurrent || navigator == null) return;
      _snack(navigator, 'Couldn’t mark that conversation as read.');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

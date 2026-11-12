// Main-isolate side of rich notifications, mounted by wrapWithNotifications
// above the signed-in navigator:
//  - renders verified pushes with the live client (PushNotifications.
//    richRenderer);
//  - receives pushes and quick replies handed over by background isolates;
//  - sends quick replies through the guarded send path;
//  - clears a room's notification when it is opened or read.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../../push_notifications.dart';
import 'notification_features.dart';
import 'notification_media.dart';
import 'notification_renderer.dart';
import 'notification_store.dart';
import 'push_handoff.dart';
import 'rich_push_handler.dart';

/// Platform dependencies of [NotificationsHost] (fakes in tests).
class NotificationHostEnvironment {
  const NotificationHostEnvironment({
    required this.store,
    required this.surface,
    required this.cacheRoot,
    this.directory = const IsolateNameServerDirectory(),
  });

  factory NotificationHostEnvironment.production() =>
      NotificationHostEnvironment(
        store: NotificationStore.open,
        surface: PluginNotificationSurface.new,
        cacheRoot: getTemporaryDirectory,
      );

  final Future<NotificationStore> Function() store;
  final NotificationSurface Function() surface;
  final Future<Directory> Function() cacheRoot;
  final PortDirectory directory;
}

class NotificationsHost extends StatefulWidget {
  const NotificationsHost({
    super.key,
    required this.app,
    required this.child,
    this.environment,
  });

  final AppHookContext app;
  final Widget child;
  final NotificationHostEnvironment? environment;

  @override
  State<NotificationsHost> createState() => _NotificationsHostState();
}

class _NotificationsHostState extends State<NotificationsHost>
    with WidgetsBindingObserver {
  late final NotificationHostEnvironment _env =
      widget.environment ?? NotificationHostEnvironment.production();
  late final ChatBackend _backend = widget.app.backend;
  NotificationFeatures? _features;
  PushNotifications? _notifications;
  PushRichRenderer? _renderer;
  PushHandoffServer? _server;
  Future<NotificationStore>? _store;
  Future<Directory?>? _cacheRoot;
  String? _userId;
  String? _deviceId;
  String? _lastActiveRoom;
  final _unread = <String, int>{};
  bool _disposed = false;
  bool _draining = false;

  @override
  void initState() {
    super.initState();
    final features = notificationFeaturesOf(_backend);
    _features = features;
    if (features == null) return;
    _userId = features.userId;
    _deviceId = features.deviceId;
    _server = PushHandoffServer(_onHandoff, directory: _env.directory)..start();
    _backend.addListener(_backendChanged);
    WidgetsBinding.instance.addObserver(this);
    _backendChanged();
    unawaited(_drainPendingReplies());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_features == null) return;
    final notifications = FeatureSettingsScope.maybeOf(context)?.notifications;
    if (identical(notifications, _notifications)) return;
    _detachRenderer();
    _notifications = notifications;
    if (notifications != null) {
      final renderer = _render;
      _renderer = renderer;
      notifications.richRenderer = renderer;
    }
  }

  void _detachRenderer() {
    final notifications = _notifications;
    if (notifications != null &&
        identical(notifications.richRenderer, _renderer)) {
      notifications.richRenderer = null;
    }
    _notifications = null;
    _renderer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _detachRenderer();
    _server?.stop();
    _server = null;
    if (_features != null) {
      _backend.removeListener(_backendChanged);
      WidgetsBinding.instance.removeObserver(this);
      final signedOut =
          _backend.connection == SessionStatus.signedOut ||
          _features?.userId != _userId;
      if (signedOut) unawaited(_forgetAccount());
    }
    super.dispose();
  }

  bool get _sessionCurrent {
    final features = _features;
    return !_disposed &&
        features != null &&
        _userId != null &&
        features.userId == _userId &&
        features.deviceId == _deviceId;
  }

  Future<NotificationStore?> _openStore() async {
    try {
      return await (_store ??= _env.store());
    } catch (_) {
      _store = null;
      return null;
    }
  }

  Future<Directory?> _openCache() => _cacheRoot ??= _env
      .cacheRoot()
      .then<Directory?>((dir) => dir)
      .catchError((Object _) => null);

  Future<RichPushHandler?> _handler({bool Function()? isCurrent}) async {
    final features = _features;
    final user = _userId;
    final device = _deviceId;
    if (features == null || user == null || device == null) return null;
    final store = await _openStore();
    final cache = await _openCache();
    if (!_sessionCurrent) return null;
    return RichPushHandler(
      store: store,
      surface: _env.surface(),
      resolve: (envelope, preferences) =>
          features.resolvePush(envelope, preferences, cacheRoot: cache),
      userId: user,
      deviceId: device,
      contentUriFor: cache == null
          ? null
          : (path) => notificationContentUri(path, cache.path),
      isCurrent: () => _sessionCurrent && (isCurrent?.call() ?? true),
      suppressRoom: _isViewing,
    );
  }

  bool _isViewing(String roomId) =>
      _backend.activeRoomId == roomId &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// PushNotifications.richRenderer. Throwing makes it show the generic
  /// alert instead.
  Future<void> _render(PushEnvelope envelope, bool Function() isCurrent) async {
    final handler = await _handler(isCurrent: isCurrent);
    if (handler == null) throw StateError('Notifications are not ready');
    await handler.handle(envelope);
  }

  /// Synchronous accept/reject for background hand-offs.
  bool _onHandoff(String kind, Map<String, Object?> payload) {
    final notifications = _notifications;
    if (!_sessionCurrent || notifications == null) return false;
    final data = Map<String, dynamic>.from(payload);
    switch (kind) {
      case handoffKindPush:
        return notifications.acceptHandedOffPush(data);
      case handoffKindReply:
        final text = payload['text'];
        if (text is! String || text.trim().isEmpty || text.length > 4000) {
          return false;
        }
        final request = notifications.verifiedRequest(data);
        if (request == null) return false;
        unawaited(_sendReply(request, text.trim()));
        return true;
      default:
        return false;
    }
  }

  Future<void> _sendReply(PushNavigationRequest request, String text) async {
    final features = _features;
    final handler = await _handler();
    if (features == null || handler == null || !request.isCurrent) return;
    final registration = request.envelope.registrationId;
    // Update at once: Android shows a spinner until the notification changes.
    await handler.showReplyResult(
      request.roomId,
      text,
      registrationId: registration,
    );
    try {
      await features.sendQuickReply(request.roomId, text);
    } catch (_) {
      if (!_sessionCurrent) return;
      await handler.showReplyResult(
        request.roomId,
        text,
        registrationId: registration,
        appendReply: false,
        statusLine: quickReplyFailedLine,
      );
    }
  }

  /// Sends quick replies typed while Parallax was not running.
  Future<void> _drainPendingReplies() async {
    if (_draining || !_sessionCurrent) return;
    _draining = true;
    try {
      final store = await _openStore();
      final features = _features;
      if (store == null || features == null || !_sessionCurrent) return;
      final replies = await store.takePendingReplies();
      if (replies.isEmpty) return;
      final handler = await _handler();
      if (handler == null) return;
      final now = DateTime.now();
      for (final reply in replies) {
        if (!_sessionCurrent) return;
        if (reply.userId != _userId || reply.deviceId != _deviceId) continue;
        if (reply.isExpired(now)) {
          await handler.showReplyResult(
            reply.roomId,
            reply.text,
            registrationId: '',
            appendReply: false,
            statusLine: quickReplyFailedLine,
          );
          continue;
        }
        try {
          await features.sendQuickReply(reply.roomId, reply.text);
          await handler.clearRooms([reply.roomId]);
        } catch (_) {
          if (!_sessionCurrent) return;
          await handler.showReplyResult(
            reply.roomId,
            reply.text,
            registrationId: '',
            appendReply: false,
            statusLine: quickReplyFailedLine,
          );
        }
      }
    } catch (_) {
      // Best effort; nothing is logged.
    } finally {
      _draining = false;
    }
  }

  void _backendChanged() {
    if (!_sessionCurrent) return;
    final toClear = <String>{};
    final active = _backend.activeRoomId;
    if (active != null &&
        active != _lastActiveRoom &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused) {
      toClear.add(active);
    }
    _lastActiveRoom = active;
    for (final room in _backend.rooms) {
      final previous = _unread[room.id];
      if (previous != null && previous > 0 && room.unread == 0) {
        toClear.add(room.id);
      }
      _unread[room.id] = room.unread;
    }
    if (toClear.isNotEmpty) unawaited(_clear(toClear));
  }

  Future<void> _clear(Set<String> roomIds) async {
    final handler = await _handler();
    if (handler == null) return;
    await handler.clearRooms(roomIds);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_sessionCurrent) return;
    final active = _backend.activeRoomId;
    if (active != null) unawaited(_clear({active}));
    unawaited(_drainPendingReplies());
  }

  /// Sign-out: forget history, pending replies and cached previews.
  Future<void> _forgetAccount() async {
    try {
      final store = await _openStore();
      await store?.clearHistory();
      final cache = await _openCache();
      if (cache != null) await clearNotificationMedia(cache);
    } catch (_) {
      // Best effort.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

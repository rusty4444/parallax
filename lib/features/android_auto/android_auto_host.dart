// Main-isolate side of the Android Auto car screen, mounted by
// wrapWithAndroidAuto inside the signed-in app. It answers the car's requests
// (chats, reply, mark as read) with the live client and tells the car when
// the chats change while its screen is showing.
//
// Privacy: locked chats never reach the car, and while the app lock would
// show on the phone the car only says that Parallax is locked.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../app_temporary_directory.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../chat_lock/chat_lock_store.dart';
import '../home/app_lock/app_lock_gate.dart';
import '../notifications/notification_model.dart' show PendingReply;
import 'android_auto_features.dart';
import 'android_auto_platform.dart';
import 'car_conversations.dart';

class AndroidAutoHost extends StatefulWidget {
  const AndroidAutoHost({
    super.key,
    required this.app,
    required this.child,
    this.platform,
    this.enabled,
    this.cacheRoot,
    this.chatLocks,
  });

  final AppHookContext app;
  final Widget child;

  /// The native car side (tests use a fake).
  final AndroidAutoPlatform? platform;

  /// Defaults to Android only.
  final bool? enabled;

  /// Where pictures are cached (defaults to the app's temporary directory).
  final Future<Directory?> Function()? cacheRoot;

  /// Locked chats (defaults to [ChatLockStore.shared]).
  final ChatLockStore? chatLocks;

  /// How long room changes are gathered before the car is told.
  static const changeDelay = Duration(seconds: 1);

  @override
  State<AndroidAutoHost> createState() => _AndroidAutoHostState();
}

/// The host currently registered with the car side. A replacement host (an
/// account switch) registers before the old one is disposed, so the old one
/// must not unregister it.
_AndroidAutoHostState? _registered;

class _AndroidAutoHostState extends State<AndroidAutoHost> {
  late final AndroidAutoPlatform _platform =
      widget.platform ?? const MethodChannelAndroidAuto();
  late final ChatLockStore _chatLocks =
      widget.chatLocks ?? ChatLockStore.shared;
  late final bool _enabled = widget.enabled ?? (!kIsWeb && Platform.isAndroid);
  ChatBackend get _backend => widget.app.backend;
  AndroidAutoFeatures? _features;
  String? _userId;
  bool _carScreenActive = false;
  bool _disposed = false;
  bool? _locked;
  List<ChatRoom>? _lastRooms;
  Timer? _changes;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    final features = androidAutoFeaturesOf(_backend);
    _features = features;
    _userId = features?.userId;
    if (features == null || _userId == null) return;
    _registered = this;
    _platform.setHandler(_handle);
    _backend.addListener(_backendChanged);
    _chatLocks.addListener(_changed);
    unawaited(_attach());
  }

  Future<void> _attach() async {
    final active = await _platform.hostAttached(true);
    if (_disposed || !identical(_registered, this)) return;
    _carScreenActive = active;
    _lastRooms = _backend.rooms;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_enabled) return;
    final lock = AppLockScope.maybeOf(context);
    final locked = lock != null && (!lock.loaded || lock.locked);
    if (_locked != null && locked != _locked) _changed();
    _locked = locked;
  }

  @override
  void dispose() {
    _disposed = true;
    _changes?.cancel();
    if (_features != null && _userId != null) {
      _backend.removeListener(_backendChanged);
      _chatLocks.removeListener(_changed);
    }
    if (identical(_registered, this)) {
      _registered = null;
      _platform.setHandler(null);
      unawaited(_platform.hostAttached(false));
    }
    super.dispose();
  }

  bool get _current =>
      !_disposed &&
      identical(_registered, this) &&
      _userId != null &&
      _features?.userId == _userId;

  void _backendChanged() {
    // The room list keeps its identity until a room changes.
    final rooms = _backend.rooms;
    if (identical(rooms, _lastRooms)) return;
    _lastRooms = rooms;
    _changed();
  }

  /// Tells a showing car screen to ask again, once changes settle.
  void _changed() {
    if (!_current || !_carScreenActive) return;
    _changes?.cancel();
    _changes = Timer(AndroidAutoHost.changeDelay, () {
      if (_current && _carScreenActive) unawaited(_platform.invalidate());
    });
  }

  Future<Object?> _handle(String method, Map<String, Object?> arguments) async {
    switch (method) {
      case 'carScreenActive':
        _carScreenActive = arguments['active'] == true;
        return null;
      case 'conversations':
        return _conversations(arguments);
      case 'markRead':
        return _markRead(arguments['roomId']);
      case 'reply':
        return _reply(arguments['roomId'], arguments['text']);
      default:
        return null;
    }
  }

  Future<Map<String, Object?>> _conversations(
    Map<String, Object?> arguments,
  ) async {
    final features = _features;
    if (!_current || features == null) {
      return carSnapshotJson(CarScreenState.signedOut);
    }
    if (_locked ?? true) return carSnapshotJson(CarScreenState.locked);
    final rooms = _backend.rooms;
    // Until the locked-chat list is read, nothing can be shown safely.
    if (!_chatLocks.loaded ||
        (rooms.isEmpty && _backend.roomSyncState == RoomSyncState.loading)) {
      return carSnapshotJson(CarScreenState.loading);
    }
    final limit = arguments['limit'];
    final messages = arguments['messages'];
    final chosen = carRoomsFor(
      rooms,
      unreadOnly: arguments['unreadOnly'] == true,
      limit: limit is int ? limit : 6,
      isLocked: _chatLocks.isLocked,
    );
    Directory? cache;
    try {
      cache = await (widget.cacheRoot ?? appTemporaryDirectory)();
    } catch (_) {
      cache = null;
    }
    final conversations = await features.conversations(
      chosen,
      messages: messages is int ? messages : maxCarMessagesPerConversation,
      cacheRoot: cache,
      onLatePictures: _changed,
    );
    if (!_current) return carSnapshotJson(CarScreenState.signedOut);
    // A chat may have been locked while its messages were read.
    return carSnapshotJson(
      CarScreenState.ready,
      selfId: _userId,
      conversations: [
        for (final conversation in conversations)
          if (!_chatLocks.isLocked(conversation.roomId)) conversation,
      ],
    );
  }

  /// Only joined chats that are not locked may be read or answered.
  bool _allowed(Object? roomId) =>
      roomId is String &&
      !(_locked ?? true) &&
      _chatLocks.loaded &&
      !_chatLocks.isLocked(roomId) &&
      _backend.rooms.any((room) => room.id == roomId && !room.invited);

  Future<bool> _markRead(Object? roomId) async {
    final features = _features;
    if (!_current || features == null || !_allowed(roomId)) return false;
    final publicReceipt =
        FeatureSettingsScope.maybeOf(context)?.preferences.sendReadReceipts ??
        true;
    try {
      await features.markRead(roomId! as String, publicReceipt: publicReceipt);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _reply(Object? roomId, Object? text) async {
    final features = _features;
    final message = text is String ? text.trim() : '';
    if (!_current ||
        features == null ||
        !_allowed(roomId) ||
        message.isEmpty ||
        message.length > PendingReply.maxLength) {
      return CarReplyResult.failed.name;
    }
    final result = await features.reply(roomId! as String, message);
    return result.name;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

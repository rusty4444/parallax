// Recent chats as Android sharing shortcuts: Android suggests them in the
// share sheet (Direct Share) and under the launcher icon, as Element X does.
//
// The list mirrors the top of the inbox. ShareShortcuts.kt publishes it to
// ShortcutManager; a share aimed at one of them comes back as
// ShareIntent.targetRoomId, and a tap under the launcher icon as
// OpenRoomIntent.
//
// Android shows these names and pictures outside Parallax's screen lock, so
// nothing is published while a PIN is set (Element X does the same), and
// everything is removed at sign-out.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../../room_pictures.dart';
import '../../widgets.dart';
import '../home/app_lock/app_lock_gate.dart';

/// Chats offered to Android. The share sheet shows four to eight; launchers
/// show the first four.
const maxShareShortcuts = 8;

/// Android truncates long labels itself; this only bounds what is sent.
const maxShareShortcutLabel = 60;

/// Largest avatar passed to Android (avatars are small thumbnails).
const maxShareShortcutIconBytes = 1024 * 1024;

/// One chat as Android should show it.
@immutable
class ShareShortcut {
  const ShareShortcut({
    required this.roomId,
    required this.label,
    required this.isDirect,
    required this.initial,
    required this.background,
    required this.foreground,
    required this.iconSource,
    this.icon,
  });

  final String roomId;
  final String label;
  final bool isDirect;

  /// Drawn on [background] in [foreground] (ARGB) when there is no [icon].
  final String initial;
  final int background;
  final int foreground;

  /// Encoded picture (JPEG, PNG, …), or null for the initial.
  final Uint8List? icon;

  /// Identifies the picture in use, so an unchanged list is not republished.
  final String iconSource;

  Map<String, Object?> toChannel() => {
    'roomId': roomId,
    'label': label,
    'isDirect': isDirect,
    'initial': initial,
    'background': background,
    'foreground': foreground,
    'icon': icon,
  };
}

/// The chats to suggest, most recent first: joined chats in inbox order,
/// without Spaces or chats marked low priority.
List<ChatRoom> shareShortcutRooms(
  Iterable<ChatRoom> rooms, {
  int limit = maxShareShortcuts,
}) {
  final chats = [
    for (final room in rooms)
      if (!room.invited && !room.isSpace && !room.lowPriority) room,
  ]..sort(compareRooms);
  final chosen = <ChatRoom>[];
  for (final room in chats) {
    if (chosen.length >= limit) break;
    if (shareShortcutLabel(room.name) != null) chosen.add(room);
  }
  return chosen;
}

/// [name] on one line without control characters, or null when it is empty.
String? shareShortcutLabel(String name) {
  final label = name
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f\u2028\u2029]+'), ' ')
      .trim();
  if (label.isEmpty) return null;
  return label.length > maxShareShortcutLabel
      ? '${label.substring(0, maxShareShortcutLabel - 1).trimRight()}…'
      : label;
}

/// Where shortcuts are published (Android in production, fakes in tests).
abstract interface class ShareShortcutSink {
  /// Replaces the published chats with [shortcuts], most recent first.
  /// False when the system did not take them.
  Future<bool> publish(List<ShareShortcut> shortcuts);

  /// Removes every published chat.
  Future<void> clear();
}

/// Production sink backed by ShareShortcuts.kt.
class MethodChannelShareShortcuts implements ShareShortcutSink {
  const MethodChannelShareShortcuts();

  static const channel = MethodChannel('parallax/share_shortcuts');

  @override
  Future<bool> publish(List<ShareShortcut> shortcuts) async {
    try {
      final published = await channel.invokeMethod<int>('publish', {
        'shortcuts': [for (final shortcut in shortcuts) shortcut.toChannel()],
      });
      return published != null && published >= 0;
    } on MissingPluginException {
      // Not on Android (tests, desktop).
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> clear() async {
    try {
      await channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      // Not on Android: nothing was published.
    } on PlatformException {
      // The next publish replaces whatever is left.
    }
  }
}

class _Plan {
  _Plan(this.room, this.label, {this.local, this.url});
  final ChatRoom room;
  final String label;

  /// A picture set on this phone.
  final Uint8List? local;

  /// The chat's own picture, or its only person's.
  final Uri? url;

  String get source {
    final local = this.local;
    if (local != null) return 'p:${local.length}:${_fnv(local)}';
    return url == null ? 'i' : 'u:$url';
  }
}

int _fnv(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Keeps Android's sharing shortcuts in step with one session's inbox.
class ShareShortcutPublisher {
  ShareShortcutPublisher({
    required this.backend,
    required this._palette,
    ShareShortcutSink? sink,
    RoomPictures? pictures,
    this.delay = const Duration(seconds: 2),
    this.avatarTimeout = const Duration(seconds: 20),
    this.retryFailedAvatarAfter = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _sink = sink ?? const MethodChannelShareShortcuts(),
       _pictures = pictures ?? RoomPictures.shared,
       _clock = clock ?? DateTime.now,
       _owner = BackendSessionOwner(backend) {
    backend.addListener(_backendChanged);
    _pictures.addListener(_schedule);
  }

  final ChatBackend backend;

  /// Changes within this time are published together.
  final Duration delay;
  final Duration avatarTimeout;

  /// A picture that would not load is not asked for again for this long, so
  /// a broken one cannot make every new message republish the list.
  final Duration retryFailedAvatarAfter;

  final ShareShortcutSink _sink;
  final RoomPictures _pictures;
  final DateTime Function() _clock;
  final BackendSessionOwner _owner;

  AppPalette _palette;

  /// Null until the screen lock's settings are known.
  bool? _hidden;
  Timer? _timer;
  final _avatarTimers = <Timer>{};
  final _failedAvatars = <Uri, DateTime>{};
  List<ChatRoom>? _seenRooms;
  RoomSyncState? _seenSync;

  /// What Android last accepted; null when unknown or cleared.
  String? _published;

  /// Whether Android may still hold shortcuts of this session.
  bool _mayHold = true;
  int _epoch = 0;
  bool _running = false;
  bool _again = false;
  bool _disposed = false;

  /// [hidden] is true while a screen-lock PIN is set, null while unknown.
  void configure({required AppPalette palette, required bool? hidden}) {
    if (_disposed) return;
    final wasHidden = _hidden;
    final changed = hidden != wasHidden || !identical(palette, _palette);
    _palette = palette;
    _hidden = hidden;
    if (hidden == true && wasHidden != true) {
      // A new PIN hides the names straight away.
      unawaited(_clear());
    } else if (changed) {
      _schedule();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    for (final timer in _avatarTimers) {
      timer.cancel();
    }
    _avatarTimers.clear();
    backend.removeListener(_backendChanged);
    _pictures.removeListener(_schedule);
    // Signed out or another account: the names go. Otherwise (the engine is
    // shutting down) they stay for the next start.
    if (!_owner.isCurrent) unawaited(_clear());
    _owner.release();
  }

  void _backendChanged() {
    if (_disposed) return;
    if (!_owner.isCurrent) {
      unawaited(_clear());
      return;
    }
    final rooms = backend.rooms;
    final sync = backend.roomSyncState;
    if (identical(rooms, _seenRooms) && sync == _seenSync) return;
    _seenRooms = rooms;
    _seenSync = sync;
    _schedule();
  }

  void _schedule() {
    if (_disposed || _timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_run());
    });
  }

  Future<void> _clear() async {
    _epoch++;
    _published = null;
    if (!_mayHold) return;
    _mayHold = false;
    await _sink.clear();
  }

  bool get _live => !_disposed && _owner.isCurrent && _hidden == false;

  Future<void> _run() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        await _publish();
      } while (_again && !_disposed);
    } catch (_) {
      // Suggestions are optional; the next change tries again.
    } finally {
      _running = false;
    }
  }

  bool _mayLoad(Uri url) {
    final failedAt = _failedAvatars[url];
    if (failedAt == null) return true;
    if (_clock().difference(failedAt) < retryFailedAvatarAfter) return false;
    _failedAvatars.remove(url);
    return true;
  }

  /// The picture [RoomAvatar] shows, when it is a single image.
  _Plan _plan(ChatRoom room, String label) {
    final local = _pictures.pictureFor(room.id);
    if (local != null && local.length <= maxShareShortcutIconBytes) {
      return _Plan(room, label, local: local);
    }
    var url = room.avatarUrl;
    if (url == null) {
      final faces = room.heroes.take(4).toList();
      if (faces.length == 1) url = faces.single.url;
    }
    return _Plan(room, label, url: url != null && _mayLoad(url) ? url : null);
  }

  String _signature(Iterable<String> entries, int background, int foreground) =>
      ['$background/$foreground', ...entries].join('\n');

  String _entry(ChatRoom room, String label, String source) =>
      '${room.id}\u0000$label\u0000${room.isDirect}\u0000$source';

  Future<Uint8List?> _avatar(Uri url) {
    final cached = backend.cachedAvatar(url);
    if (cached != null) return Future.value(cached);
    final done = Completer<Uint8List?>();
    late final Timer timer;
    void finish(Uint8List? bytes) {
      timer.cancel();
      _avatarTimers.remove(timer);
      if (!done.isCompleted) done.complete(bytes);
    }

    timer = Timer(avatarTimeout, () => finish(null));
    _avatarTimers.add(timer);
    backend.loadAvatar(url).then(finish, onError: (Object _) => finish(null));
    return done.future;
  }

  Future<void> _publish() async {
    if (!_live) return;
    final rooms = backend.rooms;
    // An empty list before the first sync means "not loaded yet".
    if (rooms.isEmpty && backend.roomSyncState != RoomSyncState.ready) return;
    final palette = _palette;
    final background = Color.alphaBlend(
      palette.accent.withValues(alpha: 0.47),
      palette.background,
    ).toARGB32();
    final foreground = palette.foreground.toARGB32();
    final plans = [
      for (final room in shareShortcutRooms(rooms))
        _plan(room, shareShortcutLabel(room.name)!),
    ];
    final planned = _signature(
      plans.map((plan) => _entry(plan.room, plan.label, plan.source)),
      background,
      foreground,
    );
    if (planned == _published) return;

    final icons = await Future.wait([
      for (final plan in plans)
        plan.local != null
            ? Future<Uint8List?>.value(plan.local)
            : plan.url == null
            ? Future<Uint8List?>.value()
            : _avatar(plan.url!),
    ]);
    if (!_live) return;
    final shortcuts = <ShareShortcut>[];
    for (var i = 0; i < plans.length; i++) {
      final plan = plans[i];
      var icon = icons[i];
      if (icon != null &&
          (icon.isEmpty || icon.length > maxShareShortcutIconBytes)) {
        icon = null;
      }
      final url = plan.url;
      if (icon == null && url != null) _failedAvatars[url] = _clock();
      shortcuts.add(
        ShareShortcut(
          roomId: plan.room.id,
          label: plan.label,
          isDirect: plan.room.isDirect,
          initial: avatarInitial(plan.label),
          background: background,
          foreground: foreground,
          icon: icon,
          iconSource: icon == null ? 'i' : plan.source,
        ),
      );
    }
    final epoch = _epoch;
    _mayHold = true;
    final accepted = await _sink.publish(shortcuts);
    // A clear sent meanwhile (sign-out, new PIN) follows this publish on the
    // channel, so Android ends up empty; just don't record the list.
    if (epoch != _epoch || !accepted) return;
    _published = _signature(
      [
        for (var i = 0; i < plans.length; i++)
          _entry(plans[i].room, plans[i].label, shortcuts[i].iconSource),
      ],
      background,
      foreground,
    );
  }
}

/// Publishes the signed-in session's recent chats while mounted. Mounted by
/// wrapWithPlatformIntents, keyed by account.
class ShareShortcutsHost extends StatefulWidget {
  const ShareShortcutsHost({
    super.key,
    required this.app,
    required this.child,
    this.sink,
    this.pictures,
    this.delay = const Duration(seconds: 2),
  });

  final AppHookContext app;
  final Widget child;

  /// Defaults to Android's ShortcutManager.
  final ShareShortcutSink? sink;

  /// Pictures set on this phone; defaults to [RoomPictures.shared].
  final RoomPictures? pictures;
  final Duration delay;

  @override
  State<ShareShortcutsHost> createState() => _ShareShortcutsHostState();
}

class _ShareShortcutsHostState extends State<ShareShortcutsHost> {
  late final ShareShortcutPublisher _publisher = ShareShortcutPublisher(
    backend: widget.app.backend,
    palette: widget.app.palette,
    sink: widget.sink,
    pictures: widget.pictures,
    delay: widget.delay,
  );

  void _configure() {
    // No screen lock in this tree (tests): nothing to hide behind.
    final lock = AppLockScope.maybeOf(context);
    _publisher.configure(
      palette: widget.app.palette,
      hidden: lock == null
          ? false
          : lock.loaded
          ? lock.pinSet
          : null,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configure();
  }

  @override
  void didUpdateWidget(ShareShortcutsHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configure();
  }

  @override
  void dispose() {
    _publisher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

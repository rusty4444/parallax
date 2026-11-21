import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';

/// A short status line / note shown over your avatar (Instagram Notes,
/// WhatsApp About, Slack status). Synced across your devices through account
/// data and, best-effort, to other clients through presence `status_msg`.
@immutable
class UserStatus {
  const UserStatus({this.text = '', this.emoji = '', this.expiresAt});

  static const eventType = 'net.samrusselltech.parallax.user_status';

  final String text;
  final String emoji;
  final DateTime? expiresAt;

  bool get isEmpty => text.trim().isEmpty && emoji.trim().isEmpty;

  bool isActive(DateTime now) =>
      !isEmpty && (expiresAt == null || now.isBefore(expiresAt!));

  /// "🌴 On holiday" style label.
  String get label {
    final t = text.trim();
    final e = emoji.trim();
    if (e.isEmpty) return t;
    if (t.isEmpty) return e;
    return '$e $t';
  }

  Map<String, Object?> toJson() => {
    'text': text,
    'emoji': emoji,
    if (expiresAt != null) 'expires_at': expiresAt!.millisecondsSinceEpoch,
  };

  factory UserStatus.fromJson(Object? json) {
    if (json is! Map) return const UserStatus();
    final text = json['text'];
    final emoji = json['emoji'];
    final expires = json['expires_at'];
    return UserStatus(
      text: text is String ? text : '',
      emoji: emoji is String ? emoji : '',
      expiresAt: expires is int
          ? DateTime.fromMillisecondsSinceEpoch(expires)
          : null,
    );
  }

  static const none = UserStatus();
}

/// Preset expiry choices for a status.
const statusExpiries = <(String, Duration?)>[
  ('Don’t clear', null),
  ('1 hour', Duration(hours: 1)),
  ('4 hours', Duration(hours: 4)),
  ('Today', Duration(hours: 24)),
];

const statusEmojis = [
  '🙂',
  '😎',
  '🌴',
  '💼',
  '🎧',
  '🍽️',
  '😴',
  '🏠',
  '✈️',
  '❤️',
];

class UserStatusController extends ChangeNotifier {
  UserStatusController();

  static final shared = UserStatusController();

  ChatBackend? _backend;
  UserStatus _status = UserStatus.none;
  bool _loaded = false;

  UserStatus get status => _status;
  bool get loaded => _loaded;
  ChatBackend? get backend => _backend;

  matrix.Client? get _client {
    final backend = _backend;
    return backend is MatrixSdkAccess
        ? (backend as MatrixSdkAccess).sdkClient
        : null;
  }

  void bindBackend(ChatBackend? backend) {
    if (identical(_backend, backend)) return;
    _backend = backend;
    _status = UserStatus.none;
    _loaded = false;
    notifyListeners();
    unawaited(load());
  }

  /// Reads the synced status from account data.
  Future<void> load() async {
    final client = _client;
    if (client == null) {
      _loaded = true;
      notifyListeners();
      return;
    }
    try {
      final content = client.accountData[UserStatus.eventType]?.content;
      _status = UserStatus.fromJson(content);
    } catch (_) {
      _status = UserStatus.none;
    }
    _loaded = true;
    notifyListeners();
  }

  bool _current(matrix.Client client) {
    final backend = _backend;
    return backend is MatrixSdkAccess &&
        (backend as MatrixSdkAccess).isSessionCurrent(client);
  }

  /// Sets (or clears, when empty) the status, syncing it to the account and
  /// best-effort to presence.
  Future<void> setStatus(String text, String emoji, Duration? expiry) async {
    final client = _client;
    final status = UserStatus(
      text: text.trim(),
      emoji: emoji.trim(),
      expiresAt: expiry == null ? null : DateTime.now().add(expiry),
    );
    _status = status;
    notifyListeners();
    if (client == null || client.userID == null) return;
    final userId = client.userID!;
    try {
      await client.request(
        matrix.RequestType.PUT,
        '/client/v3/user/${Uri.encodeComponent(userId)}'
        '/account_data/${UserStatus.eventType}',
        data: status.toJson(),
      );
    } catch (_) {
      // Account-data sync failed; the local status still shows here.
    }
    if (!_current(client)) return;
    // Best-effort presence so other clients can see the note too.
    try {
      await client.setPresence(
        userId,
        matrix.PresenceType.online,
        statusMsg: status.isEmpty ? null : status.label,
      );
    } catch (_) {
      // Presence may be disabled on the homeserver.
    }
  }

  Future<void> clear() => setStatus('', '', null);

  /// Best-effort read of another user's presence status message.
  Future<String?> contactStatus(String userId) async {
    final client = _client;
    if (client == null) return null;
    try {
      final presence = await client.fetchCurrentPresence(userId);
      if (!_current(client)) return null;
      final msg = presence.statusMsg;
      return msg == null || msg.trim().isEmpty ? null : msg.trim();
    } catch (_) {
      return null;
    }
  }
}

class UserStatusScope extends InheritedNotifier<UserStatusController> {
  const UserStatusScope({
    super.key,
    required UserStatusController controller,
    required super.child,
  }) : super(notifier: controller);

  UserStatusController get controller => notifier!;

  static UserStatusController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UserStatusScope>()?.controller;
}

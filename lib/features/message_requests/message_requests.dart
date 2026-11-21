import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';
import '../rooms_admin/rooms_admin_features.dart';

/// Message requests (Instagram/Signal style): invitations from people you
/// share no joined room with are reviewed in a separate, safe inbox instead
/// of the main chat list. Avatars stay hidden until revealed.
class MessageRequestsController extends ChangeNotifier {
  MessageRequestsController({SharedPreferences? preferences})
    : _prefs = preferences;

  static final shared = MessageRequestsController();

  static const _separateKey = 'parallax.message_requests.v1.separate';

  SharedPreferences? _prefs;
  ChatBackend? _backend;
  bool _separate = true;
  bool _loaded = false;

  bool get separate => _separate;
  bool get loaded => _loaded;
  ChatBackend? get backend => _backend;

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    try {
      _separate = (await _preferences()).getBool(_separateKey) ?? true;
    } catch (_) {
      _separate = true;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setSeparate(bool value) async {
    _separate = value;
    notifyListeners();
    try {
      await (await _preferences()).setBool(_separateKey, value);
    } catch (_) {
      // Best-effort persistence.
    }
  }

  void bindBackend(ChatBackend? backend) {
    if (identical(_backend, backend)) return;
    _backend = backend;
    notifyListeners();
  }

  String? inviterOf(String roomId) {
    final backend = _backend;
    if (backend == null) return null;
    return roomsAdminFeaturesOf(backend)?.inviterOf(roomId);
  }

  /// An invite is a request when its inviter shares no joined room with you
  /// (checked against cached membership). Unknown inviters stay in the main
  /// list; an unverifiable inviter is treated as a request (the safe choice).
  bool isRequest(ChatRoom room) {
    if (!room.invited) return false;
    final backend = _backend;
    if (backend == null) return false;
    final inviter = inviterOf(room.id);
    if (inviter == null || inviter == backend.userId) return false;
    final sdk = backend is MatrixSdkAccess
        ? (backend as MatrixSdkAccess).sdkClient
        : null;
    if (sdk == null) return true;
    for (final joined in sdk.rooms) {
      if (joined.membership != matrix.Membership.join) continue;
      if (joined.getState(matrix.EventTypes.RoomMember, inviter) != null) {
        return false;
      }
    }
    return true;
  }

  Set<String> requestIds(List<ChatRoom> rooms) => {
    for (final room in rooms)
      if (isRequest(room)) room.id,
  };

  List<ChatRoom> requests(List<ChatRoom> rooms) => [
    for (final room in rooms)
      if (isRequest(room)) room,
  ];
}

/// Provides the message-requests controller to the signed-in UI.
class MessageRequestsScope
    extends InheritedNotifier<MessageRequestsController> {
  const MessageRequestsScope({
    super.key,
    required MessageRequestsController controller,
    required super.child,
  }) : super(notifier: controller);

  MessageRequestsController get controller => notifier!;

  static MessageRequestsController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MessageRequestsScope>()
      ?.controller;
}

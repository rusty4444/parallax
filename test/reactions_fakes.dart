import 'dart:typed_data';

import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/reactions/message_action_features.dart';

const fakeRoomId = '!room:matrix.example';

/// A backend without message-action support.
class PlainBackend extends ChatBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory [MessageActionFeatures] for widget and visual tests.
class FakeReactionsBackend extends ChatBackend
    implements MessageActionFeatures {
  MessageActionPermissions perms = const MessageActionPermissions(
    canReact: true,
    canPin: true,
    canRedactOthers: true,
    canSendMessages: true,
  );
  List<ChatRoom> roomList = const [];
  List<String> pins = const [];
  List<ChatEntry> active = const [];
  List<ReactionSender> senders = const [];
  bool failSenders = false;
  bool failReport = false;
  Set<String> failRooms = {};
  Future<ChatEntry?> Function(String id)? loader;
  final forwarded =
      <({String roomId, String type, Map<String, Object?> content})>[];
  final pinCalls = <(String, bool)>[];
  final reports = <(String, String)>[];
  final ignored = <String>[];
  final removals = <(String, String?)>[];

  void notify() => notifyListeners();

  @override
  String? get userId => '@sam:matrix.example';
  @override
  SessionStatus get connection => SessionStatus.ready;
  @override
  List<ChatRoom> get rooms => roomList;
  @override
  String? get activeRoomId => fakeRoomId;
  @override
  List<ChatEntry> get messages => active;
  @override
  Future<Uint8List?> loadAvatar(Uri url) async => null;

  @override
  MessageActionPermissions permissions(String roomId) => perms;

  @override
  List<String> pinnedEventIds(String roomId) => pins;

  @override
  Future<void> setPinned(
    String roomId,
    String eventId, {
    required bool pinned,
  }) async {
    pinCalls.add((eventId, pinned));
    pins = pinned
        ? [...pins, eventId]
        : pins.where((id) => id != eventId).toList();
    notifyListeners();
  }

  @override
  Future<ChatEntry?> loadEvent(String roomId, String eventId) =>
      loader?.call(eventId) ?? Future.value(null);

  @override
  Future<List<ReactionSender>> reactionSenders(
    String roomId,
    String eventId,
  ) async {
    if (failSenders) throw StateError('offline');
    return senders;
  }

  @override
  Future<String> forwardEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    if (failRooms.contains(roomId)) throw StateError('nope');
    forwarded.add((roomId: roomId, type: type, content: content));
    return r'$new';
  }

  @override
  Future<void> reportContent(
    String roomId,
    String eventId, {
    required String reason,
  }) async {
    if (failReport) throw StateError('nope');
    reports.add((eventId, reason));
  }

  @override
  Future<void> ignoreUser(String userId) async => ignored.add(userId);

  @override
  Future<void> removeEvent(
    String roomId,
    String eventId, {
    String? reason,
  }) async => removals.add((eventId, reason));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

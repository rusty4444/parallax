// Shared fakes for the platform module tests (not a test file itself).
import 'dart:async';

import 'package:image_picker/image_picker.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/platform/platform_features.dart';
import 'package:parallax/features/platform/platform_intents.dart';
import 'package:parallax/messaging_features.dart';

import 'widget_test.dart' show FakeBackend;

ChatRoom room(
  String id,
  String name, {
  int minutesAgo = 0,
  bool invited = false,
  bool direct = false,
}) => ChatRoom(
  id: id,
  name: name,
  preview: '',
  lastActivity: DateTime(
    2026,
    11,
    12,
    12,
  ).subtract(Duration(minutes: minutesAgo)),
  invited: invited,
  isDirect: direct,
);

/// A signed-in backend with the platform and messaging feature surfaces.
class PlatformBackend extends FakeBackend
    implements PlatformFeatures, MessagingFeatures {
  PlatformBackend() {
    currentUserId = '@me:example.org';
  }

  String account = 'account-a';
  final joinedIds = <String>{};
  final invitedIds = <String>{};
  final aliases = <String, String>{};
  final joins = <(String, List<String>)>[];
  final queuedMedia = <(String, MediaSelection, String?)>[];
  final queuedText = <(String, String)>[];
  final attachments = <(String, XFile)>[];
  final directChats = <String>[];
  final accepted = <String>[];
  final markedRead = <(String, String, bool)>[];
  RoomLinkPreview? preview;
  Object? joinError;
  Completer<void>? joinGate;
  int failMediaAfter = -1;

  void replaceAccount(String value) {
    account = value;
    notifyListeners();
  }

  @override
  String get accountKey => account;

  @override
  Future<ResolvedRoom> resolveRoom(
    String roomIdOrAlias, {
    List<String> via = const [],
  }) async {
    if (!roomIdOrAlias.startsWith('#')) {
      return ResolvedRoom(roomId: roomIdOrAlias, via: via);
    }
    final id = aliases[roomIdOrAlias];
    if (id == null) throw StateError('Unknown alias');
    return ResolvedRoom(roomId: id, via: [...via, 'directory.org']);
  }

  @override
  LinkedRoomMembership membership(String roomId) => joinedIds.contains(roomId)
      ? LinkedRoomMembership.joined
      : invitedIds.contains(roomId)
      ? LinkedRoomMembership.invited
      : LinkedRoomMembership.none;

  @override
  Future<RoomLinkPreview?> previewRoom(
    String roomIdOrAlias, {
    List<String> via = const [],
  }) async => preview;

  @override
  Future<String> joinRoom(
    String roomIdOrAlias, {
    List<String> via = const [],
  }) async {
    joins.add((roomIdOrAlias, via));
    await joinGate?.future;
    final error = joinError;
    if (error != null) throw error;
    final id = aliases[roomIdOrAlias] ?? roomIdOrAlias;
    joinedIds.add(id);
    return id;
  }

  @override
  Future<LinkedUserProfile> userProfile(String userId) async =>
      LinkedUserProfile(userId: userId, displayName: 'Alice Example');

  @override
  Future<void> markRead(
    String roomId,
    String eventId, {
    required bool publicReceipt,
  }) async => markedRead.add((roomId, eventId, publicReceipt));

  @override
  Future<void> createDirectChat(String userId) async {
    directChats.add(userId);
    activeId = '!dm:example.org';
  }

  @override
  Future<void> acceptInvite(String roomId) async => accepted.add(roomId);

  @override
  Future<void> sendAttachment(String roomId, XFile file) async =>
      attachments.add((roomId, file));

  @override
  Future<void> queueMedia(
    String roomId,
    MediaSelection media, {
    String? caption,
    String? replyToId,
    String? threadRootId,
  }) async {
    if (failMediaAfter >= 0 && queuedMedia.length >= failMediaAfter) {
      throw StateError('outbox full');
    }
    queuedMedia.add((roomId, media, caption));
  }

  @override
  Future<void> queueMessage(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
    String? threadRootId,
    String? font,
  }) async => queuedText.add((roomId, text));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory intent source.
class FakeIntentSource implements PlatformIntentSource {
  final controller = StreamController<PlatformIntent>();
  final discarded = <String>[];

  @override
  Stream<PlatformIntent> get intents => controller.stream;

  @override
  Future<void> discard(Iterable<SharedFile> files) async =>
      discarded.addAll(files.map((f) => f.path));
}

SharedFile sharedFile(
  String name, {
  String mime = 'image/jpeg',
  int size = 4,
}) => SharedFile(
  path: '/data/cache/shared_intents/abc/$name',
  name: name,
  mimeType: mime,
  size: size,
);

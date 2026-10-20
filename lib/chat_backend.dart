import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

enum SessionStatus { loading, signedOut, ready, offline }

@immutable
class ChatRoom {
  const ChatRoom({
    required this.id,
    required this.name,
    required this.preview,
    required this.lastActivity,
    this.unread = 0,
    this.avatarUrl,
    this.encrypted = false,
    this.isDirect = false,
    this.manuallyUnread = false,
    this.heroes = const [],
    this.invited = false,
  });

  final String id;
  final String name;
  final String preview;
  final DateTime? lastActivity;
  final int unread;
  final Uri? avatarUrl;
  final bool encrypted;
  final bool isDirect;
  final bool manuallyUnread;
  final List<ChatAvatar> heroes;
  final bool invited;
}

@immutable
class ChatAvatar {
  const ChatAvatar({required this.name, this.url});
  final String name;
  final Uri? url;
}

@immutable
class PublicRoom {
  const PublicRoom({
    required this.id,
    required this.name,
    required this.members,
    this.topic,
    this.alias,
    this.avatarUrl,
  });
  final String id;
  final String name;
  final int members;
  final String? topic;
  final String? alias;
  final Uri? avatarUrl;
}

@immutable
class PublicRoomPage {
  const PublicRoomPage({required this.rooms, this.nextBatch});
  final List<PublicRoom> rooms;
  final String? nextBatch;
}

@immutable
class MessageHit {
  const MessageHit({
    required this.id,
    required this.roomId,
    required this.roomName,
    required this.sender,
    required this.body,
    required this.time,
  });
  final String id;
  final String roomId;
  final String roomName;
  final String sender;
  final String body;
  final DateTime time;
}

@immutable
class MessageSearchPage {
  const MessageSearchPage({required this.hits, this.nextBatch});
  final List<MessageHit> hits;
  final String? nextBatch;
}

@immutable
class ChatEntry {
  const ChatEntry({
    required this.id,
    required this.sender,
    required this.body,
    required this.time,
    required this.mine,
    this.isImage = false,
    this.isAttachment = false,
  });

  final String id;
  final String sender;
  final String body;
  final DateTime time;
  final bool mine;
  final bool isImage;
  final bool isAttachment;
}

@immutable
class DownloadedAttachment {
  const DownloadedAttachment({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });
  final String name;
  final String mimeType;
  final Uint8List bytes;
}

@immutable
class CryptoStatus {
  const CryptoStatus({
    required this.initialized,
    required this.connected,
    required this.keyBackupEnabled,
    required this.crossSigningEnabled,
  });
  final bool initialized;
  final bool connected;
  final bool keyBackupEnabled;
  final bool crossSigningEnabled;
}

abstract class ChatBackend extends ChangeNotifier {
  SessionStatus get connection;
  String? get userId;
  String? get error;
  List<ChatRoom> get rooms;
  String? get activeRoomId;
  List<ChatEntry> get messages;
  bool get sending;
  bool get canLoadOlder;
  bool get loadingHistory;

  Future<void> initialize();
  Future<void> login({
    required String homeserver,
    required String username,
    required String password,
  });
  Future<void> logout();
  Future<void> openRoom(String roomId);
  Future<void> loadOlder(String roomId);
  void closeRoom(String roomId);
  Future<void> sendText(String roomId, String text);
  Future<void> sendImages(String roomId, List<XFile> images);
  Future<void> sendAttachment(String roomId, XFile file);
  Future<Uint8List?> loadImage(String roomId, String eventId);
  Future<DownloadedAttachment> loadAttachment(String roomId, String eventId);
  Future<Uint8List?> loadAvatar(Uri url);
  Future<void> react(String roomId, String eventId);
  Future<void> createDirectChat(String userId);
  Future<void> acceptInvite(String roomId);
  Future<void> declineInvite(String roomId);
  Future<PublicRoomPage> searchPublicRooms(String query, {String? nextBatch});
  Future<String> joinPublicRoom(String roomId);
  Future<MessageSearchPage> searchMessages(String query, {String? nextBatch});
  Future<CryptoStatus> cryptoStatus();
  Future<void> restoreCryptoIdentity(String keyOrPassphrase);
  Future<void> restoreBackedUpKeys();
}

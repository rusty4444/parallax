import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

enum SessionStatus { loading, signedOut, ready, offline }

enum RoomSyncState { loading, ready, error }

enum RoomSyncIssue { network, homeserver, processing }

enum VerificationStage { accept, waiting, choose, compare, secret, done, error }

@immutable
class VerificationEmoji {
  const VerificationEmoji(this.symbol, this.name);
  final String symbol;
  final String name;
}

@immutable
class VerificationDetails {
  const VerificationDetails({
    required this.id,
    required this.userId,
    required this.stage,
    required this.incoming,
    this.deviceId,
    this.emojis = const [],
    this.numbers = const [],
    this.busy = false,
    this.secretSkipped = false,
    this.error,
  });
  final int id;
  final String userId;
  final String? deviceId;
  final VerificationStage stage;
  final bool incoming;
  final List<VerificationEmoji> emojis;
  final List<int> numbers;
  final bool busy;
  final bool secretSkipped;
  final String? error;
}

@immutable
class VerificationDevice {
  const VerificationDevice({
    required this.id,
    required this.name,
    required this.verified,
  });
  final String id;
  final String name;
  final bool verified;
}

@immutable
class UntrustedRecipient {
  const UntrustedRecipient({required this.userId, this.masterKey});
  final String userId;
  final String? masterKey;
}

@immutable
class TrustWarning {
  const TrustWarning({required this.roomId, required this.recipients});
  final String roomId;
  final List<UntrustedRecipient> recipients;
}

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

int compareRooms(ChatRoom a, ChatRoom b) {
  if (a.invited != b.invited) return a.invited ? -1 : 1;
  final activity = (b.lastActivity ?? DateTime(1970)).compareTo(
    a.lastActivity ?? DateTime(1970),
  );
  return activity == 0 ? a.id.compareTo(b.id) : activity;
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
class ChatReaction {
  const ChatReaction({
    required this.emoji,
    required this.count,
    required this.mine,
  });

  final String emoji;
  final int count;
  final bool mine;
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
    this.replyToId,
    this.redacted = false,
    this.edited = false,
    this.reactions = const [],
  });

  final String id;
  final String sender;
  final String body;
  final DateTime time;
  final bool mine;
  final bool isImage;
  final bool isAttachment;
  final String? replyToId;
  final bool redacted;
  final bool edited;
  final List<ChatReaction> reactions;
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
  RoomSyncState get roomSyncState;
  RoomSyncIssue? get roomSyncIssue;
  String? get userId;
  String? get error;
  List<ChatRoom> get rooms;
  String? get activeRoomId;
  List<ChatEntry> get messages;
  bool get sending;
  bool get canLoadOlder;
  bool get loadingHistory;
  List<String> get typingUsers;
  VerificationDetails? get verification;
  TrustWarning? get trustWarning;

  Future<List<VerificationDevice>> ownDevices();
  Future<void> startVerification(String userId, {String? deviceId});
  Future<void> acceptVerification();
  Future<void> chooseEmojiVerification();
  Future<void> confirmVerification({required bool matches});
  Future<void> unlockVerification(String keyOrPassphrase);
  Future<void> skipVerificationSigning();
  Future<void> cancelVerification();
  void dismissVerification();
  void respondToTrustWarning(bool approved);

  Future<void> initialize();
  Future<void> refreshRooms();
  Future<void> login({
    required String homeserver,
    required String username,
    required String password,
  });
  Future<void> logout();
  Future<void> openRoom(String roomId);
  Future<void> loadOlder(String roomId);
  void closeRoom(String roomId);
  Future<void> sendText(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
  });
  Future<void> sendImages(String roomId, List<XFile> images);
  Future<void> sendAttachment(String roomId, XFile file);
  Future<Uint8List?> loadImage(String roomId, String eventId);
  Future<DownloadedAttachment> loadAttachment(String roomId, String eventId);
  Future<Uint8List?> loadAvatar(Uri url);
  Future<void> react(String roomId, String eventId, {String emoji = '❤️'});
  Future<void> redactMessage(String roomId, String eventId);
  Future<void> setTyping(String roomId, bool typing);
  Future<void> createDirectChat(String userId);
  Future<void> acceptInvite(String roomId);
  Future<void> declineInvite(String roomId);
  Future<void> setRoomUnread(String roomId, bool unread);
  Future<void> leaveRoom(String roomId);
  Future<PublicRoomPage> searchPublicRooms(String query, {String? nextBatch});
  Future<String> joinPublicRoom(String roomId);
  Future<MessageSearchPage> searchMessages(String query, {String? nextBatch});
  Future<CryptoStatus> cryptoStatus();
  Future<void> restoreCryptoIdentity(String keyOrPassphrase);
  Future<void> restoreBackedUpKeys();
}

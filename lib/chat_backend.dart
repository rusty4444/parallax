import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'chat_network.dart';
import 'crypto_setup_policy.dart';
import 'room_details.dart';

enum SessionStatus { loading, signedOut, ready, offline }

enum RoomSyncState { loading, ready, error }

enum RoomSyncIssue { network, homeserver, processing }

enum RoomCreationFailureKind { notSubmitted, rejected }

/// Definitive evidence that this attempt did not create a room. Other errors
/// do not prove non-delivery and must not release non-idempotent admission.
@immutable
class RoomCreationFailure implements Exception {
  const RoomCreationFailure.notSubmitted(this.message)
    : kind = RoomCreationFailureKind.notSubmitted;

  const RoomCreationFailure.rejected()
    : kind = RoomCreationFailureKind.rejected,
      message =
          'The server rejected this room request. '
          'Check your settings or permissions, then try again.';

  final RoomCreationFailureKind kind;
  final String message;
}

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

/// Per-room notification setting derived from the account's push rules.
enum RoomNotificationMode { allMessages, mentionsAndKeywords, mute }

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
    this.highlightCount = 0,
    this.favourite = false,
    this.lowPriority = false,
    this.tags = const [],
    this.notificationMode = RoomNotificationMode.allMessages,
    this.isSpace = false,
    this.isPublic = false,
    this.previewSender,
    this.previewIncludesSender = false,
    this.previewCode,
    this.canonicalAlias,
    this.network,
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

  /// Unread mentions/keywords (`highlight_count`).
  final int highlightCount;

  /// Tagged `m.favourite`.
  final bool favourite;

  /// Tagged `m.lowpriority`.
  final bool lowPriority;

  /// Valid `m.tag` names for this room.
  final List<String> tags;
  final RoomNotificationMode notificationMode;

  /// The room is a Space (`m.room.create` type `m.space`).
  final bool isSpace;

  /// Anyone can join (join rule `public`). Drives "media in private rooms".
  final bool isPublic;

  /// Display name of the last message's sender, for group previews.
  final String? previewSender;

  /// Whether [preview] already includes [previewSender], as in
  /// "Chris sent a photo", rather than being a message body.
  final bool previewIncludesSender;

  /// A one-time code in the last message, when that message is unread and
  /// from someone else. The home row offers to copy it.
  final String? previewCode;
  final String? canonicalAlias;

  /// The app the chat comes from (bridged or native Matrix); null when
  /// unknown. Picks the logo shown when the chat has no picture.
  final ChatNetwork? network;

  bool get muted => notificationMode == RoomNotificationMode.mute;

  ChatRoom copyWith({
    String? name,
    String? preview,
    int? unread,
    bool? manuallyUnread,
    bool? invited,
    int? highlightCount,
    bool? favourite,
    bool? lowPriority,
    List<String>? tags,
    RoomNotificationMode? notificationMode,
  }) => ChatRoom(
    id: id,
    name: name ?? this.name,
    preview: preview ?? this.preview,
    lastActivity: lastActivity,
    unread: unread ?? this.unread,
    avatarUrl: avatarUrl,
    encrypted: encrypted,
    isDirect: isDirect,
    manuallyUnread: manuallyUnread ?? this.manuallyUnread,
    heroes: heroes,
    invited: invited ?? this.invited,
    highlightCount: highlightCount ?? this.highlightCount,
    favourite: favourite ?? this.favourite,
    lowPriority: lowPriority ?? this.lowPriority,
    tags: tags ?? this.tags,
    notificationMode: notificationMode ?? this.notificationMode,
    isSpace: isSpace,
    isPublic: isPublic,
    previewSender: previewSender,
    previewIncludesSender: previewIncludesSender,
    // A replaced preview is no longer the message the code came from.
    previewCode: preview == null ? previewCode : null,
    canonicalAlias: canonicalAlias,
    network: network,
  );
}

/// Whether two projections of a room show the same thing (every field).
bool sameChatRoom(ChatRoom a, ChatRoom b) {
  if (identical(a, b)) return true;
  if (a.id != b.id ||
      a.name != b.name ||
      a.preview != b.preview ||
      a.lastActivity != b.lastActivity ||
      a.unread != b.unread ||
      a.avatarUrl != b.avatarUrl ||
      a.encrypted != b.encrypted ||
      a.isDirect != b.isDirect ||
      a.manuallyUnread != b.manuallyUnread ||
      a.invited != b.invited ||
      a.highlightCount != b.highlightCount ||
      a.favourite != b.favourite ||
      a.lowPriority != b.lowPriority ||
      a.notificationMode != b.notificationMode ||
      a.isSpace != b.isSpace ||
      a.isPublic != b.isPublic ||
      a.previewSender != b.previewSender ||
      a.previewIncludesSender != b.previewIncludesSender ||
      a.previewCode != b.previewCode ||
      a.canonicalAlias != b.canonicalAlias ||
      a.network != b.network ||
      a.tags.length != b.tags.length ||
      a.heroes.length != b.heroes.length) {
    return false;
  }
  for (var i = 0; i < a.tags.length; i++) {
    if (a.tags[i] != b.tags[i]) return false;
  }
  for (var i = 0; i < a.heroes.length; i++) {
    if (a.heroes[i].name != b.heroes[i].name ||
        a.heroes[i].url != b.heroes[i].url) {
      return false;
    }
  }
  return true;
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

/// What a timeline row represents. Renderers dispatch on this.
enum EntryKind {
  text,
  emote,
  notice,
  image,
  video,
  audio,
  voice,
  file,
  sticker,
  location,
  liveLocation,
  poll,
  state,
  call,
  undecryptable,
  redacted,
  unknown,
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
    EntryKind? kind,
    this.eventType = 'm.room.message',
    this.msgtype,
    this.formattedBody,
    this.senderName,
    this.senderAvatar,
    this.content = const {},
    this.stateKey,
    this.threadReplyCount = 0,
    this.threadLatestBody,
    this.pinned = false,
    this.highlight = false,
    // Public name `kind`, private storage: the getter supplies a fallback.
    // ignore: prefer_initializing_formals
  }) : _kind = kind;

  final String id;

  /// Matrix user ID of the sender.
  final String sender;

  /// Plain-text body (reply fallback stripped). For state/call/poll entries a
  /// short human-readable fallback.
  final String body;
  final DateTime time;
  final bool mine;
  final bool isImage;
  final bool isAttachment;
  final String? replyToId;
  final bool redacted;
  final bool edited;
  final List<ChatReaction> reactions;
  final EntryKind? _kind;

  /// Matrix event type (after decryption), e.g. `m.room.message`.
  final String eventType;

  /// `msgtype` of an `m.room.message`.
  final String? msgtype;

  /// Raw `formatted_body` when `format` is `org.matrix.custom.html`.
  /// Untrusted: renderers must sanitise it.
  final String? formattedBody;

  /// Sender display name from cached room membership, if known.
  final String? senderName;

  /// Sender avatar `mxc://` URI from cached room membership, if known.
  final Uri? senderAvatar;

  /// Decrypted display content (edits applied). Read-only by convention.
  final Map<String, Object?> content;

  /// State key for state events.
  final String? stateKey;

  /// Server-side thread summary for a thread root.
  final int threadReplyCount;
  final String? threadLatestBody;

  /// Whether the event is in the room's pinned events.
  final bool pinned;

  /// Whether the event mentions the current user (or @room).
  final bool highlight;

  EntryKind get kind =>
      _kind ??
      (redacted
          ? EntryKind.redacted
          : isImage
          ? EntryKind.image
          : isAttachment
          ? EntryKind.file
          : EntryKind.text);

  /// Display name if known, otherwise the Matrix ID.
  String get senderLabel =>
      (senderName?.trim().isNotEmpty ?? false) ? senderName!.trim() : sender;
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
    required this.setupAvailability,
  });
  final bool initialized;
  final bool connected;
  final bool keyBackupEnabled;
  final bool crossSigningEnabled;
  final CryptoSetupAvailability setupAvailability;
}

@immutable
class CryptoSetupResult {
  const CryptoSetupResult({required this.recoveryKey, required this.ready});
  final String recoveryKey;
  final bool ready;
}

abstract class ChatBackend extends ChangeNotifier {
  SessionStatus get connection;
  RoomSyncState get roomSyncState;
  RoomSyncIssue? get roomSyncIssue;
  String? get userId;
  String? get error;

  /// Replaced by a new list whenever any room changes (never edited in
  /// place), so screens can skip work while the identity is unchanged.
  List<ChatRoom> get rooms;
  String? get activeRoomId;
  List<ChatEntry> get messages;
  bool get sending;

  /// Whether a direct non-queued send (such as a gallery upload) is active in
  /// [roomId]. Queued outbox sends sit in the pending panel without blocking.
  bool isRoomSending(String roomId) => sending;
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

  /// Marks what the open room shows as read (Parallax came back on screen
  /// with the room open). Backends without read state ignore it.
  void markActiveRoomRead() {}

  /// [font] is a message font ID (`message_fonts.dart`) for a non-default
  /// font, or null. Backends without message fonts ignore it.
  Future<void> sendText(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
    String? font,
  });
  Future<void> sendImages(String roomId, List<XFile> images);
  Future<void> sendAttachment(String roomId, XFile file);
  Future<Uint8List?> loadImage(String roomId, String eventId);
  Future<DownloadedAttachment> loadAttachment(String roomId, String eventId);
  Future<Uint8List?> loadAvatar(Uri url);

  /// A room row was shown: the backend may check the names of the people it
  /// shows (once per session). Must not notify synchronously.
  void roomShown(String roomId) {}

  /// An already downloaded avatar, so rows can show it on their first frame
  /// instead of flashing the initial while [loadAvatar] completes.
  Uint8List? cachedAvatar(Uri url) => null;
  Future<void> react(String roomId, String eventId, {String emoji = '❤️'});
  Future<void> redactMessage(String roomId, String eventId);
  Future<void> setTyping(String roomId, bool typing);
  Future<void> createDirectChat(String userId);

  /// Throws [RoomCreationFailure] only for definite non-creation; any other
  /// failure leaves delivery uncertain and must not be automatically retried.
  Future<String> createRoom(String name, {required bool encrypted});
  Future<void> acceptInvite(String roomId);
  Future<void> declineInvite(String roomId);
  Future<void> setRoomUnread(String roomId, bool unread);
  Future<void> leaveRoom(String roomId);
  Future<RoomDetails> getRoomDetails(String roomId);
  Future<void> editRoomName(String roomId, String name);
  Future<void> editRoomTopic(String roomId, String topic);
  Future<void> inviteToRoom(String roomId, String userId);
  Future<void> moderateRoomMember(
    String roomId,
    String userId,
    RoomAction action,
  );
  Future<PublicRoomPage> searchPublicRooms(String query, {String? nextBatch});
  Future<String> joinPublicRoom(String roomId);
  Future<MessageSearchPage> searchMessages(String query, {String? nextBatch});
  Future<CryptoStatus> cryptoStatus();
  Future<CryptoSetupResult> createCryptoIdentity(String recoveryPassphrase);
  Future<void> repairCryptoIdentity(String keyOrPassphrase);
  Future<void> restoreCryptoIdentity(String keyOrPassphrase);
  Future<void> restoreBackedUpKeys();
}

// Module interface for the Android Auto car screen and its live Matrix
// implementation (main isolate). Chats and their recent messages come from
// the signed-in client's local store; nothing is fetched per message. Replies
// and read receipts reuse the guarded paths of quick replies and the inbox.
import 'dart:async';
import 'dart:io';

import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../matrix_room_names.dart';
import '../../room_events.dart';
import '../home/home_features.dart';
import '../notifications/notification_content.dart';
import '../notifications/notification_features.dart';
import '../notifications/notification_media.dart';
import 'car_conversations.dart';

/// Outcome of a reply sent from the car.
enum CarReplyResult { sent, failed, stillSending }

abstract interface class AndroidAutoFeatures {
  /// The signed-in account, or null when signed out.
  String? get userId;

  /// [rooms] (already chosen and ordered) with their recent messages.
  /// Pictures are cached under [cacheRoot] (null: none). Pictures still
  /// downloading after a short wait are left out; [onLatePictures] runs once
  /// they are cached so the car can ask again.
  Future<List<CarConversation>> conversations(
    List<ChatRoom> rooms, {
    int messages = maxCarMessagesPerConversation,
    Directory? cacheRoot,
    void Function()? onLatePictures,
  });

  /// Marks [roomId] read up to its latest message, like the inbox does.
  Future<void> markRead(String roomId, {required bool publicReceipt});

  /// Sends [text] to [roomId] through the guarded send path.
  Future<CarReplyResult> reply(String roomId, String text);
}

final _cache = Expando<AndroidAutoFeatures>('androidAutoFeatures');

AndroidAutoFeatures? androidAutoFeaturesOf(ChatBackend backend) {
  if (backend is AndroidAutoFeatures) return backend as AndroidAutoFeatures;
  if (backend is MatrixSdkAccess) {
    return _cache[backend] ??= MatrixAndroidAutoFeatures(backend);
  }
  return null;
}

class CarSessionChanged implements Exception {
  const CarSessionChanged();
  @override
  String toString() => 'The account changed while the car was asking.';
}

class MatrixAndroidAutoFeatures implements AndroidAutoFeatures {
  MatrixAndroidAutoFeatures(this._backend)
    : assert(_backend is MatrixSdkAccess);

  final ChatBackend _backend;
  MatrixSdkAccess get _access => _backend as MatrixSdkAccess;

  /// Stored events read per room to find its recent messages.
  static const eventsPerRoom = 40;

  /// How long pictures may hold up an answer to the car.
  static const pictureWait = Duration(milliseconds: 2500);

  /// How long names of people not loaded yet may hold up an answer.
  static const memberWait = Duration(seconds: 2);

  /// How long a reply may take before the car is told it is still sending.
  static const replyWait = Duration(seconds: 30);

  matrix.Client _client() {
    final client = _access.sdkClient;
    if (client == null ||
        !_access.isSessionCurrent(client) ||
        client.userID == null) {
      throw const CarSessionChanged();
    }
    return client;
  }

  void _check(matrix.Client client) {
    if (!_access.isSessionCurrent(client)) throw const CarSessionChanged();
  }

  @override
  String? get userId {
    final client = _access.sdkClient;
    return client != null && _access.isSessionCurrent(client)
        ? client.userID
        : null;
  }

  @override
  Future<List<CarConversation>> conversations(
    List<ChatRoom> rooms, {
    int messages = maxCarMessagesPerConversation,
    Directory? cacheRoot,
    void Function()? onLatePictures,
  }) async {
    final client = _client();
    final me = client.userID!;
    final homeserver = client.homeserver;
    final token = client.accessToken;
    final pictures = cacheRoot != null && homeserver != null && token != null
        ? NotificationMediaLoader(
            httpClient: client.httpClient,
            homeserver: homeserver,
            accessToken: token,
            cacheRoot: cacheRoot,
          )
        : null;
    final byId = {for (final room in client.rooms) room.id: room};
    // Pictures that missed the wait: the car asks again once they are cached.
    final latePictures = <Future<String?>>[];
    final deadline = DateTime.now().add(pictureWait);
    Future<String?> picture(Uri? mxc) async {
      if (pictures == null || mxc == null) return null;
      final load = pictures.avatar(mxc);
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        latePictures.add(load);
        return null;
      }
      return load.timeout(
        left,
        onTimeout: () {
          latePictures.add(load);
          return null;
        },
      );
    }

    final results = await Future.wait([
      for (final summary in rooms)
        if (byId[summary.id] case final room?)
          _conversation(
            client,
            room,
            summary,
            me,
            messages,
            picture,
          ).catchError((Object _) => null),
    ]);
    _check(client);
    if (onLatePictures != null && latePictures.isNotEmpty) {
      unawaited(
        Future.wait(latePictures).then((paths) {
          // Ask again only when one of them actually arrived.
          if (paths.any((path) => path != null) &&
              _access.isSessionCurrent(client)) {
            onLatePictures();
          }
        }, onError: (Object _) {}),
      );
    }
    return [for (final conversation in results) ?conversation];
  }

  Future<CarConversation?> _conversation(
    matrix.Client client,
    matrix.Room room,
    ChatRoom summary,
    String me,
    int max,
    Future<String?> Function(Uri? mxc) picture,
  ) async {
    if (room.membership != matrix.Membership.join) return null;
    final stored = await client.database.getEventList(
      room,
      limit: eventsPerRoom,
    );
    _check(client);
    final events = <matrix.Event>[
      ...stored.where((event) => event.status.isSynced),
    ];
    final last = room.lastEvent;
    if (last != null &&
        last.status.isSynced &&
        !events.any((event) => event.eventId == last.eventId)) {
      events.add(last);
    }
    final senders = {for (final event in events) event.senderId}..remove(me);
    if (senders.isNotEmpty) {
      await room.loadMissingMembers(senders, timeout: memberWait);
      _check(client);
    }
    String nameOf(String userId) =>
        sanitiseNotificationName(
          room.memberInMemory(userId).calcDisplayname(),
        ) ??
        userId;
    final lines = carMessageLines(
      [
        for (final event in events)
          CarTimelineEvent(
            eventId: event.eventId,
            senderId: event.senderId,
            type: event.type,
            content: Map<String, Object?>.from(event.content),
            timestamp: event.originServerTs,
            redacted: event.redacted,
            stateKey: event.stateKey,
          ),
      ],
      myUserId: me,
      nameOf: nameOf,
      unreadCount: summary.unread,
      markedUnread: summary.manuallyUnread,
      readUpTo: _readUpTo(room),
      roomName: summary.name,
      isDirect: summary.isDirect,
      decorate: room.withMentionNames,
      max: max.clamp(1, maxCarMessagesPerConversation),
    );
    if (lines.isEmpty) return null;
    final partner = summary.isDirect
        ? room.peopleHeroes.where((id) => id != me).firstOrNull
        : null;
    final roomPicture = picture(
      room.parallaxAvatar ??
          (partner == null ? null : room.memberInMemory(partner).avatarUrl),
    );
    final senderPictures = {
      if (!summary.isDirect)
        for (final id in {
          for (final line in lines)
            if (!line.fromMe) line.senderId,
        })
          id: picture(room.memberInMemory(id).avatarUrl),
    };
    final iconPath = await roomPicture;
    final icons = <String, String?>{
      for (final entry in senderPictures.entries) entry.key: await entry.value,
    };
    return CarConversation(
      roomId: room.id,
      title: summary.name,
      isDirect: summary.isDirect,
      unread: summary.unread,
      iconPath: iconPath,
      messages: [
        for (final line in lines)
          icons[line.senderId] == null
              ? line
              : line.copyWith(senderIconPath: icons[line.senderId]),
      ],
    );
  }

  /// When your latest read receipt in [room] was sent, if known.
  DateTime? _readUpTo(matrix.Room room) {
    final receipt =
        room.receiptState.global.latestOwnReceipt ??
        room.receiptState.mainThread?.latestOwnReceipt;
    final ts = receipt?.ts;
    return ts == null || ts <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ts);
  }

  @override
  Future<void> markRead(String roomId, {required bool publicReceipt}) async {
    final client = _client();
    final features = roomListFeaturesOf(_backend);
    if (features == null) throw StateError('Marking read is unavailable');
    await features.markAsRead(roomId, publicReceipt: publicReceipt);
    _check(client);
  }

  @override
  Future<CarReplyResult> reply(String roomId, String text) async {
    final client = _client();
    final features = notificationFeaturesOf(_backend);
    if (features == null) return CarReplyResult.failed;
    final send = features.sendQuickReply(roomId, text);
    try {
      await send.timeout(replyWait);
      _check(client);
      return CarReplyResult.sent;
    } on TimeoutException {
      // Still going (waiting for another send or a decision on the phone).
      unawaited(send.then<void>((_) {}, onError: (Object _) {}));
      return CarReplyResult.stillSending;
    } catch (_) {
      return CarReplyResult.failed;
    }
  }
}

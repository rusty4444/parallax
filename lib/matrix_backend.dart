import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vodozemac;
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:matrix/encryption.dart' as encryption;
import 'package:matrix/matrix.dart' as matrix;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

import 'chat_backend.dart';

/// One SDK client and one active timeline for the lifetime of the app.
class MatrixBackend extends ChatBackend {
  matrix.Client? _client;
  matrix.Timeline? _timeline;
  StreamSubscription<matrix.SyncUpdate>? _syncSubscription;
  StreamSubscription<matrix.LoginState>? _loginSubscription;
  Timer? _roomUpdateTimer;
  int _roomGeneration = 0;
  bool _disposed = false;
  bool _initializing = false;
  bool _sending = false;
  bool _loadingHistory = false;
  int _visibleMessageLimit = 100;
  String? _activeRoomId;
  String? _error;
  SessionStatus _connection = SessionStatus.loading;
  List<ChatRoom> _rooms = const [];
  List<ChatEntry> _messages = const [];
  final _imageCache = <String, Uint8List>{};
  int _imageCacheBytes = 0;
  final _avatarCache = <Uri, Uint8List>{};
  final _avatarInFlight = <Uri, Future<Uint8List?>>{};
  final _avatarWaiters = Queue<Completer<void>>();
  int _avatarActive = 0;

  @override
  SessionStatus get connection => _connection;
  @override
  String? get userId => _client?.userID;
  @override
  String? get error => _error;
  @override
  List<ChatRoom> get rooms => _rooms;
  @override
  String? get activeRoomId => _activeRoomId;
  @override
  List<ChatEntry> get messages => _messages;
  @override
  bool get sending => _sending;
  @override
  bool get canLoadOlder =>
      (_timeline?.events.length ?? 0) > _visibleMessageLimit ||
      (_timeline?.canRequestHistory ?? false);
  @override
  bool get loadingHistory => _loadingHistory;

  @override
  Future<void> initialize() async {
    if (_initializing || _client != null) return;
    _initializing = true;
    _setStatus(SessionStatus.loading);
    sqlite.Database? openedDatabase;
    matrix.Client? openedClient;
    try {
      await vodozemac.init();
      final directory = await getApplicationSupportDirectory();
      openedDatabase = await sqlite.openDatabase(
        path.join(directory.path, 'matrixpress.db'),
      );
      openedClient = matrix.Client(
        'MatriXpress',
        database: await matrix.MatrixSdkDatabase.init(
          'matrixpress',
          database: openedDatabase,
        ),
        supportedLoginTypes: {matrix.AuthenticationTypes.password},
      );
      final client = openedClient;
      _client = client;
      await client.init(
        waitForFirstSync: false,
        waitUntilLoadCompletedLoaded: true,
      );
      _syncSubscription = client.onSync.stream.listen(
        (_) => _scheduleRoomUpdate(),
      );
      _loginSubscription = client.onLoginStateChanged.stream.listen((_) {
        if (_disposed) return;
        _setStatus(
          client.isLogged() ? SessionStatus.ready : SessionStatus.signedOut,
        );
        _scheduleRoomUpdate();
      });
      _setStatus(
        client.isLogged() ? SessionStatus.ready : SessionStatus.signedOut,
      );
      _scheduleRoomUpdate();
    } catch (_) {
      await _syncSubscription?.cancel();
      await _loginSubscription?.cancel();
      _syncSubscription = null;
      _loginSubscription = null;
      if (openedClient != null) {
        await openedClient.dispose();
      } else {
        await openedDatabase?.close();
      }
      _client = null;
      _error = 'Could not initialise local Matrix storage or encryption.';
      _setStatus(SessionStatus.offline);
    } finally {
      _initializing = false;
    }
  }

  @override
  Future<void> login({
    required String homeserver,
    required String username,
    required String password,
  }) async {
    final client = _requireClient();
    final url = Uri.parse(homeserver);
    if (url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.query.isNotEmpty ||
        url.fragment.isNotEmpty) {
      throw const FormatException('An HTTPS homeserver URL is required.');
    }
    await client.checkHomeserver(url);
    await client.login(
      matrix.LoginType.mLoginPassword,
      identifier: matrix.AuthenticationUserIdentifier(user: username),
      password: password,
    );
    _setStatus(SessionStatus.ready);
    _scheduleRoomUpdate();
  }

  @override
  Future<void> logout() async {
    final client = _requireClient();
    closeRoom(_activeRoomId ?? '');
    await client.logout();
    _rooms = const [];
    _messages = const [];
    _imageCache.clear();
    _imageCacheBytes = 0;
    _avatarCache.clear();
    _setStatus(SessionStatus.signedOut);
  }

  @override
  Future<void> openRoom(String roomId) async {
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    if (_activeRoomId == roomId && _timeline != null) return;
    _roomGeneration++;
    final generation = _roomGeneration;
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _activeRoomId = roomId;
    _visibleMessageLimit = 100;
    _loadingHistory = false;
    _messages = const [];
    notifyListeners();

    matrix.Timeline? created;
    created = await room.getTimeline(
      onUpdate: () {
        if (generation == _roomGeneration && created != null && !_disposed) {
          _refreshMessages(created);
        }
      },
    );
    if (generation != _roomGeneration || _disposed) {
      created.cancelSubscriptions();
      return;
    }
    _timeline = created;
    _refreshMessages(created);
    if (room.isUnread && created.events.isNotEmpty) {
      final eventId = created.events.first.eventId;
      if (eventId.isNotEmpty) {
        // Receipt delivery must never hold the timeline's first frame hostage.
        unawaited(
          room
              .setReadMarker(eventId, mRead: eventId)
              .then((_) => _scheduleRoomUpdate())
              .catchError((Object _) {}),
        );
      }
    }
  }

  @override
  Future<void> loadOlder(String roomId) async {
    final timeline = _timeline;
    if (_activeRoomId != roomId ||
        timeline == null ||
        _loadingHistory ||
        !canLoadOlder) {
      return;
    }
    _loadingHistory = true;
    notifyListeners();
    try {
      _visibleMessageLimit += 50;
      if (timeline.events.length < _visibleMessageLimit &&
          timeline.canRequestHistory) {
        await timeline.requestHistory(historyCount: 50);
      }
      if (_timeline == timeline) _refreshMessages(timeline);
    } finally {
      _loadingHistory = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void closeRoom(String roomId) {
    if (_activeRoomId != roomId) return;
    _roomGeneration++;
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _activeRoomId = null;
    _messages = const [];
  }

  @override
  Future<void> sendText(String roomId, String text) async {
    if (_sending) throw StateError('A send is already in progress');
    if (text.trim().isEmpty) return;
    final room = _requireClient().getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    _sending = true;
    notifyListeners();
    try {
      await room.sendTextEvent(
        text.trim(),
        parseCommands: false,
        parseMarkdown: false,
      );
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  @override
  Future<void> sendImages(String roomId, List<XFile> images) async {
    if (_sending) throw StateError('A send is already in progress');
    if (images.isEmpty || images.length > 10) {
      throw ArgumentError('Select between 1 and 10 images');
    }
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    if (room.encrypted && !client.fileEncryptionEnabled) {
      throw StateError('Encrypted uploads are unavailable');
    }
    _sending = true;
    notifyListeners();
    try {
      for (final image in images) {
        final size = await image.length();
        if (size == 0 || size > 20 * 1024 * 1024) {
          throw ArgumentError('Each image must be under 20 MB');
        }
      }
      for (final image in images) {
        final bytes = await image.readAsBytes();
        await room.sendFileEvent(
          matrix.MatrixImageFile(bytes: bytes, name: image.name),
          shrinkImageMaxDimension: 1600,
        );
      }
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  @override
  Future<void> sendAttachment(String roomId, XFile file) async {
    if (_sending) throw StateError('A send is already in progress');
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    if (room.encrypted && !client.fileEncryptionEnabled) {
      throw StateError('Encrypted uploads are unavailable');
    }
    _sending = true;
    notifyListeners();
    try {
      final size = await file.length();
      if (size <= 0 || size > 20 * 1024 * 1024) {
        throw ArgumentError('Choose a file smaller than 20 MB');
      }
      await room.sendFileEvent(
        matrix.MatrixFile.fromMimeType(
          bytes: await file.readAsBytes(),
          name: file.name,
        ),
      );
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  @override
  Future<Uint8List?> loadImage(String roomId, String eventId) async {
    final key = '$roomId/$eventId';
    final cached = _imageCache.remove(key);
    if (cached != null) {
      _imageCache[key] = cached;
      return cached;
    }
    final timeline = _timeline;
    if (_activeRoomId != roomId || timeline == null) return null;
    final event = await timeline.getEventById(eventId);
    if (event?.messageType != matrix.MessageTypes.Image) return null;
    final bytes = (await event!.downloadAndDecryptAttachment(
      getThumbnail: true,
    )).bytes;
    if (_activeRoomId != roomId || _timeline != timeline) return null;
    if (bytes.lengthInBytes <= 4 * 1024 * 1024) {
      _imageCache[key] = bytes;
      _imageCacheBytes += bytes.lengthInBytes;
      while (_imageCacheBytes > 16 * 1024 * 1024 && _imageCache.isNotEmpty) {
        final oldest = _imageCache.keys.first;
        _imageCacheBytes -= _imageCache.remove(oldest)!.lengthInBytes;
      }
    }
    return bytes;
  }

  @override
  Future<DownloadedAttachment> loadAttachment(
    String roomId,
    String eventId,
  ) async {
    final client = _requireClient();
    final timeline = _timeline;
    if (_activeRoomId != roomId || timeline == null) {
      throw StateError('Room unavailable');
    }
    final event = await timeline.getEventById(eventId);
    if (event?.hasAttachment != true) {
      throw StateError('Attachment unavailable');
    }
    final declared = event!.infoMap['size'];
    if (declared is int && declared > 25 * 1024 * 1024) {
      throw StateError('Attachment is too large');
    }
    final file = await event.downloadAndDecryptAttachment(
      downloadCallback: (uri) async {
        final request = http.Request('GET', uri);
        request.headers['authorization'] = 'Bearer ${client.accessToken}';
        final response = await client.httpClient.send(request);
        if (response.statusCode != 200 ||
            (response.contentLength ?? 0) > 25 * 1024 * 1024) {
          throw StateError('Attachment download failed');
        }
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          buffer.add(chunk);
          if (buffer.length > 25 * 1024 * 1024) {
            throw StateError('Attachment is too large');
          }
        }
        return buffer.takeBytes();
      },
    );
    if (_timeline != timeline ||
        _activeRoomId != roomId ||
        file.bytes.lengthInBytes > 25 * 1024 * 1024) {
      throw StateError('Attachment unavailable');
    }
    return DownloadedAttachment(
      name: file.name,
      mimeType: file.mimeType,
      bytes: file.bytes,
    );
  }

  @override
  Future<Uint8List?> loadAvatar(Uri url) async {
    if (url.scheme != 'mxc' || _disposed) return null;
    final cached = _avatarCache.remove(url);
    if (cached != null) {
      _avatarCache[url] = cached;
      return cached;
    }
    final existing = _avatarInFlight[url];
    if (existing != null) return existing;
    final pending = _fetchAvatar(url);
    _avatarInFlight[url] = pending;
    try {
      return await pending;
    } finally {
      _avatarInFlight.remove(url);
    }
  }

  Future<Uint8List?> _fetchAvatar(Uri url) async {
    if (_avatarActive >= 4) {
      final waiter = Completer<void>();
      _avatarWaiters.add(waiter);
      await waiter.future;
    } else {
      _avatarActive++;
    }
    try {
      final client = _client;
      if (client == null || !client.isLogged() || _disposed) return null;
      final thumbnail = await matrix.MxcUriExtension(
        url,
      ).getThumbnailUri(client, width: 96, height: 96);
      if (thumbnail.scheme != 'https') return null;
      final request = http.Request('GET', thumbnail);
      request.headers['authorization'] = 'Bearer ${client.accessToken}';
      final response = await client.httpClient.send(request);
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > 1024 * 1024) {
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        builder.add(chunk);
        if (builder.length > 1024 * 1024) return null;
      }
      if (_client != client || !client.isLogged() || _disposed) return null;
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) return null;
      _avatarCache[url] = bytes;
      if (_avatarCache.length > 24) {
        _avatarCache.remove(_avatarCache.keys.first);
      }
      return bytes;
    } catch (_) {
      return null;
    } finally {
      if (_avatarWaiters.isNotEmpty) {
        _avatarWaiters.removeFirst().complete();
      } else {
        _avatarActive--;
      }
    }
  }

  @override
  Future<void> react(String roomId, String eventId) async {
    final room = _requireClient().getRoomById(roomId);
    if (room == null) throw StateError('Room unavailable');
    await room.sendReaction(eventId, '❤️');
  }

  @override
  Future<void> createDirectChat(String userId) async {
    final id = await _requireClient().startDirectChat(userId);
    _activeRoomId = id;
    _scheduleRoomUpdate();
    notifyListeners();
  }

  @override
  Future<void> acceptInvite(String roomId) async {
    final room = _requireClient().getRoomById(roomId);
    if (room?.membership != matrix.Membership.invite) {
      throw StateError('Invitation unavailable');
    }
    await room!.join(waitForSync: true);
    _scheduleRoomUpdate();
  }

  @override
  Future<void> declineInvite(String roomId) async {
    final room = _requireClient().getRoomById(roomId);
    if (room?.membership != matrix.Membership.invite) {
      throw StateError('Invitation unavailable');
    }
    await room!.leave();
    _scheduleRoomUpdate();
  }

  @override
  Future<PublicRoomPage> searchPublicRooms(
    String query, {
    String? nextBatch,
  }) async {
    final result = await _requireClient().queryPublicRooms(
      filter: matrix.PublicRoomQueryFilter(genericSearchTerm: query.trim()),
      limit: 20,
      since: nextBatch,
    );
    return PublicRoomPage(
      rooms: List.unmodifiable(
        result.chunk.map(
          (room) => PublicRoom(
            id: room.roomId,
            name: room.name ?? room.canonicalAlias ?? room.roomId,
            members: room.numJoinedMembers,
            topic: room.topic,
            alias: room.canonicalAlias,
            avatarUrl: room.avatarUrl,
          ),
        ),
      ),
      nextBatch: result.nextBatch,
    );
  }

  @override
  Future<String> joinPublicRoom(String roomId) async {
    final client = _requireClient();
    if (client.getRoomById(roomId)?.membership == matrix.Membership.join) {
      return roomId;
    }
    final joinedId = await client.joinRoomById(roomId);
    await client.waitForRoomInSync(joinedId, join: true);
    _scheduleRoomUpdate();
    return joinedId;
  }

  @override
  Future<MessageSearchPage> searchMessages(
    String query, {
    String? nextBatch,
  }) async {
    final client = _requireClient();
    if (query.trim().length < 2) {
      return const MessageSearchPage(hits: []);
    }
    final response = await client.search(
      matrix.Categories(
        roomEvents: matrix.RoomEventsCriteria(
          searchTerm: query.trim(),
          filter: matrix.SearchFilter(
            limit: 20,
            types: [matrix.EventTypes.Message],
          ),
          orderBy: matrix.SearchOrder.recent,
        ),
      ),
      nextBatch: nextBatch,
    );
    final results = response.searchCategories.roomEvents;
    return MessageSearchPage(
      hits: List.unmodifiable([
        for (final item in results?.results ?? <matrix.Result>[])
          if (item.result case final event?)
            if (event.roomId case final roomId?)
              if (client.getRoomById(roomId) case final room?)
                if (room.membership == matrix.Membership.join)
                  if (event.content['body'] case final String body)
                    MessageHit(
                      id: event.eventId,
                      roomId: roomId,
                      roomName: room.getLocalizedDisplayname(),
                      sender: event.senderId,
                      body: body,
                      time: event.originServerTs,
                    ),
      ]),
      nextBatch: results?.nextBatch,
    );
  }

  @override
  Future<CryptoStatus> cryptoStatus() async {
    final state = await encryption.CryptoSetupExtension(
      _requireClient(),
    ).getCryptoIdentityState();
    return CryptoStatus(
      initialized: state.initialized,
      connected: state.connected,
      keyBackupEnabled: state.keyBackupEnabled,
      crossSigningEnabled: state.crossSigningEnabled,
    );
  }

  @override
  Future<void> restoreCryptoIdentity(String keyOrPassphrase) async {
    if (keyOrPassphrase.trim().isEmpty) {
      throw ArgumentError('Recovery credential required');
    }
    await encryption.CryptoSetupExtension(
      _requireClient(),
    ).restoreCryptoIdentity(keyOrPassphrase);
  }

  @override
  Future<void> restoreBackedUpKeys() async {
    final client = _requireClient();
    final state = await encryption.CryptoSetupExtension(
      client,
    ).getCryptoIdentityState();
    if (!state.connected || !state.keyBackupEnabled) {
      throw StateError('Key backup is not connected');
    }
    await client.encryption!.keyManager.loadAllKeys();
  }

  matrix.Client _requireClient() {
    final client = _client;
    if (client == null || _connection == SessionStatus.offline) {
      throw StateError('Matrix is not available');
    }
    return client;
  }

  void _setStatus(SessionStatus value) {
    _connection = value;
    if (!_disposed) notifyListeners();
  }

  void _scheduleRoomUpdate() {
    if (_roomUpdateTimer?.isActive ?? false) return;
    _roomUpdateTimer = Timer(const Duration(milliseconds: 40), _refreshRooms);
  }

  void _refreshRooms() {
    final client = _client;
    if (client == null || _disposed || !client.isLogged()) return;
    final joined =
        client.rooms
            .where(
              (r) =>
                  r.membership == matrix.Membership.join ||
                  r.membership == matrix.Membership.invite,
            )
            .toList()
          ..sort((a, b) {
            if (a.membership != b.membership) {
              return a.membership == matrix.Membership.invite ? -1 : 1;
            }
            return (b.lastEvent?.originServerTs ?? DateTime(1970)).compareTo(
              a.lastEvent?.originServerTs ?? DateTime(1970),
            );
          });
    _rooms = List.unmodifiable(
      joined.map((room) {
        final event = room.lastEvent;
        final name = room.getLocalizedDisplayname();
        final heroIds =
            room.summary.mHeroes ??
            [if (room.directChatMatrixID != null) room.directChatMatrixID!];
        return ChatRoom(
          id: room.id,
          name: name,
          preview: event?.type == matrix.EventTypes.Message
              ? event!.body
              : event?.type == matrix.EventTypes.Encrypted
              ? 'Encrypted message'
              : '',
          lastActivity: event?.originServerTs,
          unread: room.notificationCount,
          manuallyUnread: room.markedUnread,
          avatarUrl: room.avatar,
          encrypted: room.encrypted,
          isDirect: room.isDirectChat,
          invited: room.membership == matrix.Membership.invite,
          heroes: [
            for (final id
                in heroIds
                    .where((id) => id != client.userID && id.isNotEmpty)
                    .take(4))
              ChatAvatar(
                name: room
                    .unsafeGetUserFromMemoryOrFallback(id)
                    .calcDisplayname(),
                url: room.unsafeGetUserFromMemoryOrFallback(id).avatarUrl,
              ),
          ],
        );
      }),
    );
    notifyListeners();
  }

  void _refreshMessages(matrix.Timeline timeline) {
    final client = _client;
    if (_disposed || timeline != _timeline || client == null) return;
    _messages = List.unmodifiable(
      timeline.events
          .take(_visibleMessageLimit)
          .where(
            (event) =>
                event.type == matrix.EventTypes.Message ||
                event.type == matrix.EventTypes.Encrypted,
          )
          .map((event) {
            final display = event.getDisplayEvent(timeline);
            return ChatEntry(
              id: event.eventId,
              sender: event.senderId,
              body: display.type == matrix.EventTypes.Encrypted
                  ? '🔒 Unable to decrypt this message'
                  : display.body,
              time: event.originServerTs,
              mine: event.senderId == client.userID,
              isImage: display.messageType == matrix.MessageTypes.Image,
              isAttachment: {
                matrix.MessageTypes.File,
                matrix.MessageTypes.Audio,
                matrix.MessageTypes.Video,
              }.contains(display.messageType),
            );
          })
          .toList()
          .reversed,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _roomUpdateTimer?.cancel();
    _syncSubscription?.cancel();
    _loginSubscription?.cancel();
    _timeline?.cancelSubscriptions();
    final client = _client;
    if (client != null) unawaited(client.dispose());
    super.dispose();
  }
}

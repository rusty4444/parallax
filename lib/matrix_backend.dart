import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vodozemac;
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:matrix/encryption.dart' as encryption;
import 'package:matrix/matrix.dart' as matrix;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:vodozemac/vodozemac.dart' as vod;

import 'chat_backend.dart';
import 'crypto_setup_policy.dart';
import 'features/scheduled/undo_send.dart';
import 'crypto_signature_validation.dart';
import 'encrypted_media.dart';
import 'features/rich_timeline/message_composition.dart';
import 'homeserver_security.dart';
import 'key_query_validation.dart';
import 'media_download.dart';
import 'matrix_send_guard.dart';
import 'message_text.dart';
import 'recipient_trust.dart';
import 'reaction_summary.dart';
import 'room_creation_request.dart';
import 'room_details.dart';
import 'room_events.dart';
import 'timeline_kinds.dart';
import 'room_join.dart';
import 'safe_matrix_database.dart';
import 'matrix_auth_service.dart';
import 'matrix_room_features.dart';
import 'message_outbox.dart';
import 'messaging_features.dart';
import 'queued_media_sender.dart';
import 'push_notifications.dart';
import 'secure_store.dart';
import 'send_cancellation.dart';
import 'hooks/registry.dart' show transformOutgoingText;
import 'hooks/hook_types.dart' show OutgoingTextContext;

/// One SDK client and one active timeline for the lifetime of the app.
class MatrixBackend extends ChatBackend
    implements
        MessagingFeatures,
        RecoverableRoomJoining,
        RoomEventFeatures,
        MatrixSdkAccess,
        UndoSendFeatures {
  MatrixBackend({
    bool Function()? sendReadReceipts,
    bool Function()? sendTypingNotifications,
    this.localStorage,
    this.beforeLogout,
    Future<Duration> Function()? undoSendDelay,
  }) : _sendReadReceipts = sendReadReceipts ?? (() => true),
       _sendTypingNotifications = sendTypingNotifications ?? (() => true),
       _undoSendDelay =
           undoSendDelay ?? UndoSendPreferences.shared.resolveDelay;

  @visibleForTesting
  factory MatrixBackend.withClient(
    matrix.Client client, {
    SecureValueStore? localStorage,
    Future<void> Function()? beforeLogout,
    Future<Duration> Function()? undoSendDelay,
  }) {
    final backend = MatrixBackend(
      localStorage: localStorage,
      beforeLogout: beforeLogout,
      undoSendDelay: undoSendDelay,
    );
    backend._client = client;
    client.onSoftLogout = backend._refreshAuthentication;
    backend._connection = client.isLogged()
        ? SessionStatus.ready
        : SessionStatus.signedOut;
    return backend;
  }

  final bool Function() _sendReadReceipts;
  final bool Function() _sendTypingNotifications;
  final Future<void> Function()? beforeLogout;
  final SecureValueStore? localStorage;
  // Undo send (lib/features/scheduled): grace period for new sends, the
  // background listener that releases held sends, and the queued-transmit
  // lane that lets several held sends fall due together.
  final Future<Duration> Function() _undoSendDelay;
  AppLifecycleListener? _heldSendLifecycle;
  Future<void> _queuedTransmitTail = Future<void>.value();
  String? _outboxAccount;
  Future<void>? _outboxRestoring;
  late final MessageOutbox _outbox = MessageOutbox(
    storage: localStorage,
    currentAccount: () =>
        !_loggingOut && _client?.isLogged() == true ? _outboxIdentity : null,
    transmit: _transmitQueued,
    onChanged: () {
      if (!_disposed) notifyListeners();
    },
  );
  matrix.Client? _client;
  MatrixSendGuard? _sendGuard;
  matrix.Timeline? _timeline;
  StreamSubscription<matrix.SyncUpdate>? _syncSubscription;
  StreamSubscription<matrix.SyncStatusUpdate>? _syncStatusSubscription;
  StreamSubscription<matrix.LoginState>? _loginSubscription;
  StreamSubscription<matrix.SessionClearReason>? _sessionClearedSubscription;
  StreamSubscription<encryption.KeyVerification>? _verificationSubscription;
  encryption.KeyVerification? _verificationRequest;
  final _verificationQueue = Queue<encryption.KeyVerification>();
  VerificationDetails? _verificationDetails;
  bool _verificationStarting = false;
  bool _verificationBusy = false;
  bool _verificationSecretSkipped = false;
  String? _verificationError;
  int _verificationId = 0;
  int _securityGeneration = 0;
  TrustWarning? _trustWarning;
  Completer<bool>? _trustDecision;
  final _validatedRoster = <String, RoomRecipientSnapshot>{};
  Timer? _roomUpdateTimer;
  int _roomGeneration = 0;
  bool _disposed = false;
  bool _initializing = false;
  bool _loggingOut = false;
  bool _passwordLoginBusy = false;
  bool _requiresReauthentication = false;
  bool _cryptoSetupBusy = false;
  bool _refreshingRooms = false;
  bool _firstSyncCompleted = false;
  int _successfulSyncs = 0;
  bool _sending = false;
  bool _loadingHistory = false;
  int _visibleMessageLimit = 100;
  String? _activeRoomId;
  String? _error;
  SessionStatus _connection = SessionStatus.loading;
  RoomSyncState _roomSyncState = RoomSyncState.loading;
  RoomSyncIssue? _roomSyncIssue;
  List<ChatRoom> _rooms = const [];
  List<ChatEntry> _messages = const [];
  final _imageCache = <String, Uint8List>{};
  int _imageCacheBytes = 0;
  final _avatarCache = <Uri, Uint8List>{};
  final _avatarInFlight = <Uri, Future<Uint8List?>>{};
  final _avatarWaiters = Queue<Completer<void>>();
  int _avatarActive = 0;
  final _reactionInFlight = <String>{};

  @override
  SessionStatus get connection => _connection;
  @override
  RoomSyncState get roomSyncState => _roomSyncState;
  @override
  RoomSyncIssue? get roomSyncIssue => _roomSyncIssue;
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
  List<String> get typingUsers {
    final client = _client;
    final room = client?.getRoomById(_activeRoomId ?? '');
    if (room == null) return const [];
    return [
      for (final user in room.typingUsers)
        if (user.id != client!.userID) user.calcDisplayname(),
    ];
  }

  @override
  VerificationDetails? get verification => _verificationDetails;
  @override
  TrustWarning? get trustWarning => _trustWarning;

  @override
  String get accountKey {
    final client = _client;
    if (client?.userID == null || client?.homeserver == null) return '';
    return jsonEncode([client!.homeserver.toString(), client.userID]);
  }

  // Matrix transaction IDs are device-scoped. Hard re-login must not replay an
  // ambiguous send from the former device, while drafts remain account-scoped.
  String? get _outboxIdentity {
    final client = _client;
    if (accountKey.isEmpty || client?.deviceID == null) return null;
    return jsonEncode([
      client!.homeserver.toString(),
      client.userID,
      client.deviceID,
    ]);
  }

  String? get pushSessionKey =>
      !_disposed &&
          !_loggingOut &&
          _connection == SessionStatus.ready &&
          _client?.isLogged() == true
      ? _outboxIdentity
      : null;

  PushSession? createPushSession(
    Future<void> Function(PushNavigationRequest) onNavigate,
  ) {
    final client = _client;
    if (pushSessionKey == null || client == null) return null;
    final user = client.userID!;
    final device = client.deviceID!;
    final generation = _securityGeneration;
    bool sameCredentials() =>
        !_disposed &&
        identical(_client, client) &&
        client.userID == user &&
        client.deviceID == device &&
        client.isLogged();
    void check() {
      if (!sameCredentials()) {
        throw StateError('Push session credentials changed');
      }
    }

    return PushSession(
      userId: user,
      deviceId: device,
      registerPusher: (registration) async {
        check();
        if (_loggingOut || generation != _securityGeneration) {
          throw StateError('Push registration belongs to a retired session');
        }
        await client.postPusher(registration.pusher, append: false);
        check();
        final pushers = await client.getPushers();
        check();
        if (!(pushers ?? []).any(
          (p) =>
              p.appId == registration.pusher.appId &&
              p.pushkey == registration.pusher.pushkey &&
              p.kind == 'http' &&
              p.data.format == 'event_id_only' &&
              p.data.url == registration.configuration.gatewayUrl &&
              p.data.additionalProperties['registration_id'] ==
                  registration.registrationId,
        )) {
          throw StateError('Push registration could not be verified');
        }
      },
      removePusher: (registration) async {
        // Cleanup survives local invalidation, but never borrows another
        // account's mutable credentials. Logout joins it before SDK logout.
        check();
        await client.deletePusher(registration.pusherId);
        check();
        final pushers = await client.getPushers();
        check();
        if (pushers == null ||
            pushers.any(
              (p) =>
                  p.appId == registration.pusherId.appId &&
                  p.pushkey == registration.pusherId.pushkey,
            )) {
          throw StateError('Push removal could not be verified');
        }
      },
      onNavigate: onNavigate,
    );
  }

  @override
  List<PendingSend> get pendingSends => [
    for (final record in _outbox.records)
      if (record.accountKey == _outboxIdentity)
        PendingSend(
          id: record.id,
          roomId: record.roomId,
          body: record.body,
          state: record.state,
          createdAt: record.createdAt,
          fileName: record.media?.name,
          error: record.error,
          progress: record.progress,
        ),
  ];

  MatrixAuthService _authService(matrix.Client client) {
    final generation = _securityGeneration;
    return MatrixAuthService(
      client,
      storage: localStorage,
      ownerCurrent: () =>
          !_disposed &&
          !_loggingOut &&
          identical(_client, client) &&
          _securityGeneration == generation,
    );
  }

  Future<void> _refreshAuthentication(matrix.Client client) async {
    final generation = _securityGeneration;
    try {
      await _authService(client).refresh();
      if (!_disposed &&
          identical(_client, client) &&
          generation == _securityGeneration) {
        _requiresReauthentication = false;
      }
    } on ReauthenticationRequired {
      if (!_disposed &&
          identical(_client, client) &&
          generation == _securityGeneration) {
        _requiresReauthentication = true;
        _error = 'Sign in again to reconnect the existing Matrix session.';
        _setStatus(SessionStatus.signedOut);
      }
      rethrow;
    }
  }

  @override
  Future<ProviderDiscovery> discoverProvider(String input) {
    final client = _requireClient();
    _requireAuthenticationAvailable(client);
    return _authService(client).discover(input);
  }

  @override
  Future<void> loginWithBrowser(
    ProviderDiscovery discovery, {
    required bool oidc,
  }) async {
    final client = _requireClient();
    _requireAuthenticationAvailable(client);
    final generation = _securityGeneration;
    await _authService(client).browserLogin(discovery, oidc: oidc);
    if (_disposed ||
        !identical(_client, client) ||
        generation != _securityGeneration) {
      throw StateError('Authentication session changed');
    }
    _requiresReauthentication = false;
    _setStatus(SessionStatus.ready);
    _scheduleRoomUpdate();
    _restoreOutboxQuietly();
  }

  MatrixRoomFeatures _roomFeatures() {
    final client = _requireClient();
    final generation = _securityGeneration;
    return MatrixRoomFeatures(
      client,
      ownerCurrent: () =>
          !_disposed &&
          identical(_client, client) &&
          client.isLogged() &&
          generation == _securityGeneration,
      mapEvent: (event) => _projectEntry(
        event,
        _timeline?.room.id == event.room.id ? _timeline : null,
      ),
    );
  }

  @override
  Future<List<DirectoryUser>> searchUsers(String query) =>
      _roomFeatures().searchUsers(query);
  @override
  List<SpaceSummary> get spaces =>
      _client?.isLogged() == true ? _roomFeatures().spaces : const [];
  @override
  Future<SpacePage> loadSpace(String spaceId, {String? nextBatch}) =>
      _roomFeatures().loadSpace(spaceId, nextBatch: nextBatch);
  @override
  Future<ThreadPage> loadThread(
    String roomId,
    String rootEventId, {
    String? nextBatch,
  }) => _roomFeatures().loadThread(roomId, rootEventId, nextBatch: nextBatch);
  @override
  Future<List<MessageReader>> messageReaders(String roomId, String eventId) =>
      _roomFeatures().messageReaders(roomId, eventId);
  @override
  bool isFavourite(String roomId) =>
      _client?.isLogged() == true && _roomFeatures().isFavourite(roomId);
  @override
  Future<void> setFavourite(String roomId, bool favourite) async {
    await _roomFeatures().setFavourite(roomId, favourite);
    _scheduleRoomUpdate();
  }

  Future<void> _restoreOutbox() {
    if (_loggingOut || _client?.isLogged() != true || _outboxIdentity == null) {
      throw StateError('No signed-in account');
    }
    final owner = _outboxIdentity!;
    if (_outboxAccount == owner && _outboxRestoring != null) {
      return _outboxRestoring!;
    }
    _outboxAccount = owner;
    final pending = _outbox.restore(owner);
    _outboxRestoring = pending;
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_outboxRestoring, pending)) {
            _outboxAccount = null;
            _outboxRestoring = null;
          }
        },
      ),
    );
    return pending;
  }

  void _restoreOutboxQuietly() {
    final owner = _outboxIdentity;
    final generation = _securityGeneration;
    unawaited(
      _restoreOutbox().catchError((Object _) {
        if (_disposed ||
            generation != _securityGeneration ||
            owner != _outboxIdentity) {
          return;
        }
        _error =
            'The encrypted outbox could not be opened. No saved messages were replaced.';
        _outboxAccount = null;
        _outboxRestoring = null;
        notifyListeners();
      }),
    );
  }

  @override
  Future<void> queueMessage(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
    String? threadRootId,
  }) async {
    if (text.trim().isEmpty) return;
    final owner = _outboxIdentity ?? '';
    final generation = _securityGeneration;
    // Undo send holds new main-timeline messages. Edits and thread replies
    // (no undo surface in the thread screen) go straight out.
    final hold = editEventId == null && threadRootId == null
        ? await _undoSendHold()
        : Duration.zero;
    await _restoreOutbox();
    _requireQueueOwner(owner, generation);
    await _outbox.enqueueText(
      owner,
      roomId,
      text,
      replyToId: replyToId,
      editEventId: editEventId,
      threadRootId: threadRootId,
      hold: hold,
    );
    if (hold > Duration.zero) _watchHeldSends();
  }

  @override
  Future<void> queueMedia(
    String roomId,
    MediaSelection media, {
    String? caption,
    String? replyToId,
    String? threadRootId,
  }) async {
    final owner = _outboxIdentity ?? '';
    final generation = _securityGeneration;
    final hold = threadRootId == null ? await _undoSendHold() : Duration.zero;
    await _restoreOutbox();
    _requireQueueOwner(owner, generation);
    await _outbox.enqueueMedia(
      owner,
      roomId,
      media,
      caption: caption,
      replyToId: replyToId,
      threadRootId: threadRootId,
      hold: hold,
    );
    if (hold > Duration.zero) _watchHeldSends();
  }

  Future<Duration> _undoSendHold() async {
    try {
      final delay = await _undoSendDelay();
      if (delay.isNegative) return Duration.zero;
      return delay > MessageOutbox.maxHold ? MessageOutbox.maxHold : delay;
    } catch (_) {
      return Duration.zero;
    }
  }

  /// Held sends go out as soon as the app is backgrounded: the OS may freeze
  /// or kill a background process before the grace period ends.
  void _watchHeldSends() {
    if (_disposed) return;
    _heldSendLifecycle ??= watchAppBackground(_outbox.releaseHeld);
  }

  @override
  DateTime? undoDeadline(String pendingId) => _outbox.heldUntil(pendingId);

  @override
  Future<UndoneSend?> undoSend(String pendingId) async {
    final record = await _outbox.undo(pendingId);
    if (record == null) return null;
    final media = record.media;
    return UndoneSend(
      text: media == null ? record.body : record.caption ?? '',
      replyToId: record.replyToId,
      threadRootId: record.threadRootId,
      attachmentName: media?.name,
    );
  }

  @override
  Future<void> retryPending(String id) => _outbox.retry(id);
  @override
  Future<void> discardPending(String id) => _outbox.discard(id);
  @override
  void cancelPending(String id) => _outbox.cancel(id);

  void _requireQueueOwner(String owner, int generation) {
    if (_disposed ||
        _loggingOut ||
        owner.isEmpty ||
        owner != _outboxIdentity ||
        generation != _securityGeneration ||
        _client?.isLogged() != true) {
      throw StateError('The account changed before saving this message');
    }
  }

  Future<void> _transmitQueued(
    OutboxRecord record,
    SendCancellation cancellation,
    void Function(double) onProgress,
  ) async {
    // Held sends can fall due together (deadline or app pause): queue their
    // transmissions behind each other instead of failing later ones as busy.
    final previous = _queuedTransmitTail;
    final turn = Completer<void>();
    _queuedTransmitTail = Future.wait<void>([
      previous,
      turn.future,
    ]).then((_) {});
    try {
      await Future.any<void>([previous, cancellation.whenCancelled]);
      await _transmitQueuedNow(record, cancellation, onProgress);
    } finally {
      turn.complete();
    }
  }

  Future<void> _transmitQueuedNow(
    OutboxRecord record,
    SendCancellation cancellation,
    void Function(double) onProgress,
  ) async {
    final client = _requireClient();
    final generation = _securityGeneration;
    bool current() =>
        !_disposed &&
        !_loggingOut &&
        identical(_client, client) &&
        generation == _securityGeneration &&
        record.accountKey == _outboxIdentity &&
        client.onLoginStateChanged.value == matrix.LoginState.loggedIn;
    void check() {
      cancellation.check();
      if (!current()) {
        throw StateError('Send belongs to an unavailable session');
      }
    }

    check();
    if (_sending || _cryptoSetupBusy) {
      throw StateError('Another secure operation is running');
    }
    final room = client.getRoomById(record.roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is no longer joined');
    }
    _sending = true;
    notifyListeners();
    try {
      await MatrixSendGuard.cancellable(cancellation, () async {
        final reply = record.replyToId == null
            ? null
            : await room.getEventById(record.replyToId!);
        check();
        if (record.replyToId != null && (reply == null || reply.redacted)) {
          throw StateError('Reply target is unavailable');
        }
        matrix.Event? edited;
        if (record.editEventId != null) {
          final edit = await room.getEventById(record.editEventId!);
          check();
          if (edit == null ||
              edit.redacted ||
              edit.senderId != client.userID ||
              edit.messageType != matrix.MessageTypes.Text) {
            throw StateError('Message can no longer be edited');
          }
          edited = edit;
        }
        await _ensureTrusted(room, cancellation: cancellation);
        check();
        _requireEncryptedTransport(room);
        await MatrixSendGuard.cancellable(
          cancellation,
          () => _protectSend(room, () async {
            final media = record.media;
            if (media != null) {
              await sendQueuedAttachment(
                client: client,
                room: room,
                media: media,
                transactionId: record.id,
                ownerCurrent: current,
                cancellation: cancellation,
                onProgress: onProgress,
                caption: record.caption,
                inReplyTo: reply,
                threadRootId: record.threadRootId,
              );
            } else {
              // The outbox stores plain text; markdown, /me and m.mentions
              // are derived deterministically here (rich_timeline module).
              final isEdit = record.editEventId != null;
              final eventId = await room.sendEvent(
                transformOutgoingText(
                  OutgoingTextContext(
                    backend: this,
                    roomId: room.id,
                    text: record.body,
                    editing: isEdit,
                  ),
                  composeTextMessage(
                    record.body,
                    ownUserId: client.userID,
                    replyToSender: reply?.senderId,
                    editEventId: record.editEventId,
                    previousMentions: mentionedUserIds(edited?.content),
                  ),
                ),
                txid: record.id,
                inReplyTo: isEdit ? null : reply,
                threadRootEventId: isEdit ? null : record.threadRootId,
              );
              check();
              if (eventId == null) {
                throw StateError('Message was not acknowledged');
              }
              onProgress(1);
            }
          }),
        );
      });
    } catch (_) {
      if (cancellation.isCancelled) throw const SendCancelled();
      rethrow;
    } finally {
      if (!_disposed && generation == _securityGeneration) {
        _sending = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> initialize() async {
    if (_disposed || _initializing || _client != null) return;
    _initializing = true;
    _setStatus(SessionStatus.loading);
    sqlite.Database? openedDatabase;
    matrix.Client? openedClient;
    void checkStartup() {
      if (_disposed) throw StateError('Startup owner was disposed');
    }

    try {
      await vodozemac.init();
      checkStartup();
      final directory = await getApplicationSupportDirectory();
      checkStartup();
      openedDatabase = await sqlite.openDatabase(
        path.join(directory.path, 'parallax.db'),
      );
      checkStartup();
      final sdkDatabase = SafeMatrixDatabase(
        'parallax',
        database: openedDatabase,
      );
      await sdkDatabase.open();
      await sdkDatabase.dropLegacyEncryptedQueue();
      final storedUrl = (await sdkDatabase.getClient(
        'Parallax',
      ))?['homeserver_url'];
      checkStartup();
      if (storedUrl != null &&
          (storedUrl is! String ||
              !isSecureHomeserver(Uri.tryParse(storedUrl)))) {
        throw StateError('Stored Matrix session has an insecure homeserver');
      }
      final sendGuard = MatrixSendGuard(
        http.Client(),
        encryptionAvailable: () => _client?.encryptionEnabled == true,
        isEncryptedRoom: (id) => _client?.getRoomById(id)?.encrypted == true,
      );
      _sendGuard = sendGuard;
      openedClient = matrix.Client(
        'Parallax',
        database: sdkDatabase,
        httpClient: sendGuard,
        supportedLoginTypes: {
          matrix.AuthenticationTypes.password,
          matrix.AuthenticationTypes.sso,
          matrix.AuthenticationTypes.token,
        },
        onSoftLogout: _refreshAuthentication,
        verificationMethods: {
          encryption.KeyVerificationMethod.emoji,
          encryption.KeyVerificationMethod.numbers,
        },
        defaultNetworkRequestTimeout: const Duration(seconds: 90),
      );
      final client = openedClient;
      _client = client;
      _syncSubscription = client.onSync.stream.listen((_) {
        _firstSyncCompleted = true;
        _successfulSyncs++;
        _scheduleRoomUpdate();
      });
      _syncStatusSubscription = client.onSyncStatus.stream.listen(
        _handleSyncStatus,
      );
      _verificationSubscription = client.onKeyVerificationRequest.stream.listen(
        (request) => _offerVerification(request, incoming: true),
      );
      _sessionClearedSubscription = client.onSessionCleared.stream.listen((_) {
        _resetSessionView();
        _setStatus(SessionStatus.signedOut);
      });
      await client.init(
        waitForFirstSync: false,
        waitUntilLoadCompletedLoaded: true,
      );
      checkStartup();
      _loginSubscription = client.onLoginStateChanged.stream.listen((
        loginState,
      ) {
        if (_disposed) return;
        if (!client.isLogged()) _resetSessionView();
        if (loginState == matrix.LoginState.loggedIn) {
          _requiresReauthentication = false;
        }
        _setStatus(
          client.isLogged() && !_requiresReauthentication
              ? SessionStatus.ready
              : SessionStatus.signedOut,
        );
        _scheduleRoomUpdate();
        if (loginState == matrix.LoginState.loggedIn) _restoreOutboxQuietly();
      });
      _setStatus(
        client.isLogged() && !_requiresReauthentication
            ? SessionStatus.ready
            : SessionStatus.signedOut,
      );
      _scheduleRoomUpdate();
      if (client.onLoginStateChanged.value == matrix.LoginState.loggedIn) {
        _restoreOutboxQuietly();
      }
    } catch (_) {
      await _syncSubscription?.cancel();
      await _syncStatusSubscription?.cancel();
      await _loginSubscription?.cancel();
      await _verificationSubscription?.cancel();
      await _sessionClearedSubscription?.cancel();
      _syncSubscription = null;
      _syncStatusSubscription = null;
      _loginSubscription = null;
      _verificationSubscription = null;
      _sessionClearedSubscription = null;
      _clearSecurityPrompts();
      if (openedClient != null) {
        await openedClient.dispose();
      } else {
        _sendGuard?.close();
        await openedDatabase?.close();
      }
      _client = null;
      _sendGuard = null;
      if (_disposed) return;
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
    _requireAuthenticationAvailable(client);
    _passwordLoginBusy = true;
    final generation = _securityGeneration;
    void check() {
      if (_disposed ||
          _loggingOut ||
          !identical(_client, client) ||
          generation != _securityGeneration) {
        throw StateError('Authentication session changed');
      }
    }

    try {
      final url = Uri.parse(homeserver);
      if (!isSecureHomeserver(url)) {
        throw const FormatException('An HTTPS homeserver URL is required.');
      }
      if (client.onLoginStateChanged.value == matrix.LoginState.softLoggedOut) {
        if (url != client.homeserver) {
          throw StateError(
            'Re-authentication must use the existing homeserver',
          );
        }
        await _authService(client).reauthenticatePassword(username, password);
        check();
      } else {
        if (client.isLogged()) {
          throw StateError('Sign out before replacing an account');
        }
        final discovery = await _authService(client).discover(homeserver);
        check();
        _firstSyncCompleted = false;
        _roomSyncState = RoomSyncState.loading;
        _roomSyncIssue = null;
        await _authService(client).passwordLogin(discovery, username, password);
        check();
      }
      _requiresReauthentication = false;
      _setStatus(SessionStatus.ready);
      _scheduleRoomUpdate();
      _restoreOutboxQuietly();
    } finally {
      _passwordLoginBusy = false;
    }
  }

  void _requireAuthenticationAvailable(matrix.Client client) {
    if (_disposed ||
        _loggingOut ||
        _cryptoSetupBusy ||
        _passwordLoginBusy ||
        _authService(client).busy ||
        MatrixAuthService.isApplyingSession(client)) {
      throw StateError('Wait for the current account operation to finish');
    }
  }

  @override
  Future<void> logout() async {
    final client = _requireClient();
    if (_loggingOut ||
        _cryptoSetupBusy ||
        _passwordLoginBusy ||
        MatrixAuthService.isApplyingSession(client)) {
      throw StateError(
        'Wait for the current account operation before signing out',
      );
    }
    _loggingOut = true;
    try {
      // Invalidate synchronously, then join sends and push cleanup before the
      // SDK may erase/change credentials used by those operations.
      _clearSecurityPrompts();
      await _outbox.closeAccount();
      _outboxAccount = null;
      _outboxRestoring = null;
      _sending = false;
      await beforeLogout?.call();
      if (_disposed || !identical(client, _client)) {
        throw StateError('Session changed during logout');
      }
      closeRoom(_activeRoomId ?? '');
      await client.logout();
      _resetSessionView();
      _setStatus(SessionStatus.signedOut);
    } finally {
      _loggingOut = false;
      if (!_disposed) notifyListeners();
    }
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
    _focusedEventId = null;
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
    if (_sendReadReceipts() && room.isUnread && created.events.isNotEmpty) {
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

  // --- Jump to event (lib/features/threads/timeline_navigation.dart) ------

  String? _focusedEventId;
  bool _focusHasNewer = false;

  /// Event the active timeline is focused on after [openRoomAt], or null
  /// while the active timeline shows the live end of the room.
  String? get focusedEventId =>
      _timeline == null || _activeRoomId == null ? null : _focusedEventId;

  /// Whether messages newer than the focused event exist (or arrived) and are
  /// hidden. Always true for a server-fetched (fragmented) context.
  bool get focusHasNewer {
    final timeline = _timeline;
    final focus = focusedEventId;
    if (timeline == null || focus == null) return false;
    return _focusHasNewer ||
        timeline.canRequestFuture ||
        timeline.events.indexWhere((event) => event.eventId == focus) > 0;
  }

  /// Opens [roomId] with its timeline loaded around [eventId] (search results,
  /// permalinks, pinned messages). Messages newer than the event stay hidden
  /// until [jumpToLatest], so the event is the newest visible entry. Sync
  /// updates keep flowing; a server-fetched context switches to the live
  /// timeline on [jumpToLatest]. Read receipts are not sent for a focused
  /// timeline because the latest messages have not been seen.
  Future<void> openRoomAt(String roomId, String eventId) async {
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    if (!eventId.startsWith(r'$')) throw ArgumentError.value(eventId);
    _roomGeneration++;
    final generation = _roomGeneration;
    final security = _securityGeneration;
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _activeRoomId = roomId;
    _focusedEventId = eventId;
    _focusHasNewer = false;
    _visibleMessageLimit = 100;
    _loadingHistory = false;
    _messages = const [];
    notifyListeners();
    bool current() =>
        generation == _roomGeneration &&
        security == _securityGeneration &&
        !_disposed &&
        isSessionCurrent(client);
    matrix.Timeline? created;
    try {
      created = await room.getTimeline(
        eventContextId: eventId,
        onUpdate: () {
          if (current() && created != null) _refreshMessages(created);
        },
        onNewEvent: () {
          if (current() && !_focusHasNewer && _focusedEventId != null) {
            _focusHasNewer = true;
            notifyListeners();
          }
        },
      );
    } catch (_) {
      if (current()) {
        _activeRoomId = null;
        _focusedEventId = null;
        notifyListeners();
      }
      rethrow;
    }
    if (!current()) {
      created.cancelSubscriptions();
      throw StateError('Room changed while jumping to the message');
    }
    if (!created.events.any((event) => event.eventId == eventId)) {
      created.cancelSubscriptions();
      _activeRoomId = null;
      _focusedEventId = null;
      notifyListeners();
      throw StateError('Message unavailable');
    }
    _timeline = created;
    _refreshMessages(created);
  }

  /// Leaves a focused timeline for the live end of [roomId].
  Future<void> jumpToLatest(String roomId) async {
    final timeline = _timeline;
    if (_activeRoomId != roomId || _focusedEventId == null) return;
    _focusedEventId = null;
    _focusHasNewer = false;
    if (timeline != null && !timeline.canRequestFuture) {
      // The context was the cached live timeline: just reveal newer entries.
      _refreshMessages(timeline);
      return;
    }
    _timeline?.cancelSubscriptions();
    _timeline = null;
    await openRoom(roomId);
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
    final generation = _securityGeneration;
    _loadingHistory = true;
    notifyListeners();
    try {
      _visibleMessageLimit += 50;
      if (timeline.events.length < _visibleMessageLimit &&
          timeline.canRequestHistory) {
        await timeline.requestHistory(historyCount: 50);
      }
      if (_securityGeneration == generation && _timeline == timeline) {
        _refreshMessages(timeline);
      }
    } finally {
      if (_securityGeneration == generation) {
        _loadingHistory = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  @override
  void closeRoom(String roomId) {
    if (_activeRoomId != roomId) return;
    _roomGeneration++;
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _focusedEventId = null;
    _activeRoomId = null;
    _messages = const [];
  }

  @override
  Future<void> sendText(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
  }) async {
    if (_sending) throw StateError('A send is already in progress');
    if (text.trim().isEmpty) return;
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    if (replyToId != null && editEventId != null) {
      throw ArgumentError('Cannot reply and edit in the same message');
    }
    final timeline = _timeline;
    if ((replyToId != null || editEventId != null) &&
        (_activeRoomId != roomId || timeline == null)) {
      throw StateError('Message unavailable');
    }
    final generation = _securityGeneration;
    final owner = _sendOwnership(client, room, generation);
    _sending = true;
    notifyListeners();
    try {
      await MatrixSendGuard.owned(owner, () async {
        final reply = replyToId == null
            ? null
            : await timeline!.getEventById(replyToId);
        _checkSendOwner(owner);
        if (replyToId != null && (reply == null || reply.redacted)) {
          throw StateError('Reply target unavailable');
        }
        matrix.Event? edited;
        if (editEventId != null) {
          final original = await timeline!.getEventById(editEventId);
          _checkSendOwner(owner);
          if (original == null ||
              original.redacted ||
              original.senderId != _requireClient().userID ||
              original.type != matrix.EventTypes.Message ||
              original.messageType != matrix.MessageTypes.Text) {
            throw StateError('Message cannot be edited');
          }
          edited = original;
        }
        if ((replyToId != null || editEventId != null) &&
            (_activeRoomId != roomId || _timeline != timeline)) {
          throw StateError('Room changed before sending');
        }
        await _ensureTrusted(room);
        _checkSendOwner(owner);
        if ((replyToId != null || editEventId != null) &&
            (_activeRoomId != roomId || _timeline != timeline)) {
          throw StateError('Room changed before sending');
        }
        _requireEncryptedTransport(room);
        // Markdown, /me and m.mentions are derived from the plain text here
        // (rich_timeline module); the guards above are unchanged.
        final content = transformOutgoingText(
          OutgoingTextContext(
            backend: this,
            roomId: roomId,
            text: text.trim(),
            editing: editEventId != null,
          ),
          composeTextMessage(
            text.trim(),
            ownUserId: client.userID,
            replyToSender: reply?.senderId,
            editEventId: editEventId,
            previousMentions: mentionedUserIds(edited?.content),
          ),
        );
        final sentId = await _protectSend(
          room,
          () => room.sendEvent(
            content,
            inReplyTo: editEventId == null ? reply : null,
          ),
          ownerCurrent: owner,
        );
        if (sentId == null) throw StateError('Message was not sent');
      });
    } finally {
      if (_securityGeneration == generation) {
        _sending = false;
        if (!_disposed) notifyListeners();
      }
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
    final generation = _securityGeneration;
    final owner = _sendOwnership(client, room, generation);
    _sending = true;
    notifyListeners();
    try {
      await MatrixSendGuard.owned(owner, () async {
        for (final image in images) {
          final size = await image.length();
          _checkSendOwner(owner);
          if (size == 0 || size > 20 * 1024 * 1024) {
            throw ArgumentError('Each image must be under 20 MB');
          }
        }
        await _ensureTrusted(room);
        for (final image in images) {
          final bytes = await _readSendMedia(image, owner);
          _checkSendOwner(owner);
          _requireEncryptedTransport(room);
          final matrixFile = matrix.MatrixImageFile(
            bytes: bytes,
            name: image.name,
          );
          if (room.encrypted) {
            await _protectSend(
              room,
              () => sendEncryptedMedia(
                client: client,
                room: room,
                file: matrixFile,
                shrinkImageMaxDimension: 1600,
                canSend: () =>
                    _securityGeneration == generation &&
                    _client == client &&
                    client.isLogged(),
              ),
              ownerCurrent: owner,
            );
          } else {
            final sentId = await _protectSend(
              room,
              () =>
                  room.sendFileEvent(matrixFile, shrinkImageMaxDimension: 1600),
              ownerCurrent: owner,
            );
            if (sentId == null) throw StateError('Image was not sent');
          }
        }
      });
    } finally {
      if (_securityGeneration == generation) {
        _sending = false;
        if (!_disposed) notifyListeners();
      }
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
    final generation = _securityGeneration;
    final owner = _sendOwnership(client, room, generation);
    _sending = true;
    notifyListeners();
    try {
      await MatrixSendGuard.owned(owner, () async {
        final size = await file.length();
        _checkSendOwner(owner);
        if (size <= 0 || size > 20 * 1024 * 1024) {
          throw ArgumentError('Choose a file smaller than 20 MB');
        }
        await _ensureTrusted(room);
        final bytes = await _readSendMedia(file, owner);
        _checkSendOwner(owner);
        _requireEncryptedTransport(room);
        final matrixFile = matrix.MatrixFile.fromMimeType(
          bytes: bytes,
          name: file.name,
        );
        if (room.encrypted) {
          await _protectSend(
            room,
            () => sendEncryptedMedia(
              client: client,
              room: room,
              file: matrixFile,
              canSend: () =>
                  _securityGeneration == generation &&
                  _client == client &&
                  client.isLogged(),
            ),
            ownerCurrent: owner,
          );
        } else {
          final sentId = await _protectSend(
            room,
            () => room.sendFileEvent(matrixFile),
            ownerCurrent: owner,
          );
          if (sentId == null) throw StateError('Attachment was not sent');
        }
      });
    } finally {
      if (_securityGeneration == generation) {
        _sending = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  @override
  Future<Uint8List?> loadImage(String roomId, String eventId) async {
    final key = '$roomId/$eventId';
    final timeline = _timeline;
    if (_activeRoomId != roomId || timeline == null) return null;
    final event = await timeline.getEventById(eventId);
    if (event == null ||
        event.redacted ||
        event.messageType != matrix.MessageTypes.Image) {
      final stale = _imageCache.remove(key);
      if (stale != null) _imageCacheBytes -= stale.lengthInBytes;
      return null;
    }
    final cached = _imageCache.remove(key);
    if (cached != null) {
      _imageCache[key] = cached;
      return cached;
    }
    const maxImageBytes = 8 * 1024 * 1024;
    if (!event.hasThumbnail &&
        event.infoMap['size'] is int &&
        (event.infoMap['size'] as int) > maxImageBytes) {
      return null;
    }
    final bytes = (await event.downloadAndDecryptAttachment(
      getThumbnail: true,
      downloadCallback: (uri) => _downloadMedia(uri, maxImageBytes),
    )).bytes;
    if (_activeRoomId != roomId ||
        _timeline != timeline ||
        event.redacted ||
        bytes.lengthInBytes > maxImageBytes) {
      return null;
    }
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
    final timeline = _timeline;
    if (_activeRoomId != roomId || timeline == null) {
      throw StateError('Room unavailable');
    }
    final event = await timeline.getEventById(eventId);
    if (event?.hasAttachment != true || event!.redacted) {
      throw StateError('Attachment unavailable');
    }
    final declared = event.infoMap['size'];
    if (declared is int && declared > 25 * 1024 * 1024) {
      throw StateError('Attachment is too large');
    }
    final file = await event.downloadAndDecryptAttachment(
      downloadCallback: (uri) => _downloadMedia(uri, 25 * 1024 * 1024),
    );
    if (_timeline != timeline ||
        _activeRoomId != roomId ||
        event.redacted ||
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
    final generation = _securityGeneration;
    if (_avatarActive >= 4) {
      final waiter = Completer<void>();
      _avatarWaiters.add(waiter);
      await waiter.future;
    } else {
      _avatarActive++;
    }
    try {
      final client = _client;
      if (client == null ||
          !client.isLogged() ||
          _disposed ||
          generation != _securityGeneration) {
        return null;
      }
      final thumbnail = await matrix.MxcUriExtension(
        url,
      ).getThumbnailUri(client, width: 96, height: 96);
      final homeserver = client.homeserver;
      final token = client.accessToken;
      if (homeserver == null || token == null) return null;
      final bytes = await downloadMatrixMedia(
        httpClient: client.httpClient,
        homeserver: homeserver,
        uri: thumbnail,
        accessToken: token,
        maxBytes: 1024 * 1024,
      );
      if (_client != client ||
          !client.isLogged() ||
          _disposed ||
          generation != _securityGeneration) {
        return null;
      }
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
  Future<void> react(
    String roomId,
    String eventId, {
    String emoji = '❤️',
  }) async {
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    final timeline = _timeline;
    if (room == null || timeline == null || _activeRoomId != roomId) {
      throw StateError('Room unavailable');
    }
    if (emoji.isEmpty || emoji.runes.length > 8) {
      throw ArgumentError('Invalid reaction');
    }
    final inFlightKey = '$roomId/$eventId/$emoji';
    if (!_reactionInFlight.add(inFlightKey)) return;
    try {
      final event = await timeline.getEventById(eventId);
      if (event == null ||
          event.redacted ||
          _timeline != timeline ||
          _activeRoomId != roomId) {
        throw StateError('Message unavailable');
      }
      final ownReaction = event
          .aggregatedEvents(timeline, matrix.RelationshipTypes.reaction)
          .where(
            (reaction) =>
                !reaction.redacted && reaction.senderId == client.userID,
          )
          .where(
            (reaction) =>
                (reaction.content['m.relates_to'] as Map?)?['key'] == emoji,
          )
          .firstOrNull;
      if (ownReaction == null) {
        // Encrypted rooms use the same recipient approval, fail-closed
        // encryption and final HTTP guard as messages. The content keeps the
        // SDK from sending a relation-only plaintext m.reaction (see
        // reactionEventContent); the guard refuses anything not encrypted.
        await _ensureTrusted(room);
        _requireEncryptedTransport(room);
        final sentId = await _protectSend(
          room,
          () => room.sendEvent(
            Map<String, dynamic>.of(
              reactionEventContent(eventId, emoji, encrypted: room.encrypted),
            ),
            type: matrix.EventTypes.Reaction,
          ),
        );
        if (sentId == null) throw StateError('Reaction was not sent');
      } else {
        await room.redactEvent(ownReaction.eventId);
      }
    } finally {
      _reactionInFlight.remove(inFlightKey);
    }
  }

  @override
  Future<void> redactMessage(String roomId, String eventId) async {
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    final timeline = _timeline;
    if (room == null || timeline == null || _activeRoomId != roomId) {
      throw StateError('Message unavailable');
    }
    final event = await timeline.getEventById(eventId);
    if (_timeline != timeline ||
        event == null ||
        event.redacted ||
        event.senderId != client.userID ||
        event.type != matrix.EventTypes.Message) {
      throw StateError('Only your own messages can be deleted');
    }
    await room.redactEvent(eventId, redactAllEdits: true);
  }

  @override
  Future<void> setTyping(String roomId, bool typing) async {
    // Privacy preference (Settings → Media & privacy). Stop notices are still
    // allowed so turning the preference off cannot leave a stale indicator.
    if (typing && !_sendTypingNotifications()) return;
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    final userId = client.userID;
    if (room == null ||
        userId == null ||
        room.membership != matrix.Membership.join) {
      return;
    }
    if (!room.encrypted) {
      await room.setTyping(typing, timeout: 5000);
      return;
    }
    // Client.setTyping also starts an unawaited Megolm session pre-share,
    // outside any recipient approval. The typing notification itself is a
    // plaintext EDU that carries no keys, so send only the EDU here and leave
    // key sharing to the guarded message send path.
    await client.request(
      matrix.RequestType.PUT,
      '/client/v3/rooms/${Uri.encodeComponent(roomId)}'
      '/typing/${Uri.encodeComponent(userId)}',
      data: {'typing': typing, if (typing) 'timeout': 5000},
    );
  }

  @override
  Future<void> createDirectChat(String userId) async {
    final id = await _requireClient().startDirectChat(userId);
    _activeRoomId = id;
    _scheduleRoomUpdate();
    notifyListeners();
  }

  @override
  Future<String> createRoom(String name, {required bool encrypted}) async {
    final value = name.trim();
    if (value.isEmpty || value.length > 255) {
      throw const RoomCreationFailure.notSubmitted(
        'Room name must be between 1 and 255 characters. Try again.',
      );
    }
    final client = _client;
    if (client == null ||
        _connection == SessionStatus.offline ||
        _disposed ||
        _loggingOut ||
        !client.isLogged()) {
      throw const RoomCreationFailure.notSubmitted(
        'Sign in and connect before creating a room, then try again.',
      );
    }
    final userId = client.userID;
    final deviceId = client.deviceID;
    if (encrypted && !client.encryptionEnabled) {
      throw const RoomCreationFailure.notSubmitted(
        'Encryption is unavailable. Set up encryption or explicitly turn off '
        'Encrypted room, then try again.',
      );
    }
    final generation = _securityGeneration;
    // Always pass the choice explicitly: the SDK otherwise decides whether to
    // encrypt a private room based on the client configuration.
    late final String roomId;
    try {
      roomId = await client.createGroupChat(
        groupName: value,
        preset: matrix.CreateRoomPreset.privateChat,
        enableEncryption: encrypted,
        // Keep the acknowledged ID even if the subsequent sync stalls. The UI
        // reconciles that ID with a bounded, cancellable wait instead of creating
        // a second room when sync cannot finish.
        waitForSync: false,
      );
    } on matrix.MatrixException catch (error) {
      // The SDK does not retain the HTTP status on generated API errors.
      // Only explicit refusal codes prove non-creation; M_UNKNOWN, generic
      // server errors, malformed replies and transport failures stay uncertain.
      if (!definiteRoomCreationRefusals.contains(error.errcode)) {
        rethrow;
      }
      throw const RoomCreationFailure.rejected();
    }
    if (_disposed ||
        _loggingOut ||
        generation != _securityGeneration ||
        !identical(_client, client) ||
        client.userID != userId ||
        client.deviceID != deviceId ||
        !client.isLogged()) {
      throw StateError('Session changed after creating the room');
    }
    _scheduleRoomUpdate();
    return roomId;
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
  Future<void> setRoomUnread(String roomId, bool unread) async {
    final room = _requireClient().getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    await room.markUnread(unread);
    _refreshRooms();
  }

  @override
  Future<void> leaveRoom(String roomId) async {
    final room = _requireClient().getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    await room.leave(waitForSync: true).timeout(const Duration(seconds: 30));
    closeRoom(roomId);
    _refreshRooms();
  }

  matrix.Room _joinedRoom(matrix.Client client, String roomId) {
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    return room;
  }

  @override
  Future<RoomDetails> getRoomDetails(String roomId) async {
    final client = _requireClient();
    _joinedRoom(client, roomId);
    final userId = client.userID;
    if (userId == null) throw StateError('Not signed in');
    // Lazy SDK state is insufficient for a complete roster or permissions.
    final state = await client.getRoomState(roomId);
    if (!identical(_client, client)) throw StateError('Session changed');
    _joinedRoom(client, roomId);
    return RoomDetails.fromState(
      roomId: roomId,
      userId: userId,
      state: [
        for (final event in state)
          RoomStateEntry(
            event.type,
            event.stateKey ?? '',
            event.content,
            event.senderId,
          ),
      ],
    );
  }

  Future<matrix.Room> _authoriseRoomAction(
    String roomId,
    RoomAction action, [
    String? targetId,
  ]) async {
    final client = _requireClient();
    final details = await getRoomDetails(roomId);
    if (!identical(_client, client)) throw StateError('Session changed');
    final target = targetId == null
        ? null
        : details.members.where((member) => member.id == targetId).firstOrNull;
    if (!details.can(action, target)) {
      throw StateError('Not permitted to ${action.name} in this room');
    }
    if (targetId != null && targetId == client.userID) {
      throw StateError('Cannot moderate yourself');
    }
    return _joinedRoom(client, roomId);
  }

  @override
  Future<void> editRoomName(String roomId, String name) async {
    final value = name.trim();
    if (value.isEmpty) throw ArgumentError('Room name cannot be empty');
    final room = await _authoriseRoomAction(roomId, RoomAction.name);
    await room.setName(value);
    _scheduleRoomUpdate();
  }

  @override
  Future<void> editRoomTopic(String roomId, String topic) async {
    final room = await _authoriseRoomAction(roomId, RoomAction.topic);
    await room.setDescription(topic.trim());
    _scheduleRoomUpdate();
  }

  @override
  Future<void> inviteToRoom(String roomId, String userId) async {
    final target = userId.trim();
    if (!isValidRoomInviteId(target)) {
      throw ArgumentError('Enter a valid Matrix ID');
    }
    final room = await _authoriseRoomAction(roomId, RoomAction.invite);
    // Room.invite can silently skip a stale locally-cached member.
    await room.client.inviteUser(roomId, target);
    _scheduleRoomUpdate();
  }

  @override
  Future<void> moderateRoomMember(
    String roomId,
    String userId,
    RoomAction action,
  ) async {
    if (action != RoomAction.kick &&
        action != RoomAction.ban &&
        action != RoomAction.unban) {
      throw ArgumentError('Not a moderation action');
    }
    final room = await _authoriseRoomAction(roomId, action, userId);
    switch (action) {
      case RoomAction.kick:
        await room.kick(userId);
      case RoomAction.ban:
        await room.ban(userId);
      case RoomAction.unban:
        await room.unban(userId);
      default:
        throw ArgumentError('Not a moderation action');
    }
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

  RoomJoinOwner? _roomJoins;
  int _joinSessionGeneration = 0;

  RoomJoinOwner _joinOwner() {
    final client = _requireClient();
    final existing = _roomJoins;
    if (existing != null && existing.ownerCurrent()) return existing;
    final generation = _joinSessionGeneration;
    final user = client.userID;
    final device = client.deviceID;
    final homeserver = client.homeserver;
    bool current() =>
        !_disposed &&
        !_loggingOut &&
        client.isLogged() &&
        identical(client, _client) &&
        generation == _joinSessionGeneration &&
        user == client.userID &&
        device == client.deviceID &&
        homeserver == client.homeserver;
    if (!current()) throw StateError('Join session unavailable');
    return _roomJoins = RoomJoinOwner(client, ownerCurrent: current);
  }

  @override
  Future<String> waitForRoomJoin(
    String roomId,
    SendCancellation cancellation, {
    List<String> via = const [],
  }) => _joinOwner().join(roomId, cancellation: cancellation, via: via);

  @override
  Future<String> joinPublicRoom(String roomId) => _joinOwner().join(roomId);

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
    return _inspectCryptoStatus(_requireClient());
  }

  Future<CryptoStatus> _inspectCryptoStatus(matrix.Client client) async {
    if (!client.isLogged() || client.encryption == null) {
      throw StateError('Sign in with encryption enabled first');
    }
    final state = await encryption.CryptoSetupExtension(
      client,
    ).getCryptoIdentityState().timeout(const Duration(seconds: 45));
    if (_disposed || _client != client || !client.isLogged()) {
      throw StateError('Matrix session changed');
    }
    // The SDK's `initialized` flag only means *both* components exist. A
    // partial identity must never be mistaken for a new account.
    final userId = client.userID!;
    final remoteKeys = await client.queryKeys({userId: []}, timeout: 10000);
    if (remoteKeys.failures?.isNotEmpty == true ||
        remoteKeys.deviceKeys?[userId] == null) {
      throw StateError('Could not check existing device keys');
    }
    final ownDeviceId = client.deviceID;
    final ownDevices = remoteKeys.deviceKeys![userId]!;
    if (ownDeviceId == null || !ownDevices.containsKey(ownDeviceId)) {
      throw StateError('This device has not published its encryption keys');
    }
    final hasOtherDevices = ownDevices.keys.any((id) => id != ownDeviceId);
    var hasBackup = false;
    try {
      await client.getRoomKeysVersionCurrent();
      hasBackup = true;
    } on matrix.MatrixException catch (error) {
      if (error.error != matrix.MatrixError.M_NOT_FOUND) rethrow;
    }
    var hasServerStorage = false;
    String? serverDefaultKeyId;
    try {
      final serverDefault = await client.getAccountData(
        userId,
        matrix.EventTypes.SecretStorageDefaultKey,
      );
      hasServerStorage = true;
      serverDefaultKeyId = serverDefault['key'] as String?;
    } on matrix.MatrixException catch (error) {
      if (error.error != matrix.MatrixError.M_NOT_FOUND) rethrow;
    }
    if (_disposed || _client != client || !client.isLogged()) {
      throw StateError('Matrix session changed');
    }
    final ssss = client.encryption!.ssss;
    final keyId = ssss.defaultKeyId;
    final defaultMatches = defaultStorageMatchesServer(
      serverKeyId: serverDefaultKeyId,
      localKeyId: keyId,
    );
    final orphanedStorageKeys = keyId == null
        ? [
            for (final type in client.accountData.keys)
              if (type.startsWith('m.secret_storage.key.') &&
                  ssss.isKeyValid(
                    type.substring('m.secret_storage.key.'.length),
                  ))
                type.substring('m.secret_storage.key.'.length),
          ]
        : const <String>[];
    final hasOrphanedStorage = orphanedStorageKeys.length == 1;
    final validStorage =
        keyId != null && ssss.isKeyValid(keyId) || hasOrphanedStorage;
    final hasMasterPublic = remoteKeys.masterKeys?.containsKey(userId) == true;
    final hasSelfSigningPublic =
        remoteKeys.selfSigningKeys?.containsKey(userId) == true;
    final hasUserSigningPublic =
        remoteKeys.userSigningKeys?.containsKey(userId) == true;
    final masterSecret = ssss.isSecret(matrix.EventTypes.CrossSigningMasterKey);
    final selfSigningSecret = ssss.isSecret(
      matrix.EventTypes.CrossSigningSelfSigning,
    );
    final userSigningSecret = ssss.isSecret(
      matrix.EventTypes.CrossSigningUserSigning,
    );
    final backupSecret = ssss.isSecret(matrix.EventTypes.MegolmBackup);
    // A missing private secret alongside an existing public component must
    // never be 'repaired' by generating a replacement master key or backup.
    final componentsMatch = canRepairIdentityWithoutRotation(
      masterPublic: hasMasterPublic,
      masterSecret: masterSecret,
      selfSigningPublic: hasSelfSigningPublic,
      selfSigningSecret: selfSigningSecret,
      userSigningPublic: hasUserSigningPublic,
      userSigningSecret: userSigningSecret,
      backupVersion: hasBackup,
      backupSecret: backupSecret,
    );
    final repairSafe =
        componentsMatch &&
        (keyId != null ||
            (hasOrphanedStorage &&
                !hasMasterPublic &&
                !hasSelfSigningPublic &&
                !hasUserSigningPublic &&
                !hasBackup));
    final existingMaterial =
        state.keyBackupEnabled ||
        state.crossSigningEnabled ||
        hasBackup ||
        hasServerStorage ||
        keyId != null ||
        client.accountData.keys.any(
          (key) =>
              key.startsWith('m.secret_storage.key.') ||
              key.startsWith('m.cross_signing.'),
        ) ||
        ssss.analyzeEncryptedSecrets().isNotEmpty ||
        hasMasterPublic ||
        hasSelfSigningPublic ||
        hasUserSigningPublic ||
        client.userDeviceKeys[userId]?.masterKey != null;
    return CryptoStatus(
      initialized: state.initialized,
      connected: state.connected,
      keyBackupEnabled: state.keyBackupEnabled,
      crossSigningEnabled: state.crossSigningEnabled,
      setupAvailability: defaultMatches
          ? classifyCryptoSetup(
              initialized: state.initialized,
              connected: state.connected,
              validSecretStorage: validStorage,
              existingIdentityMaterial: existingMaterial,
              repairSafe: repairSafe,
              hasOtherDevices: hasOtherDevices,
            )
          : CryptoSetupAvailability.blocked,
    );
  }

  /// The existence of an encrypted SSSS entry says nothing about whether it
  /// contains the private half of the *current* server identity. Verify all
  /// existing parts under the supplied recovery credential before repair.
  Future<void> _verifyExistingCryptoMaterial(
    matrix.Client client,
    String keyOrPassphrase,
  ) async {
    final id = client.userID;
    final ssss = client.encryption?.ssss;
    final keyId = ssss?.defaultKeyId;
    if (id == null || ssss == null || keyId == null) {
      throw StateError('Existing secret storage is unavailable');
    }
    final opened = ssss.open(keyId);
    await opened.unlock(keyOrPassphrase: keyOrPassphrase, postUnlock: false);
    final keys = await client.queryKeys({id: []}, timeout: 10000);
    if (keys.failures?.isNotEmpty == true || keys.deviceKeys?[id] == null) {
      throw StateError('Could not validate existing signing keys');
    }

    Future<void> checkSigningKey(
      String type,
      matrix.MatrixCrossSigningKey? serverKey,
    ) async {
      if (serverKey == null && !ssss.isSecret(type)) return;
      if (serverKey == null || !ssss.isSecret(type)) {
        throw StateError('Existing signing key is incomplete');
      }
      final privateKey = await opened.getStored(type);
      final publicKey = vod.PkSigning.fromSecretKey(
        base64Encode(base64.decode(base64.normalize(privateKey))),
      ).publicKey.toBase64();
      if (publicKey != serverKey.publicKey) {
        throw StateError('Existing signing key does not match the server');
      }
    }

    await checkSigningKey(
      matrix.EventTypes.CrossSigningMasterKey,
      keys.masterKeys?[id],
    );
    await checkSigningKey(
      matrix.EventTypes.CrossSigningSelfSigning,
      keys.selfSigningKeys?[id],
    );
    await checkSigningKey(
      matrix.EventTypes.CrossSigningUserSigning,
      keys.userSigningKeys?[id],
    );
    final masterPublicKey = keys.masterKeys?[id]?.publicKey;
    for (final subkey in [
      keys.selfSigningKeys?[id],
      keys.userSigningKeys?[id],
    ]) {
      if (subkey == null) continue;
      if (masterPublicKey == null ||
          !isSubkeySignedByMaster(
            subkey,
            userId: id,
            masterPublicKey: masterPublicKey,
          )) {
        throw StateError('Existing signing chain is not trusted');
      }
    }

    matrix.GetRoomKeysVersionCurrentResponse? backup;
    try {
      backup = await client.getRoomKeysVersionCurrent();
    } on matrix.MatrixException catch (error) {
      if (error.error != matrix.MatrixError.M_NOT_FOUND) rethrow;
    }
    if (backup != null || ssss.isSecret(matrix.EventTypes.MegolmBackup)) {
      if (backup == null || !ssss.isSecret(matrix.EventTypes.MegolmBackup)) {
        throw StateError('Existing key backup is incomplete');
      }
      final privateKey = Uint8List.fromList(
        base64.decode(
          base64.normalize(
            await opened.getStored(matrix.EventTypes.MegolmBackup),
          ),
        ),
      );
      final publicKey = vod.PkDecryption.fromSecretKey(
        vod.Curve25519PublicKey.fromBytes(privateKey),
      ).publicKey;
      if (backup.algorithm !=
              matrix.BackupAlgorithm.mMegolmBackupV1Curve25519AesSha2 ||
          backup.authData['public_key'] != publicKey) {
        throw StateError('Existing key backup does not match the server');
      }
    }
    if (_disposed || _client != client || !client.isLogged()) {
      throw StateError('Matrix session changed during repair');
    }
  }

  @override
  Future<CryptoSetupResult> createCryptoIdentity(
    String recoveryPassphrase,
  ) async {
    if (recoveryPassphrase.length < 32) {
      throw ArgumentError('A generated recovery phrase is required');
    }
    if (_cryptoSetupBusy) throw StateError('Encryption setup already running');
    final client = _requireClient();
    if (_verificationRequest != null) {
      throw StateError('Finish verification before setting up encryption');
    }
    _cryptoSetupBusy = true;
    final generation = _securityGeneration;
    try {
      return await runOnlyWhenCryptoSetupIsSafe(
        expected: CryptoSetupAvailability.create,
        inspect: () async =>
            (await _inspectCryptoStatus(client)).setupAvailability,
        action: () async {
          // Explicitly forbid every destructive branch even if discovery was
          // stale. Do not automatically retry a partial bootstrap as a reset.
          final key = await encryption.CryptoSetupExtension(client)
              .initCryptoIdentity(
                passphrase: recoveryPassphrase,
                wipeSecureStorage: false,
                wipeKeyBackup: false,
                wipeCrossSigning: false,
                setupMasterKey: true,
                setupSelfSigningKey: true,
                setupUserSigningKey: true,
                setupOnlineKeyBackup: true,
              );
          if (_disposed ||
              _client != client ||
              generation != _securityGeneration ||
              !client.isLogged()) {
            throw StateError('Matrix session changed during setup');
          }
          var ready = false;
          try {
            final state = await encryption.CryptoSetupExtension(
              client,
            ).getCryptoIdentityState().timeout(const Duration(seconds: 45));
            ready = state.initialized && state.connected;
          } catch (_) {
            // Never lose the newly generated recovery key merely because the
            // follow-up status request failed. The UI must show it either way.
          }
          return CryptoSetupResult(recoveryKey: key, ready: ready);
        },
      );
    } finally {
      _cryptoSetupBusy = false;
    }
  }

  @override
  Future<void> repairCryptoIdentity(String keyOrPassphrase) async {
    if (keyOrPassphrase.trim().isEmpty) {
      throw ArgumentError('Existing recovery credential required');
    }
    if (_cryptoSetupBusy) throw StateError('Encryption setup already running');
    final client = _requireClient();
    _cryptoSetupBusy = true;
    final generation = _securityGeneration;
    try {
      await runOnlyWhenCryptoSetupIsSafe(
        expected: CryptoSetupAvailability.repair,
        inspect: () async =>
            (await _inspectCryptoStatus(client)).setupAvailability,
        action: () async {
          final ssss = client.encryption!.ssss;
          if (ssss.defaultKeyId == null) {
            final candidates = [
              for (final type in client.accountData.keys)
                if (type.startsWith('m.secret_storage.key.') &&
                    ssss.isKeyValid(
                      type.substring('m.secret_storage.key.'.length),
                    ))
                  type.substring('m.secret_storage.key.'.length),
            ];
            if (candidates.length != 1) {
              throw StateError('Existing storage key is ambiguous');
            }
            final keyId = candidates.single;
            // A failed initial setup can leave a key record before the SDK
            // writes the default-key pointer. Prove this is the saved key
            // before adopting it; never create another one.
            final serverKey = await client.getAccountData(
              client.userID!,
              matrix.EventTypes.secretStorageKey(keyId),
            );
            final localKey = ssss.getKey(keyId);
            final serverPhrase = serverKey['passphrase'];
            if (localKey == null ||
                serverKey['iv'] != localKey.iv ||
                serverKey['mac'] != localKey.mac ||
                serverKey['algorithm'] != localKey.algorithm ||
                (serverPhrase is Map ? serverPhrase['salt'] : null) !=
                    localKey.passphrase?.salt) {
              throw StateError('Storage key changed on the server');
            }
            await ssss
                .open(keyId)
                .unlock(keyOrPassphrase: keyOrPassphrase, postUnlock: false);
            if (_disposed ||
                _client != client ||
                generation != _securityGeneration ||
                !client.isLogged()) {
              throw StateError('Matrix session changed during repair');
            }
            if ((await _inspectCryptoStatus(client)).setupAvailability !=
                CryptoSetupAvailability.repair) {
              throw StateError('Encryption identity changed during repair');
            }
            await ssss.setDefaultKeyId(keyId);
          }
          if ((await _inspectCryptoStatus(client)).setupAvailability !=
              CryptoSetupAvailability.repair) {
            throw StateError('Encryption identity changed during repair');
          }
          await _verifyExistingCryptoMaterial(client, keyOrPassphrase);
          if ((await _inspectCryptoStatus(client)).setupAvailability !=
              CryptoSetupAvailability.repair) {
            throw StateError('Encryption identity changed during repair');
          }
          await encryption.CryptoSetupExtension(client).initCryptoIdentity(
            reuseExistingStorageRecoveryKeyOrPassphrase: keyOrPassphrase,
            wipeSecureStorage: false,
            wipeKeyBackup: false,
            wipeCrossSigning: false,
            setupMasterKey: !ssss.isSecret(
              matrix.EventTypes.CrossSigningMasterKey,
            ),
            setupSelfSigningKey: !ssss.isSecret(
              matrix.EventTypes.CrossSigningSelfSigning,
            ),
            setupUserSigningKey: !ssss.isSecret(
              matrix.EventTypes.CrossSigningUserSigning,
            ),
            setupOnlineKeyBackup: !ssss.isSecret(
              matrix.EventTypes.MegolmBackup,
            ),
          );
        },
      );
      if (_disposed || _client != client || generation != _securityGeneration) {
        throw StateError('Matrix session changed during repair');
      }
      final state = await encryption.CryptoSetupExtension(
        client,
      ).getCryptoIdentityState().timeout(const Duration(seconds: 45));
      if (!state.initialized || !state.connected) {
        throw StateError(
          'Identity is not yet complete; retry with existing key',
        );
      }
    } finally {
      _cryptoSetupBusy = false;
    }
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

  /// Unlocks secret storage with [keyOrPassphrase] and proves every stored
  /// signing/backup secret matches the server's current public keys. Throws
  /// without writing anything when the credential or identity does not match.
  Future<void> verifyRecoveryCredential(String keyOrPassphrase) async {
    if (keyOrPassphrase.trim().isEmpty) {
      throw ArgumentError('Recovery credential required');
    }
    await _verifyExistingCryptoMaterial(_requireClient(), keyOrPassphrase);
  }

  /// Runs an exclusive encryption-identity operation for the security module
  /// (key storage, recovery key rotation, identity reset). Sends, sign-in and
  /// sign-out stay blocked until the SDK work settles, even if the session is
  /// invalidated meanwhile: SDK bootstrap callbacks use the mutable user ID.
  /// [action] must re-check `isCurrent` after every await before writing.
  Future<T> runCryptoMaintenance<T>(
    Future<T> Function(matrix.Client client, bool Function() isCurrent) action,
  ) async {
    if (_cryptoSetupBusy) throw StateError('Encryption setup already running');
    final client = _requireClient();
    if (!client.isLogged() || client.encryption == null) {
      throw StateError('Encryption is unavailable');
    }
    if (_verificationRequest != null || _verificationStarting) {
      throw StateError('Finish verification before changing encryption');
    }
    _cryptoSetupBusy = true;
    final generation = _securityGeneration;
    bool current() =>
        !_disposed &&
        !_loggingOut &&
        identical(_client, client) &&
        generation == _securityGeneration &&
        client.isLogged();
    try {
      return await action(client, current);
    } finally {
      _cryptoSetupBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  Future<List<VerificationDevice>> ownDevices() async {
    final client = _requireClient();
    final id = client.userID;
    if (id == null || !client.isLogged()) throw StateError('Sign in first');
    await client.updateUserDeviceKeys(additionalUsers: {id});
    return [
      for (final device
          in client.userDeviceKeys[id]?.deviceKeys.values ??
              <matrix.DeviceKeys>[])
        if (device.deviceId != null && device.deviceId != client.deviceID)
          VerificationDevice(
            id: device.deviceId!,
            name: device.deviceDisplayName ?? device.deviceId!,
            verified: device.verified,
          ),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<void> startVerification(String userId, {String? deviceId}) async {
    final client = _requireClient();
    if (!client.isLogged() || client.encryption == null) {
      throw StateError('Encryption is unavailable');
    }
    if (_verificationRequest != null ||
        _verificationQueue.isNotEmpty ||
        _verificationStarting) {
      throw StateError('Finish the current verification first');
    }
    if (deviceId != null && userId != client.userID) {
      throw ArgumentError('Only your own devices can be selected here');
    }
    _verificationStarting = true;
    try {
      await client.updateUserDeviceKeys(additionalUsers: {userId});
      final keys = client.userDeviceKeys[userId];
      if (keys == null) throw StateError('No device keys available');
      final request = deviceId == null
          ? await keys.startVerification()
          : await (keys.deviceKeys[deviceId] ??
                    (throw StateError('Device unavailable')))
                .startVerification();
      if (_disposed || _client != client || !client.isLogged()) {
        unawaited(request.cancel('m.user').catchError((Object _) {}));
        return;
      }
      _offerVerification(request, incoming: false);
    } finally {
      _verificationStarting = false;
      _showNextVerification();
    }
  }

  void _offerVerification(
    encryption.KeyVerification request, {
    required bool incoming,
  }) {
    if (_disposed ||
        request.isDone ||
        _verificationRequest == request ||
        _verificationQueue.contains(request)) {
      return;
    }
    _verificationQueue.add(request);
    _incomingVerification[request] = incoming;
    _showNextVerification();
  }

  final _incomingVerification = <encryption.KeyVerification, bool>{};

  void _showNextVerification() {
    if (_disposed || _verificationStarting || _verificationRequest != null) {
      return;
    }
    while (_verificationQueue.isNotEmpty) {
      final next = _verificationQueue.removeFirst();
      if (next.isDone) {
        _incomingVerification.remove(next);
        continue;
      }
      _verificationRequest = next;
      _verificationId++;
      _verificationBusy = false;
      _verificationSecretSkipped = false;
      _verificationError = null;
      next.onUpdate = () {
        if (_verificationRequest == next && !_disposed) _publishVerification();
      };
      _publishVerification();
      return;
    }
  }

  void _publishVerification() {
    final request = _verificationRequest;
    if (request == null || _disposed) return;
    final stage = switch (request.state) {
      encryption.KeyVerificationState.askAccept => VerificationStage.accept,
      encryption.KeyVerificationState.askChoice => VerificationStage.choose,
      encryption.KeyVerificationState.askSas => VerificationStage.compare,
      encryption.KeyVerificationState.askSSSS => VerificationStage.secret,
      encryption.KeyVerificationState.done => VerificationStage.done,
      encryption.KeyVerificationState.error ||
      encryption.KeyVerificationState.showQRSuccess ||
      encryption.KeyVerificationState.confirmQRScan => VerificationStage.error,
      encryption.KeyVerificationState.waitingAccept ||
      encryption.KeyVerificationState.waitingSas => VerificationStage.waiting,
    };
    _verificationDetails = VerificationDetails(
      id: _verificationId,
      userId: request.userId,
      deviceId: request.deviceId,
      incoming: _incomingVerification[request] ?? false,
      stage: stage,
      busy: _verificationBusy,
      secretSkipped: _verificationSecretSkipped,
      error:
          _verificationError ??
          (request.canceled ? request.canceledCode : null),
      emojis:
          stage == VerificationStage.compare &&
              request.sasTypes.contains('emoji')
          ? List.unmodifiable([
              for (final emoji in request.sasEmojis)
                VerificationEmoji(emoji.emoji, emoji.name),
            ])
          : const [],
      numbers:
          stage == VerificationStage.compare &&
              request.sasTypes.contains('decimal')
          ? List.unmodifiable(request.sasNumbers)
          : const [],
    );
    notifyListeners();
  }

  Future<void> _verificationAction(
    Future<void> Function(encryption.KeyVerification) action,
  ) async {
    final request = _verificationRequest;
    if (request == null || _verificationBusy || request.isDone) {
      throw StateError('Verification is not active');
    }
    _verificationBusy = true;
    _verificationError = null;
    _publishVerification();
    try {
      await action(request);
    } catch (_) {
      if (request == _verificationRequest && !_disposed) {
        _verificationError =
            'Could not complete this step. Try again or cancel.';
      }
      rethrow;
    } finally {
      if (request == _verificationRequest && !_disposed) {
        _verificationBusy = false;
        _publishVerification();
      }
    }
  }

  @override
  Future<void> acceptVerification() => _verificationAction((request) {
    if (request.state != encryption.KeyVerificationState.askAccept) {
      throw StateError('Request is no longer awaiting acceptance');
    }
    return request.acceptVerification();
  });

  @override
  Future<void> chooseEmojiVerification() => _verificationAction((request) {
    if (request.state != encryption.KeyVerificationState.askChoice ||
        !request.possibleMethods.contains(matrix.EventTypes.Sas)) {
      throw StateError('SAS verification is unavailable');
    }
    return request.continueVerification(matrix.EventTypes.Sas);
  });

  @override
  Future<void> confirmVerification({required bool matches}) =>
      _verificationAction((request) {
        if (request.state != encryption.KeyVerificationState.askSas ||
            !(request.sasTypes.contains('emoji') ||
                request.sasTypes.contains('decimal'))) {
          throw StateError('Comparison is no longer available');
        }
        return matches ? request.acceptSas() : request.rejectSas();
      });

  @override
  Future<void> unlockVerification(String keyOrPassphrase) {
    if (keyOrPassphrase.isEmpty) throw ArgumentError('Recovery key required');
    return _verificationAction((request) {
      if (request.state != encryption.KeyVerificationState.askSSSS) {
        throw StateError('Recovery is no longer needed');
      }
      return request.openSSSS(keyOrPassphrase: keyOrPassphrase);
    });
  }

  @override
  Future<void> skipVerificationSigning() =>
      _verificationAction((request) async {
        if (request.state != encryption.KeyVerificationState.askSSSS) {
          throw StateError('Recovery is no longer needed');
        }
        await request.openSSSS(skip: true);
        _verificationSecretSkipped = true;
      });

  @override
  Future<void> cancelVerification() async {
    final request = _verificationRequest;
    if (request == null) return;
    if (request.isDone) {
      dismissVerification();
    } else {
      await _verificationAction((active) async {
        try {
          await active.cancel('m.user');
        } catch (_) {
          // Keep the UI dismissible offline even when the peer cannot be told.
          await active.cancel('m.user', true);
        }
      });
    }
  }

  @override
  void dismissVerification() {
    final request = _verificationRequest;
    if (request == null || !request.isDone || _verificationBusy) return;
    request.onUpdate = null;
    _incomingVerification.remove(request);
    _verificationRequest = null;
    _verificationDetails = null;
    if (!_disposed) notifyListeners();
    _showNextVerification();
  }

  void _clearSecurityPrompts() {
    _securityGeneration++;
    final pending = _trustDecision;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    _trustDecision = null;
    _trustWarning = null;
    _verificationRequest?.onUpdate = null;
    _verificationRequest = null;
    _verificationDetails = null;
    _verificationQueue.clear();
    _incomingVerification.clear();
    if (!_disposed) notifyListeners();
  }

  void _resetSessionView() {
    if (_disposed) return;
    _joinSessionGeneration++;
    _roomJoins = null;
    _requiresReauthentication = false;
    _clearSecurityPrompts();
    _outbox.closeAccount();
    _outboxAccount = null;
    _outboxRestoring = null;
    _roomUpdateTimer?.cancel();
    _roomGeneration++;
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _activeRoomId = null;
    _rooms = const [];
    _messages = const [];
    _sending = false;
    _loadingHistory = false;
    _refreshingRooms = false;
    _imageCache.clear();
    _imageCacheBytes = 0;
    _avatarCache.clear();
    _reactionInFlight.clear();
    _validatedRoster.clear();
    _firstSyncCompleted = false;
    _successfulSyncs = 0;
    _roomSyncState = RoomSyncState.loading;
    _roomSyncIssue = null;
    notifyListeners();
  }

  void _requireEncryptedTransport(matrix.Room room) {
    final client = _requireClient();
    if (client.onLoginStateChanged.value != matrix.LoginState.loggedIn ||
        (room.encrypted && !client.encryptionEnabled)) {
      throw StateError('Encrypted messaging is unavailable');
    }
  }

  void _checkSendOwner(bool Function() current) {
    if (!current()) throw StateError('Send belongs to a retired account');
  }

  Future<Uint8List> _readSendMedia(XFile file, bool Function() current) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      _checkSendOwner(current);
      if (bytes.length + chunk.length > 20 * 1024 * 1024) {
        throw ArgumentError('Attachment exceeds the 20 MB limit');
      }
      bytes.add(chunk);
    }
    _checkSendOwner(current);
    if (bytes.isEmpty) throw ArgumentError('The attachment is empty');
    return bytes.takeBytes();
  }

  bool Function() _sendOwnership(
    matrix.Client client,
    matrix.Room room,
    int generation,
  ) {
    final user = client.userID;
    final device = client.deviceID;
    final encrypted = room.encrypted;
    return () =>
        !_disposed &&
        !_loggingOut &&
        identical(_client, client) &&
        user == client.userID &&
        device == client.deviceID &&
        generation == _securityGeneration &&
        room.encrypted == encrypted &&
        room.membership == matrix.Membership.join &&
        client.onLoginStateChanged.value == matrix.LoginState.loggedIn;
  }

  Future<T> _protectSend<T>(
    matrix.Room room,
    Future<T> Function() action, {
    bool Function()? ownerCurrent,
  }) {
    final client = _requireClient();
    final generation = _securityGeneration;
    final current = ownerCurrent ?? _sendOwnership(client, room, generation);
    if (!current()) throw StateError('Send session changed');
    if (!room.encrypted) return MatrixSendGuard.owned(current, action);
    _requireEncryptedTransport(room);
    final guard = _sendGuard;
    if (guard == null) throw StateError('Encrypted send guard unavailable');
    final approvedRoster = _validatedRoster[room.id];
    if (approvedRoster == null) {
      throw StateError('Encrypted recipients were not checked');
    }
    return guard.protect(
      room.id,
      action,
      ownerCurrent: current,
      validateRecipients: () async {
        await _untrustedRecipients(room);
        final currentRoster = _validatedRoster[room.id];
        if (currentRoster == null ||
            !sameRecipientSnapshot(approvedRoster, currentRoster)) {
          throw StateError('Encrypted-room recipients changed during send');
        }
      },
    );
  }

  Future<Uint8List> _downloadMedia(Uri uri, int maxBytes) {
    final client = _requireClient();
    final homeserver = client.homeserver;
    final token = client.accessToken;
    if (!client.isLogged() || homeserver == null || token == null) {
      throw StateError('Media session unavailable');
    }
    return downloadMatrixMedia(
      httpClient: client.httpClient,
      homeserver: homeserver,
      uri: uri,
      accessToken: token,
      maxBytes: maxBytes,
    );
  }

  Future<List<UntrustedRecipient>> _untrustedRecipients(
    matrix.Room room,
  ) async {
    final client = _requireClient();
    // Use the same roster the SDK uses to distribute outbound Megolm keys.
    final allParticipants = await room.requestParticipants(
      const [
        matrix.Membership.join,
        matrix.Membership.invite,
        matrix.Membership.knock,
      ],
      true,
      true,
      true,
    );
    final participants = allParticipants
        .where(
          (user) =>
              user.membership == matrix.Membership.join ||
              user.membership == matrix.Membership.invite,
        )
        .toList();
    final joinedCount = room.summary.mJoinedMemberCount;
    final invitedCount = room.summary.mInvitedMemberCount;
    final actualJoined = participants
        .where((u) => u.membership == matrix.Membership.join)
        .length;
    final actualInvited = participants
        .where((u) => u.membership == matrix.Membership.invite)
        .length;
    if (participants.isEmpty ||
        !participants.any((user) => user.id == client.userID) ||
        (joinedCount != null && actualJoined < joinedCount) ||
        (invitedCount != null && actualInvited < invitedCount)) {
      throw StateError('Could not confirm all encrypted-room participants');
    }
    final allUserIds = {for (final user in participants) user.id};
    final userIds = {
      for (final user in participants)
        if (user.id != client.userID) user.id,
    };
    if (allUserIds.isNotEmpty) {
      final response = await client.queryKeys({
        for (final id in allUserIds) id: <String>[],
      }, timeout: 10000);
      if (!keyQueryComplete(response, allUserIds)) {
        throw StateError('Could not refresh recipient encryption keys');
      }
      await client.updateUserDeviceKeys(additionalUsers: allUserIds);
      for (final id in allUserIds) {
        final local = client.userDeviceKeys[id];
        final remoteDevices = response.deviceKeys![id]!;
        if (local == null ||
            local.masterKey?.publicKey != response.masterKeys?[id]?.publicKey ||
            local.deviceKeys.length != remoteDevices.length ||
            remoteDevices.entries.any((entry) {
              final device = local.deviceKeys[entry.key];
              return device == null ||
                  device.ed25519Key !=
                      entry.value.keys['ed25519:${entry.key}'] ||
                  device.curve25519Key !=
                      entry.value.keys['curve25519:${entry.key}'];
            })) {
          throw StateError('Recipient encryption keys changed or are stale');
        }
      }
    }
    _validatedRoster[room.id] = {
      for (final id in allUserIds)
        id: {
          '__master__': client.userDeviceKeys[id]?.masterKey?.publicKey ?? '',
          for (final device
              in client.userDeviceKeys[id]?.deviceKeys.entries ??
                  <MapEntry<String, matrix.DeviceKeys>>[])
            device.key:
                '${device.value.curve25519Key}/${device.value.ed25519Key}',
        },
    };
    final recipients = <UntrustedRecipient>[];
    for (final id in userIds) {
      final key = client.userDeviceKeys[id]?.masterKey;
      if (key?.blocked == true) {
        throw StateError('A recipient has a blocked encryption identity');
      }
      if (key?.verified == true || key?.trustOnFirstUseSince != null) continue;
      recipients.add(UntrustedRecipient(userId: id, masterKey: key?.publicKey));
    }
    recipients.sort((a, b) => a.userId.compareTo(b.userId));
    return recipients;
  }

  Future<void> _ensureTrusted(
    matrix.Room room, {
    SendCancellation? cancellation,
  }) async {
    if (!room.encrypted) return;
    _requireEncryptedTransport(room);
    final client = _requireClient();
    final generation = _securityGeneration;
    await confirmRecipientTrust(
      readRecipients: () => _untrustedRecipients(room),
      isCurrentSession: () =>
          !_disposed &&
          _client == client &&
          client.isLogged() &&
          cancellation?.isCancelled != true &&
          generation == _securityGeneration,
      askUser: (recipients) async {
        cancellation?.check();
        if (_trustDecision != null) {
          throw StateError('Another trust decision is in progress');
        }
        final decision = Completer<bool>();
        _trustDecision = decision;
        _trustWarning = TrustWarning(
          roomId: room.id,
          recipients: List.unmodifiable(recipients),
        );
        notifyListeners();
        if (cancellation == null) return decision.future;
        try {
          return await Future.any([
            decision.future,
            cancellation.whenCancelled.then((_) => false),
          ]);
        } finally {
          if (identical(_trustDecision, decision)) respondToTrustWarning(false);
        }
      },
      trustKey: (recipient) async {
        final key = client.userDeviceKeys[recipient.userId]?.masterKey;
        if (key?.publicKey != recipient.masterKey) {
          throw StateError('Recipient encryption key changed');
        }
        if (key != null) await key.trustOnFirstUse();
      },
    );
  }

  @override
  void respondToTrustWarning(bool approved) {
    final decision = _trustDecision;
    if (decision == null || decision.isCompleted) return;
    _trustDecision = null;
    _trustWarning = null;
    decision.complete(approved);
    if (!_disposed) notifyListeners();
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

  void _handleSyncStatus(matrix.SyncStatusUpdate update) {
    if (_disposed || _client?.isLogged() != true) return;
    switch (update.status) {
      case matrix.SyncStatus.error:
        final failure = update.error?.exception;
        _roomSyncIssue = failure is matrix.SyncConnectionException
            ? RoomSyncIssue.network
            : failure is matrix.MatrixException
            ? RoomSyncIssue.homeserver
            : RoomSyncIssue.processing;
        if (_rooms.isEmpty) _roomSyncState = RoomSyncState.error;
        notifyListeners();
      case matrix.SyncStatus.finished:
        _firstSyncCompleted = true;
        _successfulSyncs++;
        if (_roomSyncState == RoomSyncState.error) {
          _roomSyncState = RoomSyncState.loading;
          _roomSyncIssue = null;
          notifyListeners();
        }
        _scheduleRoomUpdate();
      case matrix.SyncStatus.waitingForResponse:
      case matrix.SyncStatus.processing:
      case matrix.SyncStatus.cleaningUp:
        if (!_firstSyncCompleted &&
            _rooms.isEmpty &&
            _roomSyncState != RoomSyncState.loading &&
            _roomSyncState != RoomSyncState.error) {
          _roomSyncState = RoomSyncState.loading;
          notifyListeners();
        }
    }
  }

  @override
  Future<void> refreshRooms() async {
    if (_refreshingRooms) return;
    final client = _requireClient();
    final generation = _securityGeneration;
    _refreshingRooms = true;
    final previousSyncs = _successfulSyncs;
    _roomSyncState = RoomSyncState.loading;
    _roomSyncIssue = null;
    notifyListeners();
    try {
      await client.oneShotSync(timeout: Duration.zero);
      if (_securityGeneration != generation || _disposed) return;
      if (_successfulSyncs != previousSyncs) {
        _refreshRooms();
      } else if (_rooms.isEmpty && _roomSyncState == RoomSyncState.loading) {
        _roomSyncState = RoomSyncState.error;
        _roomSyncIssue = RoomSyncIssue.processing;
        notifyListeners();
      }
    } catch (_) {
      if (_securityGeneration != generation || _disposed) return;
      _roomSyncState = RoomSyncState.error;
      _roomSyncIssue ??= RoomSyncIssue.network;
      notifyListeners();
    } finally {
      if (_securityGeneration == generation) _refreshingRooms = false;
    }
  }

  void _scheduleRoomUpdate() {
    if (_roomUpdateTimer?.isActive ?? false) return;
    _roomUpdateTimer = Timer(const Duration(milliseconds: 40), _refreshRooms);
  }

  void _refreshRooms() {
    try {
      _projectRooms();
    } catch (_) {
      _roomSyncState = RoomSyncState.error;
      _roomSyncIssue = RoomSyncIssue.processing;
      if (!_disposed) notifyListeners();
    }
  }

  void _projectRooms() {
    final client = _client;
    if (client == null || _disposed || !client.isLogged()) return;
    final joined = client.rooms.where(
      (r) =>
          r.membership == matrix.Membership.join ||
          r.membership == matrix.Membership.invite,
    );
    final projected = <ChatRoom>[];
    for (final room in joined) {
      try {
        projected.add(_projectRoom(room, client));
      } catch (_) {
        // One malformed room must not hide the rest of the inbox.
        projected.add(
          ChatRoom(
            id: room.id,
            name: room.id,
            preview: 'Room details unavailable',
            lastActivity: null,
            invited: room.membership == matrix.Membership.invite,
          ),
        );
      }
    }
    projected.sort(compareRooms);
    _rooms = List.unmodifiable(projected);
    if (_rooms.isNotEmpty ||
        (_firstSyncCompleted && _roomSyncState != RoomSyncState.error)) {
      _roomSyncState = RoomSyncState.ready;
      _roomSyncIssue = null;
    }
    notifyListeners();
  }

  ChatRoom _projectRoom(matrix.Room room, matrix.Client client) {
    final event = room.lastEvent;
    final name = room.getLocalizedDisplayname();
    final heroIds =
        room.summary.mHeroes ??
        [if (room.directChatMatrixID != null) room.directChatMatrixID!];
    final tags = room.tags.keys.toList(growable: false);
    // Cached membership only: never trigger member fetches while projecting.
    String? previewSender;
    if (!room.isDirectChat &&
        event != null &&
        (event.type == matrix.EventTypes.Message ||
            event.type == matrix.EventTypes.Encrypted)) {
      if (event.senderId == client.userID) {
        previewSender = 'You';
      } else {
        final member = room
            .getState(matrix.EventTypes.RoomMember, event.senderId)
            ?.content['displayname'];
        previewSender = member is String && member.trim().isNotEmpty
            ? member.trim()
            : event.senderId;
      }
    }
    return ChatRoom(
      highlightCount: room.highlightCount,
      favourite: tags.contains(matrix.TagType.favourite),
      lowPriority: tags.contains(matrix.TagType.lowPriority),
      tags: tags,
      notificationMode: switch (room.pushRuleState) {
        matrix.PushRuleState.notify => RoomNotificationMode.allMessages,
        matrix.PushRuleState.mentionsOnly =>
          RoomNotificationMode.mentionsAndKeywords,
        matrix.PushRuleState.dontNotify => RoomNotificationMode.mute,
      },
      isSpace: room.isSpace,
      isPublic: room.joinRules == matrix.JoinRules.public,
      previewSender: previewSender,
      canonicalAlias: room.canonicalAlias.isEmpty ? null : room.canonicalAlias,
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
            name: room.unsafeGetUserFromMemoryOrFallback(id).calcDisplayname(),
            url: room.unsafeGetUserFromMemoryOrFallback(id).avatarUrl,
          ),
      ],
    );
  }

  void _refreshMessages(matrix.Timeline timeline) {
    final client = _client;
    if (_disposed || timeline != _timeline || client == null) return;
    final queuedIds = _outbox.records.map((record) => record.id).toSet();
    var events = timeline.events;
    // Jump to event: the focused event is the newest visible entry.
    final focus = _focusedEventId == null
        ? -1
        : events.indexWhere((event) => event.eventId == _focusedEventId);
    if (focus > 0) events = events.sublist(focus);
    _messages = List.unmodifiable(
      events
          .take(_visibleMessageLimit)
          .where(
            (event) =>
                isTimelineVisibleType(event.type) &&
                event.relationshipType != matrix.RelationshipTypes.edit &&
                event.relationshipType != matrix.RelationshipTypes.thread &&
                // Undecryptable relations (reactions, poll votes) keep their
                // cleartext relation; aggregate them, never show a row.
                event.relationshipType != matrix.RelationshipTypes.reaction &&
                event.relationshipType != matrix.RelationshipTypes.reference &&
                (event.status.isSynced ||
                    !queuedIds.contains(event.transactionId ?? event.eventId)),
          )
          .map((event) => _projectEntry(event, timeline))
          .toList()
          .reversed,
    );
    notifyListeners();
  }

  ChatEntry _projectEntry(matrix.Event event, matrix.Timeline? timeline) {
    final client = _requireClient();
    final display = timeline == null ? event : event.getDisplayEvent(timeline);
    final replyToId = event.inReplyToEventId(includingFallback: false);
    final reactions = event.redacted || timeline == null
        ? const <ChatReaction>[]
        : summarizeReactions(
            event
                .aggregatedEvents(timeline, matrix.RelationshipTypes.reaction)
                .where((reaction) => !reaction.redacted)
                .map(
                  (reaction) => ReactionVote(
                    ((reaction.content['m.relates_to'] as Map?)?['key']
                            as String?) ??
                        '',
                    reaction.senderId,
                  ),
                ),
            client.userID,
          );
    final kind = entryKindFor(
      type: display.type,
      msgtype: display.messageType,
      content: display.content,
      redacted: event.redacted,
    );
    // Cached membership only: never trigger member fetches while projecting.
    final member = event.room.getState(
      matrix.EventTypes.RoomMember,
      event.senderId,
    );
    final memberName = member?.content['displayname'];
    final memberAvatar = member?.content['avatar_url'];
    final content = event.redacted
        ? const <String, Object?>{}
        : Map<String, Object?>.unmodifiable(display.content);
    final format = content['format'];
    final formatted = content['formatted_body'];
    final thread =
        (event.unsigned?['m.relations'] as Map?)?['m.thread'] as Map?;
    final threadLatest = thread?['latest_event'] as Map?;
    final threadLatestContent = threadLatest?['content'] as Map?;
    final mentions = content['m.mentions'];
    final mentionIds = mentions is Map ? mentions['user_ids'] : null;
    return ChatEntry(
      id: event.eventId,
      sender: event.senderId,
      body: event.redacted
          ? 'Message removed'
          : display.type == matrix.EventTypes.Encrypted
          ? '🔒 Unable to decrypt this message'
          : kind == EntryKind.state || kind == EntryKind.call
          ? _fallbackBody(display)
          : visibleMessageBody(display.body, isReply: replyToId != null),
      time: event.originServerTs,
      mine: event.senderId == client.userID,
      isImage:
          !event.redacted &&
          (display.messageType == matrix.MessageTypes.Image ||
              display.type == matrix.EventTypes.Sticker),
      isAttachment:
          !event.redacted &&
          display.type == matrix.EventTypes.Message &&
          {
            matrix.MessageTypes.File,
            matrix.MessageTypes.Audio,
            matrix.MessageTypes.Video,
          }.contains(display.messageType),
      replyToId: replyToId,
      redacted: event.redacted,
      edited: display.eventId != event.eventId,
      reactions: reactions,
      kind: kind,
      eventType: display.type,
      msgtype: display.type == matrix.EventTypes.Message
          ? display.messageType
          : null,
      formattedBody: format == 'org.matrix.custom.html' && formatted is String
          ? formatted
          : null,
      senderName: memberName is String ? memberName : null,
      senderAvatar: memberAvatar is String ? Uri.tryParse(memberAvatar) : null,
      content: content,
      stateKey: event.stateKey,
      threadReplyCount: (thread?['count'] as num?)?.toInt() ?? 0,
      threadLatestBody: threadLatestContent?['body'] as String?,
      pinned: event.room.pinnedEventIds.contains(event.eventId),
      highlight:
          mentionIds is List && mentionIds.contains(client.userID) ||
          (mentions is Map && mentions['room'] == true),
    );
  }

  String _fallbackBody(matrix.Event event) {
    try {
      return event.calcLocalizedBodyFallback(
        const matrix.MatrixDefaultLocalizations(),
        hideReply: true,
      );
    } catch (_) {
      return event.type;
    }
  }

  // --- Feature-module access (see lib/room_events.dart) -------------------

  @override
  matrix.Client? get sdkClient =>
      _disposed || _loggingOut || _connection == SessionStatus.offline
      ? null
      : _client;

  @override
  bool isSessionCurrent(matrix.Client client) =>
      !_disposed &&
      !_loggingOut &&
      identical(_client, client) &&
      client.isLogged();

  @override
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    if (type.isEmpty || type == matrix.EventTypes.Encrypted) {
      throw ArgumentError.value(type, 'type', 'Invalid event type');
    }
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    final owner = _sendOwnership(client, room, _securityGeneration);
    return MatrixSendGuard.owned(owner, () async {
      await _ensureTrusted(room);
      _checkSendOwner(owner);
      _requireEncryptedTransport(room);
      final id = await _protectSend(
        room,
        () => room.sendEvent(Map<String, dynamic>.of(content), type: type),
        ownerCurrent: owner,
      );
      if (id == null) throw StateError('Event was not sent');
      return id;
    });
  }

  @override
  Future<void> setRoomState(
    String roomId,
    String type,
    Map<String, Object?> content, {
    String stateKey = '',
  }) async {
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    await client.setRoomStateWithKey(
      roomId,
      type,
      stateKey,
      Map<String, dynamic>.of(content),
    );
    if (!isSessionCurrent(client)) throw StateError('Session changed');
  }

  @override
  Future<Map<String, Object?>?> roomState(
    String roomId,
    String type, {
    String stateKey = '',
  }) async {
    final client = _requireClient();
    try {
      final state = await client.getRoomStateWithKey(roomId, type, stateKey);
      if (!isSessionCurrent(client)) throw StateError('Session changed');
      return state;
    } on matrix.MatrixException catch (error) {
      if (error.error == matrix.MatrixError.M_NOT_FOUND) return null;
      rethrow;
    }
  }

  @override
  Future<void> redactEvent(
    String roomId,
    String eventId, {
    String? reason,
  }) async {
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    await room.redactEvent(eventId, reason: reason);
    if (!isSessionCurrent(client)) throw StateError('Session changed');
  }

  @override
  void dispose() {
    _disposed = true;
    _clearSecurityPrompts();
    _roomUpdateTimer?.cancel();
    _syncSubscription?.cancel();
    _syncStatusSubscription?.cancel();
    _loginSubscription?.cancel();
    _sessionClearedSubscription?.cancel();
    _verificationSubscription?.cancel();
    _timeline?.cancelSubscriptions();
    _heldSendLifecycle?.dispose();
    _heldSendLifecycle = null;
    final client = _client;
    final startupOwnsClient = _initializing;
    _sendGuard?.close();
    unawaited(
      () async {
        try {
          await _outbox.dispose();
        } finally {
          // Startup owns its partial client until its uncancellable init settles.
          if (client != null && !startupOwnsClient) await client.dispose();
        }
      }().catchError((Object _) {}),
    );
    super.dispose();
  }
}

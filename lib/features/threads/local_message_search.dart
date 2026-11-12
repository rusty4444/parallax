import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat_backend.dart';
import '../../message_text.dart';
import '../../room_events.dart';
import 'message_index_store.dart';
import '../../matrix_room_names.dart';

/// A local (device index) search result. [threadRootId] is set for thread
/// replies: those open at their thread root in the main timeline.
@immutable
class LocalMessageHit extends MessageHit {
  const LocalMessageHit({
    required super.id,
    required super.roomId,
    required super.roomName,
    required super.sender,
    required super.body,
    required super.time,
    this.threadRootId,
  });
  final String? threadRootId;

  /// Event to focus when opening the result.
  String get jumpEventId => threadRootId ?? id;
}

@immutable
class LocalSearchPage {
  const LocalSearchPage({required this.hits, this.nextOffset});
  final List<LocalMessageHit> hits;
  final int? nextOffset;
}

/// Element X's "Message search": decrypted messages from encrypted rooms are
/// indexed on this device so they can be searched (the server cannot search
/// encrypted text). The index lives in the app's private storage and, like
/// the SDK's message store, is plaintext at rest inside the app sandbox. It
/// is deleted on sign-out, when the session is cleared remotely, and when the
/// user turns the feature off.
abstract interface class LocalMessageSearch {
  /// Starts indexing for the signed-in session (idempotent and cheap).
  void ensureStarted();

  /// Whether local indexing is turned on (default on, as in Element X).
  Future<bool> isEnabled();

  /// Turning off stops indexing and deletes the index.
  Future<void> setEnabled(bool enabled);

  /// Deletes the index. New messages are indexed again while enabled.
  Future<void> clear();

  /// Indexed messages matching every word of [query], newest first. Only
  /// rooms that are still joined are returned.
  Future<LocalSearchPage> search(String query, {int offset = 0, int limit});
}

final _indexes = Expando<LocalMessageSearch>('local message search');

/// Local search for [backend], or null when it has no Matrix session access.
LocalMessageSearch? localMessageSearchOf(ChatBackend backend) =>
    backend is LocalMessageSearch
    ? backend as LocalMessageSearch
    : backend is MatrixSdkAccess
    ? _indexes[backend] ??= MatrixMessageSearchIndex(backend as MatrixSdkAccess)
    : null;

/// Index operations for one timeline event. Only decrypted text messages
/// (text, notice, emote) in encrypted rooms are indexed: unencrypted rooms
/// are searchable on the server. Edits by the original sender replace the
/// indexed text and redactions remove it.
List<IndexOp> indexOpsFor(matrix.Event event) {
  if (!event.room.encrypted) return const [];
  if (event.type == matrix.EventTypes.Redaction) {
    final target = event.redacts ?? event.content['redacts'];
    return target is String && target.isNotEmpty
        ? [IndexDelete(target)]
        : const [];
  }
  if (!event.eventId.startsWith(r'$')) return const [];
  if (event.redacted) return [IndexDelete(event.eventId)];
  if (event.type != matrix.EventTypes.Message) return const [];
  const indexable = {
    matrix.MessageTypes.Text,
    matrix.MessageTypes.Notice,
    matrix.MessageTypes.Emote,
  };
  if (event.relationshipType == matrix.RelationshipTypes.edit) {
    final target = event.relationshipEventId;
    final replacement = event.content['m.new_content'];
    final body = replacement is Map ? replacement['body'] : null;
    final msgtype = replacement is Map ? replacement['msgtype'] : null;
    if (target == null || body is! String || !indexable.contains(msgtype)) {
      return const [];
    }
    final text = body.trim();
    return [
      if (text.isEmpty)
        IndexDelete(target)
      else
        IndexEdit(eventId: target, sender: event.senderId, body: text),
    ];
  }
  if (!indexable.contains(event.messageType)) return const [];
  final raw = event.content['body'];
  if (raw is! String) return const [];
  final body = visibleMessageBody(
    raw,
    isReply: event.inReplyToEventId(includingFallback: false) != null,
  ).trim();
  if (body.isEmpty) return const [];
  return [
    IndexUpsert(
      IndexedMessage(
        eventId: event.eventId,
        roomId: event.room.id,
        sender: event.senderId,
        time: event.originServerTs,
        body: body,
        threadRootId: event.relationshipType == matrix.RelationshipTypes.thread
            ? event.relationshipEventId
            : null,
      ),
    ),
  ];
}

/// Persists whether local indexing is enabled.
abstract interface class MessageSearchPreference {
  Future<bool> read();
  Future<void> write(bool enabled);
}

class SharedMessageSearchPreference implements MessageSearchPreference {
  const SharedMessageSearchPreference();
  static const key = 'parallax.message_search.v1.local_index';

  @override
  Future<bool> read() async {
    final value = (await SharedPreferences.getInstance()).get(key);
    return value is bool ? value : true;
  }

  @override
  Future<void> write(bool enabled) async {
    final saved = await (await SharedPreferences.getInstance()).setBool(
      key,
      enabled,
    );
    if (!saved) throw StateError('Preference not saved');
  }
}

/// [LocalMessageSearch] fed by the SDK's decrypted timeline and history
/// streams, plus a bounded backfill from the SDK's local event store. Each
/// room's stored history is read once per index (progress is kept in the
/// index itself); after that the live streams keep it current.
class MatrixMessageSearchIndex implements LocalMessageSearch {
  MatrixMessageSearchIndex(
    this._access, {
    this._storage = const SqfliteMessageIndexStorage(),
    this._preference = const SharedMessageSearchPreference(),
    this.backfillRooms = 100,
    this.backfillEventsPerRoom = 300,
    this.firstSyncTimeout = const Duration(seconds: 30),
    this.liveBatchDelay = const Duration(milliseconds: 250),
  });

  final MatrixSdkAccess _access;
  final MessageIndexStorage _storage;
  final MessageSearchPreference _preference;
  final int backfillRooms;
  final int backfillEventsPerRoom;

  /// Backfill waits for the first sync after start (the SDK stores it on the
  /// same sqflite worker thread), or this long when there is none (offline).
  final Duration firstSyncTimeout;

  /// Live events arrive one at a time while the SDK stores a sync; they are
  /// written together this long after the first one.
  final Duration liveBatchDelay;

  matrix.Client? _client;
  String? _session;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool? _enabled;
  Future<bool>? _enabledLoad;
  String? _account;
  Future<MessageIndexStore?>? _store;
  Future<void> _io = Future<void>.value();
  int _epoch = 0;
  final _pending = <({String account, int epoch, IndexOp op})>[];
  Future<void>? _draining;
  Timer? _flushTimer;
  final _backfilled = <String>{};

  // [accountHash] of the session it was computed for (it is needed for
  // every live event, and SHA-256 per event adds up during a big sync).
  Uri? _hashedHomeserver;
  String? _hashedUser;
  String? _hashedDevice;
  String? _hashed;

  /// Stable, non-reversible index file name for one signed-in session
  /// (homeserver, user and device). A new sign-in gets a new device and so a
  /// new file; the previous session's index is deleted when the new one
  /// opens, even if its sign-out happened while indexing was not attached.
  static String accountHash(matrix.Client client) => sha256
      .convert(
        utf8.encode(
          jsonEncode(['${client.homeserver}', client.userID, client.deviceID]),
        ),
      )
      .toString()
      .substring(0, 32);

  String _accountOf(matrix.Client client) {
    final homeserver = client.homeserver;
    final user = client.userID;
    final device = client.deviceID;
    final hashed = _hashed;
    if (hashed != null &&
        homeserver == _hashedHomeserver &&
        user == _hashedUser &&
        device == _hashedDevice) {
      return hashed;
    }
    _hashedHomeserver = homeserver;
    _hashedUser = user;
    _hashedDevice = device;
    return _hashed = accountHash(client);
  }

  /// Completes when queued index writes, including live events still
  /// waiting for [liveBatchDelay], have been applied (for tests).
  @visibleForTesting
  Future<void> get idle async {
    while (_draining != null || _flushTimer != null) {
      if (_flushTimer != null) _drain();
      await _draining;
    }
    await _io;
  }

  matrix.Client? _currentClient() {
    final client = _access.sdkClient;
    if (client == null ||
        client.userID == null ||
        !_access.isSessionCurrent(client)) {
      return null;
    }
    return client;
  }

  /// Serialises opening, closing and deleting index files.
  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _io.then((_) => task());
    _io = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  void ensureStarted() {
    final client = _currentClient();
    if (client == null) return;
    if (!identical(client, _client)) _attach(client);
    final session = '${client.homeserver}|${client.userID}|${client.deviceID}';
    // Hot path (room screens rebuild on every sync): nothing to do while
    // this session's index is open or opening.
    if (session == _session && _store != null) return;
    _session = session;
    unawaited(_prepare(client).catchError((Object _) {}));
  }

  void _attach(matrix.Client client) {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions
      ..clear()
      ..add(client.onTimelineEvent.stream.listen((e) => _onEvent(client, e)))
      ..add(client.onHistoryEvent.stream.listen((e) => _onEvent(client, e)))
      // Messages whose keys arrive after their sync are stored decrypted
      // later and announced only on the deprecated onEvent stream (SDK 14.1
      // has no replacement). The per-launch backfill used to pick these up;
      // it now reads each room once, so index them as they are decrypted.
      ..add(
        // ignore: deprecated_member_use
        client.onEvent.stream.listen((update) {
          if (update.type != matrix.EventUpdateType.decryptedTimelineQueue) {
            return;
          }
          final room = client.getRoomById(update.roomID);
          if (room == null) return;
          final matrix.Event event;
          try {
            event = matrix.Event.fromJson(update.content, room);
          } catch (_) {
            return;
          }
          _onEvent(client, event);
        }),
      )
      ..add(
        client.onSessionCleared.stream.listen((_) {
          // Sign-out or remote session invalidation: delete the plaintext.
          _backfilled.clear();
          unawaited(_wipe().catchError((Object _) {}));
        }),
      );
    _client = client;
  }

  Future<void> _prepare(matrix.Client client) async {
    if (!await isEnabled()) return;
    if (!_access.isSessionCurrent(client) || client.userID == null) return;
    final account = _accountOf(client);
    final store = await _storeFor(account);
    if (store == null || !_access.isSessionCurrent(client)) return;
    if (_backfilled.add(account)) await _backfill(client, account);
  }

  Future<MessageIndexStore?> _storeFor(String account) {
    final existing = _store;
    if (_account == account && existing != null) return existing;
    _account = account;
    final epoch = _epoch;
    late final Future<MessageIndexStore?> opening;
    opening =
        _serial(() async {
          try {
            await (await existing)?.close();
          } catch (_) {}
          if (epoch != _epoch || _account != account) return null;
          try {
            // Single-account app: an index for any other account is stale.
            await _storage.deleteOthers(account);
            final store = await _storage.open(account);
            if (epoch != _epoch || _account != account) {
              await store.close();
              return null;
            }
            return store;
          } catch (_) {
            return null;
          }
        }).then((store) {
          // Allow a later retry after a failed open (no plugin, disk full …).
          if (store == null && identical(_store, opening)) _store = null;
          return store;
        });
    return _store = opening;
  }

  void _onEvent(matrix.Client client, matrix.Event event) {
    if (_enabled != true ||
        !_access.isSessionCurrent(client) ||
        client.userID == null) {
      return;
    }
    final List<IndexOp> ops;
    try {
      ops = indexOpsFor(event);
    } catch (_) {
      return;
    }
    if (ops.isEmpty) return;
    final account = _accountOf(client);
    for (final op in ops) {
      _pending.add((account: account, epoch: _epoch, op: op));
    }
    // Coalesce a sync's events into one write. A drain in progress picks
    // them up when its current batch is written.
    if (_draining == null) {
      _flushTimer ??= Timer(liveBatchDelay, _drain);
    }
  }

  /// Writes queued ops now.
  void _drain() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_draining != null) return;
    _draining = _drainPending().whenComplete(() {
      _draining = null;
      if (_pending.isNotEmpty) _drain();
    });
  }

  Future<void> _drainPending() async {
    while (_pending.isNotEmpty) {
      final batch = List.of(_pending);
      _pending.clear();
      final account = batch.first.account;
      final epoch = _epoch;
      final ops = [
        for (final item in batch)
          if (item.epoch == epoch && item.account == account) item.op,
      ];
      // Requeue another account's items (account switch mid-batch).
      _pending.insertAll(0, [
        for (final item in batch)
          if (item.epoch == epoch && item.account != account) item,
      ]);
      if (ops.isEmpty) continue;
      final store = await _storeFor(account);
      if (store == null || epoch != _epoch) continue;
      try {
        await store.apply(ops);
      } catch (_) {
        // Never retry indefinitely; later events write again.
      }
    }
  }

  /// Indexes the stored history of the first [backfillRooms] joined
  /// encrypted rooms, skipping rooms this index already holds. Each room
  /// costs a database read and JSON decoding on this isolate, so it waits
  /// for the first sync and yields between rooms.
  Future<void> _backfill(matrix.Client client, String account) async {
    final epoch = _epoch;
    bool current() =>
        epoch == _epoch && _enabled == true && _access.isSessionCurrent(client);
    await _firstSync(client);
    if (!current()) return;
    final store = await _storeFor(account);
    if (store == null || !current()) return;
    final Set<String> done;
    try {
      done = await store.backfilledRooms();
    } catch (_) {
      return;
    }
    if (!current()) return;
    final rooms = client.rooms
        .where(
          (room) => room.membership == matrix.Membership.join && room.encrypted,
        )
        .take(backfillRooms)
        .where((room) => !done.contains(room.id))
        .toList();
    for (final room in rooms) {
      // Let frames, input and sync work run between rooms.
      await Future<void>.delayed(Duration.zero);
      if (!current()) return;
      List<matrix.Event> events;
      try {
        events = await client.database.getEventList(
          room,
          limit: backfillEventsPerRoom,
        );
      } catch (_) {
        continue;
      }
      if (!current()) return;
      // Oldest first, so edits and redactions apply after their targets.
      for (final event in events.reversed) {
        try {
          for (final op in indexOpsFor(event)) {
            _pending.add((account: account, epoch: epoch, op: op));
          }
        } catch (_) {}
      }
      // Same batch as the room's messages: if the write fails, the room is
      // read again on a later launch.
      _pending.add((
        account: account,
        epoch: epoch,
        op: IndexRoomBackfilled(room.id),
      ));
      _drain();
      await _draining;
    }
  }

  /// Completes once [client] has synced since it started, or after
  /// [firstSyncTimeout] (offline), whichever is first.
  Future<void> _firstSync(matrix.Client client) async {
    if (client.onSync.value != null) return;
    final synced = Completer<void>();
    void done([Object? _]) {
      if (!synced.isCompleted) synced.complete();
    }

    final subscription = client.onSync.stream.listen(done, onError: done);
    final timer = Timer(firstSyncTimeout, done);
    try {
      await synced.future;
    } finally {
      timer.cancel();
      unawaited(subscription.cancel());
    }
  }

  Future<void> _wipe() async {
    _epoch++;
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    final store = _store;
    _store = null;
    _account = null;
    final draining = _draining;
    if (draining != null) await draining.catchError((Object _) {});
    await _serial(() async {
      try {
        await (await store)?.close();
      } catch (_) {}
      await _storage.deleteAll();
    });
  }

  @override
  Future<bool> isEnabled() async {
    final known = _enabled;
    if (known != null) return known;
    return _enabledLoad ??= () async {
      bool value;
      try {
        value = await _preference.read();
      } catch (_) {
        value = true;
      }
      return _enabled ??= value;
    }();
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    await _preference.write(enabled);
    _enabled = enabled;
    if (enabled) {
      _backfilled.clear();
      ensureStarted();
    } else {
      await _wipe();
    }
  }

  @override
  Future<void> clear() => _wipe();

  @override
  Future<LocalSearchPage> search(
    String query, {
    int offset = 0,
    int limit = 30,
  }) async {
    final client = _currentClient();
    if (client == null) throw StateError('No signed-in Matrix session');
    ensureStarted();
    if (!await isEnabled()) return const LocalSearchPage(hits: []);
    final tokens = searchTokens(query);
    if (tokens.isEmpty) return const LocalSearchPage(hits: []);
    final store = await _storeFor(_accountOf(client));
    if (store == null) throw StateError('Search index unavailable');
    final rows = await store.search(tokens, limit: limit + 1, offset: offset);
    if (!_access.isSessionCurrent(client)) {
      throw StateError('Matrix session changed');
    }
    final hits = <LocalMessageHit>[];
    for (final row in rows.take(limit)) {
      final room = client.getRoomById(row.roomId);
      if (room == null || room.membership != matrix.Membership.join) continue;
      final name = room
          .getState(matrix.EventTypes.RoomMember, row.sender)
          ?.content['displayname'];
      hits.add(
        LocalMessageHit(
          id: row.eventId,
          roomId: row.roomId,
          roomName: room.parallaxName,
          sender: name is String && name.trim().isNotEmpty
              ? name.trim()
              : row.sender,
          body: row.body,
          time: row.time,
          threadRootId: row.threadRootId,
        ),
      );
    }
    return LocalSearchPage(
      hits: hits,
      nextOffset: rows.length > limit ? offset + limit : null,
    );
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';
import '../threads/event_projection.dart';
import 'saved_features.dart';
import 'saved_models.dart';

typedef _Overlay = ({matrix.BasicEvent? base, Map<String, Object?> content});

/// Matrix implementation of [SavedFeatures].
///
/// Everything is user account data (`PUT /user/{id}/account_data/{type}`),
/// which is not end-to-end encrypted: only room IDs, event IDs, timestamps
/// and folder names are written. No timeline events are sent here; the only
/// room this creates is the Note to self room.
///
/// Writes re-read the server's current value first and are serialised per
/// type, so two quick changes (or a change made on another device a moment
/// ago) are not lost. Matrix has no compare-and-swap for account data, so a
/// simultaneous write on another device can still win.
class MatrixSavedFeatures extends ChangeNotifier implements SavedFeatures {
  MatrixSavedFeatures(
    this._backend,
    this._access, {
    this.syncWait = const Duration(seconds: 30),
  });

  final ChatBackend _backend;
  final MatrixSdkAccess _access;

  /// How long to wait for a new Note to self room to arrive through sync.
  final Duration syncWait;

  static const _eventCacheLimit = 200;
  static const _eventCacheTtl = Duration(minutes: 5);

  matrix.Client? _owner;
  // This device's latest write per type until sync delivers a newer event.
  final _overlays = <String, _Overlay>{};
  final _queues = <String, Future<void>>{};
  final _parsed = <String, (Map<String, Object?>?, Object)>{};
  final _events = <String, (SavedEventResult, DateTime)>{};
  Future<String>? _noteRequest;

  /// The current client, dropping per-session state when it changed.
  matrix.Client? _session() {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) return null;
    if (!identical(_owner, client)) {
      _owner = client;
      _overlays.clear();
      _queues.clear();
      _parsed.clear();
      _events.clear();
      _noteRequest = null;
    }
    return client;
  }

  matrix.Client _client() {
    final client = _session();
    if (client == null || client.userID == null) {
      throw StateError('Not signed in');
    }
    return client;
  }

  void _check(matrix.Client client) {
    if (!_access.isSessionCurrent(client) || !identical(_owner, client)) {
      throw StateError('This account session is no longer current.');
    }
  }

  bool _joined(matrix.Client client, String roomId) =>
      client.getRoomById(roomId)?.membership == matrix.Membership.join;

  // --- Account data plumbing -------------------------------------------------

  Map<String, Object?>? _content(String type) {
    final client = _session();
    if (client == null) return null;
    final event = client.accountData[type];
    final overlay = _overlays[type];
    if (overlay != null) {
      // Sync has not delivered anything for this type since our write.
      if (identical(overlay.base, event)) return overlay.content;
      _overlays.remove(type);
    }
    return event?.content;
  }

  T _parse<T extends Object>(
    String type,
    T Function(Map<String, Object?>? json) parse,
  ) {
    final content = _content(type);
    final cached = _parsed[type];
    if (cached != null && identical(cached.$1, content)) return cached.$2 as T;
    T value;
    try {
      value = parse(content);
    } catch (_) {
      value = parse(null); // A malformed record must not break the inbox.
    }
    _parsed[type] = (content, value);
    return value;
  }

  Future<Map<String, Object?>> _fresh(matrix.Client client, String type) async {
    try {
      final content = await client.getAccountData(client.userID!, type);
      _check(client);
      return content;
    } on matrix.MatrixException catch (error) {
      _check(client);
      if (error.errcode == 'M_NOT_FOUND') return const {};
      rethrow;
    }
  }

  /// Read-modify-write of one account-data type, serialised per type.
  Future<Map<String, Object?>> _modify(
    String type,
    Map<String, Object?> Function(Map<String, Object?> current) change,
  ) {
    final client = _client();
    final previous = _queues[type] ?? Future<void>.value();
    final run = previous.then((_) async {
      _check(client);
      final current = await _fresh(client, type);
      final next = change(current);
      if (jsonEncode(next) == jsonEncode(current)) return current;
      final base = client.accountData[type];
      await client.setAccountData(client.userID!, type, next);
      _check(client);
      _overlays[type] = (base: base, content: Map.unmodifiable(next));
      notifyListeners();
      return next;
    });
    _queues[type] = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Shows a fresher server value until sync catches up.
  void _adopt(matrix.Client client, String type, Map<String, Object?> content) {
    _overlays[type] = (
      base: client.accountData[type],
      content: Map.unmodifiable(content),
    );
    notifyListeners();
  }

  // --- Note to self ---------------------------------------------------------

  NoteToSelfRecord get _noteRecord =>
      _parse(SavedAccountData.noteToSelf, NoteToSelfRecord.fromJson);

  @override
  String? get noteToSelfRoomId {
    final client = _session();
    if (client == null) return null;
    final roomId = _noteRecord.roomId;
    return roomId != null && _joined(client, roomId) ? roomId : null;
  }

  @override
  bool get noteToSelfPromptDismissed =>
      _session() != null && _noteRecord.promptDismissed;

  @override
  Future<void> dismissNoteToSelfPrompt() => _modify(
    SavedAccountData.noteToSelf,
    (current) => NoteToSelfRecord.fromJson(
      current,
    ).copyWith(promptDismissed: true).toJson(),
  );

  @override
  Future<String> openNoteToSelf() {
    final client = _client();
    final existing = _noteRequest;
    if (existing != null) return existing;
    late final Future<String> request;
    request = _openNoteToSelf(client).whenComplete(() {
      if (identical(_noteRequest, request)) _noteRequest = null;
    });
    _noteRequest = request;
    return request;
  }

  Future<String> _openNoteToSelf(matrix.Client client) async {
    // 1. The synced record.
    final synced = _noteRecord.roomId;
    if (synced != null && _joined(client, synced)) {
      await _markDirect(client, synced);
      return synced;
    }
    // 2. Another device may have created it since the last sync.
    final freshContent = await _fresh(client, SavedAccountData.noteToSelf);
    final fresh = NoteToSelfRecord.fromJson(freshContent).roomId;
    if (fresh != null) {
      if (_joined(client, fresh)) {
        _adopt(client, SavedAccountData.noteToSelf, freshContent);
        await _markDirect(client, fresh);
        return fresh;
      }
      final joinedRooms = await client.getJoinedRooms();
      _check(client);
      if (joinedRooms.contains(fresh)) {
        _adopt(client, SavedAccountData.noteToSelf, freshContent);
        if (!await _waitForJoined(client, fresh)) {
          throw NoteToSelfNotSynced(fresh);
        }
        return fresh;
      }
      // The recorded room was left; a new one is created below.
    }
    // 3. A room created earlier whose record write did not complete.
    final recovered = _existingSelfRoom(client);
    if (recovered != null) {
      await _recordNoteToSelf(client, recovered);
      await _markDirect(client, recovered);
      return recovered;
    }
    // 4. Create a private, encrypted room with nobody else in it.
    if (!client.encryptionEnabled) {
      throw const NoteToSelfUnavailable(
        'Encryption isn’t available on this device yet, so your note to '
        'self wasn’t created. Set up encryption, then try again.',
      );
    }
    final roomId = await client.createRoom(
      name: noteToSelfTitle,
      preset: matrix.CreateRoomPreset.privateChat,
      isDirect: true,
      initialState: [
        matrix.StateEvent(
          type: matrix.EventTypes.Encryption,
          stateKey: '',
          content: {'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2},
        ),
      ],
    );
    _check(client);
    // Keep going after a failed record write: the room exists and the next
    // open recovers it from m.direct instead of creating another one.
    try {
      await _recordNoteToSelf(client, roomId);
    } catch (_) {
      _check(client);
    }
    await _markDirect(client, roomId);
    if (!await _waitForJoined(client, roomId)) {
      throw NoteToSelfNotSynced(roomId);
    }
    return roomId;
  }

  Future<void> _recordNoteToSelf(matrix.Client client, String roomId) async {
    _check(client);
    await _modify(
      SavedAccountData.noteToSelf,
      (current) =>
          NoteToSelfRecord.fromJson(current).copyWith(roomId: roomId).toJson(),
    );
  }

  /// Marks [roomId] as a direct chat with the user themselves so other
  /// clients treat it as a DM. Best effort: Parallax pins it either way.
  Future<void> _markDirect(matrix.Client client, String roomId) async {
    final own = client.userID!;
    if (client.directChats[own]?.contains(roomId) ?? false) return;
    try {
      await _modify('m.direct', (current) {
        final list = current[own];
        final ids = [if (list is List) ...list.whereType<String>()];
        if (ids.contains(roomId)) return current;
        return {
          ...current,
          own: [...ids, roomId],
        };
      });
    } catch (_) {
      _check(client);
    }
  }

  /// A joined room with only this user in it that is marked as a DM with
  /// themselves, or that this user created as "Note to self".
  String? _existingSelfRoom(matrix.Client client) {
    final own = client.userID;
    bool alone(matrix.Room room) =>
        room.membership == matrix.Membership.join &&
        !room.isSpace &&
        (room.summary.mJoinedMemberCount ?? 1) <= 1 &&
        (room.summary.mInvitedMemberCount ?? 0) == 0;
    for (final id in client.directChats[own] ?? const <String>[]) {
      final room = client.getRoomById(id);
      if (room != null && alone(room)) return id;
    }
    for (final room in client.rooms) {
      if (alone(room) &&
          room.encrypted &&
          room.name == noteToSelfTitle &&
          room.getState(matrix.EventTypes.RoomCreate)?.senderId == own) {
        return room.id;
      }
    }
    return null;
  }

  Future<bool> _waitForJoined(matrix.Client client, String roomId) async {
    if (_joined(client, roomId)) return true;
    final done = Completer<bool>();
    final subscription = client.onSyncStatus.stream.listen((update) {
      if (update.status == matrix.SyncStatus.finished &&
          _joined(client, roomId) &&
          !done.isCompleted) {
        done.complete(true);
      }
    });
    final timer = Timer(syncWait, () {
      if (!done.isCompleted) done.complete(false);
    });
    try {
      // A sync may have finished between the first check and subscribing.
      if (_joined(client, roomId)) return true;
      final joined = await done.future;
      _check(client);
      return joined;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  // --- Saved messages -------------------------------------------------------

  @override
  BookmarkList get bookmarks => _session() == null
      ? BookmarkList.empty
      : _parse(SavedAccountData.bookmarks, BookmarkList.fromJson);

  @override
  Future<void> setSaved(
    String roomId,
    String eventId, {
    required bool saved,
    DateTime? savedAt,
  }) async {
    if (!isRoomIdLike(roomId) || !isEventIdLike(eventId)) {
      throw ArgumentError('Only sent messages can be saved');
    }
    final savedTs = (savedAt ?? DateTime.now()).millisecondsSinceEpoch;
    await _modify(SavedAccountData.bookmarks, (current) {
      final list = BookmarkList.fromJson(current);
      return (saved
              ? list.withAdded(roomId, eventId, savedTs: savedTs)
              : list.withRemoved(roomId, eventId))
          .toJson();
    });
  }

  @override
  Future<SavedEventResult> loadSavedEvent(String roomId, String eventId) async {
    final client = _client();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      return const SavedEventResult.roomUnavailable();
    }
    // The open room's projection already has edits applied.
    if (_backend.activeRoomId == roomId) {
      for (final entry in _backend.messages) {
        if (entry.id == eventId) return SavedEventResult.available(entry);
      }
    }
    final key = '$roomId\n$eventId';
    final cached = _events[key];
    if (cached != null &&
        DateTime.now().difference(cached.$2) < _eventCacheTtl) {
      return cached.$1;
    }
    // Local database first, then GET /rooms/{id}/event/{id}; decrypted by
    // the SDK when keys are available.
    final event = await room.getEventById(eventId);
    _check(client);
    if (event == null) return const SavedEventResult.notFound();
    final result = SavedEventResult.available(projectStandaloneEvent(event));
    // Keys may still arrive for an undecryptable message: do not cache it.
    if (event.type != matrix.EventTypes.Encrypted) {
      _events.remove(key);
      _events[key] = (result, DateTime.now());
      while (_events.length > _eventCacheLimit) {
        _events.remove(_events.keys.first);
      }
    }
    return result;
  }

  // --- Chat folders ---------------------------------------------------------

  @override
  ChatFolders get folders => _session() == null
      ? ChatFolders.empty
      : _parse(SavedAccountData.folders, ChatFolders.fromJson);

  @override
  Future<ChatFolders> updateFolders(
    ChatFolders Function(ChatFolders current) change,
  ) async {
    ChatFolders? written;
    await _modify(SavedAccountData.folders, (current) {
      final next = change(ChatFolders.fromJson(current));
      written = next;
      return next.toJson();
    });
    return written ?? folders;
  }
}

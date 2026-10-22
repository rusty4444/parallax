import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails, VoidCallback, visibleForTesting;

import 'messaging_features.dart';
import 'secure_store.dart';
import 'send_cancellation.dart';

/// An immutable, durably accepted send. [id] is also its Matrix transaction ID.
class OutboxRecord {
  const OutboxRecord({
    required this.id,
    required this.accountKey,
    required this.roomId,
    required this.body,
    required this.createdAt,
    required this.state,
    this.media,
    this.caption,
    this.replyToId,
    this.editEventId,
    this.threadRootId,
    this.error,
    this.progress,
  });

  final String id;
  final String accountKey;
  final String roomId;
  final String body;
  final MediaSelection? media;
  final String? caption;
  final String? replyToId;
  final String? editEventId;
  final String? threadRootId;
  final String? error;
  final double? progress;
  final DateTime createdAt;
  final DeliveryState state;

  OutboxRecord _status(
    DeliveryState state, {
    String? error,
    double? progress,
  }) => OutboxRecord(
    id: id,
    accountKey: accountKey,
    roomId: roomId,
    body: body,
    createdAt: createdAt,
    state: state,
    media: media,
    caption: caption,
    replyToId: replyToId,
    editEventId: editEventId,
    threadRootId: threadRootId,
    error: error,
    progress: progress,
  );
}

/// Secure local acceptance followed by an independently owned network operation.
///
/// Enqueue/retry finish after persistence, not network delivery. Restore never
/// sends anything. A closed/replaced owner cancels and joins its transports;
/// transport implementations must eventually settle after cancellation. Already
/// issued storage writes cannot be revoked, so replacements read behind a
/// process-wide durable write fence. This is a single-isolate service, not an
/// inter-process database lock.
class MessageOutbox {
  MessageOutbox({
    SecureValueStore? storage,
    required String? Function() currentAccount,
    required Future<void> Function(
      OutboxRecord,
      SendCancellation,
      void Function(double),
    )
    transmit,
    VoidCallback? onChanged,
    @visibleForTesting int storedByteLimit = maxStoredBytes,
  }) : _storage = storage ?? const PlatformSecureValueStore(),
       _storedByteLimit = storedByteLimit,
       // Public callback names intentionally differ from private fields.
       // ignore: prefer_initializing_formals
       _currentAccount = currentAccount,
       // ignore: prefer_initializing_formals
       _transmit = transmit,
       // ignore: prefer_initializing_formals
       _onChanged = onChanged {
    if (storedByteLimit <= 0 || storedByteLimit > maxStoredBytes) {
      throw ArgumentError.value(storedByteLimit, 'storedByteLimit');
    }
  }

  static const maxPayloadBytes = 20 * 1024 * 1024;
  static const maxStoredBytes = 64 * 1024 * 1024;
  static const maxRecords = 100;
  static const _maxMetadataBytes = 64 * 1024;
  static const _maxErrorCodeUnits = 4096;
  // JSON escapes one UTF-16 code unit to at most six bytes. This covers a
  // bounded error (4096 * 6), state, progress, keys and punctuation per record.
  static const _lifecycleReserveBytes = 32 * 1024;
  static final _transactionId = RegExp(r'^mx_[A-Za-z0-9_-]{43}$');
  static final _random = Random.secure();
  static final _durable = _SerialQueue();
  static final _lanes = <String, _AccountLane>{};

  final SecureValueStore _storage;
  final int _storedByteLimit;
  final String? Function() _currentAccount;
  final Future<void> Function(
    OutboxRecord,
    SendCancellation,
    void Function(double),
  )
  _transmit;
  final VoidCallback? _onChanged;
  final _commands = _SerialQueue();
  final _retiring = <_Session, Future<void>>{};
  _Session? _session;
  bool _disposed = false;

  /// Only queued, sending and failed sends. A durably acknowledged delivery is
  /// removed, including its sensitive text/media, rather than retained as sent.
  List<OutboxRecord> get records {
    final session = _session;
    if (session == null || !_owns(session)) return const [];
    return List<OutboxRecord>.unmodifiable(session.records.values);
  }

  Future<void> restore(String accountKey) async {
    final session = _select(accountKey);
    await _commands.run(() => _load(session));
  }

  Future<String> enqueueText(
    String accountKey,
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
    String? threadRootId,
  }) async {
    if (text.trim().isEmpty) throw ArgumentError('Message must not be empty');
    return _enqueue(
      OutboxRecord(
        id: _newId(),
        accountKey: accountKey,
        roomId: roomId,
        body: text,
        createdAt: DateTime.now().toUtc(),
        state: DeliveryState.queued,
        replyToId: replyToId,
        editEventId: editEventId,
        threadRootId: threadRootId,
      ),
    );
  }

  Future<String> enqueueMedia(
    String accountKey,
    String roomId,
    MediaSelection media, {
    String? caption,
    String? replyToId,
    String? threadRootId,
  }) async {
    // Check before copying or base64 encoding an untrusted picker payload.
    if (media.bytes.isEmpty || media.bytes.length > maxPayloadBytes) {
      throw ArgumentError('Media must contain 1 to $maxPayloadBytes bytes');
    }
    final ownedMedia = MediaSelection(
      bytes: Uint8List.fromList(media.bytes).asUnmodifiableView(),
      name: media.name,
      mimeType: media.mimeType,
      durationMs: media.durationMs,
    );
    return _enqueue(
      OutboxRecord(
        id: _newId(),
        accountKey: accountKey,
        roomId: roomId,
        body: caption == null || caption.isEmpty ? media.name : caption,
        media: ownedMedia,
        caption: caption,
        replyToId: replyToId,
        threadRootId: threadRootId,
        createdAt: DateTime.now().toUtc(),
        state: DeliveryState.queued,
      ),
    );
  }

  Future<String> _enqueue(OutboxRecord record) async {
    try {
      _validateRecord(record, record.accountKey);
    } on FormatException catch (error) {
      throw ArgumentError(error.message);
    }
    final session = _select(record.accountKey);
    return _commands.run(() async {
      await _load(session);
      await _update(
        session,
        (next) => next[record.id] = record,
        reserveLifecycleSpace: true,
      );
      _start(session, record.id);
      return record.id;
    });
  }

  /// Durable retry acceptance. Ambiguous/failed sends retain their transaction
  /// ID for Matrix idempotency. Retired successful IDs are no-ops.
  Future<void> retry(String id) async {
    final session = _session;
    if (session == null) return;
    await _commands.run(() async {
      _check(session);
      await _load(session);
      final oldJob = session.jobs[id];
      if (oldJob != null) {
        if (!oldJob.stopped) return;
        await oldJob.done.future;
      }
      _check(session);
      final record = session.records[id];
      if (record == null || record.state == DeliveryState.sent) return;
      await _update(
        session,
        (next) => next[id] = record._status(DeliveryState.queued),
      );
      _start(session, id);
    });
  }

  /// Request cancellation synchronously, then join before marking it failed.
  Future<void> cancel(String id) => _stop(id, discard: false);

  /// No transport can still be using the payload when this future completes.
  Future<void> discard(String id) => _stop(id, discard: true);

  Future<void> _stop(String id, {required bool discard}) {
    final session = _session;
    if (session == null) return Future<void>.value();
    // Fence starts as well as an existing transport: retry may currently be
    // suspended in its durable acceptance write and not have a job yet.
    session.stops.update(id, (count) => count + 1, ifAbsent: () => 1);
    session.jobs[id]?.stop();
    return _commands.run(() async {
      try {
        final job = session.jobs[id];
        job?.stop();
        await job?.done.future;
        if (!_owns(session)) return;
        final record = session.records[id];
        if (record == null) return;
        if (discard) {
          await _update(session, (next) => next.remove(id));
        } else if (record.state != DeliveryState.sent) {
          await _update(
            session,
            (next) => next[id] = record._status(
              DeliveryState.failed,
              error: 'Send cancelled',
            ),
          );
        }
      } finally {
        final remaining = session.stops[id]! - 1;
        if (remaining == 0) {
          session.stops.remove(id);
        } else {
          session.stops[id] = remaining;
        }
      }
    });
  }

  /// Synchronously invalidate all callbacks; the returned future joins cleanup.
  /// Durable entries are retained for explicit retry after the next restore.
  Future<void> closeAccount() {
    final session = _session;
    _session = null;
    if (session != null) _retire(session);
    return Future.wait<void>([
      ..._retiring.values,
      _commands.idle,
    ]).then((_) {});
  }

  Future<void> dispose() {
    _disposed = true;
    return closeAccount();
  }

  static String _newId() =>
      'mx_${base64Url.encode(List<int>.generate(32, (_) => _random.nextInt(256))).replaceAll('=', '')}';

  static String _storageKey(String accountKey) =>
      'matrixpress.outbox.v1.${sha256.convert(utf8.encode(accountKey))}';

  _Session _select(String accountKey) {
    if (_disposed) throw StateError('Outbox is disposed');
    if (_currentAccount() != accountKey) throw const SendCancelled();
    if (accountKey.isEmpty ||
        utf8.encode(accountKey).length > _maxMetadataBytes) {
      throw ArgumentError('Invalid account key');
    }
    final old = _session;
    if (old != null && !old.closed && old.accountKey == accountKey) return old;
    if (old != null) _retire(old);
    final key = _storageKey(accountKey);
    final lane = _lanes.putIfAbsent(key, _AccountLane.new);
    return _session = _Session(accountKey, key, lane, this);
  }

  bool _requested(_Session session) =>
      !_disposed &&
      !session.closed &&
      identical(_session, session) &&
      _currentAccount() == session.accountKey;

  bool _owns(_Session session) =>
      _requested(session) && identical(session.lane.owner, session);

  void _check(_Session session) {
    if (!_owns(session)) throw const SendCancelled();
  }

  Future<void> _retire(_Session session) {
    final existing = _retiring[session];
    if (existing != null) return existing;
    session.closed = true;
    for (final job in session.jobs.values) {
      job.stop();
    }
    final joined =
        Future.wait<void>([
          for (final job in session.jobs.values) job.done.future,
        ]).then((_) {
          if (identical(session.lane.owner, session)) session.lane.owner = null;
          session.records.clear();
          _retiring.remove(session);
        });
    _retiring[session] = joined;
    return joined;
  }

  Future<void> _load(_Session session) async {
    if (!_requested(session)) throw const SendCancelled();
    if (session.loaded) {
      _check(session);
      return;
    }
    // Ownership acquisition is separate from the durable queue: joining while
    // holding the write fence could deadlock a transport's terminal write.
    await session.lane.claims.run(() async {
      if (!_requested(session)) throw const SendCancelled();
      final previous = session.lane.owner;
      if (previous != null && !identical(previous, session)) {
        await previous.outbox._retire(previous);
      }
      if (!_requested(session)) throw const SendCancelled();
      session.lane.owner = session;
    });
    await _durable.run(() async {
      _check(session);
      // A failed read or corrupt snapshot never grants permission to overwrite.
      final raw = await _storage.read(session.storageKey);
      _check(session);
      final restored = raw == null
          ? <String, OutboxRecord>{}
          : _decode(raw, session.accountKey);
      var retiredSent = false;
      for (final record in restored.values.toList()) {
        if (record.state == DeliveryState.sent) {
          retiredSent = true;
          restored.remove(record.id);
        } else if (record.state == DeliveryState.queued ||
            record.state == DeliveryState.sending) {
          restored[record.id] = record._status(
            DeliveryState.failed,
            error: 'Send interrupted; retry explicitly',
          );
        }
      }
      // Recovery is a projection, not a mandatory expanded write: a valid
      // legacy snapshot at the byte ceiling must remain readable/discardable
      // even when storage is unavailable. Never replay it automatically.
      if (retiredSent) {
        await _persist(session, restored);
        _check(session);
      }
      session.records = restored;
      session.loaded = true;
      _notify(session);
    });
  }

  Future<void> _update(
    _Session session,
    void Function(Map<String, OutboxRecord>) change, {
    bool Function()? allowed,
    bool reserveLifecycleSpace = false,
  }) => _durable.run(() async {
    _check(session);
    if (allowed != null && !allowed()) throw const SendCancelled();
    // Compute at the write fence, not before waiting for another writer.
    final next = Map<String, OutboxRecord>.of(session.records);
    change(next);
    if (reserveLifecycleSpace) {
      _checkAcceptanceCapacity(session.accountKey, next);
    }
    await _persist(session, next);
    _check(session);
    // A stop can prevent a write from starting, but cannot undo a committed
    // acknowledgement. Publish that removal before cancel joins this job.
    session.records = next;
    _notify(session);
  });

  void _start(_Session session, String id) {
    if (!_owns(session) ||
        session.jobs.containsKey(id) ||
        session.stops.containsKey(id)) {
      return;
    }
    final job = _SendJob();
    session.jobs[id] = job;
    // _send catches transport AND persistence errors; done always settles.
    unawaited(_send(session, id, job));
  }

  bool _active(_Session session, String id, _SendJob job) =>
      _owns(session) &&
      !session.stops.containsKey(id) &&
      !job.stopped &&
      !job.cancellation.isCancelled &&
      identical(session.jobs[id], job);

  Future<void> _send(_Session session, String id, _SendJob job) async {
    bool active() => _active(session, id, job);
    try {
      await _update(
        session,
        (next) => next[id] = next[id]!._status(DeliveryState.sending),
        allowed: active,
      );
      if (!active()) return;
      await _transmit(session.records[id]!, job.cancellation, (progress) {
        if (!active() || !progress.isFinite) return;
        final record = session.records[id];
        if (record == null || record.state != DeliveryState.sending) return;
        session.records[id] = record._status(
          DeliveryState.sending,
          progress: progress.clamp(0.0, 1.0),
        );
        _notify(session);
      });
      if (!active()) return;
      await _update(session, (next) => next.remove(id), allowed: active);
    } catch (error) {
      if (!active()) return;
      final record = session.records[id];
      if (record == null) return;
      var failed = record._status(
        DeliveryState.failed,
        error: _errorText(error),
      );
      try {
        await _update(session, (next) => next[id] = failed, allowed: active);
      } catch (persistenceError) {
        if (!active()) return;
        // Acceptance is already durable. Surface the failure locally even if
        // storage is unavailable; the durable queued/sending marker is recovered
        // as failed on restart, with the same transaction ID.
        failed = failed._status(
          DeliveryState.failed,
          error: _errorText(
            '$error (outbox persistence failed: $persistenceError)',
          ),
        );
        session.records[id] = failed;
        _notify(session);
      }
    } finally {
      if (identical(session.jobs[id], job)) session.jobs.remove(id);
      job.done.complete();
    }
  }

  static String _errorText(Object error) {
    final text = error.toString();
    // Bound arbitrary provider exception strings even for multi-byte content.
    return text.length > _maxErrorCodeUnits
        ? text.substring(0, _maxErrorCodeUnits)
        : text;
  }

  void _notify(_Session session) {
    if (!_owns(session)) return;
    try {
      _onChanged?.call();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack, library: 'outbox'),
      );
    }
  }

  Future<void> _persist(_Session session, Map<String, OutboxRecord> records) =>
      records.isEmpty
      ? _storage.delete(session.storageKey)
      : _storage.write(
          session.storageKey,
          _encode(session.accountKey, records),
        );

  void _checkAcceptanceCapacity(
    String accountKey,
    Map<String, OutboxRecord> records,
  ) {
    if (records.length > maxRecords) throw StateError('Outbox is full');
    final payloads = records.values.map((record) {
      final entry = _recordJson(record)
        ..remove('error')
        ..remove('progress');
      entry['state'] = 'sending'; // Longest pending state name.
      return entry;
    }).toList();
    final bytes = utf8.encode(_snapshot(accountKey, payloads)).length;
    if (bytes + records.length * _lifecycleReserveBytes > _storedByteLimit) {
      throw StateError('Outbox exceeds $_storedByteLimit stored bytes');
    }
  }

  String _encode(String accountKey, Map<String, OutboxRecord> records) {
    if (records.length > maxRecords) throw StateError('Outbox is full');
    final entries = records.values.map(_recordJson).toList();
    var encoded = _snapshot(accountKey, entries);
    if (_exceedsLimit(encoded)) {
      // Old valid snapshots did not reserve lifecycle headroom. Diagnostics are
      // optional; never let their expansion strand accepted payloads or prevent
      // deleting one record while recovering the others. Identity/payload and
      // failed state are retained, so explicit retries remain idempotent.
      for (final entry in entries) {
        entry.remove('error');
        entry.remove('progress');
      }
      encoded = _snapshot(accountKey, entries);
    }
    if (_exceedsLimit(encoded)) {
      throw StateError('Outbox exceeds $_storedByteLimit stored bytes');
    }
    return encoded;
  }

  bool _exceedsLimit(String encoded) =>
      encoded.length > _storedByteLimit ||
      utf8.encode(encoded).length > _storedByteLimit;

  static String _snapshot(
    String accountKey,
    List<Map<String, Object?>> entries,
  ) => jsonEncode({'version': 1, 'accountKey': accountKey, 'records': entries});

  static Map<String, Object?> _recordJson(OutboxRecord record) => {
    'id': record.id,
    'accountKey': record.accountKey,
    'roomId': record.roomId,
    'body': record.body,
    'createdAt': record.createdAt.toUtc().toIso8601String(),
    'state': record.state.name,
    if (record.caption != null) 'caption': record.caption,
    if (record.replyToId != null) 'replyToId': record.replyToId,
    if (record.editEventId != null) 'editEventId': record.editEventId,
    if (record.threadRootId != null) 'threadRootId': record.threadRootId,
    if (record.error != null) 'error': record.error,
    if (record.progress != null) 'progress': record.progress,
    if (record.media case final media?)
      'media': {
        'bytes': base64.encode(media.bytes),
        'name': media.name,
        'mimeType': media.mimeType,
        if (media.durationMs != null) 'durationMs': media.durationMs,
      },
  };

  Map<String, OutboxRecord> _decode(String raw, String accountKey) {
    try {
      if (_exceedsLimit(raw)) {
        throw const FormatException('Oversized outbox snapshot');
      }
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['version'] != 1 || json['accountKey'] != accountKey) {
        throw const FormatException('Invalid outbox version or account');
      }
      final entries = json['records'] as List<dynamic>;
      if (entries.length > maxRecords) {
        throw const FormatException('Too many outbox records');
      }
      final result = <String, OutboxRecord>{};
      for (final value in entries) {
        final item = value as Map<String, dynamic>;
        MediaSelection? media;
        if (item['media'] != null) {
          final attachment = item['media'] as Map<String, dynamic>;
          final bytes = attachment['bytes'] as String;
          if (bytes.length > ((maxPayloadBytes + 2) ~/ 3) * 4) {
            throw const FormatException('Oversized outbox media');
          }
          media = MediaSelection(
            bytes: base64.decode(bytes).asUnmodifiableView(),
            name: attachment['name'] as String,
            mimeType: attachment['mimeType'] as String,
            durationMs: attachment['durationMs'] as int?,
          );
        }
        final record = OutboxRecord(
          id: item['id'] as String,
          accountKey: item['accountKey'] as String,
          roomId: item['roomId'] as String,
          body: item['body'] as String,
          createdAt: DateTime.parse(item['createdAt'] as String).toUtc(),
          state: DeliveryState.values.byName(item['state'] as String),
          media: media,
          caption: item['caption'] as String?,
          replyToId: item['replyToId'] as String?,
          editEventId: item['editEventId'] as String?,
          threadRootId: item['threadRootId'] as String?,
          error: item['error'] as String?,
          progress: (item['progress'] as num?)?.toDouble(),
        );
        _validateRecord(record, accountKey);
        if (result.containsKey(record.id)) {
          throw const FormatException('Duplicate outbox transaction ID');
        }
        result[record.id] = record;
      }
      return result;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid outbox snapshot');
    }
  }

  static void _validateRecord(OutboxRecord record, String accountKey) {
    if (!_transactionId.hasMatch(record.id) ||
        record.accountKey != accountKey ||
        accountKey.isEmpty ||
        record.roomId.isEmpty) {
      throw const FormatException('Invalid outbox identity');
    }
    for (final metadata in [
      record.accountKey,
      record.roomId,
      record.caption,
      record.replyToId,
      record.editEventId,
      record.threadRootId,
      record.error,
      record.media?.name,
      record.media?.mimeType,
    ]) {
      if (metadata != null &&
          (metadata.length > _maxMetadataBytes ||
              utf8.encode(metadata).length > _maxMetadataBytes)) {
        throw const FormatException('Oversized outbox metadata');
      }
    }
    if (record.body.length > maxPayloadBytes ||
        utf8.encode(record.body).length > maxPayloadBytes) {
      throw const FormatException('Oversized outbox text');
    }
    final progress = record.progress;
    if (progress != null &&
        (!progress.isFinite || progress < 0 || progress > 1)) {
      throw const FormatException('Invalid outbox progress');
    }
    final media = record.media;
    if (media == null) {
      if (record.body.trim().isEmpty) {
        throw const FormatException('Empty outbox text');
      }
    } else if (media.bytes.isEmpty ||
        media.bytes.length > maxPayloadBytes ||
        media.name.isEmpty ||
        media.mimeType.isEmpty ||
        (media.durationMs != null && media.durationMs! < 0)) {
      throw const FormatException('Invalid outbox media');
    }
  }
}

class _SerialQueue {
  Future<void> _tail = Future<void>.value();
  Future<void> get idle => _tail;

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class _AccountLane {
  final claims = _SerialQueue();
  _Session? owner;
}

class _Session {
  _Session(this.accountKey, this.storageKey, this.lane, this.outbox);
  final String accountKey;
  final String storageKey;
  final _AccountLane lane;
  final MessageOutbox outbox;
  Map<String, OutboxRecord> records = {};
  final jobs = <String, _SendJob>{};
  final stops = <String, int>{};
  bool loaded = false;
  bool closed = false;
}

class _SendJob {
  final cancellation = SendCancellation();
  final done = Completer<void>();
  bool stopped = false;

  void stop() {
    stopped = true;
    cancellation.cancel();
  }
}

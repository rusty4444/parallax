import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../secure_store.dart';
import 'delayed_events.dart';

/// The local plaintext record of a message scheduled from this device.
///
/// The server's list only holds ciphertext for encrypted rooms, so this is
/// what the scheduled-messages list previews and what Reschedule re-encrypts.
/// Kept in platform secure storage, keyed by account and `delay_id`.
@immutable
class ScheduledRecord {
  const ScheduledRecord({
    required this.delayId,
    required this.roomId,
    required this.type,
    required this.content,
    required this.sendAt,
    required this.createdAt,
    required this.encrypted,
  });

  final String delayId;
  final String roomId;
  final String type;

  /// Plaintext content exactly as scheduled (before encryption).
  final Map<String, Object?> content;
  final DateTime sendAt;
  final DateTime createdAt;
  final bool encrypted;

  String? get preview => previewOf(content);

  Map<String, Object?> toJson() => {
    'delayId': delayId,
    'roomId': roomId,
    'type': type,
    'content': content,
    'sendAt': sendAt.toUtc().millisecondsSinceEpoch,
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
    'encrypted': encrypted,
  };

  static ScheduledRecord fromJson(Map<String, Object?> json) {
    final delayId = json['delayId'];
    final roomId = json['roomId'];
    final type = json['type'];
    final content = json['content'];
    final sendAt = json['sendAt'];
    final createdAt = json['createdAt'];
    final encrypted = json['encrypted'];
    if (delayId is! String ||
        delayId.isEmpty ||
        delayId.length > 255 ||
        roomId is! String ||
        roomId.isEmpty ||
        roomId.length > 255 ||
        type is! String ||
        type.isEmpty ||
        type.length > 255 ||
        content is! Map ||
        sendAt is! int ||
        createdAt is! int ||
        encrypted is! bool) {
      throw const FormatException('Invalid scheduled message record');
    }
    return ScheduledRecord(
      delayId: delayId,
      roomId: roomId,
      type: type,
      content: Map<String, Object?>.from(content),
      sendAt: DateTime.fromMillisecondsSinceEpoch(sendAt, isUtc: true),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
      encrypted: encrypted,
    );
  }
}

/// A short, bounded plaintext preview of message content.
String? previewOf(Map<String, Object?> content) {
  final body = content['body'];
  if (body is! String || body.trim().isEmpty) return null;
  final text = body.trim();
  return text.length > 500 ? '${text.substring(0, 500)}…' : text;
}

/// Secure, account-scoped storage of [ScheduledRecord]s.
///
/// Read-modify-write is serialised per storage key across instances. A failed
/// or corrupt read throws and never authorises an overwrite.
class ScheduledMessageStore {
  ScheduledMessageStore({SecureValueStore? storage})
    : _storage = storage ?? const PlatformSecureValueStore();

  static const maxRecords = 100;
  static const maxSnapshotBytes = 1024 * 1024;
  static final _lanes = <String, Future<void>>{};

  final SecureValueStore _storage;

  static String storageKey(String accountKey) =>
      'parallax.scheduled.v1.${sha256.convert(utf8.encode(accountKey))}';

  Future<T> _serial<T>(String key, Future<T> Function() action) {
    final previous = _lanes[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _lanes[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_lanes[key], tail)) _lanes.remove(key);
      }),
    );
    return result;
  }

  Future<Map<String, ScheduledRecord>> read(String accountKey) {
    _checkAccount(accountKey);
    final key = storageKey(accountKey);
    return _serial(key, () => _read(key, accountKey));
  }

  Future<void> put(String accountKey, ScheduledRecord record) =>
      _modify(accountKey, (records) {
        records[record.delayId] = record;
        if (records.length > maxRecords) {
          throw StateError('Too many scheduled messages on this device');
        }
      });

  Future<void> remove(String accountKey, Iterable<String> delayIds) {
    final ids = delayIds.toSet();
    if (ids.isEmpty) return Future<void>.value();
    return _modify(
      accountKey,
      (records) => records.removeWhere((id, _) => ids.contains(id)),
    );
  }

  Future<void> _modify(
    String accountKey,
    void Function(Map<String, ScheduledRecord>) change,
  ) {
    _checkAccount(accountKey);
    final key = storageKey(accountKey);
    return _serial(key, () async {
      final records = await _read(key, accountKey);
      final before = records.length;
      change(records);
      if (records.isEmpty) {
        if (before > 0) await _storage.delete(key);
        return;
      }
      final encoded = jsonEncode({
        'version': 1,
        'accountKey': accountKey,
        'records': [for (final record in records.values) record.toJson()],
      });
      if (utf8.encode(encoded).length > maxSnapshotBytes) {
        throw StateError('Scheduled message records are too large');
      }
      await _storage.write(key, encoded);
    });
  }

  Future<Map<String, ScheduledRecord>> _read(
    String key,
    String accountKey,
  ) async {
    final raw = await _storage.read(key);
    if (raw == null) return {};
    try {
      if (raw.length > maxSnapshotBytes) {
        throw const FormatException('Oversized scheduled records');
      }
      final json = jsonDecode(raw);
      if (json is! Map ||
          json['version'] != 1 ||
          json['accountKey'] != accountKey ||
          json['records'] is! List) {
        throw const FormatException('Invalid scheduled records');
      }
      final records = <String, ScheduledRecord>{};
      for (final item in json['records'] as List) {
        if (item is! Map) {
          throw const FormatException('Invalid scheduled record');
        }
        final record = ScheduledRecord.fromJson(
          Map<String, Object?>.from(item),
        );
        records[record.delayId] = record;
      }
      if (records.length > maxRecords) {
        throw const FormatException('Too many scheduled records');
      }
      return records;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid scheduled records');
    }
  }

  static void _checkAccount(String accountKey) {
    if (accountKey.isEmpty || accountKey.length > 4096) {
      throw ArgumentError('Invalid account key');
    }
  }
}

/// A scheduled message as shown in the list.
@immutable
class ScheduledMessage {
  const ScheduledMessage({
    required this.delayId,
    required this.roomId,
    required this.type,
    required this.sendAt,
    required this.encrypted,
    this.content,
    this.confirmed = true,
  });

  final String delayId;
  final String roomId;

  /// Inner (plaintext) event type, e.g. `m.room.message`.
  final String type;
  final DateTime sendAt;
  final bool encrypted;

  /// Plaintext content, when known (local record or unencrypted server copy).
  final Map<String, Object?>? content;

  /// False while only the local record is known (the server list could not
  /// be read); the message may already have been sent or cancelled.
  final bool confirmed;

  String? get preview => content == null ? null : previewOf(content!);

  /// Rescheduling re-sends the plaintext content, so it must be known.
  bool get canReschedule => content != null && content!.isNotEmpty;
}

/// Display types offered in the list. Other delayed events (for example
/// Element Call's) are left alone.
const scheduledMessageTypes = {'m.room.message', 'm.sticker'};

/// Result of merging local records with the server list.
@immutable
class ScheduledReconciliation {
  const ScheduledReconciliation({required this.items, required this.stale});

  /// Messages to show, keyed by delay ID.
  final Map<String, ScheduledMessage> items;

  /// Local records the server no longer has (sent or cancelled). Only
  /// non-empty when the server list was complete.
  final Set<String> stale;
}

/// Merges [local] records with the [server] list.
///
/// * Server timeline events with a local record show the local plaintext.
/// * Unencrypted server-only `m.room.message`/`m.sticker` events show their
///   own content. Encrypted server-only events are not shown: their type is
///   unknown (they may belong to another client feature) and decrypting them
///   locally would record the Megolm message index against a synthetic event
///   ID, making the real event undecryptable later ("channel corrupted").
/// * When the server list is unavailable, local records are shown
///   unconfirmed. When it was incomplete, nothing is treated as stale.
/// * Records created after [listedAt] are never stale (the list predates them).
ScheduledReconciliation reconcileScheduled({
  required Map<String, ScheduledRecord> local,
  required ServerDelayedEvents? server,
  DateTime? listedAt,
}) {
  final items = <String, ScheduledMessage>{};
  if (server == null) {
    for (final record in local.values) {
      items[record.delayId] = ScheduledMessage(
        delayId: record.delayId,
        roomId: record.roomId,
        type: record.type,
        sendAt: record.sendAt,
        encrypted: record.encrypted,
        content: record.content,
        confirmed: false,
      );
    }
    return ScheduledReconciliation(items: items, stale: const {});
  }
  final listed = <String>{};
  for (final event in server.events) {
    listed.add(event.delayId);
    if (!event.isTimelineEvent) continue;
    final record = local[event.delayId];
    if (record != null && record.roomId == event.roomId) {
      items[event.delayId] = ScheduledMessage(
        delayId: event.delayId,
        roomId: event.roomId,
        type: record.type,
        sendAt: event.sendAt ?? record.sendAt,
        encrypted: record.encrypted || event.type == 'm.room.encrypted',
        content: record.content,
      );
      continue;
    }
    if (event.sendAt == null) continue;
    if (scheduledMessageTypes.contains(event.type)) {
      items[event.delayId] = ScheduledMessage(
        delayId: event.delayId,
        roomId: event.roomId,
        type: event.type,
        sendAt: event.sendAt!,
        encrypted: false,
        content: event.content,
      );
    }
  }
  final stale = <String>{};
  if (server.complete) {
    for (final record in local.values) {
      if (listed.contains(record.delayId)) continue;
      if (listedAt != null && record.createdAt.isAfter(listedAt)) {
        items[record.delayId] = ScheduledMessage(
          delayId: record.delayId,
          roomId: record.roomId,
          type: record.type,
          sendAt: record.sendAt,
          encrypted: record.encrypted,
          content: record.content,
        );
        continue;
      }
      stale.add(record.delayId);
    }
  } else {
    for (final record in local.values) {
      items.putIfAbsent(
        record.delayId,
        () => ScheduledMessage(
          delayId: record.delayId,
          roomId: record.roomId,
          type: record.type,
          sendAt: record.sendAt,
          encrypted: record.encrypted,
          content: record.content,
          confirmed: false,
        ),
      );
    }
  }
  return ScheduledReconciliation(items: items, stale: stale);
}

// Small private store for notification state shared by the main isolate and
// short-lived background isolates (FCM, UnifiedPush and notification-action
// engines run in the same process): preferences, the last few messages per
// room (MessagingStyle history) and quick replies waiting for the app.
//
// Files live in the app's private support directory (excluded from backup).
// Writes are atomic (temp file + rename) and serialised with an exclusive
// lock file, because POSIX file locks do not exclude isolates of one process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'notification_content.dart';
import 'notification_model.dart';

/// Largest store file read (bounds hostile/corrupt files).
const _maxStoreFileBytes = 512 * 1024;

/// Pending quick replies kept at once.
const _maxPendingReplies = 10;

/// Rooms whose newest line is older than this are dropped from history.
const _historyMaxAge = Duration(days: 3);

class NotificationStore {
  NotificationStore(this.directory, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// The production store under the app support directory.
  static Future<NotificationStore> open() async {
    final support = await getApplicationSupportDirectory();
    return NotificationStore(
      Directory(p.join(support.path, 'parallax_notifications')),
    );
  }

  final Directory directory;
  final DateTime Function() _clock;
  Future<void> _tail = Future<void>.value();

  File get _preferencesFile => File(p.join(directory.path, 'preferences.json'));
  File get _historyFile => File(p.join(directory.path, 'history.json'));
  File get _repliesFile => File(p.join(directory.path, 'pending_replies.json'));
  File get _lockFile => File(p.join(directory.path, '.lock'));

  // --- Preferences ---------------------------------------------------------

  Future<NotificationPreferences> readPreferences() async =>
      NotificationPreferences.fromJson(await _readJson(_preferencesFile));

  Future<void> writePreferences(NotificationPreferences preferences) =>
      _locked(() => _writeJson(_preferencesFile, preferences.toJson()));

  // --- History -------------------------------------------------------------

  /// Appends [event]'s line to its room (deduplicated by event ID) and
  /// returns the updated thread. History belongs to one [account]; another
  /// account's history is discarded.
  Future<RoomNotificationThread> appendEvent(
    String account,
    ResolvedPushEvent event,
  ) => _locked(() async {
    final history = await _readHistory(account);
    final existing = history.rooms[event.roomId];
    final lines = [
      ...?existing?.lines.where((line) => line.eventId != event.eventId),
      event.line,
    ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final thread = RoomNotificationThread(
      roomId: event.roomId,
      roomName: event.roomName,
      isDirect: event.isDirect,
      roomAvatarPath: event.roomAvatarPath ?? existing?.roomAvatarPath,
      latestEventId: event.eventId,
      lines: lines.length > maxLinesPerRoom
          ? lines.sublist(lines.length - maxLinesPerRoom)
          : lines,
    );
    history.rooms[event.roomId] = thread;
    await _writeHistory(history);
    return thread;
  });

  /// Adds a line sent from this device (a quick reply) to an existing room
  /// thread. Returns null when the room has no notification history.
  Future<RoomNotificationThread?> appendOwnLine(
    String account,
    String roomId,
    NotificationLine line,
  ) => _locked(() async {
    final history = await _readHistory(account);
    final existing = history.rooms[roomId];
    if (existing == null) return null;
    final lines = [...existing.lines, line];
    final thread = RoomNotificationThread(
      roomId: roomId,
      roomName: existing.roomName,
      isDirect: existing.isDirect,
      roomAvatarPath: existing.roomAvatarPath,
      latestEventId: existing.latestEventId,
      lines: lines.length > maxLinesPerRoom
          ? lines.sublist(lines.length - maxLinesPerRoom)
          : lines,
    );
    history.rooms[roomId] = thread;
    await _writeHistory(history);
    return thread;
  });

  /// Current room threads for [account], newest first.
  Future<List<RoomNotificationThread>> threads(String account) async {
    final history = await _readHistory(account);
    return history.rooms.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<RoomNotificationThread?> thread(String account, String roomId) async =>
      (await _readHistory(account)).rooms[roomId];

  /// Forgets [roomIds] (opened or read). Returns the IDs that were present.
  Future<Set<String>> removeRooms(String account, Iterable<String> roomIds) =>
      _locked(() async {
        final history = await _readHistory(account);
        final removed = <String>{};
        for (final id in roomIds) {
          if (history.rooms.remove(id) != null) removed.add(id);
        }
        if (removed.isNotEmpty) await _writeHistory(history);
        return removed;
      });

  // --- Pending quick replies ----------------------------------------------

  Future<void> addPendingReply(PendingReply reply) => _locked(() async {
    final now = _clock();
    final replies = [
      ...(await _readReplies()).where((r) => !r.isExpired(now)),
      reply,
    ];
    await _writeJson(_repliesFile, {
      'v': 1,
      'replies': [
        for (final r in replies.skip(
          max(0, replies.length - _maxPendingReplies),
        ))
          r.toJson(),
      ],
    });
  });

  /// Removes and returns every pending reply (expired ones included, so the
  /// caller can tell the user they were not sent).
  Future<List<PendingReply>> takePendingReplies() => _locked(() async {
    final replies = await _readReplies();
    if (replies.isNotEmpty || await _repliesFile.exists()) {
      await _delete(_repliesFile);
    }
    return replies;
  });

  // --- Clearing ------------------------------------------------------------

  /// Forgets history and pending replies (sign-out, account change).
  Future<void> clearHistory() => _locked(() async {
    await _delete(_historyFile);
    await _delete(_repliesFile);
  });

  // --- Internals -----------------------------------------------------------

  Future<_History> _readHistory(String account) async {
    final json = await _readJson(_historyFile);
    final history = _History(account);
    if (json is! Map || json['account'] != account) return history;
    final rooms = json['rooms'];
    if (rooms is! List) return history;
    final cutoff = _clock().subtract(_historyMaxAge);
    for (final raw in rooms.take(maxHistoryRooms * 2)) {
      final thread = RoomNotificationThread.fromJson(raw);
      if (thread != null && thread.updatedAt.isAfter(cutoff)) {
        history.rooms[thread.roomId] = thread;
      }
    }
    return history;
  }

  Future<void> _writeHistory(_History history) {
    final rooms = history.rooms.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return _writeJson(_historyFile, {
      'v': 1,
      'account': history.account,
      'rooms': [
        for (final thread in rooms.take(maxHistoryRooms)) thread.toJson(),
      ],
    });
  }

  Future<List<PendingReply>> _readReplies() async {
    final json = await _readJson(_repliesFile);
    if (json is! Map || json['replies'] is! List) return [];
    return [
      for (final raw in (json['replies'] as List).take(_maxPendingReplies * 2))
        ?PendingReply.fromJson(raw),
    ];
  }

  Future<Object?> _readJson(File file) async {
    try {
      if (!await file.exists()) return null;
      if (await file.length() > _maxStoreFileBytes) return null;
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(File file, Object json) async {
    await directory.create(recursive: true);
    final temp = File(
      '${file.path}.${Random.secure().nextInt(1 << 32).toRadixString(16)}.tmp',
    );
    try {
      await temp.writeAsString(jsonEncode(json), flush: true);
      await temp.rename(file.path);
    } catch (_) {
      await _delete(temp);
      rethrow;
    }
  }

  Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// Serialises within this isolate (future chain) and across isolates
  /// (exclusive lock file; a lock older than [_staleLock] is abandoned).
  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _tail.then((_) => _withLockFile(action));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static const _staleLock = Duration(seconds: 10);

  Future<T> _withLockFile<T>(Future<T> Function() action) async {
    await directory.create(recursive: true);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    var acquired = false;
    while (!acquired) {
      try {
        await _lockFile.create(exclusive: true);
        acquired = true;
      } on FileSystemException {
        try {
          final modified = await _lockFile.lastModified();
          if (DateTime.now().difference(modified) > _staleLock) {
            await _delete(_lockFile);
            continue;
          }
        } on FileSystemException {
          continue;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw const FileSystemException('Notification store is busy');
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    try {
      return await action();
    } finally {
      await _delete(_lockFile);
    }
  }
}

class _History {
  _History(this.account);
  final String account;
  final rooms = <String, RoomNotificationThread>{};
}

/// History is scoped to the exact account and device.
String notificationAccountKey(String userId, String deviceId) =>
    jsonEncode([userId, deviceId]);

/// Sanitised own-message line for a quick reply.
NotificationLine? ownReplyLine({
  required String userId,
  required String text,
  required DateTime now,
}) {
  final body = sanitiseNotificationText(text);
  if (body == null) return null;
  return NotificationLine(
    eventId: 'reply-${now.microsecondsSinceEpoch}',
    senderId: userId,
    senderName: 'Me',
    text: body,
    timestamp: now,
    fromMe: true,
  );
}

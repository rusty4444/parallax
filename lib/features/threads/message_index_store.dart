import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

/// One decrypted message in the local search index.
@immutable
class IndexedMessage {
  const IndexedMessage({
    required this.eventId,
    required this.roomId,
    required this.sender,
    required this.time,
    required this.body,
    this.threadRootId,
  });
  final String eventId;
  final String roomId;
  final String sender;
  final DateTime time;
  final String body;

  /// Thread root when the message is a thread reply.
  final String? threadRootId;
}

/// A change to the index, derived from one timeline event or recording
/// backfill progress.
@immutable
sealed class IndexOp {
  const IndexOp();
}

/// Adds a message unless its event is already indexed.
final class IndexUpsert extends IndexOp {
  const IndexUpsert(this.message);
  final IndexedMessage message;
}

/// Replaces the body of [eventId] when [sender] also sent the original.
final class IndexEdit extends IndexOp {
  const IndexEdit({
    required this.eventId,
    required this.sender,
    required this.body,
  });
  final String eventId;
  final String sender;
  final String body;
}

/// Removes a redacted message.
final class IndexDelete extends IndexOp {
  const IndexDelete(this.eventId);
  final String eventId;
}

/// Records that [roomId]'s stored history has been indexed, so later launches
/// skip reading it again. Queued after the room's messages, so it is written
/// in the same transaction (or not at all).
final class IndexRoomBackfilled extends IndexOp {
  const IndexRoomBackfilled(this.roomId);
  final String roomId;
}

/// Version stored with each room's backfill progress. Bump it when what
/// [IndexUpsert]s are derived from stored history changes, so every room's
/// stored history is read again once.
const indexBackfillVersion = 1;

/// Longest body stored per message; longer bodies are truncated.
const maxIndexedBodyLength = 8000;

/// Maximum number of messages kept; the oldest are pruned beyond this.
const maxIndexedMessages = 100000;

/// Lower-cased word tokens of a user query (letters, digits and underscores
/// in any script). Operators and quotes are dropped, so the result is safe to
/// combine into an FTS query or LIKE patterns.
List<String> searchTokens(String query) => [
  for (final match in RegExp(
    r'[\p{L}\p{N}_]+',
    unicode: true,
  ).allMatches(query.toLowerCase()).take(8))
    if (match[0]!.length <= 64) match[0]!,
];

/// FTS MATCH expression: every token as a prefix, all required.
String ftsMatchQuery(List<String> tokens) =>
    tokens.map((token) => '$token*').join(' ');

/// Storage for one account's index.
abstract interface class MessageIndexStore {
  /// Applies [ops] in order, atomically.
  Future<void> apply(List<IndexOp> ops);

  /// Rooms whose stored history this index already holds (written by
  /// [IndexRoomBackfilled] at the current [indexBackfillVersion]). Deleting
  /// the index file forgets them, so a fresh index is backfilled again.
  Future<Set<String>> backfilledRooms();

  /// Messages matching all [tokens], newest first.
  Future<List<IndexedMessage>> search(
    List<String> tokens, {
    required int limit,
    required int offset,
  });

  Future<void> close();
}

/// Creates and deletes per-account index files.
abstract interface class MessageIndexStorage {
  /// Opens (creating if needed) the index for [account], a hashed account key.
  Future<MessageIndexStore> open(String account);

  /// Deletes index files for every account except [account].
  Future<void> deleteOthers(String account);

  /// Deletes every index file. Stores must be closed first.
  Future<void> deleteAll();
}

/// Index files under the app-support directory (inside the app sandbox, as
/// the SDK's own message store is).
class SqfliteMessageIndexStorage implements MessageIndexStorage {
  const SqfliteMessageIndexStorage();

  static Future<Directory> _directory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'message_search'));
  }

  @override
  Future<MessageIndexStore> open(String account) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    return SqfliteMessageIndexStore.open(
      path.join(directory.path, '$account.db'),
    );
  }

  @override
  Future<void> deleteOthers(String account) async {
    final directory = await _directory();
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      final name = path.basename(entity.path);
      if (entity is File && name.endsWith('.db') && name != '$account.db') {
        await sqlite.deleteDatabase(entity.path);
      }
    }
  }

  @override
  Future<void> deleteAll() async {
    final directory = await _directory();
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.db')) {
        await sqlite.deleteDatabase(entity.path);
      }
    }
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Full-text mode supported by the device's SQLite build.
enum IndexTextMode { fts5, fts4, like }

/// SQLite index with an external-content FTS5 table (FTS4, then plain LIKE
/// matching, when the platform SQLite lacks FTS5).
class SqfliteMessageIndexStore implements MessageIndexStore {
  SqfliteMessageIndexStore._(this._db, this.mode);

  /// Wraps an already open database (host tests use a recording fake).
  @visibleForTesting
  SqfliteMessageIndexStore.forDatabase(this._db, this.mode);

  final sqlite.Database _db;
  final IndexTextMode mode;
  int _writesSincePrune = 0;

  static Future<SqfliteMessageIndexStore> open(String file) async {
    final db = await sqlite.openDatabase(
      file,
      version: 1,
      onCreate: (db, _) async {
        for (final statement in baseSchema) {
          await db.execute(statement);
        }
      },
    );
    try {
      return SqfliteMessageIndexStore._(db, await _textMode(db));
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  static Future<IndexTextMode> _textMode(sqlite.Database db) async {
    final rows = await db.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['text_mode'],
    );
    final saved = rows.isEmpty ? null : rows.single['value'];
    for (final mode in IndexTextMode.values) {
      if (mode.name == saved) return mode;
    }
    // Probe once, outside a transaction: a missing FTS module only fails
    // its own statement.
    for (final mode in [IndexTextMode.fts5, IndexTextMode.fts4]) {
      try {
        await db.transaction((txn) async {
          for (final statement in ftsSchema(mode)) {
            await txn.execute(statement);
          }
          await txn.insert('meta', {
            'key': 'text_mode',
            'value': mode.name,
          }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
        });
        return mode;
      } catch (_) {
        // Try the next mode.
      }
    }
    await db.insert('meta', {
      'key': 'text_mode',
      'value': IndexTextMode.like.name,
    }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
    return IndexTextMode.like;
  }

  /// One batch per call: sqflite runs every database in the app on a single
  /// worker thread, so a statement per message would queue hundreds of
  /// platform calls behind the Matrix SDK's own sync writes and reads. The
  /// batch commits in a transaction, so [ops] still apply all or nothing.
  @override
  Future<void> apply(List<IndexOp> ops) async {
    if (ops.isEmpty) return;
    final batch = _db.batch();
    for (final op in ops) {
      switch (op) {
        case IndexUpsert(:final message):
          batch.rawInsert(insertSql, [
            message.eventId,
            message.roomId,
            message.sender,
            message.time.millisecondsSinceEpoch,
            message.threadRootId,
            _bounded(message.body),
          ]);
        case IndexEdit(:final eventId, :final sender, :final body):
          batch.rawUpdate(editSql, [_bounded(body), eventId, sender]);
        case IndexDelete(:final eventId):
          batch.rawDelete(deleteSql, [eventId]);
        case IndexRoomBackfilled(:final roomId):
          batch.rawInsert(backfilledSql, [
            '$backfillKeyPrefix$roomId',
            '$indexBackfillVersion',
          ]);
      }
    }
    final writes = _writesSincePrune + ops.length;
    final prune = writes >= 500;
    if (prune) batch.rawDelete(pruneSql, [maxIndexedMessages]);
    await batch.commit(noResult: true);
    _writesSincePrune = prune ? 0 : writes;
  }

  @override
  Future<Set<String>> backfilledRooms() async {
    final rows = await _db.rawQuery(backfilledRoomsSql, [
      '$indexBackfillVersion',
    ]);
    return {
      for (final row in rows)
        if (row['key'] case final String key
            when key.startsWith(backfillKeyPrefix))
          key.substring(backfillKeyPrefix.length),
    };
  }

  @override
  Future<List<IndexedMessage>> search(
    List<String> tokens, {
    required int limit,
    required int offset,
  }) async {
    if (tokens.isEmpty) return const [];
    final query = searchQuery(mode, tokens.length);
    final args = <Object?>[
      if (mode == IndexTextMode.like)
        for (final token in tokens) '%${escapeLike(token)}%'
      else
        ftsMatchQuery(tokens),
      limit,
      offset,
    ];
    final rows = await _db.rawQuery(query, args);
    return [
      for (final row in rows)
        IndexedMessage(
          eventId: row['event_id']! as String,
          roomId: row['room_id']! as String,
          sender: row['sender']! as String,
          time: DateTime.fromMillisecondsSinceEpoch(row['ts']! as int),
          threadRootId: row['thread_root'] as String?,
          body: row['body']! as String,
        ),
    ];
  }

  @override
  Future<void> close() => _db.close();

  static String _bounded(String body) => body.length > maxIndexedBodyLength
      ? body.substring(0, maxIndexedBodyLength)
      : body;

  // SQL is public for the schema probe in the tests/docs; it never contains
  // user input (all values are bound parameters).

  static const baseSchema = [
    'CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)',
    'CREATE TABLE IF NOT EXISTS messages('
        'id INTEGER PRIMARY KEY, '
        'event_id TEXT NOT NULL UNIQUE, '
        'room_id TEXT NOT NULL, '
        'sender TEXT NOT NULL, '
        'ts INTEGER NOT NULL, '
        'thread_root TEXT, '
        'body TEXT NOT NULL)',
    'CREATE INDEX IF NOT EXISTS messages_ts ON messages(ts)',
  ];

  static List<String> ftsSchema(IndexTextMode mode) => switch (mode) {
    IndexTextMode.fts5 => const [
      'CREATE VIRTUAL TABLE messages_fts USING fts5(body, '
          "content='messages', content_rowid='id', tokenize='unicode61')",
      'CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN '
          'INSERT INTO messages_fts(rowid, body) VALUES (new.id, new.body); '
          'END',
      'CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN '
          "INSERT INTO messages_fts(messages_fts, rowid, body) "
          "VALUES ('delete', old.id, old.body); "
          'END',
      'CREATE TRIGGER messages_au AFTER UPDATE OF body ON messages BEGIN '
          "INSERT INTO messages_fts(messages_fts, rowid, body) "
          "VALUES ('delete', old.id, old.body); "
          'INSERT INTO messages_fts(rowid, body) VALUES (new.id, new.body); '
          'END',
    ],
    IndexTextMode.fts4 => const [
      'CREATE VIRTUAL TABLE messages_fts USING fts4(content="messages", body)',
      'CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN '
          'INSERT INTO messages_fts(docid, body) VALUES (new.id, new.body); '
          'END',
      'CREATE TRIGGER messages_bd BEFORE DELETE ON messages BEGIN '
          'DELETE FROM messages_fts WHERE docid = old.id; '
          'END',
      'CREATE TRIGGER messages_bu BEFORE UPDATE OF body ON messages BEGIN '
          'DELETE FROM messages_fts WHERE docid = old.id; '
          'END',
      'CREATE TRIGGER messages_au AFTER UPDATE OF body ON messages BEGIN '
          'INSERT INTO messages_fts(docid, body) VALUES (new.id, new.body); '
          'END',
    ],
    IndexTextMode.like => const [],
  };

  static const insertSql =
      'INSERT OR IGNORE INTO messages'
      '(event_id, room_id, sender, ts, thread_root, body) '
      'VALUES (?, ?, ?, ?, ?, ?)';
  static const editSql =
      'UPDATE messages SET body = ? WHERE event_id = ? AND sender = ?';
  static const deleteSql = 'DELETE FROM messages WHERE event_id = ?';
  static const pruneSql =
      'DELETE FROM messages WHERE id IN (SELECT id FROM messages '
      'ORDER BY ts DESC LIMIT -1 OFFSET ?)';

  /// Backfill progress lives in `meta`, one row per room, so it is deleted
  /// with the index file (sign-out, account change, clearing, turning off).
  static const backfillKeyPrefix = 'backfill:';
  static const backfilledSql =
      'INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)';
  static const backfilledRoomsSql =
      "SELECT key FROM meta WHERE key LIKE 'backfill:%' AND value = ?";

  static const _columns =
      'm.event_id, m.room_id, m.sender, m.ts, m.thread_root, m.body';

  static String searchQuery(IndexTextMode mode, int tokens) => switch (mode) {
    IndexTextMode.fts5 =>
      'SELECT $_columns FROM messages_fts '
          'JOIN messages m ON m.id = messages_fts.rowid '
          'WHERE messages_fts MATCH ? ORDER BY m.ts DESC LIMIT ? OFFSET ?',
    IndexTextMode.fts4 =>
      'SELECT $_columns FROM messages_fts '
          'JOIN messages m ON m.id = messages_fts.docid '
          'WHERE messages_fts MATCH ? ORDER BY m.ts DESC LIMIT ? OFFSET ?',
    IndexTextMode.like =>
      'SELECT $_columns FROM messages m WHERE '
          '${List.filled(tokens, r"m.body LIKE ? ESCAPE '\'").join(' AND ')} '
          'ORDER BY m.ts DESC LIMIT ? OFFSET ?',
  };

  static String escapeLike(String token) => token
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}

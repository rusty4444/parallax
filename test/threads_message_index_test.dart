import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:parallax/features/threads/local_message_search.dart';
import 'package:parallax/features/threads/message_index_store.dart';
import 'package:parallax/room_events.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

const _secret = '!secret:matrix.example';
const _open = '!open:matrix.example';
const _left = '!left:matrix.example';
const _other = '!other:matrix.example';

class _Database extends Fake implements DatabaseApi {
  final cached = <String, List<Map<String, Object?>>>{};

  /// Rooms whose stored history was read, in order.
  final reads = <String>[];
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async {
    reads.add(room.id);
    return [
      for (final json in cached[room.id] ?? const <Map<String, Object?>>[])
        Event.fromJson(json, room),
    ];
  }

  @override
  Future<void> close() async {}
}

class _Client extends Client {
  _Client(_Database db)
    : super(
        'index-test',
        database: db,
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
  }
  String user = '@me:matrix.example';
  String device = 'DEVICE';
  @override
  String get userID => user;
  @override
  String get deviceID => device;
}

class _Access implements MatrixSdkAccess {
  _Access(this.client);
  final Client client;
  bool current = true;
  @override
  Client? get sdkClient => current ? client : null;
  @override
  bool isSessionCurrent(Client client) => current;
}

/// One index file: like a database on disk, it outlives the store (and the
/// process) that wrote it until it is deleted.
class _File {
  final rows = <String, IndexedMessage>{};
  final backfilled = <String>{};
  bool failWrites = false;
}

class _Store implements MessageIndexStore {
  _Store(this.file);
  final _File file;
  Map<String, IndexedMessage> get rows => file.rows;
  bool closed = false;
  int applies = 0;
  final batches = <List<IndexOp>>[];

  @override
  Future<Set<String>> backfilledRooms() async {
    if (closed) throw StateError('closed');
    return {...file.backfilled};
  }

  @override
  Future<void> apply(List<IndexOp> ops) async {
    if (closed) throw StateError('closed');
    if (file.failWrites) throw StateError('disk full');
    applies++;
    batches.add(List.of(ops));
    for (final op in ops) {
      switch (op) {
        case IndexUpsert(:final message):
          rows.putIfAbsent(message.eventId, () => message);
        case IndexEdit(:final eventId, :final sender, :final body):
          final old = rows[eventId];
          if (old != null && old.sender == sender) {
            rows[eventId] = IndexedMessage(
              eventId: old.eventId,
              roomId: old.roomId,
              sender: old.sender,
              time: old.time,
              body: body,
              threadRootId: old.threadRootId,
            );
          }
        case IndexDelete(:final eventId):
          rows.remove(eventId);
        case IndexRoomBackfilled(:final roomId):
          file.backfilled.add(roomId);
      }
    }
  }

  @override
  Future<List<IndexedMessage>> search(
    List<String> tokens, {
    required int limit,
    required int offset,
  }) async {
    final matches =
        rows.values
            .where(
              (row) => tokens.every((t) => row.body.toLowerCase().contains(t)),
            )
            .toList()
          ..sort((a, b) => b.time.compareTo(a.time));
    return matches.skip(offset).take(limit).toList();
  }

  @override
  Future<void> close() async => closed = true;
}

class _Storage implements MessageIndexStorage {
  final files = <String, _File>{};
  final opened = <String>[];
  final keptOnly = <String>[];
  int deleteAllCalls = 0;
  _Store? store;

  @override
  Future<MessageIndexStore> open(String account) async {
    opened.add(account);
    return store = _Store(files.putIfAbsent(account, _File.new));
  }

  @override
  Future<void> deleteOthers(String account) async {
    keptOnly.add(account);
    files.removeWhere((name, _) => name != account);
  }

  @override
  Future<void> deleteAll() async {
    deleteAllCalls++;
    files.clear();
    store = null;
  }
}

/// Records what [SqfliteMessageIndexStore] sends to sqflite.
class _Batch extends Fake implements sqlite.Batch {
  final ops = <(String, String, List<Object?>?)>[];
  int commits = 0;
  bool? noResult;

  @override
  void rawInsert(String sql, [List<Object?>? arguments]) =>
      ops.add(('insert', sql, arguments));
  @override
  void rawUpdate(String sql, [List<Object?>? arguments]) =>
      ops.add(('update', sql, arguments));
  @override
  void rawDelete(String sql, [List<Object?>? arguments]) =>
      ops.add(('delete', sql, arguments));
  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async {
    commits++;
    this.noResult = noResult;
    return const [];
  }
}

/// Any per-statement call (rawInsert, transaction …) is unimplemented and
/// fails the test.
class _SqliteDatabase extends Fake implements sqlite.Database {
  final batches = <_Batch>[];
  var meta = <Map<String, Object?>>[];
  List<Object?>? queryArguments;

  @override
  sqlite.Batch batch() {
    final batch = _Batch();
    batches.add(batch);
    return batch;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    expect(sql, SqfliteMessageIndexStore.backfilledRoomsSql);
    queryArguments = arguments;
    return meta;
  }
}

class _Preference implements MessageSearchPreference {
  bool value = true;
  final writes = <bool>[];
  @override
  Future<bool> read() async => value;
  @override
  Future<void> write(bool enabled) async {
    writes.add(enabled);
    value = enabled;
  }
}

Room _addRoom(
  Client client,
  String id, {
  required bool encrypted,
  String? name,
  Membership membership = Membership.join,
}) {
  final room = Room(id: id, client: client, membership: membership);
  if (encrypted) {
    room.setState(
      Event.fromJson({
        'event_id': '\$enc-$id',
        'type': 'm.room.encryption',
        'state_key': '',
        'sender': '@me:matrix.example',
        'origin_server_ts': 1,
        'room_id': id,
        'content': {'algorithm': 'm.megolm.v1.aes-sha2'},
      }, room),
    );
  }
  room.setState(
    Event.fromJson({
      'event_id': '\$name-$id',
      'type': 'm.room.name',
      'state_key': '',
      'sender': '@me:matrix.example',
      'origin_server_ts': 1,
      'room_id': id,
      'content': {'name': name ?? id},
    }, room),
  );
  client.rooms.add(room);
  return room;
}

Map<String, Object?> _msg(
  String id,
  String body, {
  String room = _secret,
  int ts = 1000,
  String sender = '@alice:matrix.example',
  String msgtype = 'm.text',
  Map<String, Object?>? relatesTo,
  Map<String, Object?>? newContent,
}) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': sender,
  'origin_server_ts': ts,
  'room_id': room,
  'content': {
    'msgtype': msgtype,
    'body': body,
    'm.relates_to': ?relatesTo,
    'm.new_content': ?newContent,
  },
};

void main() {
  group('indexOpsFor', () {
    late _Client client;
    late Room secret;
    late Room open;
    setUp(() {
      client = _Client(_Database());
      secret = _addRoom(client, _secret, encrypted: true);
      open = _addRoom(client, _open, encrypted: false);
    });

    List<IndexOp> ops(Map<String, Object?> json, [Room? room]) =>
        indexOpsFor(Event.fromJson(json, room ?? secret));

    test('indexes decrypted text in encrypted rooms only', () {
      final upsert = ops(_msg(r'$a', 'Pizza tonight?')).single as IndexUpsert;
      expect(upsert.message.body, 'Pizza tonight?');
      expect(upsert.message.roomId, _secret);
      expect(upsert.message.threadRootId, isNull);
      expect(ops(_msg(r'$b', 'public', room: _open), open), isEmpty);
      expect(ops(_msg(r'$c', 'photo.jpg', msgtype: 'm.image')), isEmpty);
      expect(ops(_msg('local-echo', 'pending')), isEmpty);
      expect(
        ops({
          ..._msg(r'$enc', ''),
          'type': 'm.room.encrypted',
          'content': {'algorithm': 'm.megolm.v1.aes-sha2'},
        }),
        isEmpty,
      );
      for (final type in ['m.notice', 'm.emote']) {
        expect(ops(_msg('\$$type', 'text', msgtype: type)), hasLength(1));
      }
    });

    test('strips reply fallbacks and records thread roots', () {
      final reply =
          ops(
                _msg(
                  r'$r',
                  '> <@bob:matrix.example> old\n\nnew words',
                  relatesTo: {
                    'm.in_reply_to': {'event_id': r'$old'},
                  },
                ),
              ).single
              as IndexUpsert;
      expect(reply.message.body, 'new words');
      final thread =
          ops(
                _msg(
                  r'$t',
                  'in a thread',
                  relatesTo: {'rel_type': 'm.thread', 'event_id': r'$root'},
                ),
              ).single
              as IndexUpsert;
      expect(thread.message.threadRootId, r'$root');
    });

    test('edits replace text and redactions delete it', () {
      final edit =
          ops(
                _msg(
                  r'$e',
                  '* fixed',
                  relatesTo: {'rel_type': 'm.replace', 'event_id': r'$a'},
                  newContent: {'msgtype': 'm.text', 'body': 'fixed'},
                ),
              ).single
              as IndexEdit;
      expect(edit.eventId, r'$a');
      expect(edit.body, 'fixed');
      expect(edit.sender, '@alice:matrix.example');
      expect(
        ops(
          _msg(
            r'$e2',
            '* ',
            relatesTo: {'rel_type': 'm.replace', 'event_id': r'$a'},
            newContent: {'msgtype': 'm.text', 'body': '  '},
          ),
        ).single,
        isA<IndexDelete>(),
      );
      final redaction =
          ops({
                'event_id': r'$red',
                'type': 'm.room.redaction',
                'sender': '@alice:matrix.example',
                'origin_server_ts': 2,
                'room_id': _secret,
                'content': {'redacts': r'$a'},
              }).single
              as IndexDelete;
      expect(redaction.eventId, r'$a');
      final redacted =
          ops({
                ..._msg(r'$gone', ''),
                'unsigned': {
                  'redacted_because': {
                    'event_id': r'$red2',
                    'type': 'm.room.redaction',
                    'sender': '@alice:matrix.example',
                    'origin_server_ts': 3,
                    'content': <String, Object?>{},
                  },
                },
              }).single
              as IndexDelete;
      expect(redacted.eventId, r'$gone');
    });
  });

  test('search tokens drop operators and quotes', () {
    expect(searchTokens('"Pizza" AND -café_2 NEAR(x)'), [
      'pizza',
      'and',
      'café_2',
      'near',
      'x',
    ]);
    expect(ftsMatchQuery(['pizza', 'café']), 'pizza* café*');
    expect(searchTokens('***'), isEmpty);
    expect(searchTokens(List.filled(20, 'word').join(' ')), hasLength(8));
    expect(SqfliteMessageIndexStore.escapeLike(r'50%_\'), r'50\%\_\\');
    expect(
      SqfliteMessageIndexStore.searchQuery(IndexTextMode.like, 2),
      contains("m.body LIKE ? ESCAPE '\\' AND m.body LIKE ? ESCAPE '\\'"),
    );
    expect(
      SqfliteMessageIndexStore.searchQuery(IndexTextMode.fts5, 2),
      contains('messages_fts MATCH ?'),
    );
  });

  test('SQLite writes are one batch per apply, progress included', () async {
    final db = _SqliteDatabase();
    final store = SqfliteMessageIndexStore.forDatabase(db, IndexTextMode.fts5);
    IndexUpsert upsert(int i) => IndexUpsert(
      IndexedMessage(
        eventId: '\$e$i',
        roomId: _secret,
        sender: '@alice:matrix.example',
        time: DateTime.fromMillisecondsSinceEpoch(i),
        body: 'message $i',
      ),
    );
    await store.apply([
      for (var i = 0; i < 300; i++) upsert(i),
      const IndexEdit(
        eventId: r'$e1',
        sender: '@alice:matrix.example',
        body: 'edited',
      ),
      const IndexDelete(r'$e2'),
      const IndexRoomBackfilled(_secret),
    ]);
    final first = db.batches.single;
    expect(first.commits, 1);
    expect(first.noResult, isTrue);
    expect(first.ops, hasLength(303));
    expect(first.ops[0].$2, SqfliteMessageIndexStore.insertSql);
    expect(first.ops[0].$3, [
      r'$e0',
      _secret,
      '@alice:matrix.example',
      0,
      null,
      'message 0',
    ]);
    expect(first.ops[300].$2, SqfliteMessageIndexStore.editSql);
    expect(first.ops[301].$2, SqfliteMessageIndexStore.deleteSql);
    expect(first.ops[302].$2, SqfliteMessageIndexStore.backfilledSql);
    expect(first.ops[302].$3, ['backfill:$_secret', '$indexBackfillVersion']);

    // Crossing the prune threshold prunes in the same batch.
    await store.apply([for (var i = 300; i < 500; i++) upsert(i)]);
    expect(db.batches, hasLength(2));
    expect(db.batches.last.commits, 1);
    expect(db.batches.last.ops.last.$2, SqfliteMessageIndexStore.pruneSql);
    expect(db.batches.last.ops.last.$3, [maxIndexedMessages]);
    await store.apply([upsert(500)]);
    expect(db.batches.last.ops, hasLength(1));

    db.meta = [
      {'key': 'backfill:$_secret'},
      {'key': 'backfill:$_other'},
    ];
    expect(await store.backfilledRooms(), {_secret, _other});
    expect(db.queryArguments, ['$indexBackfillVersion']);
  });

  group('MatrixMessageSearchIndex', () {
    late _Database db;
    late _Client client;
    late _Access access;
    late _Storage storage;
    late _Preference preference;
    late MatrixMessageSearchIndex index;
    late Room secret;

    setUp(() {
      db = _Database();
      client = _Client(db);
      access = _Access(client);
      storage = _Storage();
      preference = _Preference();
      secret = _addRoom(client, _secret, encrypted: true, name: 'Secret');
      _addRoom(client, _open, encrypted: false);
      _addRoom(client, _left, encrypted: true, membership: Membership.leave);
      // The first sync since start has completed.
      client.onSync.add(SyncUpdate(nextBatch: 'first'));
      index = MatrixMessageSearchIndex(
        access,
        storage: storage,
        preference: preference,
      );
    });

    Future<void> settle([MatrixMessageSearchIndex? other]) async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
        await (other ?? index).idle;
      }
    }

    /// The next app launch: a new SDK client over the same stored events and
    /// a new index over the same index files.
    ({_Database db, _Client client, MatrixMessageSearchIndex index}) relaunch({
      bool synced = true,
      Duration firstSyncTimeout = const Duration(seconds: 30),
    }) {
      final nextDb = _Database()..cached.addAll(db.cached);
      final nextClient = _Client(nextDb);
      for (final room in client.rooms) {
        _addRoom(
          nextClient,
          room.id,
          encrypted: room.encrypted,
          membership: room.membership,
        );
      }
      if (synced) nextClient.onSync.add(SyncUpdate(nextBatch: 'next'));
      return (
        db: nextDb,
        client: nextClient,
        index: MatrixMessageSearchIndex(
          _Access(nextClient),
          storage: storage,
          preference: preference,
          firstSyncTimeout: firstSyncTimeout,
        ),
      );
    }

    test('backfills, indexes live events and searches joined rooms', () async {
      db.cached[_secret] = [
        // Newest first, as the SDK store returns it.
        _msg(r'$newer', 'pizza at eight', ts: 2000),
        _msg(r'$older', 'who wants pizza', ts: 1000),
      ];
      index.ensureStarted();
      await settle();
      expect(storage.opened, [MatrixMessageSearchIndex.accountHash(client)]);
      expect(storage.keptOnly, storage.opened);

      client.onTimelineEvent.add(
        Event.fromJson(
          _msg(
            r'$thread',
            'pizza in a thread',
            ts: 3000,
            relatesTo: {'rel_type': 'm.thread', 'event_id': r'$older'},
          ),
          secret,
        ),
      );
      client.onTimelineEvent.add(
        Event.fromJson(
          _msg(r'$plain', 'pizza in public', room: _open, ts: 4000),
          client.getRoomById(_open)!,
        ),
      );
      // A message in a room the user has since left is not returned.
      storage.store!.rows[r'$left'] = IndexedMessage(
        eventId: r'$left',
        roomId: _left,
        sender: '@alice:matrix.example',
        time: DateTime.fromMillisecondsSinceEpoch(5000),
        body: 'pizza elsewhere',
      );
      await settle();

      final page = await index.search('PIZZA', limit: 2);
      expect(page.hits.map((h) => h.id), [r'$thread']);
      expect(page.nextOffset, 2);
      final thread = page.hits.single;
      expect(thread.roomName, 'Secret');
      expect(thread.jumpEventId, r'$older');
      final rest = await index.search('pizza', offset: 2, limit: 2);
      expect(rest.hits.map((h) => h.id), [r'$newer', r'$older']);
      expect(rest.nextOffset, isNull);
      expect(rest.hits.first.jumpEventId, r'$newer');
    });

    test('edits by the sender and redactions update the index', () async {
      index.ensureStarted();
      await settle();
      client.onTimelineEvent.add(
        Event.fromJson(_msg(r'$a', 'meet at the cafe'), secret),
      );
      client.onTimelineEvent.add(
        Event.fromJson(
          _msg(
            r'$e',
            '* meet at the park',
            relatesTo: {'rel_type': 'm.replace', 'event_id': r'$a'},
            newContent: {'msgtype': 'm.text', 'body': 'meet at the park'},
          ),
          secret,
        ),
      );
      await settle();
      expect((await index.search('cafe')).hits, isEmpty);
      expect((await index.search('park')).hits.single.body, 'meet at the park');
      client.onTimelineEvent.add(
        Event.fromJson({
          'event_id': r'$red',
          'type': 'm.room.redaction',
          'sender': '@alice:matrix.example',
          'origin_server_ts': 9,
          'room_id': _secret,
          'redacts': r'$a',
          'content': <String, Object?>{},
        }, secret),
      );
      await settle();
      expect((await index.search('park')).hits, isEmpty);
    });

    test('session clear deletes the index and drops queued text', () async {
      index.ensureStarted();
      await settle();
      final store = storage.store!;
      client.onTimelineEvent.add(Event.fromJson(_msg(r'$a', 'secret'), secret));
      client.onSessionCleared.add(SessionClearReason.logout);
      await settle();
      expect(store.closed, isTrue);
      expect(storage.deleteAllCalls, 1);
      expect(store.rows, isEmpty);
    });

    test('turning off wipes the index and stops indexing', () async {
      index.ensureStarted();
      await settle();
      final store = storage.store!;
      client.onTimelineEvent.add(Event.fromJson(_msg(r'$a', 'kept'), secret));
      await settle();
      expect(store.rows, hasLength(1));

      await index.setEnabled(false);
      expect(preference.writes, [false]);
      expect(store.closed, isTrue);
      expect(storage.deleteAllCalls, 1);
      client.onTimelineEvent.add(Event.fromJson(_msg(r'$b', 'more'), secret));
      await settle();
      expect(storage.opened, hasLength(1));
      expect((await index.search('more')).hits, isEmpty);

      await index.setEnabled(true);
      await settle();
      expect(storage.opened, hasLength(2));
      client.onTimelineEvent.add(Event.fromJson(_msg(r'$c', 'again'), secret));
      await settle();
      expect((await index.search('again')).hits.single.id, r'$c');
    });

    test('a disabled preference never opens an index', () async {
      preference.value = false;
      index.ensureStarted();
      client.onTimelineEvent.add(Event.fromJson(_msg(r'$a', 'x'), secret));
      await settle();
      expect(await index.isEnabled(), isFalse);
      expect(storage.opened, isEmpty);
    });

    test('search requires the current session', () async {
      access.current = false;
      await expectLater(index.search('pizza'), throwsStateError);
    });

    test('index files are stable per session and replaced on re-login', () {
      final first = MatrixMessageSearchIndex.accountHash(client);
      expect(MatrixMessageSearchIndex.accountHash(client), first);
      expect(first, hasLength(32));
      expect(first, isNot(contains('matrix')));
      client.device = 'NEW-DEVICE';
      final relogin = MatrixMessageSearchIndex.accountHash(client);
      expect(relogin, isNot(first));
      client.user = '@other:matrix.example';
      expect(MatrixMessageSearchIndex.accountHash(client), isNot(relogin));
    });

    test('a new session deletes the previous session index', () async {
      index.ensureStarted();
      await settle();
      final first = storage.opened.single;
      // Sign-out happened while indexing was not attached; a new sign-in
      // (new device) must not reuse the old plaintext index.
      client.device = 'NEW-DEVICE';
      index.ensureStarted();
      await settle();
      expect(storage.opened, hasLength(2));
      expect(storage.opened.last, isNot(first));
      expect(storage.keptOnly.last, storage.opened.last);
      // The old session's progress went with its file: backfilled again.
      expect(storage.files.keys, [storage.opened.last]);
      expect(db.reads, [_secret, _secret]);
    });

    test('repeated starts do not reopen or re-backfill', () async {
      db.cached[_secret] = [_msg(r'$a', 'hello')];
      index.ensureStarted();
      await settle();
      final applies = storage.store!.applies;
      for (var i = 0; i < 5; i++) {
        index.ensureStarted();
      }
      await settle();
      expect(storage.opened, hasLength(1));
      expect(storage.store!.applies, applies);
      expect(db.reads, [_secret]);
    });

    test('backfill writes each room in one batch with its progress', () async {
      _addRoom(client, _other, encrypted: true);
      db.cached[_secret] = [
        _msg(r'$b', 'second', ts: 2000),
        _msg(r'$a', 'first', ts: 1000),
      ];
      db.cached[_other] = [_msg(r'$c', 'third', room: _other)];
      index.ensureStarted();
      await settle();
      final store = storage.store!;
      expect(db.reads, [_secret, _other]);
      expect(store.applies, 2);
      expect(
        store.batches[0].map(
          (op) => switch (op) {
            IndexUpsert(:final message) => message.eventId,
            IndexRoomBackfilled(:final roomId) => roomId,
            _ => op,
          },
        ),
        [r'$a', r'$b', _secret],
      );
      expect(store.batches[1].last, isA<IndexRoomBackfilled>());
      expect(storage.files.values.single.backfilled, {_secret, _other});
    });

    test('a new process skips rooms already backfilled', () async {
      _addRoom(client, _other, encrypted: true);
      db.cached[_secret] = [_msg(r'$a', 'hello')];
      db.cached[_other] = [_msg(r'$b', 'hello again', room: _other)];
      index.ensureStarted();
      await settle();
      expect(db.reads, [_secret, _other]);

      // Next launch, with one room joined since.
      _addRoom(client, '!new:matrix.example', encrypted: true);
      db.cached['!new:matrix.example'] = [
        _msg(r'$c', 'hello new', room: '!new:matrix.example'),
      ];
      final next = relaunch();
      next.index.ensureStarted();
      await settle(next.index);
      expect(storage.opened, hasLength(2));
      expect(storage.opened.last, storage.opened.first);
      expect(next.db.reads, ['!new:matrix.example']);
      expect(
        (await next.index.search('hello')).hits.map((hit) => hit.id),
        unorderedEquals([r'$a', r'$b', r'$c']),
      );

      // And the launch after that reads nothing.
      final third = relaunch();
      third.index.ensureStarted();
      await settle(third.index);
      expect(third.db.reads, isEmpty);
    });

    test('a room whose write failed is read again next launch', () async {
      db.cached[_secret] = [_msg(r'$a', 'hello')];
      final file = storage.files[MatrixMessageSearchIndex.accountHash(client)] =
          _File()..failWrites = true;
      index.ensureStarted();
      await settle();
      expect(db.reads, [_secret]);
      expect(file.backfilled, isEmpty);

      file.failWrites = false;
      final next = relaunch();
      next.index.ensureStarted();
      await settle(next.index);
      expect(next.db.reads, [_secret]);
      expect(file.backfilled, {_secret});
    });

    test(
      'clearing the index or signing out forgets backfill progress',
      () async {
        db.cached[_secret] = [_msg(r'$a', 'hello')];
        index.ensureStarted();
        await settle();
        expect(db.reads, [_secret]);
        await index.clear();
        expect(storage.files, isEmpty);

        final next = relaunch();
        next.index.ensureStarted();
        await settle(next.index);
        expect(next.db.reads, [_secret]);
        expect((await next.index.search('hello')).hits.single.id, r'$a');

        next.client.onSessionCleared.add(SessionClearReason.logout);
        await settle(next.index);
        expect(storage.files, isEmpty);
        final third = relaunch();
        third.index.ensureStarted();
        await settle(third.index);
        expect(third.db.reads, [_secret]);
      },
    );

    test('turning search back on backfills the new index', () async {
      db.cached[_secret] = [_msg(r'$a', 'hello')];
      index.ensureStarted();
      await settle();
      await index.setEnabled(false);
      await index.setEnabled(true);
      await settle();
      expect(db.reads, [_secret, _secret]);
      expect((await index.search('hello')).hits.single.id, r'$a');
    });

    test('backfill waits for the first sync since start', () async {
      db.cached[_secret] = [_msg(r'$a', 'hello')];
      final next = relaunch(synced: false);
      next.index.ensureStarted();
      await settle(next.index);
      // Live indexing and search are ready; stored history is not read yet.
      expect(storage.opened, hasLength(1));
      expect(next.db.reads, isEmpty);
      next.client.onTimelineEvent.add(
        Event.fromJson(
          _msg(r'$live', 'live hello'),
          next.client.getRoomById(_secret)!,
        ),
      );
      await settle(next.index);
      expect((await next.index.search('live')).hits.single.id, r'$live');

      next.client.onSync.add(SyncUpdate(nextBatch: 'first'));
      await settle(next.index);
      expect(next.db.reads, [_secret]);
      expect((await next.index.search('hello')).hits, hasLength(2));
    });

    test('backfill starts after a timeout when there is no sync', () async {
      db.cached[_secret] = [_msg(r'$a', 'hello')];
      final next = relaunch(
        synced: false,
        firstSyncTimeout: const Duration(milliseconds: 20),
      );
      next.index.ensureStarted();
      await settle(next.index);
      expect(next.db.reads, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await settle(next.index);
      expect(next.db.reads, [_secret]);
    });

    test('live events are coalesced into one write', () async {
      index.ensureStarted();
      await settle();
      final store = storage.store!;
      final applies = store.applies;
      for (var i = 0; i < 20; i++) {
        client.onTimelineEvent.add(
          Event.fromJson(_msg('\$m$i', 'message $i', ts: i), secret),
        );
        await Future<void>.delayed(Duration.zero);
      }
      // Still waiting for more of the sync.
      expect(store.applies, applies);
      await settle();
      expect(store.applies, applies + 1);
      expect(store.rows, hasLength(20));
    });

    test('live events are written after a short delay', () async {
      final quick = MatrixMessageSearchIndex(
        access,
        storage: storage,
        preference: preference,
        liveBatchDelay: const Duration(milliseconds: 10),
      );
      quick.ensureStarted();
      await settle(quick);
      client.onTimelineEvent.add(Event.fromJson(_msg(r'$a', 'soon'), secret));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(storage.store!.rows.keys, [r'$a']);
    });

    test('messages decrypted after their sync are indexed', () async {
      index.ensureStarted();
      await settle();
      // ignore: deprecated_member_use
      client.onEvent.add(
        // ignore: deprecated_member_use
        EventUpdate(
          roomID: _secret,
          type: EventUpdateType.decryptedTimelineQueue,
          content: _msg(r'$late', 'keys came later'),
        ),
      );
      // Ordinary sync updates arrive on onTimelineEvent instead.
      // ignore: deprecated_member_use
      client.onEvent.add(
        // ignore: deprecated_member_use
        EventUpdate(
          roomID: _secret,
          type: EventUpdateType.timeline,
          content: _msg(r'$sync', 'from the sync'),
        ),
      );
      await settle();
      expect(storage.store!.rows.keys, [r'$late']);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:parallax/features/threads/local_message_search.dart';
import 'package:parallax/features/threads/message_index_store.dart';
import 'package:parallax/room_events.dart';

const _secret = '!secret:matrix.example';
const _open = '!open:matrix.example';
const _left = '!left:matrix.example';

class _Database extends Fake implements DatabaseApi {
  final cached = <String, List<Map<String, Object?>>>{};
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => [
    for (final json in cached[room.id] ?? const <Map<String, Object?>>[])
      Event.fromJson(json, room),
  ];

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

class _Store implements MessageIndexStore {
  final rows = <String, IndexedMessage>{};
  bool closed = false;
  int applies = 0;

  @override
  Future<void> apply(List<IndexOp> ops) async {
    if (closed) throw StateError('closed');
    applies++;
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
  final opened = <String>[];
  final keptOnly = <String>[];
  int deleteAllCalls = 0;
  _Store? store;

  @override
  Future<MessageIndexStore> open(String account) async {
    opened.add(account);
    return store = _Store();
  }

  @override
  Future<void> deleteOthers(String account) async => keptOnly.add(account);

  @override
  Future<void> deleteAll() async {
    deleteAllCalls++;
    store = null;
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
      index = MatrixMessageSearchIndex(
        access,
        storage: storage,
        preference: preference,
      );
    });

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
        await index.idle;
      }
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
    });
  });
}

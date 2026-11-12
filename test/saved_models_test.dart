import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/saved/saved_models.dart';

const _room = '!room:example.org';

ChatRoom _chat(
  String id, {
  bool direct = false,
  bool invited = false,
  bool space = false,
  bool favourite = false,
  int unread = 0,
}) => ChatRoom(
  id: id,
  name: id,
  preview: '',
  lastActivity: null,
  isDirect: direct,
  invited: invited,
  isSpace: space,
  favourite: favourite,
  unread: unread,
);

const _noFacts = (favourite: false, unread: false);

void main() {
  group('note to self record', () {
    test('parses, validates and preserves unknown fields', () {
      final record = NoteToSelfRecord.fromJson({
        'room_id': '!n:example.org',
        'prompt_dismissed': true,
        'colour': 'teal',
      });
      expect(record.roomId, '!n:example.org');
      expect(record.promptDismissed, isTrue);
      expect(record.toJson(), {
        'colour': 'teal',
        'room_id': '!n:example.org',
        'prompt_dismissed': true,
      });
      expect(
        NoteToSelfRecord.fromJson({'room_id': 'not a room'}).roomId,
        isNull,
      );
      expect(NoteToSelfRecord.fromJson({'room_id': 42}).roomId, isNull);
      expect(NoteToSelfRecord.fromJson(null).toJson(), isEmpty);
    });
  });

  group('bookmarks', () {
    test('parse sorts newest first, drops invalid and duplicate entries', () {
      final list = BookmarkList.fromJson({
        'bookmarks': [
          {'room_id': _room, 'event_id': r'$a', 'saved_ts': 10},
          {'room_id': _room, 'event_id': r'$b', 'saved_ts': 30},
          {'room_id': _room, 'event_id': r'$a', 'saved_ts': 5},
          {'room_id': 'bad', 'event_id': r'$c', 'saved_ts': 40},
          {'room_id': _room, 'event_id': 'txn', 'saved_ts': 40},
          'junk',
          {'room_id': _room, 'event_id': r'$d', 'saved_ts': 30},
        ],
      });
      expect(
        [for (final b in list.bookmarks) b.eventId],
        [r'$b', r'$d', r'$a'],
      );
      expect(list.bookmarks.last.savedTs, 10);
    });

    test('serialises only identifiers and keeps unknown fields', () {
      final list = BookmarkList.fromJson({
        'bookmarks': [
          {'room_id': _room, 'event_id': r'$a', 'saved_ts': 1, 'tag': 'x'},
        ],
        'v': 2,
      });
      final json = list.withAdded(_room, r'$b', savedTs: 2).toJson();
      expect(json['v'], 2);
      expect(json['bookmarks'], [
        {'room_id': _room, 'event_id': r'$b', 'saved_ts': 2},
        {'tag': 'x', 'room_id': _room, 'event_id': r'$a', 'saved_ts': 1},
      ]);
    });

    test('add moves an existing bookmark to the front; remove drops it', () {
      var list = BookmarkList.empty
          .withAdded(_room, r'$a', savedTs: 1)
          .withAdded(_room, r'$b', savedTs: 2)
          .withAdded(_room, r'$a', savedTs: 3);
      expect([for (final b in list.bookmarks) b.eventId], [r'$a', r'$b']);
      expect(list.contains(_room, r'$b'), isTrue);
      list = list.withRemoved(_room, r'$b');
      expect(list.contains(_room, r'$b'), isFalse);
      expect(list.length, 1);
      expect(
        () => list.withAdded(_room, 'local-echo', savedTs: 4),
        throwsArgumentError,
      );
    });

    test('an undo restores the original position', () {
      final list = BookmarkList.empty
          .withAdded(_room, r'$old', savedTs: 1)
          .withAdded(_room, r'$new', savedTs: 9)
          .withAdded(_room, r'$mid', savedTs: 5);
      expect(
        [for (final b in list.bookmarks) b.eventId],
        [r'$new', r'$mid', r'$old'],
      );
    });

    test('caps the count and the encoded size, dropping the oldest', () {
      var list = BookmarkList.empty;
      for (var i = 0; i < maxBookmarks + 20; i++) {
        list = list.withAdded(
          '!r${i % 7}:example.org',
          '\$event$i',
          savedTs: i,
        );
      }
      expect(list.length, maxBookmarks);
      expect(list.bookmarks.first.eventId, '\$event${maxBookmarks + 19}');
      expect(list.contains('!r0:example.org', r'$event0'), isFalse);
      expect(
        utf8.encode(jsonEncode(list.toJson())).length,
        lessThanOrEqualTo(maxAccountDataBytes),
      );

      // Long server names hit the byte cap before the count cap.
      var long = BookmarkList.empty;
      final server = 'x' * 150;
      for (var i = 0; i < maxBookmarks; i++) {
        long = long.withAdded('!r:$server', '\$e$i$server', savedTs: i);
      }
      expect(long.length, lessThan(maxBookmarks));
      expect(
        utf8.encode(jsonEncode(long.toJson())).length,
        lessThanOrEqualTo(maxAccountDataBytes),
      );
    });

    test('parse caps oversized lists', () {
      final list = BookmarkList.fromJson({
        'bookmarks': [
          for (var i = 0; i < maxBookmarks * 3; i++)
            {'room_id': _room, 'event_id': '\$e$i', 'saved_ts': i},
        ],
      });
      expect(list.length, maxBookmarks);
    });

    test('room IDs are listed in order of their newest bookmark', () {
      final list = BookmarkList.empty
          .withAdded('!a:x', r'$1', savedTs: 1)
          .withAdded('!b:x', r'$2', savedTs: 2)
          .withAdded('!a:x', r'$3', savedTs: 3);
      expect(list.roomIds, ['!a:x', '!b:x']);
    });
  });

  group('folders', () {
    test('parse validates, de-duplicates, sanitises and keeps unknown '
        'fields', () {
      final folders = ChatFolders.fromJson({
        'folders': [
          {
            'id': 'work',
            'name': '  Work\nstuff  ',
            'icon': '💼',
            'include_rooms': ['!a:x', '!a:x', 'nope', '!b:x'],
            'exclude_rooms': ['!b:x'],
            'include': {'people': true, 'muted': true},
            'colour': 'red',
          },
          {'id': 'work', 'name': 'Duplicate'},
          {'id': 'blank', 'name': '   '},
          {'id': 'bad id', 'name': 'Bad'},
          {'name': 'No ID'},
          {'id': 'plain', 'name': 'Plain', 'icon': 'abc'},
        ],
        'schema': 3,
      });
      expect([for (final f in folders.folders) f.id], ['work', 'plain']);
      final work = folders.byId('work')!;
      expect(work.name, 'Work stuff');
      expect(work.icon, '💼');
      expect(work.label, '💼 Work stuff');
      expect(work.includeRooms, ['!a:x']); // Exclusion wins.
      expect(work.excludeRooms, ['!b:x']);
      expect(work.include.people, isTrue);
      expect(folders.byId('plain')!.icon, isNull);

      final json = folders.toJson();
      expect(json['schema'], 3);
      final first = (json['folders']! as List).first as Map;
      expect(first['colour'], 'red');
      expect((first['include'] as Map)['muted'], true);
      expect(first['include'], containsPair('people', true));
    });

    test('names are bounded and folders capped', () {
      final long = cleanFolderName('a' * 100);
      expect(long.length, maxFolderNameLength);
      final folders = ChatFolders.fromJson({
        'folders': [
          for (var i = 0; i < maxFolders + 5; i++) {'id': 'f$i', 'name': 'F$i'},
        ],
      });
      expect(folders.folders, hasLength(maxFolders));
      expect(
        () => folders.withUpserted(const ChatFolder(id: 'new', name: 'New')),
        throwsA(isA<SavedDataTooLarge>()),
      );
    });

    test('upsert, remove, move and order', () {
      var folders = ChatFolders.empty
          .withUpserted(const ChatFolder(id: 'a', name: 'A'))
          .withUpserted(const ChatFolder(id: 'b', name: 'B'))
          .withUpserted(const ChatFolder(id: 'c', name: 'C'));
      folders = folders.withUpserted(const ChatFolder(id: 'b', name: 'Bee'));
      expect([for (final f in folders.folders) f.name], ['A', 'Bee', 'C']);
      expect(
        [for (final f in folders.withMoved('c', 0).folders) f.id],
        ['c', 'a', 'b'],
      );
      expect(
        [for (final f in folders.withMoved('a', 99).folders) f.id],
        ['b', 'c', 'a'],
      );
      // Folders missing from the order (added elsewhere) stay at the end.
      expect(
        [
          for (final f in folders.withOrder(['c', 'zzz', 'a']).folders) f.id,
        ],
        ['c', 'a', 'b'],
      );
      expect(
        [for (final f in folders.withRemoved('b').folders) f.id],
        ['a', 'c'],
      );
    });

    test('new folder IDs are valid and distinct', () {
      final random = Random(1);
      final a = newFolderId(random);
      final b = newFolderId(random);
      expect(a, isNot(b));
      expect(ChatFolder.tryParse({'id': a, 'name': 'x'}), isNotNull);
    });
  });

  group('folder membership', () {
    test('chat types include matching chats; invites only when asked', () {
      const people = ChatFolder(
        id: 'p',
        name: 'People',
        include: FolderIncludes(people: true),
      );
      expect(
        folderContainsRoom(people, _chat('!dm:x', direct: true), _noFacts),
        isTrue,
      );
      expect(folderContainsRoom(people, _chat('!g:x'), _noFacts), isFalse);
      expect(
        folderContainsRoom(
          people,
          _chat('!i:x', direct: true, invited: true),
          _noFacts,
        ),
        isFalse,
      );
      const invites = ChatFolder(
        id: 'i',
        name: 'Invites',
        include: FolderIncludes(invites: true),
      );
      expect(
        folderContainsRoom(invites, _chat('!i:x', invited: true), _noFacts),
        isTrue,
      );

      const mixed = ChatFolder(
        id: 'm',
        name: 'Mixed',
        include: FolderIncludes(groups: true, unread: true, favourites: true),
      );
      expect(folderContainsRoom(mixed, _chat('!g:x'), _noFacts), isTrue);
      final dm = _chat('!dm:x', direct: true);
      expect(folderContainsRoom(mixed, dm, _noFacts), isFalse);
      expect(
        folderContainsRoom(mixed, dm, (favourite: false, unread: true)),
        isTrue,
      );
      expect(
        folderContainsRoom(mixed, dm, (favourite: true, unread: false)),
        isTrue,
      );
      expect(
        folderContainsRoom(
          mixed,
          _chat('!f:x', direct: true, favourite: true),
          _noFacts,
        ),
        isTrue,
      );
    });

    test('explicit inclusion and exclusion; exclusion wins; never Spaces', () {
      const folder = ChatFolder(
        id: 'f',
        name: 'F',
        includeRooms: ['!in:x', '!space:x'],
        excludeRooms: ['!dm:x'],
        include: FolderIncludes(people: true),
      );
      expect(folderContainsRoom(folder, _chat('!in:x'), _noFacts), isTrue);
      expect(
        folderContainsRoom(folder, _chat('!dm:x', direct: true), _noFacts),
        isFalse,
      );
      expect(
        folderContainsRoom(folder, _chat('!space:x', space: true), _noFacts),
        isFalse,
      );
      expect(folderContainsRoom(folder, _chat('!other:x'), _noFacts), isFalse);
    });

    test('adding and removing a chat from a folder', () {
      const folder = ChatFolder(
        id: 'f',
        name: 'F',
        include: FolderIncludes(people: true),
        excludeRooms: ['!dm:x'],
      );
      final dm = _chat('!dm:x', direct: true);
      final added = folder.withRoomMembership(
        dm.id,
        member: true,
        matchesTypes: true,
      );
      expect(added.excludeRooms, isEmpty);
      expect(folderContainsRoom(added, dm, _noFacts), isTrue);
      // Removing a chat that still matches a type excludes it explicitly.
      final removed = added.withRoomMembership(
        dm.id,
        member: false,
        matchesTypes: true,
      );
      expect(removed.includeRooms, isEmpty);
      expect(removed.excludeRooms, ['!dm:x']);
      expect(folderContainsRoom(removed, dm, _noFacts), isFalse);
      // A chat added only by ID is simply dropped.
      final group = _chat('!g:x');
      final withGroup = folder.withRoomMembership(
        group.id,
        member: true,
        matchesTypes: false,
      );
      expect(folderContainsRoom(withGroup, group, _noFacts), isTrue);
      final withoutGroup = withGroup.withRoomMembership(
        group.id,
        member: false,
        matchesTypes: false,
      );
      expect(withoutGroup.includeRooms, isEmpty);
      expect(withoutGroup.excludeRooms, ['!dm:x']);
    });

    test('unread badge counts unread chats and invites in the folder', () {
      const folder = ChatFolder(
        id: 'f',
        name: 'F',
        include: FolderIncludes(groups: true, invites: true),
      );
      final rooms = [
        _chat('!a:x', unread: 2),
        _chat('!b:x'),
        _chat('!c:x', invited: true),
        _chat('!d:x', direct: true, unread: 5),
        _chat('!s:x', space: true, unread: 1),
      ];
      final count = folderUnreadCount(
        folder,
        rooms,
        (room) => (favourite: false, unread: room.unread > 0),
      );
      expect(count, 2);
    });

    test('Note to self is presented as a direct chat', () {
      final note = presentNoteToSelf(
        ChatRoom(
          id: '!n:x',
          name: 'Empty room',
          preview: 'hi',
          lastActivity: null,
          encrypted: true,
          unread: 1,
        ),
      );
      expect(note.name, noteToSelfTitle);
      expect(note.isDirect, isTrue);
      expect(note.encrypted, isTrue);
      expect(note.unread, 1);
      expect(note.preview, 'hi');
    });
  });
}

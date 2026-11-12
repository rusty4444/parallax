import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/bridge_bots.dart';
import 'package:parallax/matrix_room_names.dart';
import 'package:parallax/people_names.dart';

class _Database extends Fake implements matrix.DatabaseApi {}

class _Client extends matrix.Client {
  _Client()
    : super('bridge-test', database: _Database(), httpClient: http.Client());

  @override
  String? get userID => '@me:samprim.net';
}

const _roomId = '!portal:samprim.net';
const _bot = '@metabot:samprim.net';
const _alex = '@meta_1001:samprim.net';
const _sam = '@meta_1002:samprim.net';

void main() {
  group('joinPeopleNames (Element X room names)', () {
    test('lists people without "Group with"', () {
      expect(joinPeopleNames(['Alex']), 'Alex');
      expect(joinPeopleNames(['Alex', 'Sam']), 'Alex and Sam');
      expect(joinPeopleNames(['Alex', 'Sam', 'Kim']), 'Alex, Sam and Kim');
      expect(
        joinPeopleNames(['Alex', 'Sam'], others: 1),
        'Alex, Sam and 1 other',
      );
      expect(joinPeopleNames(['Alex'], others: 3), 'Alex and 3 others');
      expect(joinPeopleNames([' ', ''], others: 2), '2 people');
      expect(joinPeopleNames(const []), 'Empty chat');
    });
  });

  group('looksLikeBridgeBot', () {
    test('recognises bridge bot usernames and display names', () {
      expect(looksLikeBridgeBot(_bot), isTrue);
      expect(looksLikeBridgeBot('@WhatsAppBot:example.org'), isTrue);
      expect(
        looksLikeBridgeBot('@bridge:x.org', displayName: 'Meta bridge bot'),
        isTrue,
      );
      expect(
        looksLikeBridgeBot('@wa:x.org', displayName: 'WhatsApp Bridge Bot'),
        isTrue,
      );
      expect(
        looksLikeBridgeBot('@sig:x.org', displayName: 'Signal bridgebot'),
        isTrue,
      );
    });

    test('leaves people and bridged contacts alone', () {
      // Puppets of real contacts are the people the chat is with.
      expect(looksLikeBridgeBot(_alex, displayName: 'Alex Chen'), isFalse);
      expect(looksLikeBridgeBot('@robot:x.org', displayName: 'Robot'), isFalse);
      expect(
        looksLikeBridgeBot('@bridget:x.org', displayName: 'Bridget Botham'),
        isFalse,
      );
      expect(looksLikeBridgeBot('not-a-user-id'), isFalse);
    });

    test('a list of only bots is kept, so a bridge room keeps its name', () {
      bool isBot(String id) => id == _bot;
      expect(withoutBridgeBots([_bot, _alex], isBot), [_alex]);
      expect(withoutBridgeBots([_bot], isBot), [_bot]);
    });
  });

  group('room names and avatars', () {
    late _Client client;

    setUp(() => client = _Client());

    matrix.Room room(
      Map<String, String> members, {
      List<String>? heroes,
      String? roomName,
      String? bridgeBot,
      String? direct,
      int? joined,
    }) {
      if (direct != null) {
        client.accountData['m.direct'] = matrix.BasicEvent(
          type: 'm.direct',
          content: {
            direct: [_roomId],
          },
        );
      }
      final room = matrix.Room(
        id: _roomId,
        client: client,
        summary: matrix.RoomSummary.fromJson({
          'm.heroes': heroes ?? members.keys.toList(),
          'm.joined_member_count': joined ?? members.length + 1,
        }),
      );
      var n = 0;
      void state(String type, String key, Map<String, Object?> content) =>
          room.setState(
            matrix.Event(
              type: type,
              stateKey: key,
              senderId: _bot,
              content: content,
              room: room,
              eventId: '\$state${n++}',
              originServerTs: DateTime(2026, 11, 12),
            ),
          );
      for (final MapEntry(key: id, value: name) in members.entries) {
        state(matrix.EventTypes.RoomMember, id, {
          'membership': 'join',
          'displayname': name,
          'avatar_url': 'mxc://samprim.net/${id.substring(1, 8)}',
        });
      }
      if (roomName != null) {
        state(matrix.EventTypes.RoomName, '', {'name': roomName});
      }
      if (bridgeBot != null) {
        state('m.bridge', 'net.example.bridge', {'bridgebot': bridgeBot});
      }
      return room;
    }

    test('a group named after its members leaves out the bridge bot', () {
      final r = room({_bot: 'Meta bridge bot', _alex: 'Alex', _sam: 'Sam'});
      // The SDK's own name is what showed up in the room list.
      expect(r.getLocalizedDisplayname(), contains('Meta bridge bot'));
      expect(r.parallaxName, 'Alex and Sam');
      // The avatar cluster shows the two people, not the Meta logo.
      expect(r.peopleHeroes, [_alex, _sam]);
    });

    test('larger groups name two people and count the others', () {
      final r = room({
        _bot: 'Meta bridge bot',
        _alex: 'Alex',
        _sam: 'Sam',
      }, joined: 7);
      // Me, the bot, Alex and Sam are 4 of 7: 3 others.
      expect(r.parallaxName, 'Alex, Sam and 3 others');
    });

    test('a bot named by m.bridge is left out whatever it is called', () {
      const custom = '@relay:samprim.net';
      final r = room({custom: 'Relay', _alex: 'Alex'}, bridgeBot: custom);
      expect(r.bridgeBotIds, {custom});
      expect(r.parallaxName, 'Alex');
      expect(r.peopleHeroes, [_alex]);
    });

    test('a room with only the bridge bot keeps its name and picture', () {
      final r = room({_bot: 'Meta bridge bot'});
      expect(r.parallaxName, 'Meta bridge bot');
      expect(r.peopleHeroes, [_bot]);
    });

    test('names set on the room are used unchanged', () {
      final r = room({
        _bot: 'Meta bridge bot',
        _alex: 'Alex',
      }, roomName: 'Family');
      expect(r.parallaxName, 'Family');
    });

    test('a DM whose partner is the bot shows its people instead', () {
      final r = room({_bot: 'Meta bridge bot', _alex: 'Alex'}, direct: _bot);
      expect(r.avatar, isNotNull);
      expect(r.parallaxAvatar, isNull);
      expect(r.parallaxName, 'Alex');
      expect(r.peopleHeroes, [_alex]);
    });

    test('a DM partner fills an incomplete hero list before the bot', () {
      final r = room(
        {_bot: 'Meta bridge bot', _alex: 'Alex'},
        heroes: [_bot],
        direct: _alex,
      );
      expect(r.parallaxName, 'Alex');
      expect(r.peopleHeroes, [_alex]);
    });

    test('a bot-directed room finds the loaded contact with sparse heroes', () {
      final r = room(
        {_bot: 'Meta bridge bot', _alex: 'Alex'},
        heroes: [_bot],
        direct: _bot,
      );
      expect(r.parallaxAvatar, isNull);
      expect(r.parallaxName, 'Alex');
      expect(r.peopleHeroes, [_alex]);
    });

    test('an ordinary DM keeps its partner name and avatar', () {
      final r = room({_alex: 'Alex'}, direct: _alex);
      expect(r.parallaxName, 'Alex');
      expect(r.parallaxAvatar, r.avatar);
      expect(r.parallaxAvatar, isNotNull);
    });
  });
}

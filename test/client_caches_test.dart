import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/client_caches.dart';
import 'package:parallax/matrix_room_names.dart';

class _Database extends Fake implements matrix.DatabaseApi {
  int userLookups = 0;

  @override
  Future<void> close() async {}

  @override
  Future<matrix.User?> getUser(String userId, matrix.Room room) async {
    userLookups++;
    return null;
  }
}

class _Client extends matrix.Client {
  _Client() : super('caches-test', database: _Database());

  @override
  String? get userID => '@me:example.org';
}

void main() {
  late _Client client;

  setUp(() => client = _Client());

  void direct(Map<String, Object?> content) => client.accountData['m.direct'] =
      matrix.BasicEvent(type: 'm.direct', content: content);

  void pushRules(Map<String, Object?> global) =>
      client.accountData[matrix.EventTypes.PushRules] = matrix.BasicEvent(
        type: matrix.EventTypes.PushRules,
        content: {'global': global},
      );

  matrix.Room room(
    String id, {
    matrix.Membership membership = matrix.Membership.join,
  }) => matrix.Room(id: id, client: client, membership: membership);

  group('m.direct', () {
    test('the DM partner matches the SDK for every room', () {
      direct({
        '@alex:example.org': ['!a:example.org', '!shared:example.org'],
        '@sam:example.org': ['!shared:example.org', '!b:example.org'],
        'not-a-user': ['!bad:example.org'],
        '@odd:example.org': 'not a list',
      });
      for (final id in [
        '!a:example.org',
        '!b:example.org',
        '!shared:example.org',
        '!bad:example.org',
        '!group:example.org',
      ]) {
        final r = room(id);
        expect(r.directChatPartner, room(id).directChatMatrixID, reason: id);
        expect(r.isDirectChatCached, room(id).isDirectChat, reason: id);
      }
    });

    test('an invite marked direct is a DM with its sender', () {
      final invite = room(
        '!invite:example.org',
        membership: matrix.Membership.invite,
      );
      invite.setState(
        matrix.Event(
          type: matrix.EventTypes.RoomMember,
          stateKey: '@me:example.org',
          senderId: '@alex:example.org',
          content: const {'membership': 'invite', 'is_direct': true},
          room: invite,
          eventId: r'$invite',
          originServerTs: DateTime(2026, 11, 12),
        ),
      );
      expect(invite.directChatPartner, '@alex:example.org');
      expect(invite.directChatPartner, invite.directChatMatrixID);
    });

    test('the map is built once per m.direct event', () {
      direct({
        '@alex:example.org': ['!a:example.org'],
      });
      final first = cachedDirectChats(client);
      expect(identical(cachedDirectChats(client), first), isTrue);
      expect(first, {
        '@alex:example.org': ['!a:example.org'],
      });
      expect(() => first['@x:example.org'] = [], throwsUnsupportedError);

      // Sync replaces the event: the cache follows it.
      direct({
        '@sam:example.org': ['!a:example.org'],
      });
      expect(cachedDirectChats(client).keys, ['@sam:example.org']);
      expect(room('!a:example.org').directChatPartner, '@sam:example.org');
    });

    test('no m.direct means no direct chats', () {
      expect(cachedDirectChats(client), isEmpty);
      expect(room('!a:example.org').isDirectChatCached, isFalse);
    });
  });

  group('push rules', () {
    Map<String, Object?> rule(String id, List<Object?> actions) => {
      'rule_id': id,
      'default': false,
      'enabled': true,
      'actions': actions,
    };

    test('each room state matches the SDK', () {
      pushRules({
        'override': [
          rule('.m.rule.master', ['dont_notify']),
          rule('!muted:example.org', []),
          rule('!legacy:example.org', ['dont_notify']),
          rule('!loud:example.org', ['notify']),
        ],
        'room': [
          rule('!mentions:example.org', []),
          rule('!muted:example.org', ['notify']),
          rule('!loud:example.org', ['dont_notify', 'coalesce']),
          rule('!notify:example.org', [
            'notify',
            {'set_tweak': 'sound', 'value': 'default'},
          ]),
        ],
      });
      for (final id in [
        '!muted:example.org',
        '!legacy:example.org',
        '!loud:example.org',
        '!mentions:example.org',
        '!notify:example.org',
        '!plain:example.org',
      ]) {
        expect(
          room(id).pushRuleStateCached,
          room(id).pushRuleState,
          reason: id,
        );
      }
      expect(
        room('!muted:example.org').pushRuleStateCached,
        matrix.PushRuleState.dontNotify,
      );
      expect(
        room('!loud:example.org').pushRuleStateCached,
        matrix.PushRuleState.mentionsOnly,
      );
      expect(
        room('!mentions:example.org').pushRuleStateCached,
        matrix.PushRuleState.mentionsOnly,
      );
    });

    test('rules are parsed once per m.push_rules event', () {
      pushRules({
        'override': [rule('!a:example.org', [])],
      });
      final first = cachedGlobalPushRules(client);
      expect(identical(cachedGlobalPushRules(client), first), isTrue);
      pushRules({'override': []});
      expect(identical(cachedGlobalPushRules(client), first), isFalse);
      expect(
        room('!a:example.org').pushRuleStateCached,
        matrix.PushRuleState.notify,
      );
    });

    test('no push rules notify', () {
      expect(cachedGlobalPushRules(client), isNull);
      expect(
        room('!a:example.org').pushRuleStateCached,
        matrix.PushRuleState.notify,
      );
    });
  });

  test('ParallaxClient serves SDK reads from the caches', () async {
    final parallax = ParallaxClient('caches-test', database: _Database());
    addTearDown(parallax.dispose);
    parallax.accountData['m.direct'] = matrix.BasicEvent(
      type: 'm.direct',
      content: const {
        '@alex:example.org': ['!a:example.org'],
      },
    );
    expect(identical(parallax.directChats, parallax.directChats), isTrue);
    expect(
      matrix.Room(id: '!a:example.org', client: parallax).isDirectChat,
      isTrue,
    );
    expect(
      matrix.Room(id: '!b:example.org', client: parallax).isDirectChat,
      isFalse,
    );
  });

  test('room names never start member lookups for missing people', () async {
    final database = client.database as _Database;
    final room = matrix.Room(
      id: '!group:example.org',
      client: client,
      summary: matrix.RoomSummary.fromJson({
        'm.heroes': ['@alex:example.org', '@sam:example.org'],
        'm.joined_member_count': 3,
      }),
    );
    expect(room.parallaxName, isNotEmpty);
    expect(room.peopleHeroes, ['@alex:example.org', '@sam:example.org']);
    expect(room.parallaxAvatar, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(database.userLookups, 0);
  });

  test('image shrinking runs in another isolate and still resizes', () async {
    final png = img.encodePng(img.Image(width: 64, height: 32));
    const native = ParallaxNativeImplementations();
    final resized = await native.shrinkImage(
      matrix.MatrixImageFileResizeArguments(
        bytes: png,
        maxDimension: 16,
        fileName: 'photo.png',
        calcBlurhash: false,
      ),
    );
    expect(resized, isNotNull);
    expect(resized!.width, 16);
    expect(resized.height, 8);
    expect(resized.originalWidth, 64);
    final metadata = await native.calcImageMetadata(png);
    expect(metadata?.width, 64);
    expect(metadata?.height, 32);
  });
}

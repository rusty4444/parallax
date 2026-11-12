import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/chat_network.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/network_logo.dart';
import 'package:parallax/room_avatar.dart';
import 'package:parallax/room_logos.dart';
import 'package:parallax/room_pictures.dart';
import 'package:parallax/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reactions_fakes.dart';

final palette = paletteFor(VisualTheme.parallax);

class _MemoryStorage implements RoomPictureStorage {
  final files = <String, Uint8List>{};

  @override
  Future<Map<String, Uint8List>> readAll() async => {...files};

  @override
  Future<void> write(String key, Uint8List bytes) async {
    files[key] = bytes;
  }

  @override
  Future<void> delete(String key) async {
    files.remove(key);
  }
}

RoomPictures _pictures(_MemoryStorage storage) =>
    RoomPictures(storage: storage, prepare: (source) async => source);

ChatRoom _room({ChatNetwork? network}) => ChatRoom(
  id: '!family:example.org',
  name: 'Family',
  preview: '',
  lastActivity: null,
  network: network,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('chat network', () {
    ChatNetwork of(
      List<String> users, [
      List<Map<String, Object?>> bridges = const [],
    ]) => chatNetworkOf(bridgeStates: bridges, userIds: users);

    test('bridge state protocol and bot', () {
      expect(
        of([], [
          {
            'protocol': {'id': 'whatsapp'},
          },
        ]),
        ChatNetwork.whatsapp,
      );
      expect(
        of([], [
          {
            'protocol': {'id': 'gmessages'},
          },
        ]),
        ChatNetwork.googleMessages,
      );
      expect(
        of([], [
          {'bridgebot': '@discordbot:example.org'},
        ]),
        ChatNetwork.discord,
      );
      expect(
        of([], [
          {
            'protocol': {'id': 'mystery'},
          },
        ]),
        ChatNetwork.otherBridge,
      );
    });

    test('bridged contacts and bots by username', () {
      expect(of(['@whatsapp_61400000000:example.org']), ChatNetwork.whatsapp);
      expect(of(['@gmessages_12:example.org']), ChatNetwork.googleMessages);
      expect(of(['@meta_100:example.org']), ChatNetwork.messenger);
      expect(of(['@linkedin_abc:example.org']), ChatNetwork.linkedin);
      expect(of(['@xbox_abc:example.org']), ChatNetwork.xbox);
      expect(of(['@Discord_1:example.org']), ChatNetwork.discord);
      expect(of(['@whatsappbot:example.org']), ChatNetwork.whatsapp);
      // A known app wins over an unknown bridge.
      expect(
        of(['@signal_1:example.org', '@whatsapp_2:example.org']),
        ChatNetwork.whatsapp,
      );
      expect(of(['@signal_1:example.org']), ChatNetwork.otherBridge);
    });

    test('ordinary Matrix users and bare prefixes are Matrix', () {
      expect(of(['@alice:matrix.org']), ChatNetwork.matrix);
      expect(of(['@whatsapp_:example.org']), ChatNetwork.matrix);
      expect(chatNetworkForUser('not-a-user'), isNull);
    });

    test('no evidence at all is unknown, so no logo is guessed', () {
      expect(of([]), ChatNetwork.unknown);
      expect(ChatNetwork.unknown.hasLogo, isFalse);
      expect(ChatNetwork.matrix.hasLogo, isTrue);
    });

    test('portal aliases and member ghosts identify the network', () {
      expect(
        chatNetworkOf(
          bridgeStates: const [],
          userIds: const [],
          aliases: ['#whatsapp_12345:example.org'],
        ),
        ChatNetwork.whatsapp,
      );
      expect(
        chatNetworkOf(
          bridgeStates: const [],
          userIds: const [],
          aliases: ['#meta_100:example.org'],
        ),
        ChatNetwork.messenger,
      );
      expect(
        chatNetworkOf(
          bridgeStates: const [],
          userIds: const [],
          memberIds: ['@alice:example.org', '@ig_99:example.org'],
        ),
        ChatNetwork.instagram,
      );
      expect(
        chatNetworkOf(
          bridgeStates: const [],
          userIds: const [],
          aliases: ['#general:matrix.org'],
        ),
        ChatNetwork.matrix,
      );
      expect(chatNetworkForAlias('not-an-alias'), isNull);
    });

    test('a bridge bot among the members identifies the network', () {
      expect(
        chatNetworkOf(
          bridgeStates: const [],
          userIds: const [],
          memberIds: ['@alice:example.org', '@whatsappbot:example.org'],
        ),
        ChatNetwork.whatsapp,
      );
    });
  });

  group('logos', () {
    test('every logo parses and fills its 24 x 24 box', () {
      for (final network in ChatNetwork.values.where((n) => n.hasLogo)) {
        final bounds = networkLogoPath(network).getBounds();
        expect(bounds.left, greaterThanOrEqualTo(-0.5), reason: '$network');
        expect(bounds.top, greaterThanOrEqualTo(-0.5), reason: '$network');
        expect(bounds.right, lessThanOrEqualTo(24.5), reason: '$network');
        expect(bounds.bottom, lessThanOrEqualTo(24.5), reason: '$network');
        expect(bounds.width, greaterThan(15), reason: '$network');
      }
    });

    test('path parser: compact syntax, relative commands and arcs', () {
      expect(
        parseSvgPath('M0 0h10v10H0z').getBounds(),
        const Rect.fromLTRB(0, 0, 10, 10),
      );
      expect(
        parseSvgPath('M2.5.5l-1.5.5').getBounds(),
        const Rect.fromLTRB(1, 0.5, 2.5, 1),
      );
      final circle = parseSvgPath('M0 12a12 12 0 1 0 24 0a12 12 0 1 0-24 0z');
      expect(circle.getBounds().width, closeTo(24, 0.01));
      expect(circle.getBounds().height, closeTo(24, 0.01));
      expect(circle.contains(const Offset(12, 12)), isTrue);
      expect(() => parseSvgPath('X1'), throwsFormatException);
      expect(() => parseSvgPath('12 3'), throwsFormatException);
      expect(() => parseSvgPath('M1'), throwsFormatException);
    });
  });

  group('room pictures', () {
    test('prepared as a small square JPEG', () {
      final source = img.Image(width: 600, height: 300);
      img.fill(source, color: img.ColorRgb8(200, 30, 30));
      final prepared = prepareRoomPicture(img.encodePng(source));
      final decoded = img.decodeJpg(prepared)!;
      expect(decoded.width, roomPictureSize);
      expect(decoded.height, roomPictureSize);
      expect(prepared.length, lessThan(40 * 1024));
      expect(
        () => prepareRoomPicture(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    });

    test('set, shown from memory, removed', () async {
      final storage = _MemoryStorage();
      final pictures = _pictures(storage);
      addTearDown(pictures.dispose);
      var notified = 0;
      pictures.addListener(() => notified++);
      await pictures.ensureLoaded();
      expect(pictures.has('!family:example.org'), isFalse);

      final bytes = Uint8List.fromList([9, 8, 7]);
      await pictures.setFromImage('!family:example.org', bytes);
      expect(pictures.pictureFor('!family:example.org'), bytes);
      expect(pictures.has('!other:example.org'), isFalse);
      expect(notified, 1);
      // Saved under a hashed name, never the room ID.
      final key = storage.files.keys.single;
      expect(key, matches(RegExp(r'^[0-9a-f]{40}$')));

      await pictures.remove('!family:example.org');
      expect(pictures.has('!family:example.org'), isFalse);
      expect(storage.files, isEmpty);
      expect(notified, 2);
    });

    test('saved pictures load once on start', () async {
      final storage = _MemoryStorage();
      final first = _pictures(storage);
      await first.setFromImage('!a:example.org', Uint8List.fromList([1]));
      first.dispose();

      final second = _pictures(storage);
      addTearDown(second.dispose);
      expect(second.loaded, isFalse);
      await second.ensureLoaded();
      expect(second.pictureFor('!a:example.org'), [1]);
    });

    test('rejects empty and oversized images', () async {
      final pictures = _pictures(_MemoryStorage());
      addTearDown(pictures.dispose);
      expect(
        () => pictures.setFromImage('!a:example.org', Uint8List(0)),
        throwsArgumentError,
      );
      expect(
        () => pictures.setFromImage(
          '!a:example.org',
          Uint8List(maxRoomPictureSourceBytes + 1),
        ),
        throwsArgumentError,
      );
    });

    test('disk storage writes atomically and reads back', () async {
      final root = await Directory.systemTemp.createTemp('room_pictures');
      addTearDown(() => root.delete(recursive: true));
      final storage = DiskRoomPictureStorage(root: root);
      expect(await storage.readAll(), isEmpty);
      await storage.write('abc', Uint8List.fromList([4, 5]));
      expect(await storage.readAll(), {
        'abc': [4, 5],
      });
      final names = Directory(
        '${root.path}/room_pictures',
      ).listSync().map((e) => e.path.split('/').last);
      expect(names, ['abc.jpg']);
      await storage.delete('abc');
      await storage.delete('abc');
      expect(await storage.readAll(), isEmpty);
    });
  });

  test('room logo choices are saved on the phone', () async {
    final dir = await Directory.systemTemp.createTemp('room_logos');
    addTearDown(() => dir.delete(recursive: true));
    final logos = RoomLogos(directory: dir);
    await logos.set('!a:example.org', ChatNetwork.xbox);
    expect(logos.overrideFor('!a:example.org'), ChatNetwork.xbox);
    expect(logos.overrideFor('!b:example.org'), isNull);
    logos.dispose();

    final restored = RoomLogos(directory: dir);
    addTearDown(restored.dispose);
    await restored.ensureLoaded();
    expect(restored.overrideFor('!a:example.org'), ChatNetwork.xbox);
    await restored.set('!a:example.org', null);
    expect(restored.overrideFor('!a:example.org'), isNull);
  });

  test('app logos preference is off by default and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final preferences = AppearancePreferences(prefs: prefs);
    addTearDown(preferences.dispose);
    await preferences.load();
    expect(preferences.networkLogos, isFalse);
    await preferences.setNetworkLogos(true);
    expect(preferences.networkLogos, isTrue);
    final restored = AppearancePreferences(prefs: prefs);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.networkLogos, isTrue);
  });

  group('RoomAvatar', () {
    Future<void> pump(
      WidgetTester tester, {
      required ChatRoom room,
      required bool logos,
      required RoomPictures pictures,
      RoomLogos? logoOverrides,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final preferences = AppearancePreferences(prefs: prefs);
      addTearDown(preferences.dispose);
      await preferences.setNetworkLogos(logos);
      await pictures.ensureLoaded();
      await tester.pumpWidget(
        MaterialApp(
          home: FeatureSettingsScope(
            preferences: preferences,
            draftStore: MessageDraftStore(),
            child: Center(
              child: RoomAvatar(
                room: room,
                backend: PlainBackend(),
                palette: palette,
                pictures: pictures,
                logoOverrides: logoOverrides,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('letter by default, app logo when the setting is on', (
      tester,
    ) async {
      final pictures = _pictures(_MemoryStorage());
      addTearDown(pictures.dispose);
      final room = _room(network: ChatNetwork.whatsapp);
      await pump(tester, room: room, logos: false, pictures: pictures);
      expect(find.byType(InitialAvatar), findsOneWidget);
      expect(find.byType(NetworkLogo), findsNothing);

      await pump(tester, room: room, logos: true, pictures: pictures);
      expect(find.byType(NetworkLogo), findsOneWidget);
      expect(find.byType(InitialAvatar), findsNothing);
      expect(
        tester.widget<NetworkLogo>(find.byType(NetworkLogo)).network,
        ChatNetwork.whatsapp,
      );

      // Unknown bridges keep the letter.
      await pump(
        tester,
        room: _room(network: ChatNetwork.otherBridge),
        logos: true,
        pictures: pictures,
      );
      expect(find.byType(InitialAvatar), findsOneWidget);
    });

    testWidgets('a picture set on the phone wins and updates live', (
      tester,
    ) async {
      final source = img.Image(width: 4, height: 4);
      final jpeg = img.encodeJpg(source);
      final pictures = _pictures(_MemoryStorage());
      addTearDown(pictures.dispose);
      final room = _room(network: ChatNetwork.discord);
      await pump(tester, room: room, logos: true, pictures: pictures);
      expect(find.byType(NetworkLogo), findsOneWidget);

      await pictures.setFromImage(room.id, jpeg);
      await tester.pump();
      expect(find.byType(NetworkLogo), findsNothing);
      expect(find.byType(Image), findsOneWidget);

      await pictures.remove(room.id);
      await tester.pump();
      expect(find.byType(NetworkLogo), findsOneWidget);
    });

    testWidgets('a per-room logo choice wins over detection', (tester) async {
      final logos = RoomLogos(inMemory: true);
      addTearDown(logos.dispose);
      await logos.set('!family:example.org', ChatNetwork.whatsapp);
      final pictures = _pictures(_MemoryStorage());
      addTearDown(pictures.dispose);

      await pump(
        tester,
        room: _room(network: ChatNetwork.matrix),
        logos: true,
        pictures: pictures,
        logoOverrides: logos,
      );
      expect(
        tester.widget<NetworkLogo>(find.byType(NetworkLogo)).network,
        ChatNetwork.whatsapp,
      );

      // "No logo" forces the letter even with the setting on.
      await logos.set('!family:example.org', ChatNetwork.otherBridge);
      await tester.pump();
      expect(find.byType(InitialAvatar), findsOneWidget);
      expect(find.byType(NetworkLogo), findsNothing);

      // Back to automatic.
      await logos.set('!family:example.org', null);
      await tester.pump();
      expect(
        tester.widget<NetworkLogo>(find.byType(NetworkLogo)).network,
        ChatNetwork.matrix,
      );
    });
  });
}

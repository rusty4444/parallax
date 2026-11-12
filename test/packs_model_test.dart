import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/packs/custom_reactions.dart';
import 'package:parallax/features/packs/pack_features.dart';
import 'package:parallax/features/packs/pack_model.dart';
import 'package:parallax/features/packs/pack_upload.dart';

import 'packs_fakes.dart';

void main() {
  group('pack parsing', () {
    test('reads images, pack metadata and keeps unknown keys', () {
      final parsed = ImagePack.fromJson({
        'images': {
          'wave': {
            'url': 'mxc://example.org/wave',
            'body': 'A wave',
            'info': {'w': 64, 'h': 32, 'mimetype': 'image/png'},
            'usage': ['emoticon'],
            'org.example.extra': 1,
          },
        },
        'pack': {
          'display_name': 'Aussie',
          'avatar_url': 'mxc://example.org/avatar',
          'usage': ['emoticon', 'sticker'],
          'attribution': 'CC-BY',
          'org.example.pack': true,
        },
        'org.example.top': 'kept',
      });
      final wave = parsed.images['wave']!;
      expect(wave.url, Uri.parse('mxc://example.org/wave'));
      expect(wave.body, 'A wave');
      expect((wave.width, wave.height, wave.mimetype), (64, 32, 'image/png'));
      expect(parsed.displayName, 'Aussie');
      expect(parsed.avatarUrl, Uri.parse('mxc://example.org/avatar'));
      expect(parsed.attribution, 'CC-BY');
      final json = parsed.toJson();
      expect(json['org.example.top'], 'kept');
      expect((json['pack'] as Map)['org.example.pack'], true);
      expect(((json['images'] as Map)['wave'] as Map)['org.example.extra'], 1);
    });

    test('skips malformed entries without throwing and preserves them', () {
      final parsed = ImagePack.fromJson({
        'images': {
          'ok': {'url': 'mxc://example.org/ok'},
          'http': {'url': 'https://evil.example/x.png'},
          'nourl': {'body': 'missing'},
          'notmap': 'mxc://example.org/x',
          'has space': {'url': 'mxc://example.org/space'},
          'colon:code': {'url': 'mxc://example.org/colon'},
          'badmxc': {'url': 'mxc://example.org/../etc'},
        },
        'pack': 'not a map',
      });
      expect(parsed.images.keys, ['ok']);
      expect(parsed.displayName, isNull);
      expect(
        (parsed.toJson()['images'] as Map).keys,
        containsAll(['ok', 'http', 'nourl', 'notmap']),
      );
      for (final junk in <Object?>[
        null,
        7,
        'x',
        [],
        {'images': 5},
      ]) {
        expect(ImagePack.fromJson(junk).isEmpty, isTrue);
      }
    });

    test('accepts the legacy emoticons and short layouts', () {
      final legacy = ImagePack.fromJson({
        'emoticons': {
          ':blob:': {'url': 'mxc://example.org/blob'},
        },
      });
      expect(legacy.images.keys, ['blob']);
      final short = ImagePack.fromJson({
        'short': {':cat:': 'mxc://example.org/cat'},
      });
      expect(short.images['cat']!.url, Uri.parse('mxc://example.org/cat'));
    });

    test('usage defaults: absent or empty means both; unknown-only none', () {
      final p = ImagePack.fromJson({
        'images': {
          'both': {'url': 'mxc://e.org/a'},
          'empty': {'url': 'mxc://e.org/b', 'usage': <String>[]},
          'emoji': {
            'url': 'mxc://e.org/c',
            'usage': ['emoticon'],
          },
          'sticker': {
            'url': 'mxc://e.org/d',
            'usage': ['sticker', 'org.example.future'],
          },
          'future': {
            'url': 'mxc://e.org/e',
            'usage': ['org.example.future'],
          },
        },
      });
      Set<PackUsage> of(String code) => p.usageOf(p.images[code]!);
      expect(of('both'), {PackUsage.emoticon, PackUsage.sticker});
      expect(of('empty'), {PackUsage.emoticon, PackUsage.sticker});
      expect(of('emoji'), {PackUsage.emoticon});
      expect(of('sticker'), {PackUsage.sticker});
      expect(of('future'), isEmpty);

      // Pack-level usage applies to images without their own.
      final stickerPack = ImagePack.fromJson({
        'images': {
          'a': {'url': 'mxc://e.org/a'},
        },
        'pack': {
          'usage': ['sticker'],
        },
      });
      expect(stickerPack.imagesFor(PackUsage.emoticon), isEmpty);
      expect(stickerPack.imagesFor(PackUsage.sticker), hasLength(1));
    });

    test('changing usage keeps unknown values', () {
      expect(
        usageToJson({PackUsage.emoticon}, ['org.example.future', 'sticker']),
        ['org.example.future', 'emoticon'],
      );
    });

    test('withImage renames in place and refuses duplicates', () {
      final p = pack([packImage('a', 'a'), packImage('b', 'b')]);
      final renamed = p.withImage(
        p.images['a']!.copyWith(shortcode: 'z'),
        replacing: 'a',
      );
      expect(renamed.images.keys, ['z', 'b']);
      expect(() => p.withImage(packImage('b', 'other')), throwsArgumentError);
      expect(p.withoutImage('a').images.keys, ['b']);
    });

    test('bounds the number of images', () {
      final parsed = ImagePack.fromJson({
        'images': {
          for (var i = 0; i < maxPackImages + 50; i++)
            'e$i': {'url': 'mxc://example.org/m$i'},
        },
      });
      expect(parsed.images, hasLength(maxPackImages));
    });
  });

  group('validation', () {
    test('mxc URIs', () {
      expect(parseMxcUri('mxc://example.org/abc_DEF-1'), isNotNull);
      expect(parseMxcUri('mxc://example.org:8448/abc'), isNotNull);
      expect(parseMxcUri('mxc://[::1]/abc'), isNotNull);
      for (final bad in [
        'https://example.org/abc',
        'mxc://example.org/',
        'mxc://example.org/a/b',
        'mxc://exa mple.org/a',
        'mxc://example.org/a?b=c',
        'MXC://example.org/abc',
        'mxc://example.org/${'a' * 300}',
        null,
        42,
      ]) {
        expect(parseMxcUri(bad), isNull, reason: '$bad');
      }
    });

    test('shortcodes', () {
      expect(normaliseShortcode(' :Party Parrot!: '), 'Party_Parrot');
      expect(normaliseShortcode(':::'), '');
      expect(isCreatableShortcode('blob_cat+1.v2'), isTrue);
      expect(isCreatableShortcode('nope&'), isFalse);
      expect(isValidShortcode('ünïcode'), isTrue);
      expect(isValidShortcode('a b'), isFalse);
      expect(packSlug('Big Pack!!'), 'big-pack');
      expect(packSlug('***'), 'pack');
    });

    test('reaction keys (MSC4027)', () {
      expect(isValidReactionKey('👍'), isTrue);
      expect(isValidReactionKey('👨‍👩‍👧‍👦'), isTrue);
      expect(isValidReactionKey('mxc://example.org/abc'), isTrue);
      expect(isValidReactionKey('mxc://example.org/../x'), isFalse);
      expect(isValidReactionKey('mxc://'), isFalse);
      expect(isValidReactionKey(''), isFalse);
      expect(isValidReactionKey('this is far too long'), isFalse);
      expect(isCustomReactionKey('mxc://example.org/abc'), isTrue);
      expect(normaliseReactionShortcode('wave'), ':wave:');
      expect(normaliseReactionShortcode(':wave:'), ':wave:');
      expect(normaliseReactionShortcode('two words'), isNull);
      expect(normaliseReactionShortcode(7), isNull);
    });

    test('sticker content uses validated info only', () {
      final image = PackImage(
        shortcode: 'roo',
        url: Uri.parse('mxc://example.org/roo'),
        body: 'A kangaroo',
        info: const {
          'w': 256,
          'h': -1,
          'mimetype': 'text/html',
          'size': 2048,
          'thumbnail_url': 'https://evil.example',
        },
      );
      expect(stickerContent(image), {
        'body': 'A kangaroo',
        'url': 'mxc://example.org/roo',
        'info': {'w': 256, 'size': 2048},
      });
      expect(stickerContent(packImage('roo', 'roo'))['body'], 'roo');
    });
  });

  group('availability', () {
    final personal = pack([packImage('wave', 'p-wave')], name: 'Mine');
    final roomDefault = RoomPackState(
      ref: const PackRef.room(packsRoomId, ''),
      pack: pack([packImage('wave', 'r-wave'), packImage('roo', 'r-roo')]),
      roomName: 'Kangaroo Club',
    );
    final roomExtra = RoomPackState(
      ref: const PackRef.room(packsRoomId, 'extra'),
      pack: pack([packImage('roo', 'x-roo'), packImage('koala', 'x-koala')]),
      roomName: 'Kangaroo Club',
    );
    final global = RoomPackState(
      ref: const PackRef.room(packsOtherRoomId, ''),
      pack: pack([packImage('wombat', 'g-wombat'), packImage('roo', 'g-roo')]),
      roomName: 'Wombats',
    );

    test('merge order: personal, room packs by state key, then global', () {
      final packs = mergeAvailablePacks(
        personal: personal,
        roomPacks: [roomExtra, roomDefault],
        globalPacks: [global, roomDefault],
      );
      expect(packs.packs.map((p) => (p.scope, p.slug)), [
        (PackScope.personal, 'user'),
        (PackScope.room, 'room'),
        (PackScope.room, 'extra'),
        (PackScope.global, 'wombats'),
      ]);
      // A room pack that is also enabled everywhere appears once.
      expect(packs.packs.where((p) => p.ref == roomDefault.ref), hasLength(1));
      expect(packs.packs.first.name, 'Mine');
      expect(packs.packs[1].name, 'Kangaroo Club');
    });

    test('shortcode collisions resolve to the first pack; slug~code picks '
        'a specific one', () {
      final packs = mergeAvailablePacks(
        personal: personal,
        roomPacks: [roomDefault, roomExtra],
        globalPacks: [global],
      );
      expect(packs.resolve('wave')!.image.url.path, '/p-wave');
      expect(packs.resolve('roo')!.image.url.path, '/r-roo');
      expect(packs.resolve('extra~roo')!.image.url.path, '/x-roo');
      expect(packs.resolve('wombats~roo')!.image.url.path, '/g-roo');
      expect(packs.resolve('nope'), isNull);
      // An unknown pack slug does not fall back (as in the SDK's syntax).
      expect(packs.resolve('missing~wave'), isNull);

      final extra = packs.packs.firstWhere((p) => p.slug == 'extra');
      expect(packs.insertCode(extra, extra.pack.images['koala']!), ':koala:');
      expect(packs.insertCode(extra, extra.pack.images['roo']!), ':extra~roo:');
      expect(
        packs.findByUrl(Uri.parse('mxc://example.org/g-wombat'))!.pack.slug,
        'wombats',
      );
    });

    test('usage filters resolution, grouping and search', () {
      final stickers = RoomPackState(
        ref: const PackRef.room(packsRoomId, 'stickers'),
        pack: pack([packImage('big_roo', 's-roo')], usage: const ['sticker']),
        roomName: 'Kangaroo Club',
      );
      final packs = mergeAvailablePacks(
        personal: personal,
        roomPacks: [roomDefault, stickers],
      );
      expect(packs.resolve('big_roo'), isNull);
      expect(packs.resolve('big_roo', usage: PackUsage.sticker), isNotNull);
      expect(
        packs.grouped(PackUsage.sticker).map((g) => g.pack.slug),
        containsAll(['stickers', 'user', 'room']),
      );
      expect(
        packs.grouped(PackUsage.emoticon).map((g) => g.pack.slug),
        isNot(contains('stickers')),
      );
      expect(packs.search('ro').map((e) => e.image.shortcode), ['roo']);
      // Prefix matches first; each distinct image once, packs in order.
      expect(packs.search('w').map((e) => e.image.url.path), [
        '/p-wave',
        '/r-wave',
      ]);
      expect(packs.search('O').map((e) => e.image.shortcode), ['roo']);
      expect(packs.search('av').map((e) => e.pack.slug), ['user', 'room']);
    });

    test('empty packs are not available', () {
      final packs = mergeAvailablePacks(
        personal: ImagePack.empty,
        roomPacks: [
          RoomPackState(
            ref: const PackRef.room(packsRoomId, ''),
            pack: const ImagePack(displayName: 'Empty'),
            roomName: 'Room',
          ),
        ],
      );
      expect(packs.isEmpty, isTrue);
    });
  });

  group('emote_rooms', () {
    test('parses enabled packs leniently and bounded', () {
      expect(parseEmoteRooms(null), isEmpty);
      expect(
        parseEmoteRooms({
          'rooms': {
            packsRoomId: {'': {}, 'extra': {}},
            'not-a-room': {'': {}},
            packsOtherRoomId: 'junk',
          },
        }),
        {
          packsRoomId: ['', 'extra'],
        },
      );
    });

    test('toggling keeps other rooms, packs and unknown keys', () {
      final content = {
        'org.example': 1,
        'rooms': {
          packsOtherRoomId: {
            '': {'org.example.note': 'x'},
          },
        },
      };
      final enabled = setEmoteRoom(
        content,
        const PackRef.room(packsRoomId, 'extra'),
        enabled: true,
      );
      expect(enabled['org.example'], 1);
      expect(parseEmoteRooms(enabled), {
        packsOtherRoomId: [''],
        packsRoomId: ['extra'],
      });
      final disabled = setEmoteRoom(
        enabled,
        const PackRef.room(packsOtherRoomId, ''),
        enabled: false,
      );
      expect((disabled['rooms'] as Map).containsKey(packsOtherRoomId), isFalse);
      expect(
        () => setEmoteRoom({}, const PackRef.personal(), enabled: true),
        throwsArgumentError,
      );
    });
  });

  group('upload validation', () {
    test('accepts real images and reads dimensions from the header', () {
      final prepared = preparePackImage(tinyPng, 'Party Parrot.PNG');
      expect(prepared.mimeType, 'image/png');
      expect((prepared.width, prepared.height), (3, 2));
      expect(prepared.suggestedShortcode, 'party_parrot');
      expect(prepared.fileName, 'party_parrot.png');
      expect(prepared.info, {
        'w': 3,
        'h': 2,
        'mimetype': 'image/png',
        'size': tinyPng.length,
      });
    });

    test('rejects empty, oversized, unknown and corrupt files', () {
      expect(
        () => preparePackImage(Uint8List(0), 'x.png'),
        throwsFormatException,
      );
      expect(
        () => preparePackImage(Uint8List(maxPackImageBytes + 1), 'x.png'),
        throwsFormatException,
      );
      expect(
        () => preparePackImage(
          Uint8List.fromList('<svg></svg>'.codeUnits),
          'x.svg',
        ),
        throwsFormatException,
      );
      // A PNG signature with no valid header.
      expect(
        () => preparePackImage(
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
          'x.png',
        ),
        throwsFormatException,
      );
      expect(
        sniffPackImageType(Uint8List.fromList('GIF89a'.codeUnits)),
        'image/gif',
      );
    });
  });
}

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/packs/pack_features.dart';
import 'package:parallax/features/packs/pack_image.dart';
import 'package:parallax/features/packs/pack_management.dart';
import 'package:parallax/features/packs/pack_model.dart';
import 'package:parallax/features/packs/packs_hooks.dart';
import 'package:parallax/features/packs/packs_picker.dart';
import 'package:parallax/features/reactions/emoji_picker_sheet.dart';
import 'package:parallax/features/rich_timeline/rich_text_view.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/timeline/message_bubble.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'packs_fakes.dart';

FakePacksBackend _backend() {
  final backend = FakePacksBackend()
    ..personal = pack([
      packImage('wave', 'wave'),
      packImage('roo', 'roo', usage: const ['sticker']),
    ], name: 'Mine');
  backend.roomState[const PackRef.room(packsRoomId, '')] = pack([
    packImage('wave', 'room-wave'),
    packImage('koala', 'koala'),
    packImage('big_koala', 'big-koala', usage: const ['sticker']),
  ], name: 'Club pack');
  return backend;
}

RoomHookContext _room(ChatBackend backend) => RoomHookContext(
  backend: backend,
  roomId: packsRoomId,
  palette: packsPalette,
);

ChatEntry _entry({String? html, List<ChatReaction> reactions = const []}) =>
    ChatEntry(
      id: r'$event',
      sender: '@roo:example.org',
      body: 'hello',
      time: DateTime(2026, 11, 12, 9),
      mine: false,
      formattedBody: html,
      reactions: reactions,
      content: {'msgtype': 'm.text', 'body': 'hello'},
    );

class _Host extends StatelessWidget {
  const _Host({required this.onPressed});
  final Future<void> Function(BuildContext context) onPressed;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => onPressed(context),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmojiRecents.instance = EmojiRecents();
    resetCurrentPacksBackend();
  });

  group('emoticon rendering', () {
    Future<void> render(
      WidgetTester tester,
      String html, {
      ChatBackend? backend,
    }) async {
      await tester.pumpWidget(
        packsApp(
          MessageContentView(
            entry: _entry(html: html),
            style: const TextStyle(fontSize: 15),
            palette: packsPalette,
            backend: backend,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('renders mxc emoticons inline through the packs loader', (
      tester,
    ) async {
      final backend = _backend();
      await render(
        tester,
        'Hi <img data-mx-emoticon src="mxc://example.org/wave" '
        'alt=":wave:" title=":wave:" height="32"> there',
        backend: backend,
      );
      expect(find.byType(EmoticonInline), findsOneWidget);
      expect(find.byType(PackImageView), findsOneWidget);
      expect(backend.loads, [Uri.parse('mxc://example.org/wave')]);
      final view = tester.widget<PackImageView>(find.byType(PackImageView));
      expect(view.size, lessThanOrEqualTo(32));
      expect(find.textContaining('there', findRichText: true), findsOneWidget);
    });

    testWidgets('emoticon-only messages render larger', (tester) async {
      final backend = _backend();
      await render(
        tester,
        '<img data-mx-emoticon src="mxc://example.org/wave" alt=":wave:">',
        backend: backend,
      );
      final view = tester.widget<PackImageView>(find.byType(PackImageView));
      expect(view.size, greaterThan(32));
    });

    testWidgets('only mxc data-mx-emoticon images are fetched; others show '
        'alt text', (tester) async {
      final backend = _backend();
      await render(
        tester,
        '<img data-mx-emoticon src="https://evil.example/track.png" '
        'alt=":evil:"> <img src="mxc://example.org/plain" alt="plain mxc"> '
        '<img data-mx-emoticon src="data:image/png;base64,AAAA" alt=":data:">'
        ' <img data-mx-emoticon src="mxc://example.org/../x" alt=":dots:">',
        backend: backend,
      );
      expect(find.byType(EmoticonInline), findsNothing);
      expect(backend.loads, isEmpty);
      for (final alt in [':evil:', 'plain mxc', ':data:', ':dots:']) {
        expect(find.textContaining(alt, findRichText: true), findsOneWidget);
      }
    });

    testWidgets('without a packs backend emoticons fall back to alt text', (
      tester,
    ) async {
      await render(
        tester,
        '<img data-mx-emoticon src="mxc://example.org/wave" alt=":wave:">',
      );
      expect(find.byType(PackImageView), findsNothing);
      expect(find.text(':wave:'), findsOneWidget);
    });
  });

  group('emoji picker tabs', () {
    Future<String?> pick(
      WidgetTester tester, {
      required bool forReaction,
      List<CustomEmojiTab>? tabs,
      required List<Finder> taps,
    }) async {
      phoneSurface(tester);
      String? result = 'unset';
      await tester.pumpWidget(
        _Host(
          onPressed: (context) async {
            result = await showEmojiPickerSheet(
              context,
              palette: packsPalette,
              forReaction: forReaction,
              customTabs: tabs,
            );
          },
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      for (final finder in taps) {
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }
      return result;
    }

    testWidgets('pack tabs insert :shortcode: for the composer', (
      tester,
    ) async {
      final backend = _backend();
      final tabs = customEmojiTabsFor(
        backend: backend,
        roomId: packsRoomId,
        forReaction: false,
      );
      expect(tabs.map((t) => t.label), ['Mine', 'Club pack']);
      expect(
        tabs.last.items.map((i) => i.value),
        [':room~wave:', ':koala:'],
        reason: 'the room wave is shadowed by the personal one',
      );
      final result = await pick(
        tester,
        forReaction: false,
        tabs: tabs,
        taps: [
          find.byKey(const ValueKey('emoji-tab-room')),
          find.byKey(const ValueKey('custom-emoji-room-:koala:')),
        ],
      );
      expect(result, ':koala:');
    });

    testWidgets('reaction picks return the mxc key; tabs resolve from the '
        'signed-in backend', (tester) async {
      final backend = _backend();
      packsFeaturesOf(backend);
      final result = await pick(
        tester,
        forReaction: true,
        taps: [
          find.byKey(const ValueKey('emoji-tab-user')),
          find.byKey(const ValueKey('custom-emoji-user-:wave:')),
        ],
      );
      expect(result, 'mxc://example.org/wave');
    });

    testWidgets('the standard emoji tab still works and no tabs without '
        'packs', (tester) async {
      final result = await pick(
        tester,
        forReaction: true,
        taps: [find.byKey(const ValueKey('emoji-🎉'))],
      );
      expect(result, '🎉');
      expect(find.byKey(const ValueKey('emoji-tab-standard')), findsNothing);
    });
  });

  group('composer hooks', () {
    testWidgets('":" suggestions show the image and insert the code', (
      tester,
    ) async {
      final backend = _backend();
      late List<ComposerSuggestionSource> sources;
      await tester.pumpWidget(
        packsApp(
          Builder(
            builder: (context) {
              sources = packsSuggestionSources(context, _room(backend));
              return const SizedBox();
            },
          ),
        ),
      );
      expect(sources.single.trigger, ':');
      expect(sources.single.minQueryLength, 1);
      final results = sources.single.search('KOA');
      expect(results.map((s) => (s.label, s.insertText, s.subtitle)), [
        (':koala:', ':koala: ', 'Club pack'),
      ]);
      expect(results.single.leading, isNotNull);
      final waves = sources.single.search('wav');
      expect(waves.map((s) => s.insertText), [':wave: ', ':room~wave: ']);
      expect(sources.single.search('big'), isEmpty, reason: 'stickers only');

      expect(
        packsSuggestionSources(
          tester.element(find.byType(SizedBox)),
          _room(PlainPacksBackend()),
        ),
        isEmpty,
      );
    });

    testWidgets('Sticker attachment sends the picked sticker', (tester) async {
      phoneSurface(tester);
      final backend = _backend();
      await tester.pumpWidget(
        _Host(
          onPressed: (context) => packsComposerAttachments(
            context,
            _room(backend),
          ).single.onSelected(context),
        ),
      );
      final action = packsComposerAttachments(
        tester.element(find.text('Open')),
        _room(backend),
      ).single;
      expect(action.label, 'Sticker');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Mine'), findsOneWidget);
      expect(find.text('Club pack'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sticker-room-big_koala')));
      await tester.pumpAndSettle();
      expect(backend.stickers.single.$1, packsRoomId);
      expect(backend.stickers.single.$2.shortcode, 'big_koala');
    });

    testWidgets('sticker failures are reported', (tester) async {
      phoneSurface(tester);
      final backend = _backend()..failSticker = true;
      await tester.pumpWidget(
        _Host(
          onPressed: (context) =>
              pickAndSendSticker(context, _room(backend), backend),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sticker-user-roo')));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t send this sticker.'), findsOneWidget);
    });

    testWidgets('an empty sticker picker explains where to add packs', (
      tester,
    ) async {
      phoneSurface(tester);
      final backend = FakePacksBackend();
      await tester.pumpWidget(
        _Host(
          onPressed: (context) => showStickerPicker(
            context,
            features: backend,
            roomId: packsRoomId,
            palette: packsPalette,
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No sticker packs yet'), findsOneWidget);
    });
  });

  group('reaction chips', () {
    testWidgets('custom emoji reactions show the pack image and shortcode', (
      tester,
    ) async {
      phoneSurface(tester);
      final backend = _backend();
      final reacted = <String>[];
      await tester.pumpWidget(
        packsApp(
          MessageBubble(
            entry: _entry(
              reactions: const [
                ChatReaction(
                  emoji: 'mxc://example.org/koala',
                  count: 2,
                  mine: true,
                ),
                ChatReaction(emoji: '👍', count: 1, mine: false),
              ],
            ),
            backend: backend,
            roomId: packsRoomId,
            palette: packsPalette,
            group: false,
            onHeart: () {},
            onAction: () {},
            onReaction: reacted.add,
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('custom-reaction-mxc://example.org/koala')),
        findsOneWidget,
      );
      expect(find.text('2'), findsOneWidget);
      expect(find.text('👍 1'), findsOneWidget);
      expect(
        find.byTooltip('You and 1 other reacted with :koala:'),
        findsOneWidget,
      );
      await tester.tap(find.text('2'));
      await tester.pump();
      expect(reacted, ['mxc://example.org/koala']);
    });

    test('labels fall back for unknown or malformed custom keys', () {
      final backend = _backend();
      expect(reactionKeyLabel(backend, packsRoomId, '🎉'), '🎉');
      expect(
        reactionKeyLabel(backend, packsRoomId, 'mxc://example.org/unknown'),
        'custom emoji',
      );
      expect(
        customReactionChipLabel(
          backend: backend,
          roomId: packsRoomId,
          reactionKey: '🎉',
          count: 1,
        ),
        isNull,
      );
    });
  });

  group('pack management', () {
    Future<void> openRoomPacks(
      WidgetTester tester,
      FakePacksBackend backend, {
      PackImagePicker? picker,
    }) async {
      phoneSurface(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: RoomPacksScreen(
            features: backend,
            roomId: packsRoomId,
            palette: packsPalette,
            pickImage: picker,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('room details section opens the room packs', (tester) async {
      phoneSurface(tester);
      final backend = _backend();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: packsRoomDetailsSections(context, _room(backend)),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Emoji & stickers'), findsOneWidget);
      expect(find.text('1 pack'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('packs-room-details-tile')));
      await tester.pumpAndSettle();
      expect(find.text('PACKS IN THIS ROOM'), findsOneWidget);
      expect(find.text('Club pack'), findsOneWidget);
      expect(find.text('Create pack'), findsOneWidget);
    });

    testWidgets('create a pack, add an image, rename and delete it', (
      tester,
    ) async {
      final backend = FakePacksBackend();
      await openRoomPacks(
        tester,
        backend,
        picker: () async => XFile.fromData(
          tinyPng,
          name: 'Party Parrot.png',
          path: 'Party Parrot.png',
        ),
      );
      expect(find.text('No packs yet'), findsOneWidget);
      await tester.tap(find.text('Create pack'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('pack-name-field')),
        'Aussie animals',
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      const ref = PackRef.room(packsRoomId, '');
      expect(backend.roomState[ref]!.displayName, 'Aussie animals');
      expect(find.text('No images yet'), findsOneWidget);

      // Add: the shortcode is suggested from the file name.
      await tester.tap(find.byKey(const ValueKey('pack-add-image')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('pack-shortcode-field')),
      );
      expect(field.controller!.text, 'party_parrot');
      await tester.tap(find.text('Sticker'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pack-image-save')));
      await tester.pumpAndSettle();
      expect(backend.uploads, ['party_parrot.png image/png ${tinyPng.length}']);
      final added = backend.roomState[ref]!.images['party_parrot']!;
      expect(added.url, Uri.parse('mxc://example.org/upload1'));
      expect(added.usage, ['sticker']);
      expect(added.info, {
        'w': 3,
        'h': 2,
        'mimetype': 'image/png',
        'size': tinyPng.length,
      });
      expect(find.text(':party_parrot:'), findsOneWidget);

      // Rename, keeping the image.
      await tester.tap(find.byKey(const ValueKey('pack-image-party_parrot')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('pack-shortcode-field')),
        'parrot',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pack-image-save')));
      await tester.pumpAndSettle();
      expect(backend.roomState[ref]!.images.keys, ['parrot']);
      expect(backend.roomState[ref]!.images['parrot']!.url, added.url);

      // Invalid shortcodes cannot be saved.
      await tester.tap(find.byKey(const ValueKey('pack-image-parrot')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('pack-shortcode-field')),
        'two words&',
      );
      await tester.pump();
      expect(find.text('Use letters, numbers, _ - + or .'), findsOneWidget);
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('pack-image-save')),
      );
      expect(save.onPressed, isNull);

      // Delete.
      await tester.tap(find.byKey(const ValueKey('pack-image-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(backend.roomState[ref]!.images, isEmpty);
    });

    testWidgets('invalid uploads are refused before uploading', (tester) async {
      final backend = _backend();
      await openRoomPacks(
        tester,
        backend,
        picker: () async => XFile.fromData(
          Uint8List.fromList('<svg/>'.codeUnits),
          name: 'evil.svg',
          path: 'evil.svg',
        ),
      );
      await tester.tap(find.text('Club pack'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pack-add-image')));
      await tester.pumpAndSettle();
      expect(find.text('Use a PNG, GIF, WebP or JPEG image.'), findsOneWidget);
      expect(backend.uploads, isEmpty);
    });

    testWidgets('"Use in all rooms" toggles the pack everywhere', (
      tester,
    ) async {
      final backend = _backend();
      await openRoomPacks(tester, backend);
      await tester.tap(find.text('Club pack'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pack-everywhere-switch')));
      await tester.pumpAndSettle();
      expect(backend.everywhere, {const PackRef.room(packsRoomId, '')});
      await tester.tap(find.byKey(const ValueKey('pack-everywhere-switch')));
      await tester.pumpAndSettle();
      expect(backend.everywhere, isEmpty);
    });

    testWidgets('without permission the pack is read-only', (tester) async {
      final backend = _backend()..canEdit = false;
      await openRoomPacks(tester, backend);
      expect(find.text('Create pack'), findsNothing);
      await tester.tap(find.text('Club pack'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pack-add-image')), findsNothing);
      expect(find.byKey(const ValueKey('pack-delete-tile')), findsNothing);
      // Using it everywhere is account data, so it stays available.
      expect(
        find.byKey(const ValueKey('pack-everywhere-switch')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('pack-image-koala')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pack-shortcode-field')), findsNothing);
    });

    testWidgets('settings: personal pack and packs used everywhere', (
      tester,
    ) async {
      phoneSurface(tester);
      final backend = _backend()
        ..everywhere.add(const PackRef.room(packsRoomId, ''));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: packsSettingsSections(
                  context,
                  SettingsHookContext(backend: backend, palette: packsPalette),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('EMOJI & STICKERS'), findsOneWidget);
      expect(
        find.text('2 images in your pack · 1 room pack everywhere'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('packs-settings-tile')));
      await tester.pumpAndSettle();
      expect(find.text('Mine'), findsOneWidget);
      expect(find.text('Club pack'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(backend.everywhere, isEmpty);
      expect(find.text('None yet'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('personal-pack-tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pack-name-tile')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('pack-name-field')),
        'Sam’s emoji',
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(backend.personal.displayName, 'Sam’s emoji');
      expect(backend.writes, [const PackRef.personal()]);
      expect(find.byKey(const ValueKey('pack-delete-tile')), findsNothing);
    });
  });
}

/// A backend without pack support.
class PlainPacksBackend extends ChatBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

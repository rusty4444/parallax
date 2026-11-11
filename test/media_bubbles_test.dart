import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/inline_audio.dart';
import 'package:parallax/features/media/media_bubbles.dart';
import 'package:parallax/features/media/media_hooks.dart';
import 'package:parallax/features/media/media_preferences.dart';
import 'package:parallax/features/media/media_settings_section.dart';
import 'package:parallax/features/media/voice_waveform.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/media_player_owner.dart';
import 'package:parallax/message_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_test_support.dart';

const voiceContent = <String, Object?>{
  'msgtype': 'm.audio',
  'org.matrix.msc3245.voice': <String, Object?>{},
  'org.matrix.msc1767.audio': {
    'duration': 4000,
    'waveform': [0, 256, 512, 768, 1024],
  },
  'info': {'mimetype': 'audio/mp4', 'duration': 4000},
};

void main() {
  late List<String> log;
  late List<FakePlayer> players;

  setUp(() {
    log = [];
    players = [];
    debugInlineFileFactory = (_) async => FakeTempFile(log);
    debugInlinePlayerFactory = (_, _) {
      final player = FakePlayer(log, length: const Duration(seconds: 4));
      players.add(player);
      return player;
    };
    voicePlaybackSpeed.value = 1;
  });

  tearDown(() {
    debugInlineFileFactory = createMediaTempFile;
    debugInlinePlayerFactory = createNativeMediaPlayer;
    voicePlaybackSpeed.value = 1;
  });

  Widget body(FakeMediaBackend backend, ChatEntry entry) => host(
    Builder(
      builder: (context) =>
          mediaEntryBody(context, hookFor(backend, entry)) ??
          const Text('none'),
    ),
  );

  testWidgets('media kinds get Element X bodies; text and redactions do not', (
    tester,
  ) async {
    final backend = FakeMediaBackend();
    final cases = <ChatEntry, Type>{
      mediaEntry('i', EntryKind.image): ImageMessageBody,
      mediaEntry('v', EntryKind.video): VideoMessageBody,
      mediaEntry('a', EntryKind.audio): AudioMessageBody,
      mediaEntry('o', EntryKind.voice, content: voiceContent): VoiceMessageBody,
      mediaEntry('s', EntryKind.sticker): StickerMessageBody,
      mediaEntry('f', EntryKind.file): FileMessageBody,
    };
    for (final MapEntry(key: entry, value: type) in cases.entries) {
      await tester.pumpWidget(body(backend, entry));
      expect(find.byType(type), findsOneWidget, reason: '$type');
    }
    await tester.pumpWidget(body(backend, mediaEntry('t', EntryKind.text)));
    expect(find.text('none'), findsOneWidget);
    await tester.pumpWidget(
      body(backend, mediaEntry('r', EntryKind.image, redacted: true)),
    );
    expect(find.text('none'), findsOneWidget);
  });

  testWidgets('image caption shows only with a distinct filename', (
    tester,
  ) async {
    final backend = FakeMediaBackend();
    await tester.pumpWidget(
      body(
        backend,
        mediaEntry(
          'i',
          EntryKind.image,
          body: 'Sunset over Bondi',
          content: {
            'filename': 'IMG_1.jpg',
            'info': {'w': 400, 'h': 300},
          },
        ),
      ),
    );
    expect(find.text('Sunset over Bondi'), findsOneWidget);
    expect(find.byType(MessageImage), findsOneWidget);

    await tester.pumpWidget(
      body(
        backend,
        mediaEntry(
          'j',
          EntryKind.image,
          body: 'IMG_2.jpg',
          content: {'filename': 'IMG_2.jpg'},
        ),
      ),
    );
    expect(find.text('IMG_2.jpg'), findsNothing);
  });

  testWidgets('file card shows type icon, size and type label', (tester) async {
    await tester.pumpWidget(
      body(
        FakeMediaBackend(),
        mediaEntry(
          'f',
          EntryKind.file,
          body: 'Quarterly report.pdf',
          content: {
            'info': {'mimetype': 'application/pdf', 'size': 1536},
          },
        ),
      ),
    );
    expect(find.text('Quarterly report.pdf'), findsOneWidget);
    expect(find.text('1.5 KB · PDF'), findsOneWidget);
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    expect(find.byTooltip('Save Quarterly report.pdf'), findsOneWidget);
  });

  testWidgets('video shows a play badge and duration, loading its thumbnail', (
    tester,
  ) async {
    final backend = FakeMediaBackend();
    await tester.pumpWidget(
      body(
        backend,
        mediaEntry(
          'v',
          EntryKind.video,
          body: 'clip.mp4',
          content: {
            'info': {
              'duration': 65000,
              'w': 1280,
              'h': 720,
              'thumbnail_url': 'mxc://example.org/t',
            },
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('1:05'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(backend.previews, ['v']);
  });

  testWidgets(
    'voice plays on demand, cycles Element X speeds and releases on dispose',
    (tester) async {
      final backend = FakeMediaBackend();
      await tester.pumpWidget(
        body(backend, mediaEntry('o', EntryKind.voice, content: voiceContent)),
      );
      expect(find.byType(WaveformBars), findsOneWidget);
      expect(find.text('0:04'), findsOneWidget);
      expect(backend.loads, isEmpty, reason: 'no download before play');
      expect(find.text('1×'), findsOneWidget);

      await tester.tap(find.byTooltip('Play'));
      await settle(tester);
      expect(backend.loads, ['o']);
      expect(find.byTooltip('Pause'), findsOneWidget);

      for (final label in ['1.5×', '2×', '0.5×', '1×']) {
        await tester.tap(find.byType(TextButton));
        await settle(tester);
        expect(find.text(label), findsOneWidget);
      }
      expect(players.single.speeds, [1.5, 2.0, 0.5, 1.0]);

      await tester.tap(find.byTooltip('Pause'));
      await settle(tester);
      expect(find.byTooltip('Play'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      expect(log.indexOf('dispose'), lessThan(log.indexOf('delete')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('starting one inline player pauses the other', (tester) async {
    final backend = FakeMediaBackend();
    final first = mediaEntry('one', EntryKind.voice, content: voiceContent);
    final second = mediaEntry('two', EntryKind.voice, content: voiceContent);
    await tester.pumpWidget(
      host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            VoiceMessageBody(ctx: hookFor(backend, first)),
            VoiceMessageBody(ctx: hookFor(backend, second)),
          ],
        ),
      ),
    );
    await tester.tap(find.byTooltip('Play').first);
    await settle(tester);
    await tester.tap(find.byTooltip('Play'));
    await settle(tester);
    expect(players, hasLength(2));
    expect(players.first.value.playing, isFalse);
    expect(players.last.value.playing, isTrue);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('audio player shows name, size and becomes seekable', (
    tester,
  ) async {
    await tester.pumpWidget(
      body(
        FakeMediaBackend(),
        mediaEntry(
          'a',
          EntryKind.audio,
          body: 'interview.mp3',
          content: {
            'info': {
              'mimetype': 'audio/mpeg',
              'size': 2097152,
              'duration': 184000,
            },
          },
        ),
      ),
    );
    expect(find.text('interview.mp3'), findsOneWidget);
    expect(find.text('0:00 / 3:04 · 2 MB'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    await tester.tap(find.byTooltip('Play'));
    await settle(tester);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('failed downloads offer a retry', (tester) async {
    final backend = FakeMediaBackend()
      ..original = (_) => throw StateError('offline');
    await tester.pumpWidget(
      body(backend, mediaEntry('o', EntryKind.voice, content: voiceContent)),
    );
    await tester.tap(find.byTooltip('Play'));
    await settle(tester);
    expect(find.byTooltip('Retry'), findsOneWidget);
    expect(players, isEmpty);
  });

  test('message actions add share, save image and file info', () {
    final backend = FakeMediaBackend();
    List<String> ids(ChatEntry entry) => [
      for (final item in mediaMessageActions(
        _FakeContext(),
        hookFor(backend, entry),
      ))
        item.id,
    ];
    expect(ids(mediaEntry('i', EntryKind.image)), [
      'media.share',
      'media.save',
      'media.info',
    ]);
    expect(ids(mediaEntry('f', EntryKind.file)), ['media.share', 'media.info']);
    expect(ids(mediaEntry('t', EntryKind.text)), isEmpty);
    expect(ids(mediaEntry('r', EntryKind.image, redacted: true)), isEmpty);
  });

  testWidgets('room details offer "Media and files" only with media access', (
    tester,
  ) async {
    late List<Widget> withFeatures, without;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) {
            withFeatures = mediaRoomDetailsSections(
              context,
              RoomHookContext(
                backend: FakeMediaBackend(),
                roomId: roomId,
                palette: palette,
              ),
            );
            without = mediaRoomDetailsSections(
              context,
              RoomHookContext(
                backend: PlainBackend(),
                roomId: roomId,
                palette: palette,
              ),
            );
            return Column(children: withFeatures);
          },
        ),
      ),
    );
    expect(find.text('Media and files'), findsOneWidget);
    expect(without, isEmpty);
  });

  testWidgets('stickers render without bubble chrome via the new hook', (
    tester,
  ) async {
    final backend = FakeMediaBackend();
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) =>
              mediaEntryStandalone(
                context,
                hookFor(
                  backend,
                  mediaEntry('s', EntryKind.sticker, body: 'Party parrot'),
                ),
              ) ??
              const Text('none'),
        ),
      ),
    );
    expect(find.byType(StandaloneSticker), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(
      mediaEntryStandalone(
        tester.element(find.byType(StandaloneSticker)),
        hookFor(backend, mediaEntry('i', EntryKind.image)),
      ),
      isNull,
    );
  });

  testWidgets('settings toggle persists "Optimise image upload quality"', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = MediaPreferences();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              MediaSettingsSection(palette: palette, preferences: prefs),
            ],
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Optimise image upload quality'), findsOneWidget);
    expect(find.text('Video upload quality'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.byType(Switch));
    await settle(tester);
    expect(prefs.optimiseImages, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    final stored = await SharedPreferences.getInstance();
    expect(stored.getBool(MediaPreferences.optimiseImagesKey), isFalse);
    expect(prefs.uploadOptions.optimiseImages, isFalse);
  });

  test('saved preference is loaded before upload options are used', () async {
    SharedPreferences.setMockInitialValues({
      MediaPreferences.optimiseImagesKey: false,
    });
    final prefs = MediaPreferences();
    expect(prefs.optimiseImages, isTrue, reason: 'Element X default');
    final options = await prefs.resolveUploadOptions();
    expect(options.optimiseImages, isFalse);
  });
}

class _FakeContext extends Fake implements BuildContext {}

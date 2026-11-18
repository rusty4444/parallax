import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/inline_audio.dart';
import 'package:parallax/features/media/media_bubbles.dart';
import 'package:parallax/features/media/media_hooks.dart';
import 'package:parallax/features/media/media_preferences.dart';
import 'package:parallax/features/media/media_settings_section.dart';
import 'package:parallax/features/media/voice_waveform.dart';
import 'package:parallax/features/rich_timeline/message_actions.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/media_player_owner.dart';
import 'package:parallax/message_image.dart';
import 'package:parallax/timeline/message_bubble.dart';
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

  testWidgets(
    'video plays inline, fades pause control, pauses on tap anywhere, and offers full screen',
    (tester) async {
      final backend = FakeMediaBackend()
        ..original = (eventId) => DownloadedAttachment(
          name: '$eventId.mp4',
          mimeType: 'video/mp4',
          bytes: Uint8List.fromList([1, 2, 3]),
        );
      late FakePlayer player;
      await tester.pumpWidget(
        host(
          VideoMessageBody(
            ctx: hookFor(
              backend,
              mediaEntry(
                'v',
                EntryKind.video,
                content: {
                  'info': {'w': 320, 'h': 180},
                },
              ),
            ),
            fileFactory: (_) async => FakeTempFile(log),
            playerFactory: (_, _) => player = FakePlayer(log),
          ),
        ),
      );
      expect(find.byTooltip('Play video'), findsOneWidget);
      expect(find.byTooltip('Full screen video'), findsOneWidget);

      await tester.tap(find.byTooltip('Play video'));
      await settle(tester);
      expect(find.text('native video'), findsOneWidget);
      expect(log, contains('initialize'));
      expect(log, contains('play'));
      expect(find.byTooltip('Pause video'), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.byTooltip('Pause video'),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        1,
      );

      // Once playing, the pause button fades away completely.
      await tester.pump(const Duration(seconds: 1));
      expect(player.value.playing, isTrue);
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.byTooltip('Pause video'),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        0,
      );
      expect(find.byTooltip('Pause video').hitTestable(), findsNothing);

      // Tapping anywhere on the video (away from the center button) pauses it
      // and brings back the Play control.
      final topLeft = tester.getTopLeft(find.byType(VideoMessageBody));
      await tester.tapAt(topLeft + const Offset(16, 16));
      await settle(tester);
      expect(player.value.playing, isFalse);
      expect(find.byTooltip('Play video').hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.byTooltip('Play video'),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        1,
      );

      // Tapping anywhere on the paused video resumes and fades out again.
      await tester.tapAt(topLeft + const Offset(16, 16));
      await settle(tester);
      expect(player.value.playing, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byTooltip('Pause video').hitTestable(), findsNothing);

      // Tapping the center after fade also pauses via the full-bleed target.
      await tester.tap(find.byType(VideoMessageBody));
      await settle(tester);
      expect(player.value.playing, isFalse);
      expect(find.byTooltip('Play video').hitTestable(), findsOneWidget);

      // Resume, then verify app backgrounding pauses and restores Play.
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump(const Duration(seconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await settle(tester);
      expect(log, contains('pause'));
      expect(find.byTooltip('Play video').hitTestable(), findsOneWidget);
    },
  );

  testWidgets('every media kind fits a 320 dp phone inside MessageBubble', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backend = FakeMediaBackend();
    final entries = [
      mediaEntry(
        'i',
        EntryKind.image,
        body: 'A long caption for a photo',
        content: {
          'filename': 'p.jpg',
          'info': {'w': 4000, 'h': 1000},
        },
      ),
      mediaEntry(
        'v',
        EntryKind.video,
        content: {
          'info': {'w': 1080, 'h': 1920, 'duration': 3600000},
        },
      ),
      mediaEntry('o', EntryKind.voice, content: voiceContent, mine: true),
      mediaEntry(
        'a',
        EntryKind.audio,
        body: 'a very long audio file name that keeps going.mp3',
        content: {
          'info': {'size': 123456789, 'duration': 7200000},
        },
      ),
      mediaEntry('s', EntryKind.sticker),
      mediaEntry(
        'f',
        EntryKind.file,
        body: 'an extremely long document name for testing layout.docx',
        content: {
          'info': {'size': 999999999},
        },
      ),
    ];
    for (final entry in entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                MessageBubble(
                  entry: entry,
                  backend: backend,
                  roomId: roomId,
                  palette: palette,
                  group: false,
                  onHeart: () {},
                  onAction: () {},
                  onReaction: (_) {},
                  entries: entries,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: entry.kind.name);
    }
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

  group('links in captions', () {
    late List<Uri> opened;

    setUp(() {
      opened = [];
      final previous = richTimelineLaunchUrl;
      richTimelineLaunchUrl = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => richTimelineLaunchUrl = previous);
    });

    Widget bubble(ChatEntry entry) => MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            MessageBubble(
              entry: entry,
              backend: FakeMediaBackend(),
              roomId: roomId,
              palette: palette,
              group: false,
              onHeart: () {},
              onAction: () {},
              onReaction: (_) {},
            ),
          ],
        ),
      ),
    );

    // A real tap on the link's first glyph. The bubble also listens for a
    // double tap, so a single tap only counts once that wait is over.
    Future<void> tapText(WidgetTester tester, String text) async {
      for (final element in find.byType(RichText).evaluate()) {
        final rich = element.widget as RichText;
        final start = rich.text.toPlainText().indexOf(text);
        if (start < 0) continue;
        final paragraph = element.renderObject! as RenderParagraph;
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: start + text.length),
        );
        if (boxes.isEmpty) continue;
        await tester.tapAt(
          paragraph.localToGlobal(boxes.first.toRect().center),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        return;
      }
      fail('No text "$text" on screen');
    }

    testWidgets('a bridged post link under its picture opens when tapped', (
      tester,
    ) async {
      // What the Messenger bridge sends for a shared Facebook post: the
      // post's picture, captioned with the post's link.
      const link = 'https://www.facebook.com/share/p/1AbCdEfGhJ/';
      await tester.pumpWidget(
        bubble(
          mediaEntry(
            r'$post',
            EntryKind.image,
            body: link,
            formattedBody: '<a href="$link">$link</a>',
            content: {
              'msgtype': 'm.image',
              'filename': 'image.jpg',
              'format': 'org.matrix.custom.html',
              'formatted_body': '<a href="$link">$link</a>',
              'external_url': link,
              'info': {'w': 526, 'h': 526, 'mimetype': 'image/jpeg'},
            },
          ),
        ),
      );
      expect(find.byType(MessageImage), findsOneWidget);
      await tapText(tester, link);
      expect(opened, [Uri.parse(link)]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a link typed in a plain caption opens too', (tester) async {
      await tester.pumpWidget(
        bubble(
          mediaEntry(
            r'$clip',
            EntryKind.video,
            body: 'Full match at https://example.org/match.',
            content: {
              'msgtype': 'm.video',
              'filename': 'clip.mp4',
              'info': {'w': 320, 'h': 180, 'mimetype': 'video/mp4'},
            },
          ),
        ),
      );
      await tapText(tester, 'https://example.org/match');
      expect(opened, [Uri.parse('https://example.org/match')]);
    });

    testWidgets('an emoji-only caption stays caption-sized', (tester) async {
      await tester.pumpWidget(
        bubble(
          mediaEntry(
            r'$party',
            EntryKind.image,
            body: '🎉🎉',
            content: {
              'filename': 'party.jpg',
              'info': {'w': 400, 'h': 300},
            },
          ),
        ),
      );
      final caption = tester.widget<RichText>(
        find.byWidgetPredicate(
          (widget) => widget is RichText && widget.text.toPlainText() == '🎉🎉',
        ),
      );
      expect(caption.text.style!.fontSize, 15);
    });
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

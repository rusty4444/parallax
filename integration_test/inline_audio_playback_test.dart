// Real native playback of voice notes and audio files, the way the
// timeline's inline players load them:
//   flutter test integration_test/inline_audio_playback_test.dart -d <device>
//
// Host tests replace the player with a fake, so only a device run shows
// whether the platform's player opens each format. Ogg Opus is what Element,
// Element X and the WhatsApp/Signal bridges send; on Windows it reaches the
// player rewrapped as WebM (playableOnThisPlatform).
import 'package:audioplayers/audioplayers.dart' as audio;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/media_player_owner.dart';

import 'audio_playback_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final formats = <(String, String, List<int>)>[
    ('voice.ogg', 'audio/ogg; codecs=opus', opusVoiceNote),
    ('voice.m4a', 'audio/mp4', aacVoiceNote),
    ('song.mp3', 'audio/mpeg', mp3AudioFile),
  ];

  for (final (name, mime, bytes) in formats) {
    testWidgets('$name opens and plays in the native player', (tester) async {
      Object? failure;
      Duration? position;
      MediaPlaybackValue? value;
      await tester.runAsync(() async {
        final attachment = playableOnThisPlatform(
          DownloadedAttachment(
            name: name,
            mimeType: mime,
            bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          ),
        );
        // The same temporary file and player the inline bubbles use.
        final owner = MediaPlayerOwner(loader: () async => attachment);
        final probe = audio.AudioPlayer();
        final file = await createMediaTempFile(attachment);
        try {
          await owner.load();
          await owner.play();
          // The plugin reports position from frame callbacks, which do not
          // run here; ask a second player for the real position instead.
          await probe.setSourceDeviceFile(
            file.path,
            mimeType: attachment.mimeType,
          );
          await probe.resume();
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          position = await probe.getCurrentPosition();
          value = owner.player?.value;
        } catch (error) {
          failure = error;
        } finally {
          await probe.dispose();
          await owner.close();
          await file.delete();
        }
      });
      expect(failure, isNull, reason: '$failure');
      expect(value?.error, isNull);
      expect(value?.playing, isTrue);
      expect(value?.duration, greaterThan(const Duration(seconds: 1)));
      expect(
        position,
        greaterThan(const Duration(milliseconds: 600)),
        reason: 'playback advances',
      );
    });
  }
}

// On-device transcription of a voice note on a real Android 13+ device or
// emulator (needs a speech recogniser, e.g. Android System Intelligence):
//   flutter test integration_test/transcription_test.dart -d <device>
//
// The audio is decoded and streamed into the recogniser, so nothing plays
// aloud and the microphone is not used.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/transcription/transcripts.dart';

import 'spoken_note_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const engine = OnDeviceTranscriptionEngine();

  for (final (name, mime, bytes) in [
    ('note.ogg', 'audio/ogg; codecs=opus', spokenOgg),
    ('note.m4a', 'audio/mp4', spokenM4a),
  ]) {
    testWidgets('transcribes $name', (tester) async {
      late bool available;
      String? text;
      await tester.runAsync(() async {
        available = await engine.isAvailable();
        if (!available) return;
        text = await engine.transcribe(
          DownloadedAttachment(name: name, mimeType: mime, bytes: bytes),
        );
      });
      if (!available) {
        markTestSkipped('No on-device speech recogniser here');
        return;
      }
      final words = text!.toLowerCase();
      for (final word in ['voice note', 'meeting', 'tomorrow', 'laptop']) {
        expect(words, contains(word), reason: text);
      }
    });
  }
}

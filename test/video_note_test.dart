import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/media/video_note.dart';
import 'package:parallax/messaging_features.dart';

void main() {
  test('video note marker detection', () {
    expect(isVideoNote({videoNoteMarker: true}), isTrue);
    expect(isVideoNote({videoNoteMarker: false}), isFalse);
    expect(isVideoNote({}), isFalse);
    expect(isVideoNote({'msgtype': 'm.video'}), isFalse);
  });

  test('media selection carries extra content for the marker', () {
    final selection = MediaSelection(
      bytes: Uint8List(0),
      name: 'note.mp4',
      mimeType: 'video/mp4',
      extraContent: const {videoNoteMarker: true},
    );
    expect(selection.extraContent[videoNoteMarker], isTrue);
  });
}

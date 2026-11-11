import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/message_groups.dart';

void main() {
  final start = DateTime.utc(2026, 10, 20, 12);
  ChatEntry image(int minutes, {String sender = '@a:server'}) => ChatEntry(
    id: 'image-$minutes-$sender',
    sender: sender,
    body: 'photo',
    time: start.add(Duration(minutes: minutes)),
    mine: false,
    isImage: true,
  );
  ChatEntry text(int minutes) => ChatEntry(
    id: 'text-$minutes',
    sender: '@a:server',
    body: 'hello',
    time: start.add(Duration(minutes: minutes)),
    mine: false,
  );

  test('groups two, three and four contiguous photos, bounded at four', () {
    final groups = groupTimeline([for (var i = 0; i < 9; i++) image(i)]);
    expect(groups.map((g) => g.entries.length).toList(), [4, 4, 1]);
    expect(groups.map((g) => g.isGallery).toList(), [true, true, false]);
  });

  test('text, sender and elapsed time split galleries', () {
    final groups = groupTimeline([
      image(0),
      image(1),
      text(2),
      image(3),
      image(4, sender: '@b:server'),
      image(10, sender: '@b:server'),
    ]);
    expect(groups.map((g) => g.entries.length).toList(), [2, 1, 1, 1, 1]);
    expect(groups[0].entries.first.id, 'image-0-@a:server');
  });
}

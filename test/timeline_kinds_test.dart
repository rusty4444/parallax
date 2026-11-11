import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/timeline_kinds.dart';

void main() {
  EntryKind kind(String type, {String? msgtype, Map<String, Object?>? c}) =>
      entryKindFor(
        type: type,
        msgtype: msgtype,
        content: c ?? const {},
        redacted: false,
      );

  test('maps message types to timeline kinds', () {
    expect(kind('m.room.message', msgtype: 'm.text'), EntryKind.text);
    expect(kind('m.room.message', msgtype: 'm.emote'), EntryKind.emote);
    expect(kind('m.room.message', msgtype: 'm.notice'), EntryKind.notice);
    expect(kind('m.room.message', msgtype: 'm.location'), EntryKind.location);
    expect(kind('m.room.message', msgtype: 'm.audio'), EntryKind.audio);
    expect(
      kind(
        'm.room.message',
        msgtype: 'm.audio',
        c: {'org.matrix.msc3245.voice': <String, Object?>{}},
      ),
      EntryKind.voice,
    );
    expect(kind('org.matrix.msc3381.poll.start'), EntryKind.poll);
    expect(kind('m.room.member'), EntryKind.state);
    expect(kind('org.matrix.msc4075.rtc.notification'), EntryKind.call);
    expect(kind('m.room.encrypted'), EntryKind.undecryptable);
    expect(kind('com.example.custom'), EntryKind.unknown);
    expect(
      entryKindFor(
        type: 'm.room.message',
        msgtype: 'm.text',
        content: const {},
        redacted: true,
      ),
      EntryKind.redacted,
    );
  });

  test('relations stay out of the main timeline', () {
    expect(isTimelineVisibleType('m.reaction'), isFalse);
    expect(isTimelineVisibleType('org.matrix.msc3381.poll.response'), isFalse);
    expect(isTimelineVisibleType('m.call.member'), isFalse);
    expect(isTimelineVisibleType('m.room.message'), isTrue);
  });

  test('legacy entries derive a kind from their flags', () {
    final image = ChatEntry(
      id: r'$i',
      sender: '@a:b',
      body: 'a.png',
      time: DateTime(2026),
      mine: false,
      isImage: true,
    );
    expect(image.kind, EntryKind.image);
    expect(image.senderLabel, '@a:b');
  });
}

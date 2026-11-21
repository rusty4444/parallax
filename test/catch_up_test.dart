import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/catch_up/catch_up.dart';

ChatEntry entry(
  String id, {
  String sender = '@alice:example.org',
  String body = 'hello',
  bool mine = false,
  bool highlight = false,
  int threadReplyCount = 0,
  EntryKind kind = EntryKind.text,
  bool isImage = false,
}) => ChatEntry(
  id: id,
  sender: sender,
  body: body,
  time: DateTime(2026, 11, 21, 10),
  mine: mine,
  highlight: highlight,
  threadReplyCount: threadReplyCount,
  kind: kind,
  isImage: isImage,
  senderName: sender == '@alice:example.org' ? 'Alice' : 'Bob',
);

void main() {
  test('empty when no unread from others', () {
    final summary = summarizeCatchUp([
      entry('a', mine: true),
    ], '@me:example.org');
    expect(summary.isEmpty, isTrue);
    expect(summary.messageCount, 0);
  });

  test('groups mentions, questions, threads, polls, media and senders', () {
    final entries = [
      entry('1', body: 'hey @me can you review?', highlight: true),
      entry('2', body: 'what time works?'),
      entry('3', body: 'thread root', threadReplyCount: 4),
      entry('4', body: 'Poll: lunch options', kind: EntryKind.poll),
      entry('5', body: 'photo', isImage: true),
      entry('6', body: 'see https://example.org'),
      entry('7', sender: '@bob:example.org', body: 'another'),
      entry('8', sender: '@bob:example.org', body: 'more'),
      entry('9', mine: true, body: 'my own message'),
    ];
    final summary = summarizeCatchUp(entries, '@me:example.org');
    expect(summary.messageCount, 8); // excludes own
    expect(summary.senderCount, 2);
    expect(summary.mentions.length, 1);
    expect(summary.questions.length, 2); // 'review?' and 'what time works?'
    expect(summary.threads.length, 1);
    expect(summary.threads.single.text, contains('4 replies'));
    expect(summary.polls.length, 1);
    expect(summary.mediaCount, 1);
    expect(summary.linkCount, 1);
    expect(summary.topSenders.first.$1, 'Alice');
    expect(summary.topSenders.first.$2, 6);
  });
}

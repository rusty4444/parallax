import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';

/// A strictly on-device, extractive catch-up summary of unread messages.
/// No network calls and no model: it groups what is already decrypted on the
/// phone (mentions, questions, threads, polls, media and active senders).
@immutable
class CatchUpSummary {
  const CatchUpSummary({
    required this.messageCount,
    required this.senderCount,
    this.firstTime,
    this.lastTime,
    this.mentions = const [],
    this.questions = const [],
    this.threads = const [],
    this.polls = const [],
    this.mediaCount = 0,
    this.linkCount = 0,
    this.topSenders = const [],
  });

  final int messageCount;
  final int senderCount;
  final DateTime? firstTime;
  final DateTime? lastTime;
  final List<CatchUpItem> mentions;
  final List<CatchUpItem> questions;
  final List<CatchUpItem> threads;
  final List<CatchUpItem> polls;
  final int mediaCount;
  final int linkCount;
  final List<(String, int)> topSenders;

  bool get isEmpty => messageCount == 0;
}

@immutable
class CatchUpItem {
  const CatchUpItem(this.sender, this.text);
  final String sender;
  final String text;
}

String _snippet(String body, [int max = 140]) {
  final clean = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.length <= max ? clean : '${clean.substring(0, max)}…';
}

/// Builds a summary from unread [entries] (any order). [myUserId] excludes
/// your own messages from the highlights.
CatchUpSummary summarizeCatchUp(List<ChatEntry> entries, String? myUserId) {
  final unread = entries.where((e) => !e.mine && !e.redacted).toList()
    ..sort((a, b) => a.time.compareTo(b.time));
  if (unread.isEmpty) {
    return const CatchUpSummary(messageCount: 0, senderCount: 0);
  }

  final senders = <String, int>{};
  final mentions = <CatchUpItem>[];
  final questions = <CatchUpItem>[];
  final threads = <CatchUpItem>[];
  final polls = <CatchUpItem>[];
  var mediaCount = 0;
  var linkCount = 0;

  for (final e in unread) {
    final label = e.senderLabel;
    senders[label] = (senders[label] ?? 0) + 1;
    if (e.highlight) {
      mentions.add(CatchUpItem(label, _snippet(e.body)));
    }
    if (e.body.contains('?')) {
      questions.add(CatchUpItem(label, _snippet(e.body)));
    }
    if (e.threadReplyCount > 0) {
      threads.add(
        CatchUpItem(
          label,
          '${_snippet(e.body, 80)} (${e.threadReplyCount} replies)',
        ),
      );
    }
    if (e.kind == EntryKind.poll) {
      polls.add(CatchUpItem(label, _snippet(e.body)));
    }
    if (e.isImage ||
        e.isAttachment ||
        e.kind == EntryKind.video ||
        e.kind == EntryKind.audio) {
      mediaCount++;
    }
    if (RegExp(r'https?://').hasMatch(e.body)) {
      linkCount++;
    }
  }

  final top = senders.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return CatchUpSummary(
    messageCount: unread.length,
    senderCount: senders.length,
    firstTime: unread.first.time,
    lastTime: unread.last.time,
    mentions: mentions.take(8).toList(),
    questions: questions.take(8).toList(),
    threads: threads.take(6).toList(),
    polls: polls.take(6).toList(),
    mediaCount: mediaCount,
    linkCount: linkCount,
    topSenders: top.take(3).map((e) => (e.key, e.value)).toList(),
  );
}

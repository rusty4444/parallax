// Pure MSC3381 poll model: parsing, content builders and result tallies.
//
// Element X sends the unstable `org.matrix.msc3381.*` event types and reads
// both unstable and stable (`m.poll.*`) forms. Everything here is free of
// Flutter and the Matrix SDK so it can be unit-tested directly.
import 'dart:math';

import 'package:flutter/foundation.dart';

const pollStartType = 'org.matrix.msc3381.poll.start';
const pollResponseType = 'org.matrix.msc3381.poll.response';
const pollEndType = 'org.matrix.msc3381.poll.end';
const stablePollStartType = 'm.poll.start';
const stablePollResponseType = 'm.poll.response';
const stablePollEndType = 'm.poll.end';

const _textKey = 'org.matrix.msc1767.text';
const _stableTextKey = 'm.text';
const _disclosedKind = 'org.matrix.msc3381.poll.disclosed';
const _undisclosedKind = 'org.matrix.msc3381.poll.undisclosed';

/// Matches Element X (`PollConstants`).
const pollMinAnswers = 2;
const pollMaxAnswers = 20;
const pollMaxAnswerLength = 240;
const pollMaxQuestionLength = 1000;

/// The `m.reference` / `m.replace` relation types used by polls.
const referenceRelation = 'm.reference';
const replaceRelation = 'm.replace';

bool isPollStartType(String type) =>
    type == pollStartType || type == stablePollStartType;
bool isPollResponseType(String type) =>
    type == pollResponseType || type == stablePollResponseType;
bool isPollEndType(String type) =>
    type == pollEndType || type == stablePollEndType;

@immutable
class PollAnswer {
  const PollAnswer({required this.id, required this.text});
  final String id;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is PollAnswer && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);
}

/// A poll's question, answers and settings (from an `*.poll.start`).
@immutable
class PollStart {
  const PollStart({
    required this.question,
    required this.answers,
    this.disclosed = true,
    this.maxSelections = 1,
  });

  final String question;
  final List<PollAnswer> answers;

  /// Disclosed polls show live results; undisclosed ones only after ending.
  final bool disclosed;
  final int maxSelections;

  Set<String> get answerIds => {for (final a in answers) a.id};

  /// Parses unstable (`org.matrix.msc3381.poll.start`) or stable (`m.poll`)
  /// poll start content. Returns null when the content is not a valid poll.
  /// Answer lists are truncated to [pollMaxAnswers] as MSC3381 requires and
  /// duplicate or empty answer IDs are dropped.
  static PollStart? fromContent(Map<String, Object?> content) {
    final unstable = content[pollStartType];
    if (unstable is Map) return _parseBlock(unstable);
    final stable = content['m.poll'] ?? content[stablePollStartType];
    if (stable is Map) return _parseBlock(stable);
    return null;
  }

  static PollStart? _parseBlock(Map<Object?, Object?> block) {
    final question = _readText(block['question']);
    final rawAnswers = block['answers'];
    if (question == null || rawAnswers is! List) return null;
    final seen = <String>{};
    final answers = <PollAnswer>[];
    for (final raw in rawAnswers) {
      if (answers.length >= pollMaxAnswers) break;
      if (raw is! Map) continue;
      final id = raw['id'] ?? raw['m.id'];
      final text = _readText(raw);
      if (id is! String || id.isEmpty || text == null || !seen.add(id)) {
        continue;
      }
      answers.add(PollAnswer(id: id, text: text));
    }
    if (answers.isEmpty) return null;
    final kind = block['kind'];
    final max = block['max_selections'];
    final maxSelections = max is int
        ? max
        : max is num
        ? max.toInt()
        : 1;
    return PollStart(
      question: question,
      answers: List.unmodifiable(answers),
      disclosed: kind == _disclosedKind || kind == 'm.disclosed',
      maxSelections: maxSelections.clamp(1, answers.length),
    );
  }

  /// Plain-text fallback, as sent by Element X: the question then numbered
  /// answers.
  String get fallbackText => [
    question,
    for (var i = 0; i < answers.length; i++) '${i + 1}. ${answers[i].text}',
  ].join('\n');

  Map<String, Object?> get startBlock => {
    'question': {_textKey: question, 'body': question, 'msgtype': 'm.text'},
    'kind': disclosed ? _disclosedKind : _undisclosedKind,
    'max_selections': maxSelections,
    'answers': [
      for (final answer in answers) {'id': answer.id, _textKey: answer.text},
    ],
  };

  /// Content for a new `org.matrix.msc3381.poll.start` event.
  Map<String, Object?> toStartContent() => {
    pollStartType: startBlock,
    _textKey: fallbackText,
    'body': fallbackText,
  };

  /// Content for an `m.replace` edit of [pollId] (Element X "Edit poll").
  /// The top-level fields are the fallback for clients without edits.
  Map<String, Object?> toEditContent(String pollId) => {
    pollStartType: startBlock,
    _textKey: '* $fallbackText',
    'body': '* $fallbackText',
    'm.new_content': toStartContent(),
    'm.relates_to': {'rel_type': replaceRelation, 'event_id': pollId},
  };

  @override
  bool operator ==(Object other) =>
      other is PollStart &&
      other.question == question &&
      other.disclosed == disclosed &&
      other.maxSelections == maxSelections &&
      listEquals(other.answers, answers);

  @override
  int get hashCode =>
      Object.hash(question, disclosed, maxSelections, Object.hashAll(answers));
}

/// Reads an extensible-events text block: `org.matrix.msc1767.text`, the
/// stable `m.text` (string or list of representations) or `body`.
String? _readText(Object? block) {
  if (block is! Map) return null;
  final unstable = block[_textKey];
  if (unstable is String && unstable.trim().isNotEmpty) return unstable;
  final stable = block[_stableTextKey];
  if (stable is String && stable.trim().isNotEmpty) return stable;
  if (stable is List) {
    for (final item in stable) {
      if (item is Map) {
        final body = item['body'];
        final mime = item['mimetype'];
        if (body is String &&
            body.trim().isNotEmpty &&
            (mime == null || mime == 'text/plain')) {
          return body;
        }
      }
    }
  }
  final body = block['body'];
  if (body is String && body.trim().isNotEmpty) return body;
  return null;
}

/// Content for a vote (`org.matrix.msc3381.poll.response`).
Map<String, Object?> pollResponseContent(
  String pollId,
  List<String> answerIds,
) => {
  pollResponseType: {'answers': List<String>.of(answerIds)},
  'm.relates_to': {'rel_type': referenceRelation, 'event_id': pollId},
};

/// Content for ending a poll (`org.matrix.msc3381.poll.end`).
Map<String, Object?> pollEndContent(String pollId) => {
  pollEndType: <String, Object?>{},
  _textKey: 'The poll has ended.',
  'body': 'The poll has ended.',
  'm.relates_to': {'rel_type': referenceRelation, 'event_id': pollId},
};

enum PollRelationKind { response, end, edit }

/// A response, end or edit that relates to a poll start event.
@immutable
class PollRelation {
  const PollRelation({
    required this.eventId,
    required this.kind,
    required this.sender,
    required this.timestamp,
    this.answers = const [],
    this.edit,
  });

  final String eventId;
  final PollRelationKind kind;
  final String sender;
  final DateTime timestamp;

  /// Selected answer IDs (responses only; may be empty).
  final List<String> answers;

  /// Replacement poll (edits only).
  final PollStart? edit;

  /// Classifies a decrypted event relating to a poll. Returns null for
  /// anything that is not a poll response, end or poll edit.
  static PollRelation? fromEvent({
    required String eventId,
    required String type,
    required String sender,
    required DateTime timestamp,
    required Map<String, Object?> content,
  }) {
    final relates = content['m.relates_to'];
    final relType = relates is Map ? relates['rel_type'] : null;
    if (relType == referenceRelation && isPollResponseType(type)) {
      final unstable = content[pollResponseType];
      final stableBlock = content[stablePollResponseType];
      final raw = unstable is Map
          ? unstable['answers']
          : stableBlock is Map
          ? stableBlock['answers']
          : content['m.selections'];
      return PollRelation(
        eventId: eventId,
        kind: PollRelationKind.response,
        sender: sender,
        timestamp: timestamp,
        answers: raw is List
            ? List.unmodifiable(raw.whereType<String>().take(pollMaxAnswers))
            : const [],
      );
    }
    if (relType == referenceRelation && isPollEndType(type)) {
      return PollRelation(
        eventId: eventId,
        kind: PollRelationKind.end,
        sender: sender,
        timestamp: timestamp,
      );
    }
    if (relType == replaceRelation && isPollStartType(type)) {
      final newContent = content['m.new_content'];
      final edit = newContent is Map
          ? PollStart.fromContent(Map<String, Object?>.from(newContent))
          : null;
      if (edit == null) return null;
      return PollRelation(
        eventId: eventId,
        kind: PollRelationKind.edit,
        sender: sender,
        timestamp: timestamp,
        edit: edit,
      );
    }
    return null;
  }
}

/// Aggregated poll state shown in the timeline and poll history.
@immutable
class PollResults {
  const PollResults({
    required this.poll,
    required this.counts,
    required this.totalVotes,
    required this.mySelection,
    required this.ended,
    required this.winners,
    required this.edited,
  });

  /// The poll after applying the latest valid edit.
  final PollStart poll;

  /// Votes per answer ID.
  final Map<String, int> counts;

  /// Sum of all answer votes (Element X "Total votes").
  final int totalVotes;
  final Set<String> mySelection;
  final bool ended;

  /// Answer IDs with the most votes, only once the poll has ended.
  final Set<String> winners;
  final bool edited;

  bool get hasVotes => totalVotes > 0;

  /// Whether tallies may be shown (disclosed polls, or after ending).
  bool get showResults => poll.disclosed || ended;

  int votesFor(String answerId) => counts[answerId] ?? 0;

  double fractionFor(String answerId) =>
      totalVotes == 0 ? 0 : votesFor(answerId) / totalVotes;
}

/// Tallies a poll per MSC3381:
///
/// - the latest edit by the poll's sender replaces question/answers;
/// - the first `end` from the sender or a user allowed to end it (redaction
///   power) ends the poll; others are ignored;
/// - each user's latest response counts; responses after the end are
///   ignored; unknown answer IDs are dropped, selections beyond
///   `max_selections` are truncated and an empty selection spoils (clears)
///   that user's vote.
PollResults computePollResults({
  required PollStart original,
  required String pollSender,
  required Iterable<PollRelation> relations,
  required String? myUserId,
  required bool Function(String userId) mayEnd,
}) {
  final all = relations.toList();
  PollRelation? latestEdit;
  PollRelation? firstEnd;
  for (final relation in all) {
    switch (relation.kind) {
      case PollRelationKind.edit:
        if (relation.sender == pollSender &&
            (latestEdit == null ||
                relation.timestamp.isAfter(latestEdit.timestamp))) {
          latestEdit = relation;
        }
      case PollRelationKind.end:
        if ((relation.sender == pollSender || mayEnd(relation.sender)) &&
            (firstEnd == null ||
                relation.timestamp.isBefore(firstEnd.timestamp))) {
          firstEnd = relation;
        }
      case PollRelationKind.response:
        break;
    }
  }
  final poll = latestEdit?.edit ?? original;
  final validIds = poll.answerIds;
  final latest = <String, PollRelation>{};
  for (final relation in all) {
    if (relation.kind != PollRelationKind.response) continue;
    if (firstEnd != null && relation.timestamp.isAfter(firstEnd.timestamp)) {
      continue;
    }
    final existing = latest[relation.sender];
    if (existing == null ||
        relation.timestamp.isAfter(existing.timestamp) ||
        (relation.timestamp == existing.timestamp &&
            relation.eventId.compareTo(existing.eventId) > 0)) {
      latest[relation.sender] = relation;
    }
  }
  final counts = <String, int>{for (final id in validIds) id: 0};
  var total = 0;
  var mine = <String>{};
  for (final entry in latest.entries) {
    final selection = <String>{};
    for (final id in entry.value.answers) {
      if (selection.length >= poll.maxSelections) break;
      if (validIds.contains(id)) selection.add(id);
    }
    for (final id in selection) {
      counts[id] = counts[id]! + 1;
      total++;
    }
    if (entry.key == myUserId) mine = selection;
  }
  final ended = firstEnd != null;
  var winners = <String>{};
  if (ended && total > 0) {
    final best = counts.values.fold<int>(0, max);
    winners = {
      for (final e in counts.entries)
        if (e.value == best) e.key,
    };
  }
  return PollResults(
    poll: poll,
    counts: Map.unmodifiable(counts),
    totalVotes: total,
    mySelection: Set.unmodifiable(mine),
    ended: ended,
    winners: Set.unmodifiable(winners),
    edited: latestEdit != null,
  );
}

/// A poll being composed or edited (Element X `PollFormState`).
@immutable
class PollDraft {
  const PollDraft({
    this.question = '',
    this.answers = const ['', ''],
    this.disclosed = true,
    this.maxSelections = 1,
  });

  factory PollDraft.fromPoll(PollStart poll) => PollDraft(
    question: poll.question,
    answers: [for (final a in poll.answers) a.text],
    disclosed: poll.disclosed,
    maxSelections: poll.maxSelections,
  );

  final String question;
  final List<String> answers;
  final bool disclosed;
  final int maxSelections;

  bool get canAddAnswer => answers.length < pollMaxAnswers;
  bool get canDeleteAnswer => answers.length > pollMinAnswers;

  bool get isValid =>
      question.trim().isNotEmpty &&
      question.length <= pollMaxQuestionLength &&
      answers.length >= pollMinAnswers &&
      answers.length <= pollMaxAnswers &&
      answers.every(
        (a) => a.trim().isNotEmpty && a.length <= pollMaxAnswerLength,
      ) &&
      maxSelections >= 1 &&
      maxSelections <= answers.length;

  PollDraft copyWith({
    String? question,
    List<String>? answers,
    bool? disclosed,
    int? maxSelections,
  }) {
    final nextAnswers = answers ?? this.answers;
    return PollDraft(
      question: question ?? this.question,
      answers: List.unmodifiable(nextAnswers),
      disclosed: disclosed ?? this.disclosed,
      maxSelections: (maxSelections ?? this.maxSelections).clamp(
        1,
        max(1, nextAnswers.length),
      ),
    );
  }

  PollDraft withNewAnswer() =>
      canAddAnswer ? copyWith(answers: [...answers, '']) : this;

  PollDraft withAnswerRemoved(int index) =>
      canDeleteAnswer ? copyWith(answers: [...answers]..removeAt(index)) : this;

  PollDraft withAnswerChanged(int index, String text) => copyWith(
    answers: [...answers]
      ..[index] = text.length > pollMaxAnswerLength
          ? text.substring(0, pollMaxAnswerLength)
          : text,
  );

  /// Builds the poll to send. [previous] keeps answer IDs stable for
  /// unchanged positions when editing; new answers get random IDs.
  PollStart toPoll({PollStart? previous, Random? random}) {
    final rng = random ?? Random.secure();
    final used = <String>{};
    String freshId() {
      String id;
      do {
        id = List.generate(
          12,
          (_) => _idAlphabet[rng.nextInt(_idAlphabet.length)],
        ).join();
      } while (!used.add(id));
      return id;
    }

    final answersOut = <PollAnswer>[];
    for (var i = 0; i < answers.length; i++) {
      final previousId = previous != null && i < previous.answers.length
          ? previous.answers[i].id
          : null;
      final id = previousId != null && used.add(previousId)
          ? previousId
          : freshId();
      answersOut.add(PollAnswer(id: id, text: answers[i].trim()));
    }
    return PollStart(
      question: question.trim(),
      answers: List.unmodifiable(answersOut),
      disclosed: disclosed,
      maxSelections: maxSelections.clamp(1, answersOut.length),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PollDraft &&
      other.question == question &&
      other.disclosed == disclosed &&
      other.maxSelections == maxSelections &&
      listEquals(other.answers, answers);

  @override
  int get hashCode =>
      Object.hash(question, disclosed, maxSelections, Object.hashAll(answers));
}

const _idAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

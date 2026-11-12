import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/polls/location_model.dart';
import 'package:parallax/features/polls/poll_model.dart';

const _poll = PollStart(
  question: 'Lunch?',
  answers: [
    PollAnswer(id: 'a', text: 'Pizza'),
    PollAnswer(id: 'b', text: 'Sushi'),
    PollAnswer(id: 'c', text: 'Salad'),
  ],
);

PollRelation _vote(String sender, int ts, List<String> answers, {String? id}) =>
    PollRelation(
      eventId: id ?? '\$v-$sender-$ts',
      kind: PollRelationKind.response,
      sender: sender,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      answers: answers,
    );

PollRelation _end(String sender, int ts) => PollRelation(
  eventId: '\$end-$sender-$ts',
  kind: PollRelationKind.end,
  sender: sender,
  timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
);

PollResults _tally(
  List<PollRelation> relations, {
  PollStart poll = _poll,
  String me = '@me:x',
  Set<String> moderators = const {},
}) => computePollResults(
  original: poll,
  pollSender: '@creator:x',
  relations: relations,
  myUserId: me,
  mayEnd: moderators.contains,
);

void main() {
  group('PollStart parsing', () {
    test('reads the unstable MSC3381 content Element X sends', () {
      final poll = PollStart.fromContent({
        'org.matrix.msc3381.poll.start': {
          'question': {'org.matrix.msc1767.text': 'Lunch?'},
          'kind': 'org.matrix.msc3381.poll.undisclosed',
          'max_selections': 2,
          'answers': [
            {'id': 'a', 'org.matrix.msc1767.text': 'Pizza'},
            {'id': 'b', 'org.matrix.msc1767.text': 'Sushi'},
          ],
        },
        'org.matrix.msc1767.text': 'Lunch?\n1. Pizza\n2. Sushi',
      });
      expect(poll, isNotNull);
      expect(poll!.question, 'Lunch?');
      expect(poll.disclosed, isFalse);
      expect(poll.maxSelections, 2);
      expect(poll.answers.map((a) => a.id), ['a', 'b']);
    });

    test('reads the stable m.poll extensible-event form', () {
      final poll = PollStart.fromContent({
        'm.poll': {
          'kind': 'm.disclosed',
          'max_selections': 1,
          'question': {
            'm.text': [
              {'mimetype': 'text/html', 'body': '<b>Q</b>'},
              {'body': 'Question'},
            ],
          },
          'answers': [
            {
              'm.id': 'x',
              'm.text': [
                {'body': 'Yes'},
              ],
            },
            {
              'm.id': 'y',
              'm.text': [
                {'body': 'No'},
              ],
            },
          ],
        },
      });
      expect(poll!.question, 'Question');
      expect(poll.disclosed, isTrue);
      expect(poll.answers.map((a) => a.text), ['Yes', 'No']);
    });

    test('drops duplicate/invalid answers, caps at 20, clamps selections', () {
      final poll = PollStart.fromContent({
        'org.matrix.msc3381.poll.start': {
          'question': {'body': 'Many'},
          'max_selections': 99,
          'answers': [
            {'id': 'dup', 'org.matrix.msc1767.text': 'One'},
            {'id': 'dup', 'org.matrix.msc1767.text': 'Two'},
            {'org.matrix.msc1767.text': 'No id'},
            'not a map',
            for (var i = 0; i < 30; i++)
              {'id': 'n$i', 'org.matrix.msc1767.text': 'Answer $i'},
          ],
        },
      });
      expect(poll!.answers, hasLength(pollMaxAnswers));
      expect(poll.answers.first.id, 'dup');
      expect(poll.maxSelections, pollMaxAnswers);
      expect(poll.disclosed, isFalse, reason: 'missing kind is undisclosed');
    });

    test('rejects content without a question or answers', () {
      expect(PollStart.fromContent({'body': 'hi'}), isNull);
      expect(
        PollStart.fromContent({
          'org.matrix.msc3381.poll.start': {
            'question': {'org.matrix.msc1767.text': 'Q'},
            'answers': <Object>[],
          },
        }),
        isNull,
      );
    });
  });

  group('content builders', () {
    test('start content matches Element X (unstable, fallback text)', () {
      final content = _poll.toStartContent();
      expect(
        content['org.matrix.msc1767.text'],
        'Lunch?\n1. Pizza\n2. Sushi\n3. Salad',
      );
      final block = content['org.matrix.msc3381.poll.start']! as Map;
      expect(block['kind'], 'org.matrix.msc3381.poll.disclosed');
      expect(block['max_selections'], 1);
      expect((block['question'] as Map)['org.matrix.msc1767.text'], 'Lunch?');
      expect(block['answers'], [
        {'id': 'a', 'org.matrix.msc1767.text': 'Pizza'},
        {'id': 'b', 'org.matrix.msc1767.text': 'Sushi'},
        {'id': 'c', 'org.matrix.msc1767.text': 'Salad'},
      ]);
      expect(PollStart.fromContent(content), _poll);
    });

    test('edit content replaces the poll with m.new_content', () {
      final content = _poll.toEditContent(r'$poll');
      expect(content['m.relates_to'], {
        'rel_type': 'm.replace',
        'event_id': r'$poll',
      });
      final newContent = content['m.new_content']! as Map<String, Object?>;
      expect(PollStart.fromContent(newContent), _poll);
      final relation = PollRelation.fromEvent(
        eventId: r'$edit',
        type: pollStartType,
        sender: '@creator:x',
        timestamp: DateTime(2026),
        content: content,
      );
      expect(relation!.kind, PollRelationKind.edit);
      expect(relation.edit, _poll);
    });

    test('response and end relate to the poll by m.reference', () {
      final response = pollResponseContent(r'$poll', ['a']);
      expect(response, {
        'org.matrix.msc3381.poll.response': {
          'answers': ['a'],
        },
        'm.relates_to': {'rel_type': 'm.reference', 'event_id': r'$poll'},
      });
      final end = pollEndContent(r'$poll');
      expect(end['org.matrix.msc3381.poll.end'], isEmpty);
      expect(end['org.matrix.msc1767.text'], 'The poll has ended.');
      expect((end['m.relates_to'] as Map)['rel_type'], 'm.reference');
    });

    test('classifies stable and unstable relations; ignores others', () {
      PollRelation? parse(String type, Map<String, Object?> content) =>
          PollRelation.fromEvent(
            eventId: r'$e',
            type: type,
            sender: '@u:x',
            timestamp: DateTime(2026),
            content: content,
          );
      const ref = {'rel_type': 'm.reference', 'event_id': r'$p'};
      expect(
        parse('m.poll.response', {
          'm.selections': ['a'],
          'm.relates_to': ref,
        })!.answers,
        ['a'],
      );
      expect(
        parse('org.matrix.msc3381.poll.end', {'m.relates_to': ref})!.kind,
        PollRelationKind.end,
      );
      expect(parse('m.reaction', {'m.relates_to': ref}), isNull);
      expect(
        parse('org.matrix.msc3381.poll.response', {
          'm.relates_to': {'rel_type': 'm.annotation', 'event_id': r'$p'},
        }),
        isNull,
      );
    });
  });

  group('computePollResults', () {
    test('counts each user’s latest response only', () {
      final results = _tally([
        _vote('@a:x', 1, ['a']),
        _vote('@a:x', 3, ['b']),
        _vote('@b:x', 2, ['b']),
        _vote('@me:x', 4, ['c']),
      ]);
      expect(results.counts, {'a': 0, 'b': 2, 'c': 1});
      expect(results.totalVotes, 3);
      expect(results.mySelection, {'c'});
      expect(results.ended, isFalse);
      expect(results.winners, isEmpty, reason: 'no winner until ended');
    });

    test('ignores responses after a valid end and highlights winners', () {
      final results = _tally([
        _vote('@a:x', 1, ['a']),
        _vote('@b:x', 2, ['a']),
        _vote('@c:x', 3, ['b']),
        _end('@creator:x', 5),
        _vote('@d:x', 6, ['b']),
        _vote('@a:x', 7, ['b']),
      ]);
      expect(results.ended, isTrue);
      expect(results.counts, {'a': 2, 'b': 1, 'c': 0});
      expect(results.winners, {'a'});
      expect(results.showResults, isTrue);
    });

    test('ends only from the creator or a permitted user', () {
      final stranger = _tally([_end('@stranger:x', 1)]);
      expect(stranger.ended, isFalse);
      final moderator = _tally([_end('@mod:x', 1)], moderators: {'@mod:x'});
      expect(moderator.ended, isTrue);
    });

    test('drops unknown answers, truncates, and spoils empty votes', () {
      final results = _tally([
        _vote('@a:x', 1, ['zzz', 'b', 'a']),
        _vote('@b:x', 1, ['a']),
        _vote('@b:x', 2, []),
      ]);
      expect(results.counts, {'a': 0, 'b': 1, 'c': 0});
      expect(results.totalVotes, 1);
    });

    test('multi-select polls count up to max_selections each', () {
      const poll = PollStart(
        question: 'Pick two',
        answers: [
          PollAnswer(id: 'a', text: 'A'),
          PollAnswer(id: 'b', text: 'B'),
          PollAnswer(id: 'c', text: 'C'),
        ],
        maxSelections: 2,
      );
      final results = _tally([
        _vote('@a:x', 1, ['a', 'b', 'c']),
      ], poll: poll);
      expect(results.counts, {'a': 1, 'b': 1, 'c': 0});
      expect(results.fractionFor('a'), 0.5);
    });

    test('applies the latest edit from the poll creator only', () {
      const edited = PollStart(
        question: 'Dinner?',
        answers: [
          PollAnswer(id: 'x', text: 'Tacos'),
          PollAnswer(id: 'y', text: 'Ramen'),
        ],
        disclosed: false,
      );
      PollRelation edit(String sender, int ts, PollStart poll) => PollRelation(
        eventId: '\$edit$ts',
        kind: PollRelationKind.edit,
        sender: sender,
        timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
        edit: poll,
      );
      final results = _tally([
        edit('@creator:x', 2, edited),
        edit('@intruder:x', 3, _poll),
      ]);
      expect(results.poll, edited);
      expect(results.edited, isTrue);
      expect(results.showResults, isFalse, reason: 'undisclosed until ended');
    });

    test('undisclosed polls reveal results after ending', () {
      const hidden = PollStart(
        question: 'Q',
        answers: [
          PollAnswer(id: 'a', text: 'A'),
          PollAnswer(id: 'b', text: 'B'),
        ],
        disclosed: false,
      );
      expect(_tally(const [], poll: hidden).showResults, isFalse);
      expect(_tally([_end('@creator:x', 1)], poll: hidden).showResults, isTrue);
    });
  });

  group('PollDraft', () {
    test('validates like Element X and bounds answers', () {
      var draft = const PollDraft();
      expect(draft.isValid, isFalse);
      draft = draft
          .copyWith(question: 'Q')
          .withAnswerChanged(0, 'One')
          .withAnswerChanged(1, 'Two');
      expect(draft.isValid, isTrue);
      expect(draft.canDeleteAnswer, isFalse);
      expect(draft.withAnswerRemoved(0), draft);
      for (var i = 0; i < 30; i++) {
        draft = draft.withNewAnswer();
      }
      expect(draft.answers, hasLength(pollMaxAnswers));
      expect(draft.isValid, isFalse, reason: 'new answers are empty');
      final long = draft.withAnswerChanged(0, 'x' * 500);
      expect(long.answers.first.length, pollMaxAnswerLength);
    });

    test('max selections stays within the number of answers', () {
      final draft = const PollDraft(
        question: 'Q',
        answers: ['a', 'b', 'c'],
      ).copyWith(maxSelections: 3);
      expect(draft.maxSelections, 3);
      expect(draft.withAnswerRemoved(2).maxSelections, 2);
    });

    test('toPoll keeps existing answer IDs and generates unique new ones', () {
      final draft = PollDraft.fromPoll(
        _poll,
      ).withNewAnswer().withAnswerChanged(3, ' Curry ');
      final poll = draft.toPoll(previous: _poll, random: Random(1));
      expect(poll.answers.take(3).map((a) => a.id), ['a', 'b', 'c']);
      expect(poll.answers.last.text, 'Curry');
      expect(poll.answerIds, hasLength(4));
      final fresh = const PollDraft(
        question: ' Q ',
        answers: ['A', 'B'],
      ).toPoll(random: Random(2));
      expect(fresh.question, 'Q');
      expect(fresh.answers.first.id, hasLength(12));
      expect(fresh.answerIds, hasLength(2));
    });
  });

  group('location', () {
    test('parses RFC 5870 geo URIs with uncertainty', () {
      final point = GeoPoint.tryParse('geo:-33.8568,151.2153;u=35');
      expect(point, isNotNull);
      expect(point!.latitude, -33.8568);
      expect(point.longitude, 151.2153);
      expect(point.uncertainty, 35);
      expect(GeoPoint.tryParse('geo:51.5,-0.12,30;crs=wgs84'), isNotNull);
    });

    test('rejects malformed, out-of-range and foreign-CRS URIs', () {
      for (final raw in [
        'geo:91,0',
        'geo:0,181',
        'geo:abc,def',
        'https://example.org',
        'geo:1,2;crs=moon',
        'geo:1,2${';x=1' * 100}',
        null,
        42,
      ]) {
        expect(GeoPoint.tryParse(raw), isNull, reason: '$raw');
      }
    });

    test('builds Element X-compatible m.location content', () {
      const point = GeoPoint(-33.8568, 151.2153, uncertainty: 12.4);
      final content = locationContent(
        point: point,
        asset: LocationAsset.pin,
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      const uri = 'geo:-33.856800,151.215300;u=12';
      expect(content['msgtype'], 'm.location');
      expect(content['geo_uri'], uri);
      expect(content['body'], 'Location was shared at $uri');
      expect(content['org.matrix.msc1767.text'], 'Location was shared at $uri');
      expect(content['org.matrix.msc3488.location'], {
        'uri': uri,
        'zoom_level': 15,
      });
      expect(content['org.matrix.msc3488.asset'], {'type': 'm.pin'});
      expect(content['org.matrix.msc3488.ts'], 1700000000000);

      final parsed = SharedLocation.fromContent(content)!;
      expect(parsed.asset, LocationAsset.pin);
      expect(parsed.point.latitude, closeTo(-33.8568, 1e-9));
      expect(parsed.zoom, 15);
    });

    test('falls back to geo_uri and defaults the asset to self', () {
      final parsed = SharedLocation.fromContent({
        'msgtype': 'm.location',
        'geo_uri': 'geo:1.5,2.5',
        'org.matrix.msc3488.location': {
          'uri': 'nonsense',
          'description': ' Café ',
        },
      })!;
      expect(parsed.point, const GeoPoint(1.5, 2.5));
      expect(parsed.asset, LocationAsset.self);
      expect(parsed.description, 'Café');
      expect(SharedLocation.fromContent({'geo_uri': 'geo:999,0'}), isNull);
    });

    test('maps links use geo: with a label and an OSM fallback', () {
      const point = GeoPoint(-33.8568, 151.2153);
      expect(
        point.mapsAppUri(label: 'Sam R').toString(),
        'geo:0,0?q=-33.856800,151.215300(Sam%20R)',
      );
      final osm = point.openStreetMapUri;
      expect(osm.scheme, 'https');
      expect(osm.host, 'www.openstreetmap.org');
      expect(osm.queryParameters['mlat'], '-33.856800');
    });

    test('normalises wrapped longitudes', () {
      expect(normaliseLongitude(190), closeTo(-170, 1e-9));
      expect(normaliseLongitude(-540), closeTo(-180, 1e-9));
      expect(normaliseLongitude(45), 45);
    });
  });
}

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/rich_timeline/linkify.dart';
import 'package:parallax/features/rich_timeline/mention_suggestions.dart';
import 'package:parallax/features/rich_timeline/message_actions.dart';
import 'package:parallax/features/rich_timeline/message_composition.dart';
import 'package:parallax/features/rich_timeline/permalinks.dart';
import 'package:parallax/features/rich_timeline/rich_timeline_features.dart';
import 'package:parallax/features/rich_timeline/state_event_text.dart';
import 'package:parallax/features/rich_timeline/timeline_rows.dart';

const me = '@me:example.org';

ChatEntry entry(
  String id, {
  String sender = '@alice:example.org',
  String body = 'hello',
  DateTime? time,
  EntryKind kind = EntryKind.text,
  String eventType = 'm.room.message',
  Map<String, Object?> content = const {},
  String? stateKey,
  String? senderName,
  bool redacted = false,
  bool isImage = false,
}) => ChatEntry(
  id: id,
  sender: sender,
  body: body,
  time: time ?? DateTime(2026, 11, 12, 10),
  mine: sender == me,
  kind: kind,
  eventType: eventType,
  content: content,
  stateKey: stateKey,
  senderName: senderName,
  redacted: redacted,
  isImage: isImage,
);

ChatEntry member(
  String id, {
  required String sender,
  required String target,
  required String membership,
  String? displayName,
  String? reason,
  String? senderName,
}) => entry(
  id,
  sender: sender,
  kind: EntryKind.state,
  eventType: 'm.room.member',
  stateKey: target,
  senderName: senderName,
  body: 'fallback for $id',
  content: {
    'membership': membership,
    'displayname': ?displayName,
    'reason': ?reason,
  },
);

void main() {
  group('composeTextMessage', () {
    test('plain text stays plain with empty intentional mentions', () {
      final content = composeTextMessage('hello there', ownUserId: me);
      expect(content, {
        'msgtype': 'm.text',
        'body': 'hello there',
        'm.mentions': <String, Object?>{},
      });
      expect(composeTextMessage('one\ntwo')['formatted_body'], isNull);
      expect(composeTextMessage('one\n\ntwo')['formatted_body'], isNull);
    });

    test('markdown becomes Matrix HTML', () {
      final content = composeTextMessage(
        '**bold**, _it_, ~~gone~~ and `code`\n\n> quoted',
      );
      expect(content['format'], 'org.matrix.custom.html');
      final html = content['formatted_body'] as String;
      expect(html, contains('<strong>bold</strong>'));
      expect(html, contains('<em>it</em>'));
      expect(html, contains('<del>gone</del>'));
      expect(html, contains('<code>code</code>'));
      expect(html, contains('<blockquote>'));
      expect(content['body'], startsWith('**bold**'));
    });

    test('raw HTML typed by the user is never sent as markup', () {
      final content = composeTextMessage('<script>alert(1)</script> <b>x</b>');
      final html = content['formatted_body'] as String?;
      expect(html == null || !html.contains('<script'), isTrue);
      expect(html == null || !html.contains('<b>'), isTrue);
    });

    test('/me sends an emote; edits never do', () {
      final emote = composeTextMessage('/me waves');
      expect(emote['msgtype'], 'm.emote');
      expect(emote['body'], 'waves');
      final edit = composeTextMessage('/me waves', editEventId: r'$orig');
      expect((edit['m.new_content'] as Map)['msgtype'], 'm.text');
    });

    test('mentions user IDs, matrix.to links, @room and the reply sender', () {
      final content = composeTextMessage(
        'hi @alice:example.org, [Bob](https://matrix.to/#/@bob:example.org) '
        'and @room! Not me: @me:example.org, not a room: '
        'https://matrix.to/#/!abc:example.org',
        ownUserId: me,
        replyToSender: '@carol:example.org',
      );
      expect(content['m.mentions'], {
        'user_ids': [
          '@bob:example.org',
          '@alice:example.org',
          '@carol:example.org',
        ],
        'room': true,
      });
      expect(
        content['formatted_body'],
        contains('https://matrix.to/#/@alice:example.org'),
      );
    });

    test('display-name mentions resolve to IDs and intentional mentions', () {
      final content = composeTextMessage(
        '@Quinn Harper next time we should play a board game',
        ownUserId: me,
        mentionLabels: const {'Quinn Harper': '@meta_555000111:samprim.net'},
      );
      expect(
        content['body'],
        '@meta_555000111:samprim.net next time we should play a board game',
      );
      expect(content['m.mentions'], {
        'user_ids': ['@meta_555000111:samprim.net'],
      });
      expect(
        content['formatted_body'],
        contains('https://matrix.to/#/@meta_555000111:samprim.net'),
      );
    });

    test('display-name mention pills keep the name as anchor text', () {
      // Regression: the SDK pill syntax labels anchors with the raw MXID,
      // which mautrix-teams forwards as the visible Teams mention text.
      final content = composeTextMessage(
        '@Quinn Harper check your messages when you can',
        ownUserId: me,
        mentionLabels: const {'Quinn Harper': '@meta_555000111:samprim.net'},
      );
      expect(
        content['body'],
        '@meta_555000111:samprim.net check your messages when you can',
      );
      expect(content['m.mentions'], {
        'user_ids': ['@meta_555000111:samprim.net'],
      });
      expect(
        content['formatted_body'],
        contains(
          '<a href="https://matrix.to/#/@meta_555000111:samprim.net">'
          'Quinn Harper</a>',
        ),
      );
      expect(
        content['formatted_body'],
        isNot(contains('>@meta_555000111:samprim.net</a>')),
      );
    });

    test('pill relabel leaves custom link text and unlabelled IDs alone', () {
      final content = composeTextMessage(
        '[Bob](https://matrix.to/#/@bob:example.org) and '
        '@alice:example.org and @Quinn Harper',
        ownUserId: me,
        mentionLabels: const {'Quinn Harper': '@meta_555000111:samprim.net'},
      );
      final html = content['formatted_body'] as String;
      expect(
        html,
        contains('<a href="https://matrix.to/#/@bob:example.org">Bob</a>'),
      );
      expect(
        html,
        contains(
          '<a href="https://matrix.to/#/@alice:example.org">'
          '@alice:example.org</a>',
        ),
      );
      expect(
        html,
        contains(
          '<a href="https://matrix.to/#/@meta_555000111:samprim.net">'
          'Quinn Harper</a>',
        ),
      );
    });

    test('pill relabel escapes display names with HTML characters', () {
      final content = composeTextMessage(
        '@Sam & Co <team> hi',
        ownUserId: me,
        mentionLabels: const {'Sam & Co <team>': '@samco:example.org'},
      );
      final html = content['formatted_body'] as String;
      expect(
        html,
        contains(
          '<a href="https://matrix.to/#/@samco:example.org">'
          'Sam &amp; Co &lt;team&gt;</a>',
        ),
      );
      expect(content['m.mentions'], {
        'user_ids': ['@samco:example.org'],
      });
    });

    test('pill relabel applies to edits and skips code spans', () {
      final edit = composeTextMessage(
        '@Quinn Harper again',
        ownUserId: me,
        editEventId: r'$original',
        mentionLabels: const {'Quinn Harper': '@meta_555000111:samprim.net'},
      );
      final newContent = edit['m.new_content'] as Map;
      expect(
        newContent['formatted_body'],
        contains(
          '<a href="https://matrix.to/#/@meta_555000111:samprim.net">'
          'Quinn Harper</a>',
        ),
      );
      final code = composeTextMessage(
        '`@meta_555000111:samprim.net` stays literal',
        ownUserId: me,
        mentionLabels: const {'Quinn Harper': '@meta_555000111:samprim.net'},
      );
      final html = code['formatted_body'] as String?;
      if (html != null) {
        expect(html, isNot(contains('Quinn Harper')));
      }
    });

    test('email addresses and @roomful are not mentions', () {
      final content = composeTextMessage('mail sam@example.org about @roomful');
      expect(content['m.mentions'], <String, Object?>{});
    });

    test('edits are m.replace with only newly mentioned users on top', () {
      final content = composeTextMessage(
        'thanks @alice:example.org and @bob:example.org',
        ownUserId: me,
        editEventId: r'$original',
        previousMentions: ['@alice:example.org'],
        replyToSender: '@carol:example.org',
      );
      expect(content['m.relates_to'], {
        'rel_type': 'm.replace',
        'event_id': r'$original',
      });
      expect(content['body'], startsWith('* thanks'));
      expect(content['m.mentions'], {
        'user_ids': ['@bob:example.org'],
      });
      final newContent = content['m.new_content'] as Map;
      expect(
        newContent['body'],
        'thanks @alice:example.org and @bob:example.org',
      );
      expect(newContent['m.mentions'], {
        'user_ids': ['@alice:example.org', '@bob:example.org'],
      });
      expect(
        mentionedUserIds({
          'm.mentions': {
            'user_ids': ['@a:b.org', 3],
          },
        }),
        ['@a:b.org'],
      );
    });
  });

  group('links and permalinks', () {
    test('tokenizes URLs, emails, permalinks and @room', () {
      final tokens = tokenizeText(
        'See https://example.org/a_(b). Mail me@example.org, '
        'ping https://matrix.to/#/@alice:example.org and @room. '
        'javascript:alert(1) www.parallax.chat!',
      );
      final links = tokens
          .where((t) => t.kind == TextTokenKind.link)
          .map((t) => t.href.toString())
          .toList();
      expect(links, [
        'https://example.org/a_(b)',
        'mailto:me@example.org',
        'https://www.parallax.chat',
      ]);
      expect(
        tokens
            .singleWhere((t) => t.kind == TextTokenKind.permalink)
            .permalink!
            .identifier,
        '@alice:example.org',
      );
      expect(
        tokens.where((t) => t.kind == TextTokenKind.roomMention),
        hasLength(1),
      );
      expect(tokens.map((t) => t.text).join(), contains('javascript:alert(1)'));
    });

    test('parses matrix.to and matrix: permalinks', () {
      final user = MatrixPermalink.parse(
        'https://matrix.to/#/%40alice%3Aexample.org',
      )!;
      expect(user.kind, PermalinkKind.user);
      expect(user.identifier, '@alice:example.org');
      final event = MatrixPermalink.parse(
        r'https://matrix.to/#/!room:example.org/$event?via=example.org&via=b.org',
      )!;
      expect(event.kind, PermalinkKind.event);
      expect(event.eventId, r'$event');
      expect(event.via, ['example.org', 'b.org']);
      final alias = MatrixPermalink.parse('matrix:r/parallax:example.org')!;
      expect(alias.kind, PermalinkKind.room);
      expect(alias.identifier, '#parallax:example.org');
      final viaUri = MatrixPermalink.parse(
        'matrix:roomid/abc:example.org/e/ev',
      )!;
      expect(viaUri.eventId, r'$ev');
      expect(MatrixPermalink.parse('https://matrix.to/#/notanid'), isNull);
      expect(MatrixPermalink.parse('https://example.org/#/@a:b.org'), isNull);
    });

    test('builds message links like Element X', () {
      expect(
        eventPermalink('!room:example.org', r'$ab/c+d', via: ['example.org']),
        r'https://matrix.to/#/!room:example.org/$ab%2Fc%2Bd?via=example.org',
      );
      expect(userPermalink('@a:b.org'), 'https://matrix.to/#/@a:b.org');
    });

    test('only safe schemes open', () {
      for (final unsafe in [
        'javascript:alert(1)',
        'data:text/html,hi',
        'file:///etc/passwd',
        'intent://x#Intent;end',
        'https://',
        'ftp://example.org',
      ]) {
        expect(safeLinkUri(unsafe), isNull, reason: unsafe);
      }
      for (final safe in [
        'https://example.org',
        'http://example.org/x',
        'mailto:a@b.org',
        'geo:1,2',
        'matrix:u/a:b.org',
      ]) {
        expect(safeLinkUri(safe), isNotNull, reason: safe);
      }
    });

    test('flags link text that names another site', () {
      final target = Uri.parse('https://evil.example/login');
      expect(linkTextMisleads('https://bank.example', target), isTrue);
      expect(linkTextMisleads('www.evil.example/login', target), isFalse);
      expect(linkTextMisleads('click here', target), isFalse);
    });
  });

  group('state events', () {
    String? describe(
      ChatEntry e, {
      Map<String, Object?>? prev,
      bool known = true,
    }) => describeStateEvent(
      e,
      ownUserId: me,
      previous: known ? PreviousState(prev) : null,
      nameOf: (id) => id == '@bob:example.org' ? 'Bob' : null,
    );

    test('membership changes use Element X wording', () {
      expect(
        describe(
          member(
            '1',
            sender: '@alice:example.org',
            target: '@alice:example.org',
            membership: 'join',
            senderName: 'Alice',
          ),
        ),
        'Alice joined the room',
      );
      expect(
        describe(member('2', sender: me, target: me, membership: 'join')),
        'You joined the room',
      );
      expect(
        describe(
          member(
            '3',
            sender: '@alice:example.org',
            target: '@alice:example.org',
            membership: 'leave',
            senderName: 'Alice',
          ),
          prev: {'membership': 'join'},
        ),
        'Alice left the room',
      );
      expect(
        describe(
          member(
            '4',
            sender: '@alice:example.org',
            target: '@bob:example.org',
            membership: 'leave',
            senderName: 'Alice',
            reason: 'spam',
          ),
          prev: {'membership': 'join'},
        ),
        'Alice removed Bob: spam',
      );
      expect(
        describe(
          member(
            '5',
            sender: me,
            target: '@bob:example.org',
            membership: 'ban',
          ),
          known: false,
        ),
        'You banned Bob',
      );
      expect(
        describe(
          member(
            '6',
            sender: '@alice:example.org',
            target: me,
            membership: 'invite',
            senderName: 'Alice',
          ),
          known: false,
        ),
        'Alice invited you',
      );
      expect(
        describe(
          member(
            '7',
            sender: '@bob:example.org',
            target: '@bob:example.org',
            membership: 'join',
            senderName: 'Bob',
          ),
          prev: {'membership': 'invite'},
        ),
        'Bob accepted the invite',
      );
      expect(
        describe(
          member(
            '8',
            sender: '@bob:example.org',
            target: '@bob:example.org',
            membership: 'leave',
            senderName: 'Bob',
          ),
          prev: {'membership': 'invite'},
        ),
        'Bob rejected the invitation',
      );
      expect(
        describe(
          member(
            '9',
            sender: me,
            target: '@bob:example.org',
            membership: 'leave',
          ),
          prev: {'membership': 'ban'},
        ),
        'You unbanned Bob',
      );
      expect(
        describe(
          member(
            '10',
            sender: '@bob:example.org',
            target: '@bob:example.org',
            membership: 'join',
            displayName: 'Robert',
            senderName: 'Robert',
          ),
          prev: {'membership': 'join', 'displayname': 'Bob'},
        ),
        'Bob changed their display name from Bob to Robert',
      );
    });

    test('ambiguous membership waits for previous state', () {
      expect(
        describe(
          member(
            '1',
            sender: '@a:example.org',
            target: '@a:example.org',
            membership: 'join',
          ),
          known: false,
        ),
        isNull,
      );
      expect(
        stateEventNeedsPrevious(
          member(
            '1',
            sender: '@a:example.org',
            target: '@a:example.org',
            membership: 'leave',
          ),
        ),
        isTrue,
      );
      expect(
        stateEventNeedsPrevious(
          member(
            '1',
            sender: '@a:example.org',
            target: '@b:example.org',
            membership: 'invite',
          ),
        ),
        isFalse,
      );
    });

    ChatEntry state(
      String type,
      Map<String, Object?> content, {
      String sender = '@alice:example.org',
    }) => entry(
      type,
      sender: sender,
      kind: EntryKind.state,
      eventType: type,
      content: content,
      stateKey: '',
      senderName: 'Alice',
    );

    test('room details and settings', () {
      expect(
        describe(state('m.room.name', {'name': 'Ops'})),
        'Alice changed the room name to: Ops',
      );
      expect(
        describe(state('m.room.name', {}, sender: me)),
        'You removed the room name',
      );
      expect(
        describe(state('m.room.topic', {'topic': 'Hi'})),
        'Alice changed the topic to: Hi',
      );
      expect(
        describe(state('m.room.avatar', {'url': 'mxc://a/b'})),
        'Alice changed the room avatar',
      );
      expect(describe(state('m.room.create', {})), 'Alice created the room');
      expect(
        describe(
          state('m.room.encryption', {'algorithm': 'm.megolm.v1.aes-sha2'}),
        ),
        'Encryption enabled',
      );
      expect(
        describe(
          state('m.room.pinned_events', {
            'pinned': [r'$a', r'$b'],
          }),
          prev: {
            'pinned': [r'$a'],
          },
        ),
        'Alice pinned a message',
      );
      expect(
        describe(
          state('m.room.pinned_events', {'pinned': <String>[]}),
          prev: {
            'pinned': [r'$a'],
          },
        ),
        'Alice unpinned a message',
      );
      expect(
        describe(
          state('m.room.power_levels', {
            'users': {'@bob:example.org': 50},
          }),
          prev: {'users': <String, Object?>{}},
        ),
        'Bob was promoted to moderator',
      );
      expect(
        describe(state('m.room.power_levels', {'ban': 100}), prev: {'ban': 50}),
        'Alice changed the room permissions',
      );
      expect(
        describe(state('m.room.join_rules', {'join_rule': 'invite'})),
        'Alice made the room invite only',
      );
    });
  });

  group('timeline rows', () {
    test('adds day separators and groups senders within five minutes', () {
      final day1 = DateTime(2026, 11, 10, 9);
      final rows = buildTimelineRows([
        entry('a', time: day1),
        entry('b', time: day1.add(const Duration(minutes: 2))),
        entry('c', time: day1.add(const Duration(minutes: 9))),
        entry('d', sender: me, time: day1.add(const Duration(minutes: 10))),
        entry('e', time: DateTime(2026, 11, 11, 8)),
      ]);
      expect(rows.whereType<DaySeparatorRow>().map((r) => r.day.day), [10, 11]);
      final messages = rows.whereType<EntryRow>().toList();
      expect(messages.map((r) => r.showSender), [
        true,
        false,
        true,
        false,
        true,
      ]);
      expect(messages.map((r) => r.continuesGroup), [
        false,
        true,
        false,
        false,
        false,
      ]);
    });

    test('direct chats hide sender details', () {
      final rows = buildTimelineRows([entry('a')], isDirect: true);
      expect(rows.whereType<EntryRow>().single.showSender, isFalse);
    });

    test('collapses room changes and long runs of removed messages', () {
      final registry = <String, String>{};
      ChatEntry change(String id) => member(
        id,
        sender: '@a:example.org',
        target: '@a:example.org',
        membership: 'join',
      );
      ChatEntry removed(String id) =>
          entry(id, redacted: true, kind: EntryKind.redacted);
      var rows = buildTimelineRows([
        change('s1'),
        change('s2'),
        entry('m'),
        removed('r1'),
        removed('r2'),
        entry('n'),
        removed('x1'),
        removed('x2'),
        removed('x3'),
      ], groupIds: registry);
      final collapsed = rows.whereType<CollapsedRow>().toList();
      expect(collapsed.map((r) => r.label), [
        '2 room changes',
        '3 removed messages',
      ]);
      expect(
        rows.whereType<EntryRow>().where((r) => r.entry.redacted),
        hasLength(2),
      );
      final firstId = collapsed.first.groupId;
      // Older history joining the group keeps its identity.
      rows = buildTimelineRows([
        change('s0'),
        change('s1'),
        change('s2'),
      ], groupIds: registry);
      expect(rows.whereType<CollapsedRow>().single.groupId, firstId);
    });

    test('day labels', () {
      final now = DateTime(2026, 11, 12, 15);
      expect(dayLabel(DateTime(2026, 11, 12), now: now), 'Today');
      expect(dayLabel(DateTime(2026, 11, 11), now: now), 'Yesterday');
      expect(dayLabel(DateTime(2026, 11, 9), now: now), 'Monday 9 November');
      expect(dayLabel(DateTime(2026, 3, 2), now: now), '2 March');
      expect(dayLabel(DateTime(2025, 12, 25), now: now), '25 December 2025');
    });
  });

  group('mentions in the composer', () {
    test('finds the @query at the caret and replaces it', () {
      const value = TextEditingValue(
        text: 'hi @al',
        selection: TextSelection.collapsed(offset: 6),
      );
      final query = mentionQueryAt(value)!;
      expect(query.query, 'al');
      final next = applyMention(
        value,
        query,
        const MentionSuggestion(
          id: '@alice:example.org',
          label: 'Alice',
          insertText: '@alice:example.org ',
        ),
      );
      expect(next.text, 'hi @alice:example.org ');
      expect(next.selection.baseOffset, next.text.length);
      expect(
        mentionQueryAt(
          const TextEditingValue(
            text: 'mail a@b',
            selection: TextSelection.collapsed(offset: 8),
          ),
        ),
        isNull,
      );
    });

    test('ranks display-name prefixes first', () {
      const members = [
        MemberProfile(userId: '@zed:example.org', displayName: 'Alfred Zed'),
        MemberProfile(userId: '@al:example.org', displayName: 'Bob'),
        MemberProfile(userId: '@x:example.org', displayName: 'Alice'),
        MemberProfile(userId: '@y:example.org', displayName: 'Carol'),
      ];
      expect(rankMembers(members, 'al').map((m) => m.userId), [
        '@zed:example.org',
        '@x:example.org',
        '@al:example.org',
      ]);
    });
  });

  group('message actions', () {
    test('copy text and view source content', () {
      final emote = entry(
        '\$e',
        kind: EntryKind.emote,
        body: 'waves',
        senderName: 'Alice',
      );
      expect(canCopyText(emote), isTrue);
      expect(copyableText(emote), '* Alice waves');
      expect(canCopyText(entry('\$i', kind: EntryKind.image)), isFalse);
      expect(hasServerEventId(entry('txn1')), isFalse);
      final source = viewSourceJson(
        entry('\$e', content: {'body': 'hi'}),
        '!room:example.org',
      );
      expect(source['room_id'], '!room:example.org');
      expect(source['content'], {'body': 'hi'});
      expect(source.containsKey('state_key'), isFalse);
    });
  });
}

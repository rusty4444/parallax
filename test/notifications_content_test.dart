import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/notifications/notification_content.dart';
import 'package:parallax/features/notifications/notification_media.dart';

NotificationEventText? describe(
  String type,
  Map<String, Object?> content, {
  String sender = 'Alice',
  String? stateKey,
  String? roomName = 'Book club',
  bool isDirect = false,
  bool redacted = false,
  DateTime? sentAt,
  DateTime? now,
}) => describeNotificationEvent(
  type: type,
  content: content,
  senderName: sender,
  stateKey: stateKey,
  myUserId: '@me:example.org',
  roomName: roomName,
  isDirect: isDirect,
  redacted: redacted,
  originServerTs: sentAt,
  now: now,
);

String? text(String type, Map<String, Object?> content) =>
    describe(type, content)?.text;

void main() {
  group('message text per event type', () {
    test('text, notice and emote', () {
      expect(
        text('m.room.message', {'msgtype': 'm.text', 'body': 'Hi!'}),
        'Hi!',
      );
      expect(
        text('m.room.message', {'msgtype': 'm.notice', 'body': 'Bot says'}),
        'Bot says',
      );
      expect(
        text('m.room.message', {'msgtype': 'm.emote', 'body': 'waves'}),
        '* Alice waves',
      );
    });

    test('reply fallback is stripped only for real replies', () {
      const body = '> <@bob:example.org> original\n> second\n\nMy answer';
      expect(
        text('m.room.message', {
          'msgtype': 'm.text',
          'body': body,
          'm.relates_to': {
            'm.in_reply_to': {'event_id': r'$x'},
          },
        }),
        'My answer',
      );
      expect(
        text('m.room.message', {'msgtype': 'm.text', 'body': body}),
        startsWith('> <@bob'),
      );
    });

    test('edits show the new content', () {
      expect(
        text('m.room.message', {
          'msgtype': 'm.text',
          'body': '* fixed',
          'm.new_content': {'msgtype': 'm.text', 'body': 'fixed'},
          'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$x'},
        }),
        'fixed',
      );
    });

    test('media, files, voice, location and stickers', () {
      expect(
        text('m.room.message', {'msgtype': 'm.image', 'body': 'cat.jpg'}),
        'Image',
      );
      expect(
        text('m.room.message', {
          'msgtype': 'm.image',
          'body': 'Look at this',
          'filename': 'cat.jpg',
        }),
        'Look at this',
      );
      expect(
        text('m.room.message', {'msgtype': 'm.video', 'body': 'v.mp4'}),
        'Video',
      );
      expect(
        text('m.room.message', {
          'msgtype': 'm.file',
          'body': 'report.pdf',
          'filename': 'report.pdf',
        }),
        '📎 report.pdf',
      );
      expect(
        text('m.room.message', {
          'msgtype': 'm.audio',
          'body': 'Voice message.ogg',
          'org.matrix.msc3245.voice': <String, Object?>{},
        }),
        'Voice message',
      );
      expect(
        text('m.room.message', {'msgtype': 'm.audio', 'body': 'song.mp3'}),
        'Audio',
      );
      expect(
        text('m.room.message', {
          'msgtype': 'm.location',
          'body': 'geo:1,2',
          'geo_uri': 'geo:1,2',
        }),
        '📍 Location',
      );
      expect(
        text('m.sticker', {'body': 'thumbs up', 'url': 'mxc://s/id'}),
        'Sticker',
      );
    });

    test('polls, reactions and live location', () {
      expect(
        text('org.matrix.msc3381.poll.start', {
          'org.matrix.msc3381.poll.start': {
            'question': {'org.matrix.msc1767.text': 'Lunch?'},
            'answers': <Object?>[],
          },
        }),
        'Poll: Lunch?',
      );
      expect(
        text('m.poll.start', {
          'm.poll.start': {
            'question': {
              'm.text': [
                {'body': 'Dinner?'},
              ],
            },
          },
        }),
        'Poll: Dinner?',
      );
      expect(
        text('m.reaction', {
          'm.relates_to': {
            'rel_type': 'm.annotation',
            'event_id': r'$x',
            'key': '👍',
          },
        }),
        'Reacted with 👍',
      );
      expect(
        text('org.matrix.msc3672.beacon_info', {'live': true}),
        'Started sharing their live location',
      );
    });

    test('redacted, encrypted and unknown events', () {
      expect(
        describe('m.room.message', const {}, redacted: true)?.text,
        'Message removed',
      );
      expect(text('m.room.encrypted', {'ciphertext': 'x'}), isNull);
      expect(text('com.example.custom', {'body': 'x'}), isNull);
      expect(
        text('m.room.message', {'msgtype': 'm.text', 'body': '  '}),
        isNull,
      );
    });

    test('text is sanitised and bounded', () {
      final long = 'a' * 2000;
      final result = text('m.room.message', {
        'msgtype': 'm.text',
        'body': long,
      });
      expect(result!.length, maxNotificationTextLength);
      expect(result.endsWith('…'), isTrue);
      expect(
        text('m.room.message', {
          'msgtype': 'm.text',
          'body': 'safe\u202Etxt.exe\u0000',
        }),
        'safetxt.exe',
      );
      expect(sanitiseNotificationName('  Ali\nce  '), 'Ali ce');
    });
  });

  group('invites and calls', () {
    test('invites name the inviter and room', () {
      final group = describe('m.room.member', {
        'membership': 'invite',
      }, stateKey: '@me:example.org');
      expect(group?.kind, NotifiableEventKind.invite);
      expect(group?.text, 'Alice invited you to Book club');
      expect(
        describe('m.room.member', {
          'membership': 'invite',
          'is_direct': true,
        }, stateKey: '@me:example.org')?.text,
        'Alice invited you to chat',
      );
      // Someone else's membership is not ours to notify about.
      expect(
        describe('m.room.member', {
          'membership': 'invite',
        }, stateKey: '@other:example.org'),
        isNull,
      );
    });

    test('ringing calls ring until their lifetime ends', () {
      final now = DateTime(2026, 11, 12, 12);
      final ring = describe('m.rtc.notification', {
        'notification_type': 'ring',
        'sender_ts': now
            .subtract(const Duration(seconds: 5))
            .millisecondsSinceEpoch,
        'lifetime': 30000,
      }, now: now);
      expect(ring?.kind, NotifiableEventKind.call);
      expect(ring?.ringing, isTrue);
      expect(ring?.text, 'Incoming call');
      final expired = describe('org.matrix.msc4075.rtc.notification', {
        'notification_type': 'ring',
        'sender_ts': now
            .subtract(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
        'lifetime': 30000,
      }, now: now);
      expect(expired?.ringing, isFalse);
      expect(expired?.text, 'Missed call');
      expect(
        describe('m.rtc.notification', {
          'notification_type': 'notification',
        })?.text,
        'Call started',
      );
      expect(
        describe(
          'm.call.invite',
          const {},
          sentAt: now.subtract(const Duration(seconds: 2)),
          now: now,
        )?.ringing,
        isTrue,
      );
    });
  });

  group('media decision', () {
    test('prefers the thumbnail and validates mxc URIs', () {
      final media = notificationMediaFor(
        type: 'm.room.message',
        content: {
          'msgtype': 'm.image',
          'url': 'mxc://example.org/original',
          'info': {
            'mimetype': 'image/png',
            'thumbnail_url': 'mxc://example.org/thumb',
            'thumbnail_info': {'mimetype': 'image/jpeg', 'size': 1000},
          },
        },
      );
      expect(media?.thumbnail, isTrue);
      expect(media?.source.toString(), 'mxc://example.org/thumb');
      expect(
        notificationMediaFor(
          type: 'm.room.message',
          content: {'msgtype': 'm.image', 'url': 'https://evil.example/x.png'},
        ),
        isNull,
      );
      expect(validMxc('mxc://server/../etc'), isNull);
      expect(validMxc('mxc://server/abc_DEF-1'), isNotNull);
    });

    test('encrypted originals are capped by declared size', () {
      Map<String, Object?> file(String id) => {
        'url': 'mxc://example.org/$id',
        'key': {'k': 'abc'},
        'iv': 'iv',
        'hashes': {'sha256': 'h'},
        'v': 'v2',
      };
      final small = notificationMediaFor(
        type: 'm.room.message',
        content: {
          'msgtype': 'm.image',
          'file': file('small'),
          'info': {'mimetype': 'image/jpeg', 'size': 200000},
        },
      );
      expect(small?.encrypted, isTrue);
      expect(small?.thumbnail, isFalse);
      expect(
        notificationMediaFor(
          type: 'm.room.message',
          content: {
            'msgtype': 'm.image',
            'file': file('huge'),
            'info': {'mimetype': 'image/jpeg', 'size': 50 * 1024 * 1024},
          },
        ),
        isNull,
      );
    });

    test(
      'videos preview the bounded clip with thumbnail fallback; other types never',
      () {
        final plainVideo = notificationMediaFor(
          type: 'm.room.message',
          content: {'msgtype': 'm.video', 'url': 'mxc://example.org/v'},
        );
        expect(plainVideo?.source.toString(), 'mxc://example.org/v');
        expect(plainVideo?.isVideo, isTrue);
        expect(plainVideo?.mayAnimate, isTrue);
        expect(plainVideo?.thumbnail, isFalse);
        expect(plainVideo?.fallback, isNull);

        final withThumb = notificationMediaFor(
          type: 'm.room.message',
          content: {
            'msgtype': 'm.video',
            'url': 'mxc://example.org/v',
            'info': {
              'mimetype': 'video/mp4',
              'size': 4 * 1024 * 1024,
              'thumbnail_url': 'mxc://example.org/vt',
              'thumbnail_info': {'mimetype': 'image/jpeg', 'size': 12000},
            },
          },
        );
        expect(withThumb?.source.toString(), 'mxc://example.org/v');
        expect(withThumb?.isVideo, isTrue);
        expect(withThumb?.fallback?.source.toString(), 'mxc://example.org/vt');
        expect(withThumb?.fallback?.thumbnail, isTrue);

        // Oversized videos skip the clip download and fall back to the thumbnail.
        final oversizedVideo = notificationMediaFor(
          type: 'm.room.message',
          content: {
            'msgtype': 'm.video',
            'url': 'mxc://example.org/huge-v',
            'info': {
              'mimetype': 'video/mp4',
              'size': maxNotificationVideoBytes + 1,
              'thumbnail_url': 'mxc://example.org/vt',
            },
          },
        );
        expect(oversizedVideo?.source.toString(), 'mxc://example.org/vt');
        expect(oversizedVideo?.thumbnail, isTrue);
        expect(oversizedVideo?.isVideo, isFalse);

        expect(
          notificationMediaFor(
            type: 'm.room.message',
            content: {'msgtype': 'm.file', 'url': 'mxc://example.org/f'},
          ),
          isNull,
        );
        expect(
          notificationMediaFor(
            type: 'm.room.message',
            content: {
              'msgtype': 'm.image',
              'url': 'mxc://example.org/svg',
              'info': {'mimetype': 'image/svg+xml'},
            },
          ),
          isNull,
        );
      },
    );

    test(
      'animated GIF and WebP images and stickers keep animation with static fallback',
      () {
        final gif = notificationMediaFor(
          type: 'm.room.message',
          content: {
            'msgtype': 'm.image',
            'body': 'party.gif',
            'url': 'mxc://example.org/party',
            'info': {
              'mimetype': 'image/gif',
              'size': 2 * 1024 * 1024,
              'thumbnail_url': 'mxc://example.org/party-thumb',
              'thumbnail_info': {'mimetype': 'image/png'},
            },
          },
        );
        expect(gif?.source.toString(), 'mxc://example.org/party');
        expect(gif?.thumbnail, isFalse);
        expect(gif?.mayAnimate, isTrue);
        expect(
          gif?.fallback?.source.toString(),
          'mxc://example.org/party-thumb',
        );
        expect(gif?.fallback?.thumbnail, isTrue);

        // Stickers and filename-inferred GIFs without explicit mimetype animate too.
        final sticker = notificationMediaFor(
          type: 'm.sticker',
          content: {'body': 'wave.webp', 'url': 'mxc://example.org/wave'},
        );
        expect(sticker?.source.toString(), 'mxc://example.org/wave');
        expect(sticker?.thumbnail, isFalse);
        expect(sticker?.mayAnimate, isTrue);

        // Explicitly non-animated WebP photos (MSC4230) keep the fast thumbnail.
        final staticWebp = notificationMediaFor(
          type: 'm.room.message',
          content: {
            'msgtype': 'm.image',
            'url': 'mxc://example.org/photo-webp',
            'info': {
              'mimetype': 'image/webp',
              'org.matrix.msc4230.is_animated': false,
              'thumbnail_url': 'mxc://example.org/photo-thumb',
            },
          },
        );
        expect(staticWebp?.source.toString(), 'mxc://example.org/photo-thumb');
        expect(staticWebp?.thumbnail, isTrue);

        // Plaintext GIF above the animated download cap still gets a server thumbnail.
        final hugePlainGif = notificationMediaFor(
          type: 'm.room.message',
          content: {
            'msgtype': 'm.image',
            'url': 'mxc://example.org/huge-gif',
            'info': {
              'mimetype': 'image/gif',
              'size': maxNotificationAnimatedMediaBytes + 1,
            },
          },
        );
        expect(hugePlainGif?.source.toString(), 'mxc://example.org/huge-gif');
        expect(hugePlainGif?.thumbnail, isTrue);
        expect(hugePlainGif?.mayAnimate, isFalse);
      },
    );

    test('content URIs only cover the notification media directory', () {
      const cache = '/data/user/0/net.samrussell.parallax/cache';
      expect(
        notificationContentUri('$cache/notification_media/m_abc.jpg', cache),
        'content://$notificationFileProviderAuthority/notification_media/m_abc.jpg',
      );
      expect(notificationContentUri('$cache/other/x.jpg', cache), isNull);
      expect(
        notificationContentUri('$cache/notification_media/../x.jpg', cache),
        isNull,
      );
    });
  });
}

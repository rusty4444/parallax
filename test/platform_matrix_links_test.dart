import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/platform/matrix_links.dart';

void main() {
  group('parseMatrixLinkString', () {
    final cases = <(String, MatrixLink?)>[
      // matrix.to users
      (
        'https://matrix.to/#/@alice:example.org',
        const MatrixUserLink('@alice:example.org'),
      ),
      (
        'https://matrix.to/#/%40alice%3Aexample.org',
        const MatrixUserLink('@alice:example.org'),
      ),
      (
        'https://matrix.to/#/@alice:example.org:8448',
        const MatrixUserLink('@alice:example.org:8448'),
      ),
      (
        'https://matrix.to/#/@bob:[2001:db8::1]:8448',
        const MatrixUserLink('@bob:[2001:db8::1]:8448'),
      ),
      // matrix.to rooms and aliases
      (
        'https://matrix.to/#/#room:example.org',
        const MatrixRoomLink('#room:example.org'),
      ),
      (
        'https://matrix.to/#/%23room%3Aexample.org?via=a.org&via=b.org',
        const MatrixRoomLink('#room:example.org', via: ['a.org', 'b.org']),
      ),
      (
        'https://matrix.to/#/!abc123:example.org?via=example.org',
        const MatrixRoomLink('!abc123:example.org', via: ['example.org']),
      ),
      (
        'https://matrix.to/#/!opaqueRoomV12',
        const MatrixRoomLink('!opaqueRoomV12'),
      ),
      // matrix.to event permalinks
      (
        'https://matrix.to/#/!abc:example.org/\$event123?via=x.org&via=x.org',
        const MatrixRoomLink(
          '!abc:example.org',
          eventId: '\$event123',
          via: ['x.org'],
        ),
      ),
      (
        'https://matrix.to/#/%23room%3Aexample.org/%24ev%2Fslash',
        const MatrixRoomLink('#room:example.org', eventId: '\$ev/slash'),
      ),
      // Element web style permalinks
      (
        'https://app.element.io/#/room/#room:example.org',
        const MatrixRoomLink('#room:example.org'),
      ),
      (
        'https://chat.example.org/#/user/@carol:example.org',
        const MatrixUserLink('@carol:example.org'),
      ),
      // matrix: URIs (MSC2312)
      (
        'matrix:u/alice:example.org?action=chat',
        const MatrixUserLink('@alice:example.org', action: 'chat'),
      ),
      (
        'MATRIX:u/alice:example.org',
        const MatrixUserLink('@alice:example.org'),
      ),
      ('matrix:r/room:example.org', const MatrixRoomLink('#room:example.org')),
      (
        'matrix:roomid/abc:example.org?via=x.org&action=join',
        const MatrixRoomLink(
          '!abc:example.org',
          via: ['x.org'],
          action: 'join',
        ),
      ),
      (
        'matrix:roomid/abc:example.org/e/ev%2Fx?via=x.org&via=y.org',
        const MatrixRoomLink(
          '!abc:example.org',
          eventId: '\$ev/x',
          via: ['x.org', 'y.org'],
        ),
      ),
      (
        'matrix:r/room:example.org/e/event',
        const MatrixRoomLink('#room:example.org', eventId: '\$event'),
      ),
      // Unknown action is dropped, not fatal.
      (
        'matrix:r/room:example.org?action=delete',
        const MatrixRoomLink('#room:example.org'),
      ),
      // Invalid via entries are ignored.
      (
        'https://matrix.to/#/!abc:example.org?via=bad%20host&via=ok.org',
        const MatrixRoomLink('!abc:example.org', via: ['ok.org']),
      ),
      // Rejected
      ('https://matrix.to/#/', null),
      ('https://matrix.to/', null),
      ('https://matrix.to/#/alice:example.org', null),
      ('https://matrix.to/#/@alice', null),
      ('https://matrix.to/#/#room', null),
      ('https://matrix.to/#/@alice:exa mple.org', null),
      ('https://matrix.to/#/!a:example.org/notAnEvent', null),
      ('https://matrix.to/#/!a:example.org/\$e/extra', null),
      ('https://user:pass@matrix.to/#/@alice:example.org', null),
      ('https://example.org/#/@alice:example.org', null),
      ('https://example.org/room/#room:example.org', null),
      ('ftp://matrix.to/#/@alice:example.org', null),
      ('javascript:alert(1)', null),
      ('matrix:u/alice:example.org/e/event', null),
      ('matrix:x/alice:example.org', null),
      ('matrix:u/', null),
      ('matrix://u/alice:example.org', null),
      ('matrix:roomid/abc:example.org/e/', null),
      ('matrix:roomid/abc:example.org/x/ev', null),
      ('', null),
      ('not a link', null),
    ];
    for (final (input, expected) in cases) {
      test(input.isEmpty ? '(empty)' : input, () {
        expect(parseMatrixLinkString(input), expected);
      });
    }

    test('caps via servers and link length', () {
      final via = List.generate(20, (i) => 'via=s$i.org').join('&');
      final link =
          parseMatrixLinkString('https://matrix.to/#/!abc:example.org?$via')
              as MatrixRoomLink;
      expect(link.via, hasLength(maxLinkViaServers));
      final long = 'https://matrix.to/#/@a:${'x' * maxMatrixLinkLength}.org';
      expect(parseMatrixLinkString(long), isNull);
    });
  });

  test('isMatrixLinkCandidate only claims Matrix link shapes', () {
    expect(isMatrixLinkCandidate(Uri.parse('https://matrix.to/#/x')), isTrue);
    expect(isMatrixLinkCandidate(Uri.parse('matrix:u/a:b.c')), isTrue);
    expect(
      isMatrixLinkCandidate(Uri.parse('https://app.element.io/#/room/#a:b')),
      isTrue,
    );
    expect(isMatrixLinkCandidate(Uri.parse('https://example.org/')), isFalse);
    expect(isMatrixLinkCandidate(Uri.parse('mailto:a@b.c')), isFalse);
  });

  test('matrixToLink round-trips through the parser', () {
    final uri = matrixToLink(
      '#room:example.org',
      eventId: '\$ev/1',
      via: ['a.org'],
    );
    expect(
      parseMatrixLink(uri),
      const MatrixRoomLink(
        '#room:example.org',
        eventId: '\$ev/1',
        via: ['a.org'],
      ),
    );
  });
}

// ECIES interoperability with vodozemac 0.11.2 (the version matrix-rust-sdk
// uses in Element X 26.11). The vectors below were produced by a scratch
// harness running the real vodozemac `ecies` module against this Dart port,
// in both roles; vodozemac decrypted every Dart-produced message recorded
// here and the check codes matched on both sides.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/qr_login/ecies.dart';
import 'package:parallax/features/qr_login/qr_code_data.dart';

Uint8List _b64(String value) => decodeUnpaddedBase64(value);

void main() {
  group('vodozemac interop', () {
    test('vodozemac as the scanning device, Dart as the QR device', () async {
      // vodozemac S established towards Dart G's public key and sent these.
      final g = await Ecies.create(
        seed: _b64('sm+LlRTWMb1anJ4E3Y7vt90PejepGNMlcbfVlvc7NRM'),
      );
      expect(
        encodeUnpaddedBase64(g.publicKey),
        'Am4fxrSv7Uewa/ec1C6umzMtcJS9jZ9uwINLI6AdwDQ',
      );
      final (channel, plaintext) = await g.establishInbound(
        EciesInitialMessage.decode(
          'TNd6c+uH8W1o6IoAJQSvFBqkkQdmbIA8Rb2vNRshqa6CrrjdmkztKtKijN+Q|'
          '3vDeU+9cwh+NiWSBqU1qSh1xloYAwYFY4dAlCQ6n3wg',
        ),
      );
      expect(utf8.decode(plaintext), 'MATRIX_QR_CODE_LOGIN_INITIATE');
      // vodozemac: check_code=22, bytes [252, 252].
      expect(channel.checkCode.bytes, [252, 252]);
      expect(channel.checkCode.digits, 22);
      expect(
        utf8.decode(
          await channel.decrypt(
            EciesMessage.decode(
              'n0Cc6zzzwLOBih7tfdA5FWGJqitRauuofmG5XhKUie+WybMOZ9JmvULlHiO0bx'
              'Q6FqoKUSuf23FQ9ZDyWKpEc1Te+Ijev+3YZwE8QwRyga2tm/I',
            ),
          ),
        ),
        '{"type":"m.login.protocol","protocol":"device_authorization_grant"}',
      );
      expect(
        utf8.decode(
          await channel.decrypt(
            EciesMessage.decode(
              '96W6Bkgit07FFL1lZ50NVPjxmoC6/qiZpikoha88G/0dIBSanw',
            ),
          ),
        ),
        'second message from S',
      );
      // vodozemac decrypted exactly this reply as MATRIX_QR_CODE_LOGIN_OK.
      final reply = await channel.encrypt(
        utf8.encode('MATRIX_QR_CODE_LOGIN_OK'),
      );
      expect(
        reply.encode(),
        'o92DOl7nnulAikGOp4lCwYGeO2FuMav4QaW+JF99Mov35GdgJk9m',
      );
    });

    test('Dart as the scanning device, vodozemac as the QR device', () async {
      final s = await Ecies.create(
        seed: _b64('RjCECIzaTueNedqKgb4xqrhSjLgHQn4gKBTXVyR5aK8'),
      );
      final (channel, initial) = await s.establishOutbound(
        _b64('KqsclqKdyp8/eEmvQ6iHGznd6fph9GqiTFOGxeYKYQs'),
        utf8.encode('MATRIX_QR_CODE_LOGIN_INITIATE'),
      );
      // vodozemac G decrypted this initial message.
      expect(
        initial.encode(),
        'ABImWdWyUcm8eAKKjfAvH/8X1DeVNJpmTxaWumcbX+uqF5fwQ7J2eaQhlisi|'
        'K/Dpj4NpHQAQmJaWiQfZ7pxhEPl6o+CVKkiBn2sJ7jU',
      );
      // vodozemac: check_code=64, bytes [166, 174].
      expect(channel.checkCode.bytes, [166, 174]);
      expect(channel.checkCode.display, '64');
      expect(
        utf8.decode(
          await channel.decrypt(
            EciesMessage.decode(
              'nS4gvk5x0XlfB5MHY5CYH+TQ1Q0h+0hssnO/O6EROPvf8vSU/OnB',
            ),
          ),
        ),
        'MATRIX_QR_CODE_LOGIN_OK',
      );
      expect(
        utf8.decode(
          await channel.decrypt(
            EciesMessage.decode(
              'zEwcd3mheVHsWZDHPcRgQ7EJw3ZPJ52nYFw88Fh/YGlVHqTS0xr5NR0gC2Eao3'
              '25fPpbNg',
            ),
          ),
        ),
        '{"type":"m.login.protocol_accepted"}',
      );
      // vodozemac decrypted this second message from Dart S.
      final next = await channel.encrypt(
        utf8.encode('{"type":"m.login.success"}'),
      );
      expect(
        next.encode(),
        'lAtlAZnhco+oD9Mo5ynwKQvlA7eqrTKUDVQW+fBi90Iml2Epxvu8hLia',
      );
    });
  });

  group('vodozemac unit vectors', () {
    test('check code digits (AllowLeadingZero)', () {
      expect(CheckCode([0, 0]).digits, 0);
      expect(CheckCode([0, 0]).display, '00');
      expect(CheckCode([9, 9]).digits, 99);
      expect(CheckCode([0xff, 0xff]).digits, 55);
      for (var a = 0; a < 256; a += 17) {
        for (var b = 0; b < 256; b += 13) {
          expect(CheckCode([a, b]).digits, inInclusiveRange(0, 99));
        }
      }
    });

    test('nonce is the little-endian counter', () {
      expect(EstablishedEcies.nonceFor(BigInt.zero), List.filled(12, 0));
      expect(EstablishedEcies.nonceFor(BigInt.one), [1, ...List.filled(11, 0)]);
      expect(EstablishedEcies.nonceFor(BigInt.from(0x0201)), [
        1,
        2,
        ...List.filled(10, 0),
      ]);
    });

    test('info strings list the QR device key first', () {
      final ours = List.generate(32, (i) => i);
      final theirs = List.generate(32, (i) => 255 - i);
      final o = encodeUnpaddedBase64(ours), t = encodeUnpaddedBase64(theirs);
      expect(
        EstablishedEcies.infoString(
          'foobar_CHECKCODE',
          EciesRole.initiator,
          ours,
          theirs,
        ),
        'foobar_CHECKCODE|$t|$o',
      );
      expect(
        EstablishedEcies.infoString(
          'foobar_CHECKCODE',
          EciesRole.recipient,
          ours,
          theirs,
        ),
        'foobar_CHECKCODE|$o|$t',
      );
    });

    test('initial message encoding (vodozemac messages.rs vector)', () {
      const initial =
          '3On7QFJyLQMAErua9K/yIOcJALvuMYax1AW0iWgf64AwtSMZXwAA012Q|'
          '9yA/CX8pJKF02Prd75ZyBQHg3fGTVVGDNl86q1z17Us';
      final message = EciesInitialMessage.decode(initial);
      expect(
        encodeUnpaddedBase64(message.publicKey),
        '9yA/CX8pJKF02Prd75ZyBQHg3fGTVVGDNl86q1z17Us',
      );
      expect(message.encode(), initial);
      const plain = 'ZmtSLdzMcyjC5eV6L8xBI6amsq7gDNbCjz1W5OjX4Z8W';
      expect(EciesMessage.decode(plain).encode(), plain);
      expect(
        () => EciesInitialMessage.decode('no separator'),
        throwsA(isA<EciesException>()),
      );
      expect(
        () => EciesInitialMessage.decode('AAAA|AAAA'),
        throwsA(isA<EciesException>()),
      );
    });
  });

  group('channel behaviour', () {
    test('random channels agree and talk both ways', () async {
      final g = await Ecies.create();
      final s = await Ecies.create();
      final (sChannel, initial) = await s.establishOutbound(
        g.publicKey,
        utf8.encode("It's a secret to everybody"),
      );
      final (gChannel, plaintext) = await g.establishInbound(initial);
      expect(utf8.decode(plaintext), "It's a secret to everybody");
      expect(sChannel.checkCode, gChannel.checkCode);
      final reply = await gChannel.encrypt(utf8.encode('Another plaintext'));
      expect(utf8.decode(await sChannel.decrypt(reply)), 'Another plaintext');
    });

    test('a substituted public key fails decryption (MITM)', () async {
      final g = await Ecies.create();
      final s = await Ecies.create();
      final mallory = await Ecies.create();
      final (_, initial) = await s.establishOutbound(g.publicKey, [1, 2, 3]);
      final tampered = EciesInitialMessage(
        publicKey: mallory.publicKey,
        ciphertext: initial.ciphertext,
      );
      expect(
        () => g.establishInbound(tampered),
        throwsA(isA<EciesException>()),
      );
    });

    test('replayed or reordered messages are rejected', () async {
      final g = await Ecies.create();
      final s = await Ecies.create();
      final (sChannel, initial) = await s.establishOutbound(g.publicKey, [0]);
      final (gChannel, _) = await g.establishInbound(initial);
      final first = await sChannel.encrypt(utf8.encode('one'));
      final second = await sChannel.encrypt(utf8.encode('two'));
      expect(() => gChannel.decrypt(second), throwsA(isA<EciesException>()));
      // The counter moved on, so even the first message no longer opens.
      expect(() => gChannel.decrypt(first), throwsA(isA<EciesException>()));
    });

    test('a low-order public key is refused', () async {
      final s = await Ecies.create();
      expect(
        () => s.establishOutbound(Uint8List(32), [0]),
        throwsA(isA<EciesException>()),
      );
    });
  });
}

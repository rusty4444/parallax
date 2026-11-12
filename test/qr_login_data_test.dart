// QR code payload vectors copied from matrix-rust-sdk
// (crates/matrix-sdk-crypto/src/types/qr_login/{msc_4108,msc_4388}.rs at the
// revision used by Element X 26.11, sdk-android 26.11.05).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/qr_login/qr_code_data.dart';

const _msc4108Login = <int>[
  0x4D, 0x41, 0x54, 0x52, 0x49, 0x58, 0x02, 0x03, 0xd8, 0x86, 0x68, 0x6a, //
  0xb2, 0x19, 0x7b, 0x78, 0x0e, 0x30, 0x0a, 0x9d, 0x4a, 0x21, 0x47, 0x48,
  0x07, 0x00, 0xd7, 0x92, 0x9f, 0x39, 0xab, 0x31, 0xb9, 0xe5, 0x14, 0x37,
  0x02, 0x48, 0xed, 0x6b, 0x00, 0x47, 0x68, 0x74, 0x74, 0x70, 0x73, 0x3a,
  0x2f, 0x2f, 0x72, 0x65, 0x6e, 0x64, 0x65, 0x7a, 0x76, 0x6f, 0x75, 0x73,
  0x2e, 0x6c, 0x61, 0x62, 0x2e, 0x65, 0x6c, 0x65, 0x6d, 0x65, 0x6e, 0x74,
  0x2e, 0x64, 0x65, 0x76, 0x2f, 0x65, 0x38, 0x64, 0x61, 0x36, 0x33, 0x35,
  0x35, 0x2d, 0x35, 0x35, 0x30, 0x62, 0x2d, 0x34, 0x61, 0x33, 0x32, 0x2d,
  0x61, 0x31, 0x39, 0x33, 0x2d, 0x31, 0x36, 0x31, 0x39, 0x64, 0x39, 0x38,
  0x33, 0x30, 0x36, 0x36, 0x38,
];

final _msc4108Reciprocate = <int>[
  ..._msc4108Login.sublist(0, 7),
  0x04,
  ..._msc4108Login.sublist(8),
  0x00, 0x0A, 0x6d, 0x61, 0x74, 0x72, 0x69, 0x78, 0x2e, 0x6f, 0x72, 0x67, //
];

const _msc4108Base64 =
    'TUFUUklYAgS0yzZ1QVpQ1jlnoxWX3d5jrWRFfELxjS2gN7pz9y+3PABaaHR0'
    'cHM6Ly9zeW5hcHNlLW9pZGMubGFiLmVsZW1lbnQuZGV2L19zeW5hcHNlL2Ns'
    'aWVudC9yZW5kZXp2b3VzLzAxSFg5SzAwUTFINktQRDQ3RUc0RzFUM1hHACVo'
    'dHRwczovL3N5bmFwc2Utb2lkYy5sYWIuZWxlbWVudC5kZXYv';

const _msc4388Reciprocate = <int>[
  0x49, 0x4F, 0x5F, 0x45, 0x4C, 0x45, 0x4D, 0x45, 0x4E, 0x54, 0x5F, 0x4D, //
  0x53, 0x43, 0x34, 0x33, 0x38, 0x38, 0x03, 0x01, 0xd8, 0x86, 0x68, 0x6a,
  0xb2, 0x19, 0x7b, 0x78, 0x0e, 0x30, 0x0a, 0x9d, 0x4a, 0x21, 0x47, 0x48,
  0x07, 0x00, 0xd7, 0x92, 0x9f, 0x39, 0xab, 0x31, 0xb9, 0xe5, 0x14, 0x37,
  0x02, 0x48, 0xed, 0x6b, 0x24, 0x65, 0x38, 0x64, 0x61, 0x36, 0x33, 0x35,
  0x35, 0x2D, 0x35, 0x35, 0x30, 0x62, 0x2D, 0x34, 0x61, 0x33, 0x32, 0x2D,
  0x61, 0x31, 0x39, 0x33, 0x2D, 0x31, 0x36, 0x31, 0x39, 0x64, 0x39, 0x38,
  0x33, 0x30, 0x36, 0x36, 0x38, 0x20, 0x68, 0x74, 0x74, 0x70, 0x73, 0x3A,
  0x2F, 0x2F, 0x6D, 0x61, 0x74, 0x72, 0x69, 0x78, 0x2D, 0x63, 0x6C, 0x69,
  0x65, 0x6E, 0x74, 0x2E, 0x6D, 0x61, 0x74, 0x72, 0x69, 0x78, 0x2E, 0x6F,
  0x72, 0x67,
];

const _msc4388Base64 =
    'SU9fRUxFTUVOVF9NU0M0Mzg4AwG0yzZ1QVpQ1jlnoxWX3d5jrWRFfELxjS2gN'
    '7pz9y+3PBowMUhYOUswMFExSDZLUEQ0N0VHNEcxVDNYRyRodHRwczovL3N5bm'
    'Fwc2Utb2lkYy5sYWIuZWxlbWVudC5kZXY';

const _key = '2IZoarIZe3gOMAqdSiFHSAcA15KfOasxueUUNwJI7Ws';

void main() {
  group('MSC4108 QR data (Rust vectors)', () {
    test('parses the login vector', () {
      final data = QrCodeData.decode(_msc4108Login);
      expect(data.format, QrCodeFormat.msc4108);
      expect(data.intent, QrCodeIntent.login);
      expect(encodeUnpaddedBase64(data.publicKey), _key);
      expect(
        data.rendezvousUrl,
        'https://rendezvous.lab.element.dev/e8da6355-550b-4a32-a193-1619d9830668',
      );
      expect(data.serverName, isNull);
    });

    test('parses the reciprocate vector with a server name', () {
      final data = QrCodeData.decode(_msc4108Reciprocate);
      expect(data.intent, QrCodeIntent.reciprocate);
      expect(encodeUnpaddedBase64(data.publicKey), _key);
      expect(data.serverName, 'matrix.org');
    });

    test('parses the base64 vector with a homeserver URL', () {
      final data = QrCodeData.decodeBase64(_msc4108Base64);
      expect(data.intent, QrCodeIntent.reciprocate);
      expect(
        encodeUnpaddedBase64(data.publicKey),
        'tMs2dUFaUNY5Z6MVl93eY61kRXxC8Y0toDe6c/cvtzw',
      );
      expect(
        data.rendezvousUrl,
        'https://synapse-oidc.lab.element.dev/_synapse/client/rendezvous/'
        '01HX9K00Q1H6KPD47EG4G1T3XG',
      );
      expect(data.serverName, 'https://synapse-oidc.lab.element.dev/');
    });

    test('round-trips byte-exactly', () {
      expect(QrCodeData.decode(_msc4108Login).encode(), _msc4108Login);
      expect(
        QrCodeData.decode(_msc4108Reciprocate).encode(),
        _msc4108Reciprocate,
      );
      expect(
        QrCodeData.decodeBase64(_msc4108Base64).encodeBase64(),
        _msc4108Base64,
      );
    });

    test('encodes freshly built codes', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final built = QrCodeData.msc4108(
        publicKey: key,
        rendezvousUrl: 'https://hs.example/rz/abc',
        serverName: 'https://hs.example/',
      );
      final parsed = QrCodeData.decode(built.encode());
      expect(parsed.intent, QrCodeIntent.reciprocate);
      expect(parsed.publicKey, key);
      expect(parsed.rendezvousUrl, 'https://hs.example/rz/abc');
      expect(parsed.serverName, 'https://hs.example/');
    });
  });

  group('MSC4388 QR data (Rust vectors)', () {
    test('parses login and reciprocate vectors', () {
      final reciprocate = QrCodeData.decode(_msc4388Reciprocate);
      expect(reciprocate.format, QrCodeFormat.msc4388);
      expect(reciprocate.intent, QrCodeIntent.reciprocate);
      expect(encodeUnpaddedBase64(reciprocate.publicKey), _key);
      expect(reciprocate.rendezvousId, 'e8da6355-550b-4a32-a193-1619d9830668');
      expect(reciprocate.baseUrl, 'https://matrix-client.matrix.org');

      final login = QrCodeData.decode([
        ..._msc4388Reciprocate.sublist(0, 19),
        0x00,
        ..._msc4388Reciprocate.sublist(20),
      ]);
      expect(login.intent, QrCodeIntent.login);
    });

    test('round-trips the base64 vector', () {
      final data = QrCodeData.decodeBase64(_msc4388Base64);
      expect(data.rendezvousId, '01HX9K00Q1H6KPD47EG4G1T3XG');
      expect(data.baseUrl, 'https://synapse-oidc.lab.element.dev');
      expect(data.encodeBase64(), _msc4388Base64);
      expect(
        QrCodeData.decode(_msc4388Reciprocate).encode(),
        _msc4388Reciprocate,
      );
    });
  });

  group('rejects malformed codes', () {
    void expectError(List<int> bytes, QrCodeDecodeError error) => expect(
      () => QrCodeData.decode(bytes),
      throwsA(
        isA<QrCodeDecodeException>().having((e) => e.error, 'error', error),
      ),
    );

    test('wrong prefix, version and intent', () {
      expectError(
        utf8.encode('https://example.org/'),
        QrCodeDecodeError.invalidPrefix,
      );
      expectError(
        [..._msc4108Login]..[6] = 0x01,
        QrCodeDecodeError.invalidVersion,
      );
      expectError(
        [..._msc4108Login]..[7] = 0x05,
        QrCodeDecodeError.invalidIntent,
      );
      expectError(
        [..._msc4388Reciprocate]..[18] = 0x02,
        QrCodeDecodeError.invalidVersion,
      );
      expectError(
        [..._msc4388Reciprocate]..[19] = 0x07,
        QrCodeDecodeError.invalidIntent,
      );
    });

    test('truncated data', () {
      expectError([0x4D, 0x41], QrCodeDecodeError.notEnoughData);
      for (final cut in [7, 8, 20, 40, 41, 60]) {
        expectError(
          _msc4108Login.sublist(0, cut),
          QrCodeDecodeError.notEnoughData,
        );
      }
      expectError(
        _msc4108Reciprocate.sublist(0, _msc4108Reciprocate.length - 3),
        QrCodeDecodeError.notEnoughData,
      );
    });

    test('invalid UTF-8 and URLs, oversized input', () {
      final badUtf8 = [..._msc4108Login]..[45] = 0xff;
      expectError(badUtf8, QrCodeDecodeError.notUtf8);
      final notUrl = [
        ..._msc4108Login.sublist(0, 40),
        0x00,
        0x03,
        ...utf8.encode('abc'),
      ];
      expectError(notUrl, QrCodeDecodeError.urlParse);
      expectError(List.filled(5000, 0x4D), QrCodeDecodeError.tooLarge);
    });
  });

  test('unpadded base64 helpers accept both forms', () {
    expect(decodeUnpaddedBase64('AAE'), [0, 1]);
    expect(decodeUnpaddedBase64('AAE='), [0, 1]);
    expect(encodeUnpaddedBase64([0, 1]), 'AAE');
    expect(() => decodeUnpaddedBase64('A'), throwsFormatException);
    expect(() => decodeUnpaddedBase64('A-B_'), throwsFormatException);
  });
}

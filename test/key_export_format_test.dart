import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/security/key_export_format.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Straightforward PBKDF2 over package:crypto's HMAC, as an oracle.
Uint8List _referencePbkdf2(List<int> password, List<int> salt, int rounds) {
  final hmac = crypto.Hmac(crypto.sha512, password);
  final first = Uint8List(salt.length + 4)..setAll(0, salt);
  first[salt.length + 3] = 1;
  var u = Uint8List.fromList(hmac.convert(first).bytes);
  final t = Uint8List.fromList(u);
  for (var i = 1; i < rounds; i++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var j = 0; j < 64; j++) {
      t[j] ^= u[j];
    }
  }
  return t;
}

Uint8List _body(Uint8List file) => unarmourKeyExport(file);

Uint8List _rearmour(Uint8List body) => armourKeyExport(body);

Matcher _fails(KeyExportError error) => throwsA(
  isA<KeyExportFormatException>().having((e) => e.error, 'error', error),
);

/// Test vectors from matrix-react-sdk (now Element Web)
/// test/utils/MegolmExportEncryption-test.ts, produced by Element's
/// WebCrypto implementation. Decrypting them proves interoperability of
/// PBKDF2, AES-CTR, HMAC, the header layout and the armour.
const _elementVectors = [
  (
    plain: 'plain',
    password: 'password',
    file:
        '-----BEGIN MEGOLM SESSION DATA-----\n'
        'AXNhbHRzYWx0c2FsdHNhbHSIiIiIiIiIiIiIiIiIiIiIAAAACmIRUW2OjZ3L2l6j9h0lHlV3M2dx\n'
        'cissyYBxjsfsAndErh065A8=\n'
        '-----END MEGOLM SESSION DATA-----',
  ),
  (
    plain: 'Hello, World',
    password: 'betterpassword',
    file:
        '-----BEGIN MEGOLM SESSION DATA-----\n'
        'AW1vcmVzYWx0bW9yZXNhbHT//////////wAAAAAAAAAAAAAD6KyBpe1Niv5M5NPm4ZATsJo5nghk\n'
        'KYu63a0YQ5DRhUWEKk7CcMkrKnAUiZny\n'
        '-----END MEGOLM SESSION DATA-----',
  ),
  (
    plain: 'alphanumericallyalphanumericallyalphanumericallyalphanumerically',
    password: 'SWORDFISH',
    file:
        '-----BEGIN MEGOLM SESSION DATA-----\n'
        'AXllc3NhbHR5Z29vZG5lc3P//////////wAAAAAAAAAAAAAD6OIW+Je7gwvjd4kYrb+49gKCfExw\n'
        'MgJBMD4mrhLkmgAngwR1pHjbWXaoGybtiAYr0moQ93GrBQsCzPbvl82rZhaXO3iH5uHo/RCEpOqp\n'
        'Pgg29363BGR+/Ripq/VCLKGNbw==\n'
        '-----END MEGOLM SESSION DATA-----',
  ),
  (
    plain: 'alphanumericallyalphanumericallyalphanumericallyalphanumerically',
    password:
        'passwordpasswordpasswordpasswordpasswordpasswordpasswordpasswordpassword'
        'passwordpasswordpasswordpasswordpasswordpasswordpasswordpasswordpassword'
        'passwordpasswordpasswordpasswordpasswordpasswordpasswordpasswordpassword'
        'passwordpasswordpasswordpasswordpassword',
    file:
        '-----BEGIN MEGOLM SESSION DATA-----\n'
        'Af//////////////////////////////////////////AAAD6IAZJy7IQ7Y0idqSw/bmpngEEVVh\n'
        'gsH+8ptgqxw6ZVWQnohr8JsuwH9SwGtiebZuBu5smPCO+RFVWH2cQYslZijXv/BEH/txvhUrrtCd\n'
        'bWnSXS9oymiqwUIGs08sXI33ZA==\n'
        '-----END MEGOLM SESSION DATA-----',
  ),
];

Map<String, Object?> _session(String id, {String room = '!room:example.org'}) =>
    {
      'algorithm': megolmAlgorithm,
      'room_id': room,
      'session_id': id,
      'sender_key': 'RF3s+E7RkTQTGF2d8Deol0FkQvgII2aJDf3/Jp5mxVU',
      'session_key': 'AQAAAAAclzWVMeWBKH+B/WMowa3rb4ma3jEl6n5W4GCs9ue65CruzD3',
      'sender_claimed_keys': {
        'ed25519': 'aj40p+aw64yPIdsxoog8jhPu9i7l7NcFRecuOQblE3Y',
      },
      'forwarding_curve25519_key_chain': <String>[],
    };

void main() {
  group('PBKDF2-HMAC-SHA-512', () {
    // Expected values from Python's hashlib.pbkdf2_hmac('sha512', ...).
    test('matches published-style vectors', () {
      expect(
        _hex(pbkdf2HmacSha512(utf8.encode('password'), utf8.encode('salt'), 1)),
        '867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252'
        'c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b60a57fce',
      );
      expect(
        _hex(pbkdf2HmacSha512(utf8.encode('password'), utf8.encode('salt'), 2)),
        'e1d9c16aa681708a45f5c7c4e215ceb66e011a2e9f0040713f18aefdb866d53c'
        'f76cab2868a39b9f7840edce4fef5a82be67335c77a6068e04112754f27ccf4e',
      );
      expect(
        _hex(
          pbkdf2HmacSha512(
            utf8.encode('passwordPASSWORDpassword'),
            utf8.encode('saltSALTsaltSALTsaltSALTsaltSALTsalt'),
            4096,
          ),
        ),
        '8c0511f4c6e597c6ac6315d8f0362e225f3c501495ba23b868c005174dc4ee71'
        '115b59f9e60cd9532fa33e0f75aefe30225c583a186cd82bd4daea9724a3d3b8',
      );
    });

    test('hashes passwords longer than the SHA-512 block', () {
      expect(
        _hex(
          pbkdf2HmacSha512(
            utf8.encode('p' * 150),
            utf8.encode('saltsaltsaltsalt'),
            1000,
          ),
        ),
        '5f4aff0fe4c05ca155feb3437d56eff5e8e3f3e1d357b49ec38f0c58b740e7f2'
        '2b60193877f9d1991c5eae221d829d448180657aab212e3cc14aac902791872f',
      );
    });

    test('derives multi-block output', () {
      expect(
        _hex(
          pbkdf2HmacSha512(
            utf8.encode('password'),
            utf8.encode('salt'),
            2,
            length: 100,
          ),
        ),
        'e1d9c16aa681708a45f5c7c4e215ceb66e011a2e9f0040713f18aefdb866d53c'
        'f76cab2868a39b9f7840edce4fef5a82be67335c77a6068e04112754f27ccf4e'
        '473e311ad827b68945f4e2dddb204c78e40e2495141e411cd272d020640d673c'
        'd34aa29f',
      );
    });

    test('agrees with a plain HMAC loop and reports progress', () {
      final password = utf8.encode('pässwörd 🔑');
      final salt = List<int>.generate(16, (i) => i * 7);
      final progress = <double>[];
      final fast = pbkdf2HmacSha512(
        password,
        salt,
        3000,
        onProgress: progress.add,
      );
      expect(fast, _referencePbkdf2(password, salt, 3000));
      expect(progress, isNotEmpty);
      expect(progress.last, 1);
      expect(progress, orderedEquals([...progress]..sort()));
    });

    test('500,000-round default matches the reference value', () {
      // hashlib.pbkdf2_hmac('sha512', 'pässwörd 🔑', bytes(range(16)), 500000)
      expect(keyExportDefaultRounds, 500000);
      expect(
        _hex(
          pbkdf2HmacSha512(
            utf8.encode('pässwörd 🔑'),
            List<int>.generate(16, (i) => i),
            keyExportDefaultRounds,
          ),
        ),
        '3e63b17b1917273eb63fdb35e4110a5b3b0882adb017fe2a483c87e8f6a9ff0c'
        '37abbedc5dc64fac0541f87e691105b706966fb60f12db355fb830f662607539',
      );
    });
  });

  group('Element Web interoperability', () {
    for (final (index, vector) in _elementVectors.indexed) {
      test('decrypts Element test vector ${index + 1}', () {
        expect(
          decryptKeyExport(utf8.encode(vector.file), vector.password),
          vector.plain,
        );
      });
    }

    test('wrong passphrase on an Element file is reported as such', () {
      expect(
        () => decryptKeyExport(utf8.encode(_elementVectors[1].file), 'nope'),
        _fails(KeyExportError.badPassphrase),
      );
    });

    test('Element-style 128-character lines and CRLF are accepted', () {
      final file = encryptKeyExport('x' * 500, 'pass', rounds: 10);
      final compact = base64.encode(_body(file));
      final lines = [
        for (var i = 0; i < compact.length; i += 128)
          compact.substring(i, (i + 128).clamp(0, compact.length)),
      ];
      final element =
          '\uFEFF$keyExportHeader\r\n${lines.join('\r\n')}\r\n'
          '$keyExportTrailer\r\n';
      expect(decryptKeyExport(utf8.encode(element), 'pass'), 'x' * 500);
    });
  });

  group('encryption', () {
    test('writes the spec layout with default parameters', () {
      final salt = List<int>.filled(16, 0x11);
      final iv = List<int>.filled(16, 0xff); // bit 63 set on purpose
      final file = encryptKeyExport(
        '[]',
        'correct horse battery staple',
        rounds: 1000,
        salt: salt,
        iv: iv,
      );
      final text = ascii.decode(file);
      final lines = text.split('\n');
      expect(lines.first, keyExportHeader);
      expect(lines[lines.length - 2], keyExportTrailer);
      expect(lines.last, isEmpty);
      for (final line in lines.sublist(1, lines.length - 2)) {
        expect(line.length, lessThanOrEqualTo(keyExportLineLength));
      }
      final body = _body(file);
      expect(body.length, 1 + 16 + 16 + 4 + 2 + 32);
      expect(body[0], 1);
      expect(body.sublist(1, 17), salt);
      expect(body[17 + 8] & 0x80, 0, reason: 'IV bit 63 must be clear');
      expect(body.sublist(17, 25), List<int>.filled(8, 0xff));
      expect(ByteData.sublistView(body, 33, 37).getUint32(0), 1000);
    });

    test('defaults to 500,000 rounds and random salt and IV', () {
      final a = _body(encryptKeyExport('[]', 'p', rounds: 1));
      final b = _body(encryptKeyExport('[]', 'p', rounds: 1));
      expect(a.sublist(1, 17), isNot(b.sublist(1, 17)));
      expect(a.sublist(17, 33), isNot(b.sublist(17, 33)));
      expect(a[25] & 0x80, 0);
      final defaults = _body(encryptKeyExport('[]', 'p'));
      expect(ByteData.sublistView(defaults, 33, 37).getUint32(0), 500000);
    });

    test('round-trips large unicode payloads', () {
      final sessions = [for (var i = 0; i < 300; i++) _session('s$i 🔐')];
      final text = jsonEncode(sessions);
      final file = encryptKeyExport(text, 'pässwörd', rounds: 50);
      expect(decryptKeyExport(file, 'pässwörd'), text);
      expect(base64.encode(_body(file)).length, greaterThan(96 * 10));
    });

    test('rejects an empty passphrase', () {
      expect(() => encryptKeyExport('[]', '', rounds: 1), throwsArgumentError);
    });
  });

  group('decryption errors', () {
    late Uint8List file;
    setUp(() => file = encryptKeyExport('[1,2,3]', 'secret', rounds: 20));

    test('wrong passphrase', () {
      expect(
        () => decryptKeyExport(file, 'Secret'),
        _fails(KeyExportError.badPassphrase),
      );
    });

    test('tampered ciphertext fails the HMAC', () {
      final body = _body(file);
      body[40] ^= 0x01;
      expect(
        () => decryptKeyExport(_rearmour(body), 'secret'),
        _fails(KeyExportError.badPassphrase),
      );
    });

    test('tampered HMAC', () {
      final body = _body(file);
      body[body.length - 1] ^= 0x80;
      expect(
        () => decryptKeyExport(_rearmour(body), 'secret'),
        _fails(KeyExportError.badPassphrase),
      );
    });

    test('tampered round count fails the HMAC', () {
      final body = _body(file);
      ByteData.sublistView(body, 33, 37).setUint32(0, 21);
      expect(
        () => decryptKeyExport(_rearmour(body), 'secret'),
        _fails(KeyExportError.badPassphrase),
      );
    });

    test('truncated file without a trailer', () {
      final text = ascii.decode(file);
      final cut = text.substring(0, text.indexOf(keyExportTrailer) - 5);
      expect(
        () => decryptKeyExport(utf8.encode(cut), 'secret'),
        _fails(KeyExportError.damaged),
      );
    });

    test('truncated body (Element: "too short")', () {
      const short =
          '-----BEGIN MEGOLM SESSION DATA-----\n'
          'AXNhbHRzYWx0c2FsdHNhbHSIiIiIiIiIiIiIiIiIiIiIAAAACmIRUW2OjZ3L2l6j9h0lHlV3M2dx\n'
          'cissyYBxjsfsAn\n'
          '-----END MEGOLM SESSION DATA-----\n';
      expect(
        () => decryptKeyExport(utf8.encode(short), ''),
        _fails(KeyExportError.damaged),
      );
    });

    test('truncated ciphertext with a valid armour', () {
      final body = _body(file);
      expect(
        () => decryptKeyExport(
          _rearmour(Uint8List.sublistView(body, 0, body.length - 3)),
          'secret',
        ),
        _fails(KeyExportError.badPassphrase),
      );
    });

    test('missing header', () {
      expect(
        () => decryptKeyExport(utf8.encode('-----'), ''),
        _fails(KeyExportError.notKeyFile),
      );
      expect(
        () => decryptKeyExport([0xff, 0xfe, 0x00], ''),
        _fails(KeyExportError.notKeyFile),
      );
    });

    test('invalid base64', () {
      expect(
        () => decryptKeyExport(
          utf8.encode('$keyExportHeader\n@@@@\n$keyExportTrailer\n'),
          '',
        ),
        _fails(KeyExportError.damaged),
      );
    });

    test('unsupported version', () {
      final body = _body(file)..[0] = 2;
      expect(
        () => decryptKeyExport(_rearmour(body), 'secret'),
        _fails(KeyExportError.unsupportedVersion),
      );
    });

    test('zero or excessive rounds are refused before key derivation', () {
      final body = _body(file);
      ByteData.sublistView(body, 33, 37).setUint32(0, 0);
      expect(
        () => decryptKeyExport(_rearmour(body), 'secret'),
        _fails(KeyExportError.unsupportedRounds),
      );
      ByteData.sublistView(body, 33, 37).setUint32(0, 0xffffffff);
      expect(
        () => decryptKeyExport(_rearmour(body), 'secret'),
        _fails(KeyExportError.unsupportedRounds),
      );
    });

    test('oversized input', () {
      expect(
        () => unarmourKeyExport(Uint8List(keyExportMaxFileBytes + 1)),
        _fails(KeyExportError.tooLarge),
      );
    });

    test('non-JSON content', () {
      final binary = encryptKeyExport('x', 'p', rounds: 1);
      expect(decryptKeyExport(binary, 'p'), 'x');
      expect(
        () => decryptKeyExportPayload(binary, 'p'),
        _fails(KeyExportError.invalidContent),
      );
      expect(
        () => parseKeyExportJson('{"rooms": []}'),
        _fails(KeyExportError.invalidContent),
      );
    });
  });

  group('export JSON', () {
    test('keeps valid sessions, drops invalid ones, counts all', () {
      final payload = parseKeyExportJson(
        jsonEncode([
          _session('a'),
          {..._session('b'), 'unexpected': 'dropped', 'shared_history': true},
          {..._session('c'), 'algorithm': 'm.olm.v1.curve25519-aes-sha2'},
          {..._session('d'), 'room_id': 'not-a-room'},
          {..._session('e')}..remove('session_key'),
          {..._session('f'), 'forwarding_curve25519_key_chain': 'nope'},
          'garbage',
          {..._session('g')}
            ..remove('sender_claimed_keys')
            ..remove('forwarding_curve25519_key_chain'),
        ]),
      );
      expect(payload.total, 8);
      expect(payload.sessions.map((s) => s['session_id']), ['a', 'b', 'g']);
      expect(payload.sessions[1].containsKey('unexpected'), isFalse);
      expect(payload.sessions[1]['shared_history'], isTrue);
      expect(payload.sessions[2]['sender_claimed_keys'], isEmpty);
      expect(payload.sessions[2]['forwarding_curve25519_key_chain'], isEmpty);
      expect(payload.sessions[0], _session('a'));
    });

    test('builds export entries from stored SDK content', () {
      final entry = exportedSessionEntry(
        roomId: '!room:example.org',
        sessionId: 'sid',
        senderKey: 'curve',
        sessionKey: 'exported',
        senderClaimedKeys: {'ed25519': 'ed'},
        content: {
          'algorithm': megolmAlgorithm,
          'session_key': 'should not leak through',
          'forwarding_curve25519_key_chain': ['hop'],
          'shared_history': false,
        },
      );
      expect(entry, {
        'algorithm': megolmAlgorithm,
        'room_id': '!room:example.org',
        'session_id': 'sid',
        'sender_key': 'curve',
        'session_key': 'exported',
        'sender_claimed_keys': {'ed25519': 'ed'},
        'forwarding_curve25519_key_chain': ['hop'],
        'shared_history': false,
      });
      expect(
        exportedSessionEntry(
          roomId: '!r:x',
          sessionId: 's',
          senderKey: 'k',
          sessionKey: 'e',
          content: {'algorithm': 'm.olm.v1.curve25519-aes-sha2'},
        ),
        isNull,
      );
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/security/key_export_features.dart';
import 'package:parallax/features/security/key_export_format.dart';
import 'package:parallax/features/security/key_export_screens.dart';

import 'key_export_fakes.dart';
import 'security_fakes.dart';

Matcher _transferFails(
  KeyTransferFailure failure, {
  KeyExportError? format,
  int? imported,
}) => throwsA(
  isA<KeyTransferException>()
      .having((e) => e.failure, 'failure', failure)
      .having((e) => e.format, 'format', format)
      .having((e) => e.imported, 'imported', imported ?? anything),
);

void main() {
  RoomKeyTransfer transfer(
    FakeKeyStore keys, {
    KeyExportCipher cipher = const InlineKeyExportCipher(),
  }) => RoomKeyTransfer(
    keys,
    cipher: cipher,
    files: FakeKeyFiles(),
    rounds: 1000,
  );

  group('round trip', () {
    test(
      'export then import into an empty device restores every key',
      () async {
        final source = FakeKeyStore([
          fakeSession('a'),
          fakeSession('b', room: '!other:example.org'),
          {...fakeSession('c'), 'shared_history': true},
        ]);
        final progress = <KeyTransferProgress>[];
        final file = await transfer(
          source,
        ).export('correct horse battery staple', onProgress: progress.add);
        expect(file.keyCount, 3);
        expect(ascii.decode(file.bytes), startsWith(keyExportHeader));
        expect(progress.first.stage, KeyTransferStage.collecting);
        expect(progress.last.stage, KeyTransferStage.encrypting);
        expect(progress.last.fraction, 1);

        final target = FakeKeyStore();
        final steps = <KeyTransferProgress>[];
        final result = await transfer(target).import(
          file.bytes,
          'correct horse battery staple',
          onProgress: steps.add,
        );
        expect(result.imported, 3);
        expect(result.total, 3);
        expect(target.stored, source.stored);
        expect(steps.map((s) => s.stage).toSet(), {
          KeyTransferStage.decrypting,
          KeyTransferStage.importing,
        });
        expect(steps.last.done, 3);

        // Importing again changes nothing: the SDK keeps equal copies.
        final again = await transfer(
          target,
        ).import(file.bytes, 'correct horse battery staple');
        expect((again.imported, again.total), (0, 3));
      },
    );

    test('runs PBKDF2 in a background isolate with progress', () async {
      final source = FakeKeyStore([fakeSession('a'), fakeSession('b')]);
      final isolate = RoomKeyTransfer(
        source,
        files: FakeKeyFiles(),
        rounds: 20000,
      );
      final exportProgress = <double>[];
      final file = await isolate.export(
        'pass phrase',
        onProgress: (p) {
          if (p.stage == KeyTransferStage.encrypting && p.fraction != null) {
            exportProgress.add(p.fraction!);
          }
        },
      );
      expect(exportProgress.length, greaterThan(2));
      final target = FakeKeyStore();
      final result = await RoomKeyTransfer(
        target,
        files: FakeKeyFiles(),
      ).import(file.bytes, 'pass phrase');
      expect((result.imported, result.total), (2, 2));
      expect(decryptKeyExport(file.bytes, 'pass phrase'), contains('"a"'));
    });

    test(
      'counts invalid entries in the total but never imports them',
      () async {
        final file = encryptKeyExport(
          jsonEncode([
            fakeSession('a'),
            {...fakeSession('b'), 'algorithm': 'm.olm.v1.curve25519-aes-sha2'},
            {...fakeSession('c'), 'room_id': 'missing-bang'},
            fakeSession('d'),
          ]),
          'pw',
          rounds: 10,
        );
        final target = FakeKeyStore();
        final result = await transfer(target).import(file, 'pw');
        expect((result.imported, result.total), (2, 4));
        expect(target.stored.keys, ['a', 'd']);
      },
    );
  });

  group('failures', () {
    test(
      'wrong passphrase, tampered HMAC and truncation import nothing',
      () async {
        final file = await transfer(
          FakeKeyStore([fakeSession('a')]),
        ).export('right');
        final target = FakeKeyStore();
        await expectLater(
          transfer(target).import(file.bytes, 'wrong'),
          _transferFails(
            KeyTransferFailure.file,
            format: KeyExportError.badPassphrase,
          ),
        );
        final body = unarmourKeyExport(file.bytes);
        body[body.length - 2] ^= 1;
        await expectLater(
          transfer(target).import(armourKeyExport(body), 'right'),
          _transferFails(
            KeyTransferFailure.file,
            format: KeyExportError.badPassphrase,
          ),
        );
        final text = ascii.decode(file.bytes);
        await expectLater(
          transfer(target).import(
            Uint8List.fromList(
              ascii.encode(text.substring(0, text.length ~/ 2)),
            ),
            'right',
          ),
          _transferFails(
            KeyTransferFailure.file,
            format: KeyExportError.damaged,
          ),
        );
        await expectLater(
          transfer(
            target,
          ).import(Uint8List.fromList(utf8.encode('hello')), 'right'),
          _transferFails(
            KeyTransferFailure.file,
            format: KeyExportError.notKeyFile,
          ),
        );
        expect(target.stored, isEmpty);
        expect(target.imports, 0);
      },
    );

    test('oversized files are refused before decryption', () async {
      final target = FakeKeyStore();
      await expectLater(
        transfer(target).import(Uint8List(keyExportMaxFileBytes + 1), 'x'),
        _transferFails(
          KeyTransferFailure.file,
          format: KeyExportError.tooLarge,
        ),
      );
    });

    test('no keys to export', () async {
      await expectLater(
        transfer(FakeKeyStore()).export('passphrase'),
        _transferFails(KeyTransferFailure.noKeys),
      );
    });

    test('signed out before starting', () async {
      final keys = FakeKeyStore([fakeSession('a')])..session = null;
      await expectLater(
        transfer(keys).export('passphrase'),
        _transferFails(KeyTransferFailure.unavailable),
      );
      await expectLater(
        transfer(keys).import(Uint8List(10), 'passphrase'),
        _transferFails(KeyTransferFailure.unavailable),
      );
    });

    test('a session change during encryption drops the file', () async {
      final keys = FakeKeyStore([fakeSession('a')]);
      final hooked = transfer(
        keys,
        cipher: HookedCipher(beforeResult: () => keys.session = 'session-2'),
      );
      await expectLater(
        hooked.export('passphrase'),
        _transferFails(KeyTransferFailure.sessionChanged),
      );
    });

    test('a session change during decryption imports nothing', () async {
      final file = await transfer(
        FakeKeyStore([fakeSession('a')]),
      ).export('pw-pw-pw');
      final target = FakeKeyStore();
      final hooked = transfer(
        target,
        cipher: HookedCipher(beforeResult: () => target.session = null),
      );
      await expectLater(
        hooked.import(file.bytes, 'pw-pw-pw'),
        _transferFails(KeyTransferFailure.sessionChanged),
      );
      expect(target.imports, 0);
    });

    test('collection failures surface as unavailable', () async {
      final keys = FakeKeyStore([fakeSession('a')])
        ..exportError = StateError('Encryption setup already running');
      await expectLater(
        transfer(keys).export('passphrase'),
        _transferFails(KeyTransferFailure.unavailable),
      );
    });

    test('an interrupted import reports the keys already kept', () async {
      final file = await transfer(
        FakeKeyStore([
          fakeSession('a'),
          fakeSession('b'),
          fakeSession('c'),
          fakeSession('d'),
        ]),
      ).export('pw');
      final target = FakeKeyStore()..failImportAt = 2;
      await expectLater(
        transfer(target).import(file.bytes, 'pw'),
        _transferFails(KeyTransferFailure.interrupted, imported: 2),
      );
      expect(target.stored.length, 2);
    });
  });

  group('copy', () {
    test('passphrase strength hint', () {
      expect(passphraseStrength(''), PassphraseStrength.weak);
      expect(passphraseStrength('sunshine'), PassphraseStrength.weak);
      expect(
        passphraseStrength('aaaaaaaaaaaaaaaaaaaa'),
        PassphraseStrength.weak,
      );
      expect(passphraseStrength('Password1234'), PassphraseStrength.fair);
      expect(
        passphraseStrength('correct horse battery staple'),
        PassphraseStrength.strong,
      );
    });

    test('error text covers every failure', () {
      for (final failure in KeyTransferFailure.values) {
        for (final format in [null, ...KeyExportError.values]) {
          final text = keyTransferErrorText(
            KeyTransferException(failure, format: format, imported: 3),
            importing: true,
          );
          expect(text, isNotEmpty);
        }
      }
      expect(
        keyTransferErrorText(
          const KeyTransferException(
            KeyTransferFailure.file,
            format: KeyExportError.badPassphrase,
          ),
          importing: true,
        ),
        contains('Check the passphrase'),
      );
      expect(
        keyTransferErrorText(
          const KeyTransferException(
            KeyTransferFailure.interrupted,
            imported: 3,
          ),
          importing: true,
        ),
        contains('3 keys imported so far are kept'),
      );
    });

    test('backends without the module resolve to null', () {
      expect(keyExportFeaturesOf(SecurityTestBackend()), isNull);
      expect(RoomKeyTransfer.of(SecurityTestBackend()), isNull);
    });
  });
}

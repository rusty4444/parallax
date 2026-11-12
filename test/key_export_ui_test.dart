import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/security/key_export_features.dart';
import 'package:parallax/features/security/key_export_format.dart';
import 'package:parallax/features/security/key_export_screens.dart';
import 'package:parallax/features/security/security_settings.dart';

import 'key_export_fakes.dart';
import 'security_fakes.dart';

const _strong = 'correct horse battery staple';

class _Harness {
  _Harness({FakeKeyStore? keys})
    : keys = keys ?? FakeKeyStore([fakeSession('a'), fakeSession('b')]);
  final FakeKeyStore keys;
  final files = FakeKeyFiles();
  final secure = <bool>[];
  late final transfer = RoomKeyTransfer(
    keys,
    cipher: const InlineKeyExportCipher(),
    files: files,
    rounds: 1000,
  );
}

Future<_Harness> _pumpSettings(
  WidgetTester tester, {
  _Harness? harness,
  bool withTransfer = true,
}) async {
  final h = harness ?? _Harness();
  tester.view.physicalSize = const Size(1080, 4200);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(VisualTheme.parallax),
      home: Scaffold(
        body: ListView(
          children: [
            SecuritySettingsSection(
              backend: SecurityTestBackend(),
              security: FakeSecurity(),
              palette: paletteFor(VisualTheme.parallax),
              setSecureWindow: (enabled) async => h.secure.add(enabled),
              keyTransfer: withTransfer ? h.transfer : null,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> _open(WidgetTester tester, String entry) async {
  await tester.ensureVisible(find.text(entry));
  await tester.tap(find.text(entry));
  await tester.pumpAndSettle();
}

/// The AccentButton (a FilledButton.icon) labelled [label].
Finder _button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((w) => w is FilledButton),
);

bool _enabled(WidgetTester tester, String label) =>
    tester.widget<FilledButton>(_button(label)).onPressed != null;

void main() {
  testWidgets('settings show the room key entries only with the module', (
    tester,
  ) async {
    await _pumpSettings(tester);
    expect(find.text('Room keys'), findsOneWidget);
    expect(find.text('Export room keys'), findsOneWidget);
    expect(find.text('Import room keys'), findsOneWidget);
    // Existing security entries are unchanged.
    expect(find.text('Reset digital identity'), findsOneWidget);
    expect(find.text('Change recovery key'), findsOneWidget);

    await _pumpSettings(tester, withTransfer: false);
    expect(find.text('Export room keys'), findsNothing);
    expect(find.text('Import room keys'), findsNothing);
  });

  testWidgets('export: passphrase rules, encryption, save and secure window', (
    tester,
  ) async {
    final h = await _pumpSettings(tester);
    await _open(tester, 'Export room keys');
    expect(h.secure, [true]);
    expect(find.textContaining('allow anyone who can read it'), findsOneWidget);
    expect(_enabled(tester, 'Export'), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('keyExport.passphrase')),
      'sunshine',
    );
    await tester.enterText(
      find.byKey(const ValueKey('keyExport.confirm')),
      'sunshine',
    );
    await tester.pump();
    expect(find.textContaining('Too weak'), findsOneWidget);
    expect(_enabled(tester, 'Export'), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('keyExport.passphrase')),
      _strong,
    );
    await tester.pump();
    expect(find.text('Strong passphrase'), findsOneWidget);
    expect(find.text('Passphrases must match'), findsOneWidget);
    expect(_enabled(tester, 'Export'), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('keyExport.confirm')),
      _strong,
    );
    await tester.pump();
    expect(_enabled(tester, 'Export'), isTrue);
    await tester.tap(_button('Export'));
    await tester.pumpAndSettle();

    expect(find.text('Exported 2 keys'), findsOneWidget);
    expect(h.files.saved.keys, [keyExportFileName]);
    final saved = h.files.saved[keyExportFileName]!;
    expect(ascii.decode(saved), startsWith('$keyExportHeader\n'));
    final payload = parseKeyExportJson(decryptKeyExport(saved, _strong));
    expect(payload.sessions, [fakeSession('a'), fakeSession('b')]);

    await tester.tap(_button('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Export room keys'), findsOneWidget);
    expect(h.secure, [true, false]);
  });

  testWidgets('export: a cancelled save can be retried without re-encrypting', (
    tester,
  ) async {
    final h = await _pumpSettings(tester);
    h.files.cancelSave = true;
    await _open(tester, 'Export room keys');
    for (final key in ['keyExport.passphrase', 'keyExport.confirm']) {
      await tester.enterText(find.byKey(ValueKey(key)), _strong);
    }
    await tester.pump();
    await tester.tap(_button('Export'));
    await tester.pumpAndSettle();
    expect(find.textContaining('wasn’t saved'), findsOneWidget);
    expect(find.text('Your 2 keys are encrypted'), findsOneWidget);
    expect(h.keys.exports, 1);

    h.files.cancelSave = false;
    await tester.tap(_button('Save file'));
    await tester.pumpAndSettle();
    expect(find.text('Exported 2 keys'), findsOneWidget);
    expect(h.keys.exports, 1);
    expect(h.files.saves, 2);
  });

  testWidgets('export: no keys shows an error and saves nothing', (
    tester,
  ) async {
    final h = await _pumpSettings(
      tester,
      harness: _Harness(keys: FakeKeyStore()),
    );
    await _open(tester, 'Export room keys');
    for (final key in ['keyExport.passphrase', 'keyExport.confirm']) {
      await tester.enterText(find.byKey(ValueKey(key)), _strong);
    }
    await tester.pump();
    await tester.tap(_button('Export'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no room keys on this device'), findsOneWidget);
    expect(h.files.saves, 0);
  });

  testWidgets('import: pick, wrong passphrase, then "Imported N of M keys"', (
    tester,
  ) async {
    final h = await _pumpSettings(
      tester,
      harness: _Harness(keys: FakeKeyStore([fakeSession('a')])),
    );
    final file = encryptKeyExport(
      jsonEncode([
        fakeSession('a'),
        fakeSession('b'),
        fakeSession('c'),
        {'algorithm': 'unknown'},
      ]),
      'file passphrase',
      rounds: 500,
    );
    h.files.next = PickedKeyFile(name: 'element-keys.txt', bytes: file);

    await _open(tester, 'Import room keys');
    expect(h.secure, [true]);
    expect(find.text('No file chosen'), findsOneWidget);
    expect(_enabled(tester, 'Import'), isFalse);

    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    expect(find.text('element-keys.txt'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('keyImport.passphrase')),
      'wrong',
    );
    await tester.pump();
    await tester.tap(_button('Import'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Check the passphrase'), findsOneWidget);
    expect(h.keys.stored.keys, ['a']);

    await tester.enterText(
      find.byKey(const ValueKey('keyImport.passphrase')),
      'file passphrase',
    );
    await tester.pump();
    await tester.tap(_button('Import'));
    await tester.pumpAndSettle();
    expect(find.text('Imported 2 of 4 keys'), findsOneWidget);
    expect(find.textContaining('were skipped'), findsOneWidget);
    expect(find.textContaining('not as verified'), findsOneWidget);
    expect(h.keys.stored.keys, ['a', 'b', 'c']);

    await tester.tap(_button('Done'));
    await tester.pumpAndSettle();
    expect(h.secure, [true, false]);
  });

  testWidgets('import: a file that is not a key export is rejected', (
    tester,
  ) async {
    final h = await _pumpSettings(tester);
    h.files.next = PickedKeyFile(
      name: 'notes.txt',
      bytes: utf8.encode('shopping list'),
    );
    await _open(tester, 'Import room keys');
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('keyImport.passphrase')),
      'anything',
    );
    await tester.pump();
    await tester.tap(_button('Import'));
    await tester.pumpAndSettle();
    expect(find.textContaining('isn’t a room key file'), findsOneWidget);
    expect(h.keys.imports, 0);
  });

  testWidgets('import: oversized picks are refused', (tester) async {
    final h = await _pumpSettings(tester);
    h.files.pickError = const KeyExportFormatException(KeyExportError.tooLarge);
    await _open(tester, 'Import room keys');
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    expect(find.textContaining('too large'), findsOneWidget);
    expect(find.text('No file chosen'), findsOneWidget);
  });

  testWidgets('screens fail closed when screen protection is unavailable', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: KeyExportScreen(
          transfer: h.transfer,
          palette: paletteFor(VisualTheme.parallax),
          setSecureWindow: (_) async => throw StateError('no FLAG_SECURE'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Screen protection is unavailable'), findsOne);
    expect(find.byKey(const ValueKey('keyExport.passphrase')), findsNothing);
  });
}

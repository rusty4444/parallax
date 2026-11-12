import 'dart:math';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'key_export_features.dart';
import 'security_ui.dart';

enum PassphraseStrength { weak, fair, strong }

/// Rough strength hint for an export passphrase: estimated bits from the
/// character classes used, with repeated characters discounted. Not a
/// guarantee; it only steers people away from short or repetitive phrases.
PassphraseStrength passphraseStrength(String value) {
  final runes = value.runes.toList();
  if (runes.length < 8) return PassphraseStrength.weak;
  var pool = 0;
  if (runes.any((r) => r >= 0x61 && r <= 0x7a)) pool += 26;
  if (runes.any((r) => r >= 0x41 && r <= 0x5a)) pool += 26;
  if (runes.any((r) => r >= 0x30 && r <= 0x39)) pool += 10;
  if (runes.any((r) => r < 0x80 && !_alphanumeric(r))) pool += 33;
  if (runes.any((r) => r >= 0x80)) pool += 100;
  final unique = runes.toSet().length;
  if (unique < 5) return PassphraseStrength.weak;
  // Repeated characters count half.
  final effective = unique + (runes.length - unique) / 2;
  final bits = effective * log(max(pool, 2)) / ln2;
  if (bits < 45) return PassphraseStrength.weak;
  if (bits < 70) return PassphraseStrength.fair;
  return PassphraseStrength.strong;
}

bool _alphanumeric(int r) =>
    (r >= 0x61 && r <= 0x7a) ||
    (r >= 0x41 && r <= 0x5a) ||
    (r >= 0x30 && r <= 0x39);

/// User-facing text for a failed export or import.
String keyTransferErrorText(Object error, {required bool importing}) {
  if (error is KeyTransferException) {
    switch (error.failure) {
      case KeyTransferFailure.file:
        return switch (error.format) {
          KeyExportError.badPassphrase =>
            'Couldn’t decrypt this file. Check the passphrase and try again. '
                'If it’s right, the file may have been changed.',
          KeyExportError.notKeyFile =>
            'This isn’t a room key file. Choose a file exported from '
                'Parallax, Element or another Matrix app.',
          KeyExportError.damaged => 'This key file is incomplete or damaged.',
          KeyExportError.unsupportedVersion ||
          KeyExportError.unsupportedRounds =>
            'This key file uses a format Parallax doesn’t support.',
          KeyExportError.invalidContent =>
            'The file was decrypted, but it doesn’t contain room keys.',
          KeyExportError.tooLarge => 'This file is too large to be a key file.',
          null => 'Couldn’t read this key file.',
        };
      case KeyTransferFailure.noKeys:
        return 'There are no room keys on this device to export yet.';
      case KeyTransferFailure.sessionChanged:
        return importing
            ? 'You signed out or switched accounts, so the import stopped. '
                  '${_keysKept(error)}'
            : 'You signed out or switched accounts, so nothing was exported.';
      case KeyTransferFailure.unavailable:
        return 'Encryption is busy or unavailable. Finish any verification '
            'or key storage change, then try again.';
      case KeyTransferFailure.interrupted:
        return 'The import stopped before it finished. ${_keysKept(error)} '
            'Try again to import the rest.';
    }
  }
  return importing
      ? 'Couldn’t import keys from this file.'
      : 'Couldn’t export your keys. Nothing was saved.';
}

String _keysKept(KeyTransferException error) => error.imported == 0
    ? 'No keys were imported.'
    : '${_count(error.imported)} imported so far are kept.';

String _count(int n) => '$n ${n == 1 ? 'key' : 'keys'}';

String _progressLabel(KeyTransferProgress? progress) {
  final p = progress;
  if (p == null) return 'Starting…';
  return switch (p.stage) {
    KeyTransferStage.collecting =>
      p.total == null
          ? 'Collecting keys…'
          : 'Collecting keys… ${p.done ?? 0} of ${p.total}',
    KeyTransferStage.encrypting => 'Encrypting the file…',
    KeyTransferStage.decrypting => 'Checking the passphrase and decrypting…',
    KeyTransferStage.importing =>
      p.total == null
          ? 'Importing keys…'
          : 'Importing keys… ${p.done ?? 0} of ${p.total}',
  };
}

/// Holds the latest progress and redraws only when visible text or the
/// whole-percent bar changes (imports report every key).
mixin _ProgressState<T extends StatefulWidget> on State<T> {
  KeyTransferProgress? progress;
  String? _progressKey;

  void onProgress(KeyTransferProgress next) {
    if (!mounted) return;
    progress = next;
    final percent = next.fraction == null ? -1 : (next.fraction! * 100).floor();
    final key =
        '${next.stage.index}:$percent:'
        '${(next.total ?? 0) <= 200 ? next.done : ''}';
    if (key == _progressKey) return;
    _progressKey = key;
    setState(() {});
  }
}

class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.palette, required this.progress});
  final AppPalette palette;
  final KeyTransferProgress? progress;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(
          key: const ValueKey('keyExport.progress'),
          minHeight: 8,
          value: progress?.fraction?.clamp(0, 1),
          color: palette.accent,
          backgroundColor: palette.raised,
        ),
      ),
      const SizedBox(height: 10),
      Text(_progressLabel(progress), style: TextStyle(color: palette.muted)),
    ],
  );
}

class _KeyScreenScaffold extends StatelessWidget {
  const _KeyScreenScaffold({
    required this.palette,
    required this.busy,
    required this.icon,
    required this.title,
    required this.children,
  });
  final AppPalette palette;
  final bool busy;
  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      body: GlowBackdrop(
        palette: palette,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 40),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: busy ? null : () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const SizedBox(height: 16),
              Icon(icon, color: palette.secondary, size: 40),
              const SizedBox(height: 12),
              Eyebrow('Encryption', palette: palette),
              const SizedBox(height: 6),
              Text(
                title,
                style: TextStyle(
                  color: palette.foreground,
                  fontSize: 27,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              ...children,
            ],
          ),
        ),
      ),
    ),
  );
}

TextField _passphraseField({
  required Key key,
  required TextEditingController controller,
  required String label,
  required bool enabled,
  required VoidCallback onChanged,
  String? helper,
  String? errorText,
  Color? helperColour,
}) => TextField(
  key: key,
  controller: controller,
  enabled: enabled,
  obscureText: true,
  autocorrect: false,
  enableSuggestions: false,
  enableIMEPersonalizedLearning: false,
  keyboardType: TextInputType.visiblePassword,
  onChanged: (_) => onChanged(),
  decoration: InputDecoration(
    labelText: label,
    helperText: helper,
    helperStyle: helperColour == null ? null : TextStyle(color: helperColour),
    errorText: errorText,
  ),
);

/// Element Web "Export room keys": passphrase + confirmation with a
/// strength hint, encrypted off the UI thread, then saved through the
/// system file picker as `element-keys.txt`. FLAG_SECURE is held for the
/// whole route, including its exit animation.
class KeyExportScreen extends StatefulWidget {
  const KeyExportScreen({
    super.key,
    required this.transfer,
    required this.palette,
    this.setSecureWindow,
  });

  final RoomKeyTransfer transfer;
  final AppPalette palette;
  final SetSecureWindow? setSecureWindow;

  @override
  State<KeyExportScreen> createState() => _KeyExportScreenState();
}

class _KeyExportScreenState extends State<KeyExportScreen>
    with SecureScreenState<KeyExportScreen>, _ProgressState<KeyExportScreen> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _saving = false;
  String? _error;
  KeyExportFile? _file;
  bool _saved = false;

  @override
  SetSecureWindow? get secureWindowOverride => widget.setSecureWindow;

  @override
  void initState() {
    super.initState();
    protectScreen();
  }

  @override
  void dispose() {
    _passphrase.clear();
    _confirm.clear();
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  PassphraseStrength get _strength => passphraseStrength(_passphrase.text);

  bool get _matches => _passphrase.text == _confirm.text;

  bool get _canExport =>
      secureReady &&
      !_busy &&
      _file == null &&
      _passphrase.text.isNotEmpty &&
      _strength != PassphraseStrength.weak &&
      _matches;

  Future<void> _export() async {
    if (!_canExport) return;
    final passphrase = _passphrase.text;
    setState(() {
      _busy = true;
      _error = null;
      progress = null;
    });
    try {
      final file = await widget.transfer.export(
        passphrase,
        onProgress: onProgress,
      );
      if (!mounted) return;
      _passphrase.clear();
      _confirm.clear();
      setState(() {
        _file = file;
        _busy = false;
      });
      await _save();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = keyTransferErrorText(error, importing: false);
      });
    }
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null || _saving || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.transfer.files.save(
        keyExportFileName,
        file.bytes,
      );
      if (!mounted) return;
      setState(() {
        _saved = saved;
        if (!saved) {
          _error = 'The file wasn’t saved. Choose where to save it to finish.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Couldn’t save the file. Try another place.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final error = Theme.of(context).colorScheme.error;
    final file = _file;
    return _KeyScreenScaffold(
      palette: p,
      busy: _busy || _saving,
      icon: Icons.file_upload_outlined,
      title: 'Export room keys',
      children: [
        if (secureError != null)
          Text(secureError!, style: TextStyle(color: error))
        else if (!secureReady)
          const Center(child: CircularProgressIndicator())
        else if (file != null) ...[
          SecurityCard(
            palette: p,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _saved
                      ? 'Exported ${_count(file.keyCount)}'
                      : 'Your ${_count(file.keyCount)} are encrypted',
                  key: const ValueKey('keyExport.result'),
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _saved
                      ? 'Saved as $keyExportFileName. Keep the file and its '
                            'passphrase somewhere safe, and delete the file '
                            'once you’ve imported it.'
                      : 'Save the file to finish exporting.',
                  style: TextStyle(color: p.muted, height: 1.4),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: TextStyle(color: error)),
          ],
          const SizedBox(height: 22),
          if (_saved)
            AccentButton(
              palette: p,
              label: 'Done',
              icon: Icons.check_rounded,
              onPressed: () => Navigator.pop(context, true),
            )
          else
            AccentButton(
              palette: p,
              label: _saving ? 'Saving…' : 'Save file',
              icon: Icons.save_alt_rounded,
              onPressed: _saving ? null : _save,
            ),
        ] else ...[
          Text(
            'This process allows you to export the keys for messages you '
            'have received in encrypted rooms to a local file. You will then '
            'be able to import the file into another Matrix client in the '
            'future, so that client will also be able to decrypt these '
            'messages.',
            style: TextStyle(color: p.foreground, height: 1.4),
          ),
          const SizedBox(height: 14),
          SecurityCard(
            palette: p,
            borderColor: error.withValues(alpha: 0.5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: error),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'The exported file will allow anyone who can read it to '
                    'decrypt any encrypted messages that you can see, so be '
                    'careful to keep it secure. Enter a unique passphrase '
                    'below; it is only used to encrypt this file, and the '
                    'same passphrase is needed to import it.',
                    style: TextStyle(color: p.foreground, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _passphraseField(
            key: const ValueKey('keyExport.passphrase'),
            controller: _passphrase,
            label: 'Enter passphrase',
            enabled: !_busy,
            onChanged: () => setState(() {}),
            helper: _passphrase.text.isEmpty
                ? null
                : switch (_strength) {
                    PassphraseStrength.weak =>
                      'Too weak: use a longer passphrase with more variety',
                    PassphraseStrength.fair =>
                      'Fair: a longer passphrase is stronger',
                    PassphraseStrength.strong => 'Strong passphrase',
                  },
            helperColour: _passphrase.text.isEmpty
                ? null
                : switch (_strength) {
                    PassphraseStrength.weak => error,
                    PassphraseStrength.fair => p.muted,
                    PassphraseStrength.strong => p.secondary,
                  },
          ),
          const SizedBox(height: 10),
          _passphraseField(
            key: const ValueKey('keyExport.confirm'),
            controller: _confirm,
            label: 'Confirm passphrase',
            enabled: !_busy,
            onChanged: () => setState(() {}),
            errorText: _confirm.text.isNotEmpty && !_matches
                ? 'Passphrases must match'
                : null,
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            _ProgressView(palette: p, progress: progress),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: TextStyle(color: error)),
          ],
          const SizedBox(height: 22),
          AccentButton(
            palette: p,
            label: _busy ? 'Exporting…' : 'Export',
            icon: Icons.file_upload_outlined,
            onPressed: _canExport ? _export : null,
          ),
        ],
      ],
    );
  }
}

/// Element Web "Import room keys": choose a file, enter its passphrase,
/// then report "Imported N of M keys". FLAG_SECURE is held for the route.
class KeyImportScreen extends StatefulWidget {
  const KeyImportScreen({
    super.key,
    required this.transfer,
    required this.palette,
    this.setSecureWindow,
  });

  final RoomKeyTransfer transfer;
  final AppPalette palette;
  final SetSecureWindow? setSecureWindow;

  @override
  State<KeyImportScreen> createState() => _KeyImportScreenState();
}

class _KeyImportScreenState extends State<KeyImportScreen>
    with SecureScreenState<KeyImportScreen>, _ProgressState<KeyImportScreen> {
  final _passphrase = TextEditingController();
  PickedKeyFile? _file;
  bool _picking = false;
  bool _busy = false;
  String? _error;
  KeyImportResult? _result;

  @override
  SetSecureWindow? get secureWindowOverride => widget.setSecureWindow;

  @override
  void initState() {
    super.initState();
    protectScreen();
  }

  @override
  void dispose() {
    _passphrase.clear();
    _passphrase.dispose();
    super.dispose();
  }

  bool get _canImport =>
      secureReady &&
      !_busy &&
      !_picking &&
      _file != null &&
      _passphrase.text.isNotEmpty &&
      _result == null;

  Future<void> _pick() async {
    if (_busy || _picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final file = await widget.transfer.files.pick();
      if (!mounted || file == null) return;
      setState(() => _file = file);
    } on KeyExportFormatException catch (error) {
      if (mounted) {
        setState(
          () => _error = keyTransferErrorText(
            KeyTransferException(KeyTransferFailure.file, format: error.error),
            importing: true,
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t open that file.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _import() async {
    final file = _file;
    if (!_canImport || file == null) return;
    final passphrase = _passphrase.text;
    setState(() {
      _busy = true;
      _error = null;
      progress = null;
    });
    try {
      final result = await widget.transfer.import(
        file.bytes,
        passphrase,
        onProgress: onProgress,
      );
      if (!mounted) return;
      _passphrase.clear();
      setState(() {
        _result = result;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = keyTransferErrorText(error, importing: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final error = Theme.of(context).colorScheme.error;
    final result = _result;
    final file = _file;
    return _KeyScreenScaffold(
      palette: p,
      busy: _busy,
      icon: Icons.file_download_outlined,
      title: 'Import room keys',
      children: [
        if (secureError != null)
          Text(secureError!, style: TextStyle(color: error))
        else if (!secureReady)
          const Center(child: CircularProgressIndicator())
        else if (result != null) ...[
          SecurityCard(
            palette: p,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Imported ${result.imported} of ${_count(result.total)}',
                  key: const ValueKey('keyImport.result'),
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (result.imported < result.total)
                      'Keys you already had, or that couldn’t be used, were '
                          'skipped.',
                    if (result.imported > 0)
                      'Messages these keys unlock are decrypted as they '
                          'load. Imported keys are treated like keys shared '
                          'by another device, not as verified.',
                  ].join(' '),
                  style: TextStyle(color: p.muted, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          AccentButton(
            palette: p,
            label: 'Done',
            icon: Icons.check_rounded,
            onPressed: () => Navigator.pop(context, true),
          ),
        ] else ...[
          Text(
            'This process allows you to import encryption keys that you had '
            'previously exported from another Matrix client. You will then '
            'be able to decrypt any messages that the other client could '
            'decrypt.',
            style: TextStyle(color: p.foreground, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            'The export file is protected with a passphrase. Enter the '
            'passphrase here to decrypt the file.',
            style: TextStyle(color: p.muted, height: 1.4),
          ),
          const SizedBox(height: 18),
          SecurityCard(
            palette: p,
            child: Row(
              children: [
                Icon(Icons.description_outlined, color: p.secondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    file?.name ?? 'No file chosen',
                    key: const ValueKey('keyImport.fileName'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: file == null ? p.muted : p.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _busy || _picking ? null : _pick,
                  child: Text(file == null ? 'Choose file' : 'Change'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _passphraseField(
            key: const ValueKey('keyImport.passphrase'),
            controller: _passphrase,
            label: 'Enter passphrase',
            enabled: !_busy,
            onChanged: () => setState(() {}),
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            _ProgressView(palette: p, progress: progress),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(
              _error!,
              key: const ValueKey('keyImport.error'),
              style: TextStyle(color: error),
            ),
          ],
          const SizedBox(height: 22),
          AccentButton(
            palette: p,
            label: _busy ? 'Importing…' : 'Import',
            icon: Icons.file_download_outlined,
            onPressed: _canImport ? _import : null,
          ),
        ],
      ],
    );
  }
}

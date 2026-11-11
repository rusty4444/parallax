import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'secure_window.dart';
import 'widgets.dart';

/// Keeps a usable recovery phrase in the user's hands *before* bootstrapping.
/// If the SDK leaves a partial identity after a network failure, the user can
/// still repair it without rotating or destroying existing keys.
class CryptoSetupScreen extends StatefulWidget {
  const CryptoSetupScreen({
    super.key,
    required this.backend,
    required this.palette,
    this.setSecureWindow,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final Future<void> Function(bool enabled)? setSecureWindow;

  @override
  State<CryptoSetupScreen> createState() => _CryptoSetupScreenState();
}

class _CryptoSetupScreenState extends State<CryptoSetupScreen> {
  final _confirmation = TextEditingController();
  String? _phrase;
  CryptoSetupResult? _result;
  bool _secureReady = false;
  bool _savedPhrase = false;
  bool _acknowledged = false;
  bool _busy = false;
  bool _attempted = false;
  bool _allowPop = false;
  String? _error;

  Future<void> _setSecure(bool enabled) =>
      (widget.setSecureWindow ?? SecureWindow.setEnabled)(enabled);

  @override
  void initState() {
    super.initState();
    final random = Random.secure();
    _phrase = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    unawaited(_protectScreen());
  }

  Future<void> _protectScreen() async {
    try {
      await _setSecure(true);
      if (mounted) setState(() => _secureReady = true);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = 'Screen protection is unavailable. Setup did not start.',
        );
      }
    }
  }

  @override
  void dispose() {
    _confirmation.clear();
    _confirmation.dispose();
    _phrase = null;
    _result = null;
    unawaited(Future.sync(() => _setSecure(false)).catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _start() async {
    final phrase = _phrase;
    if (!_secureReady ||
        _busy ||
        _attempted ||
        !_savedPhrase ||
        phrase == null ||
        _confirmation.text.trim() != phrase) {
      return;
    }
    setState(() {
      _busy = true;
      _attempted = true;
      _error = null;
    });
    try {
      final result = await widget.backend.createCryptoIdentity(phrase);
      if (mounted) {
        _confirmation.clear();
        setState(() => _result = result);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Setup stopped. Keep your saved phrase. Go back and refresh the '
              'identity status. Repair only if offered; otherwise do not reset '
              'existing keys.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exit() async {
    if (_busy || _allowPop || (!_secureReady && _error == null)) return;
    if (_attempted && _result == null) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Leave incomplete setup?'),
          content: const Text(
            'Keep the phrase you saved. Refresh Settings before trying again; '
            'a partial identity must be repaired, not reset.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Leave'),
            ),
          ],
        ),
      );
      if (leave != true || !mounted) return;
    }
    if (_result != null && !_acknowledged) return;
    setState(() => _allowPop = true);
    Navigator.pop(context, _result?.ready ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exit());
      },
      child: Scaffold(
        body: GlowBackdrop(
          palette: p,
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 40),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: 'Back',
                    onPressed: _busy ? null : _exit,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ),
                const SizedBox(height: 20),
                Eyebrow('Encryption', palette: p),
                const SizedBox(height: 6),
                Text(
                  _result == null
                      ? 'Set up your identity'
                      : 'Save your recovery key',
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 29,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (!_secureReady && _error == null)
                  const Center(child: CircularProgressIndicator()),
                if (_secureReady && _result == null) ...[
                  const Text(
                    'Save this generated phrase outside Parallax before '
                    'continuing. It may help repair a partially completed '
                    'setup and can restore a completed identity on another '
                    'device. Some failures cannot be repaired without another '
                    'trusted client. Never share '
                    'it. Keep other Matrix clients signed out during setup; '
                    'simultaneous setup on another device is not atomic.',
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        _phrase!,
                        style: const TextStyle(fontSize: 18, letterSpacing: 1),
                      ),
                    ),
                  ),
                  CheckboxListTile(
                    value: _savedPhrase,
                    onChanged: _busy || _attempted
                        ? null
                        : (value) =>
                              setState(() => _savedPhrase = value ?? false),
                    title: const Text('I saved this phrase outside the app'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  TextField(
                    controller: _confirmation,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Re-enter the phrase to confirm',
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed:
                        _busy ||
                            _attempted ||
                            !_savedPhrase ||
                            _confirmation.text.trim() != _phrase
                        ? null
                        : _start,
                    icon: const Icon(Icons.lock_outline),
                    label: Text(
                      _busy ? 'Setting up…' : 'Create encryption identity',
                    ),
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Creating secret storage, cross-signing and key backup. '
                        'Keep the app open; this can take a while.',
                      ),
                    ),
                ],
                if (_result case final result?) ...[
                  Text(
                    result.ready
                        ? 'Secret storage, cross-signing and key backup are connected.'
                        : 'The identity was created, but completion could not be '
                              'confirmed. Keep both credentials and refresh Settings.',
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Recovery key (alternative to the phrase you saved):',
                  ),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        result.recoveryKey,
                        style: const TextStyle(fontSize: 18, letterSpacing: 1),
                      ),
                    ),
                  ),
                  CheckboxListTile(
                    value: _acknowledged,
                    onChanged: (value) =>
                        setState(() => _acknowledged = value ?? false),
                    title: const Text('I saved my recovery credentials'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  FilledButton(
                    onPressed: _acknowledged ? _exit : null,
                    child: const Text('Finish setup'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

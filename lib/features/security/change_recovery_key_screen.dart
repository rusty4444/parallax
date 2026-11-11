import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'security_features.dart';
import 'security_ui.dart';

/// Element X "Change recovery key", done as a staged copy-verify-commit
/// rotation. Unlike Element X it needs the current key: SDK 14.1.0 does not
/// cache the private master key, which must move to the new key too.
class ChangeRecoveryKeyScreen extends StatefulWidget {
  const ChangeRecoveryKeyScreen({
    super.key,
    required this.security,
    required this.palette,
    this.setSecureWindow,
  });

  final SecurityFeatures security;
  final AppPalette palette;
  final SetSecureWindow? setSecureWindow;

  @override
  State<ChangeRecoveryKeyScreen> createState() =>
      _ChangeRecoveryKeyScreenState();
}

class _ChangeRecoveryKeyScreenState extends State<ChangeRecoveryKeyScreen>
    with SecureScreenState<ChangeRecoveryKeyScreen> {
  final _current = TextEditingController();
  late final String _phrase = generateRecoveryPhrase();
  bool _phraseReady = false;
  bool _busy = false;
  bool _attempted = false;
  String? _error;
  RecoveryKeyChange? _result;

  @override
  SetSecureWindow? get secureWindowOverride => widget.setSecureWindow;

  @override
  void initState() {
    super.initState();
    protectScreen();
  }

  @override
  void dispose() {
    _current.clear();
    _current.dispose();
    super.dispose();
  }

  bool get _canChange =>
      secureReady &&
      !_busy &&
      _phraseReady &&
      _current.text.trim().isNotEmpty &&
      _result == null;

  Future<void> _change() async {
    if (!_canChange) return;
    setState(() {
      _busy = true;
      _attempted = true;
      _error = null;
    });
    try {
      final result = await widget.security.changeRecoveryKey(
        currentKeyOrPassphrase: _current.text,
        newPassphrase: _phrase,
      );
      if (!mounted) return;
      _current.clear();
      setState(() => _result = result);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error =
            'Your recovery key was not changed. Check the current key or '
            'passphrase and your connection; your old key still works.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final error = Theme.of(context).colorScheme.error;
    final result = _result;
    return PopScope(
      canPop: !_busy && result == null,
      child: Scaffold(
        body: GlowBackdrop(
          palette: p,
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 40),
              children: [
                if (result == null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      tooltip: 'Back',
                      onPressed: _busy
                          ? null
                          : () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  ),
                const SizedBox(height: 16),
                Eyebrow('Recovery', palette: p),
                const SizedBox(height: 6),
                Text(
                  result == null
                      ? 'Change recovery key?'
                      : 'Your new recovery key is now active',
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                if (result != null)
                  RecoveryKeyResult(
                    palette: p,
                    recoveryKey: result.recoveryKey,
                    message: result.oldKeyRetired
                        ? 'Your old recovery key no longer works.'
                        : 'The new key is active, but some secrets are still '
                              'also readable with your old key. Change the '
                              'key again later to finish retiring it.',
                    onDone: () => Navigator.pop(context, true),
                  )
                else if (secureError != null)
                  Text(secureError!, style: TextStyle(color: error))
                else if (!secureReady)
                  const Center(child: CircularProgressIndicator())
                else ...[
                  Text(
                    'After changing your recovery key, your old one will no '
                    'longer work. Every secret is copied to the new key and '
                    'checked before the switch, so an interrupted change '
                    'leaves your current key working. Keep other Matrix '
                    'clients from changing recovery at the same time.',
                    style: TextStyle(color: p.muted, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const ValueKey('security.currentRecovery'),
                    controller: _current,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Current recovery key or passphrase',
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Your new recovery phrase. Do not share this with anyone!',
                    style: TextStyle(color: p.foreground),
                  ),
                  const SizedBox(height: 10),
                  RecoveryPhraseConfirmation(
                    phrase: _phrase,
                    palette: p,
                    enabled: !_busy && !_attempted,
                    onReady: (ready) => setState(() => _phraseReady = ready),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!, style: TextStyle(color: error)),
                  ],
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: _canChange ? _change : null,
                    icon: const Icon(Icons.key_rounded),
                    label: Text(_busy ? 'Changing…' : 'Change recovery key'),
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

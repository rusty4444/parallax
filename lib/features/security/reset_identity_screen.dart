import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'security_features.dart';
import 'security_policy.dart';
import 'security_ui.dart';

/// Element X ResetIdentity: explain, confirm, then wipe and recreate the
/// digital identity behind a typed confirmation and account re-authentication.
/// Pops with `true` once a new identity exists.
class ResetIdentityScreen extends StatefulWidget {
  const ResetIdentityScreen({
    super.key,
    required this.security,
    required this.palette,
    this.setSecureWindow,
    this.openUrl,
  });

  final SecurityFeatures security;
  final AppPalette palette;
  final SetSecureWindow? setSecureWindow;
  final ExternalUrlOpener? openUrl;

  @override
  State<ResetIdentityScreen> createState() => _ResetIdentityScreenState();
}

enum _ResetStage { explain, form, done }

class _ResetIdentityScreenState extends State<ResetIdentityScreen>
    with SecureScreenState<ResetIdentityScreen> {
  final _typed = TextEditingController();
  final _password = TextEditingController();
  late final String _phrase = generateRecoveryPhrase();
  _ResetStage _stage = _ResetStage.explain;
  bool _phraseReady = false;
  bool _busy = false;
  bool _attempted = false;
  String? _error;
  String? _recoveryKey;

  @override
  SetSecureWindow? get secureWindowOverride => widget.setSecureWindow;

  @override
  void dispose() {
    _typed.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(
          'Are you sure you want to reset your digital identity?',
        ),
        content: const Text('This process is irreversible.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes, reset now'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _stage = _ResetStage.form);
    protectScreen();
  }

  bool get _canReset =>
      secureReady && !_busy && _phraseReady && resetConfirmed(_typed.text);

  Future<bool> _approveInBrowser(Uri url) async {
    if (!mounted) return false;
    final open = widget.openUrl ?? openExternalHttpsUrl;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Approve the reset'),
        content: Text(
          'Your account provider needs you to confirm this reset in your '
          'browser (${url.host}). Approve it there, then come back and '
          'continue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel reset'),
          ),
          TextButton(
            onPressed: () => unawaited(open(url)),
            child: const Text('Open browser'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('I’ve approved it'),
          ),
        ],
      ),
    );
    return approved == true;
  }

  Future<void> _reset() async {
    if (!_canReset) return;
    setState(() {
      _busy = true;
      _attempted = true;
      _error = null;
    });
    try {
      final key = await widget.security.resetIdentity(
        newPassphrase: _phrase,
        password: _password.text.isEmpty ? null : _password.text,
        approveInBrowser: _approveInBrowser,
      );
      if (!mounted) return;
      _password.clear();
      setState(() {
        _recoveryKey = key;
        _stage = _ResetStage.done;
      });
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error =
            'The reset did not complete. Check your account password and '
            'connection, then try again. Keep the new phrase you saved: if '
            'the server accepted part of the reset, it will be needed.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final error = Theme.of(context).colorScheme.error;
    return PopScope(
      canPop: !_busy && _stage != _ResetStage.done,
      child: Scaffold(
        body: GlowBackdrop(
          palette: p,
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 40),
              children: [
                if (_stage != _ResetStage.done)
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
                Icon(Icons.restart_alt_rounded, color: error, size: 40),
                const SizedBox(height: 12),
                Eyebrow('Digital identity', palette: p),
                const SizedBox(height: 6),
                Text(
                  switch (_stage) {
                    _ResetStage.explain =>
                      'Can’t confirm? You’ll need to reset your digital '
                          'identity.',
                    _ResetStage.form => 'Reset your digital identity',
                    _ResetStage.done => 'Your digital identity was reset',
                  },
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 18),
                ...switch (_stage) {
                  _ResetStage.explain => _explain(p),
                  _ResetStage.form => _form(p, error),
                  _ResetStage.done => [
                    RecoveryKeyResult(
                      palette: p,
                      recoveryKey: _recoveryKey!,
                      message:
                          'New cross-signing keys, secret storage and key '
                          'storage are set up. Verify your other devices '
                          'again; people you chat with will see that your '
                          'identity was reset.',
                      onDone: () => Navigator.pop(context, true),
                    ),
                  ],
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _explain(AppPalette p) => [
    SecurityCard(
      palette: p,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SecurityBullet(
            palette: p,
            icon: Icons.check_circle_outline,
            text:
                'Your account details, contacts, preferences, and chat list '
                'will be kept',
          ),
          SecurityBullet(
            palette: p,
            icon: Icons.history_toggle_off,
            critical: true,
            text:
                'You will lose any message history that’s stored only on the '
                'server',
          ),
          SecurityBullet(
            palette: p,
            icon: Icons.visibility_outlined,
            critical: true,
            text:
                'Other users will see that your digital identity has been '
                'reset',
          ),
          SecurityBullet(
            palette: p,
            icon: Icons.devices_other_outlined,
            critical: true,
            text: 'Any devices you’re signed in to will need to be reconfirmed',
          ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    Text(
      'Only reset your digital identity if you don’t have access to another '
      'verified device and you don’t have your recovery key.',
      style: TextStyle(color: p.muted, height: 1.4),
    ),
    const SizedBox(height: 22),
    FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.error,
        foregroundColor: Theme.of(context).colorScheme.onError,
        minimumSize: const Size.fromHeight(52),
      ),
      onPressed: _continue,
      child: const Text('Continue'),
    ),
  ];

  List<Widget> _form(AppPalette p, Color error) => [
    if (secureError != null)
      Text(secureError!, style: TextStyle(color: error))
    else if (!secureReady)
      const Center(child: CircularProgressIndicator())
    else ...[
      Text(
        '1. Save a new recovery phrase. It replaces your old recovery key '
        'and is shown before anything changes.',
        style: TextStyle(color: p.foreground),
      ),
      const SizedBox(height: 12),
      RecoveryPhraseConfirmation(
        phrase: _phrase,
        palette: p,
        enabled: !_busy && !_attempted,
        onReady: (ready) => setState(() => _phraseReady = ready),
      ),
      const SizedBox(height: 20),
      Text(
        '2. Type $resetConfirmationWord to confirm you understand this '
        'cannot be undone.',
        style: TextStyle(color: p.foreground),
      ),
      TextField(
        key: const ValueKey('security.resetTyped'),
        controller: _typed,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Type $resetConfirmationWord',
        ),
      ),
      const SizedBox(height: 20),
      Text(
        '3. Enter your account password to continue.',
        style: TextStyle(color: p.foreground),
      ),
      TextField(
        key: const ValueKey('security.resetPassword'),
        controller: _password,
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'Account password',
          helperText:
              'Leave blank if you sign in through a browser; you’ll be asked '
              'to approve the reset there.',
          helperMaxLines: 3,
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 14),
        Text(_error!, style: TextStyle(color: error)),
      ],
      const SizedBox(height: 22),
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: error,
          foregroundColor: Theme.of(context).colorScheme.onError,
          minimumSize: const Size.fromHeight(52),
        ),
        onPressed: _canReset ? _reset : null,
        icon: const Icon(Icons.restart_alt_rounded),
        label: Text(_busy ? 'Resetting…' : 'Reset digital identity'),
      ),
      if (_busy)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            'Creating new cross-signing keys, secret storage and key '
            'storage. Keep Parallax open.',
            style: TextStyle(color: p.muted),
          ),
        ),
    ],
  ];
}

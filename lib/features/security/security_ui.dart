import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_theme.dart';
import '../../secure_window.dart';
import 'security_policy.dart';

typedef SetSecureWindow = Future<void> Function(bool enabled);

/// Opens an https help/approval page outside the app.
typedef ExternalUrlOpener = Future<bool> Function(Uri url);

Future<bool> openExternalHttpsUrl(Uri url) async {
  if (!isSafeApprovalUrl(url)) return false;
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Element X "Learn more" pages.
final identityChangeHelpUrl = Uri.parse('https://element.io/help#encryption18');
final keyStorageHelpUrl = Uri.parse('https://element.io/help#encryption5');

/// A high-entropy phrase the user saves *before* any network write.
String generateRecoveryPhrase([Random? random]) {
  final source = random ?? Random.secure();
  return base64UrlEncode(
    List<int>.generate(32, (_) => source.nextInt(256)),
  ).replaceAll('=', '');
}

/// Rounded surface card matching the settings/login visual language.
class SecurityCard extends StatelessWidget {
  const SecurityCard({
    super.key,
    required this.palette,
    required this.child,
    this.borderColor,
  });
  final AppPalette palette;
  final Widget child;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) => Material(
    // A Material (not a decorated box) so list tiles inside show their ink.
    color: palette.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: BorderSide(color: borderColor ?? palette.stroke),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
}

/// Bullet row used by the reset and key-storage explanations.
class SecurityBullet extends StatelessWidget {
  const SecurityBullet({
    super.key,
    required this.palette,
    required this.icon,
    required this.text,
    this.critical = false,
  });
  final AppPalette palette;
  final IconData icon;
  final String text;
  final bool critical;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 20,
          color: critical
              ? Theme.of(context).colorScheme.error
              : palette.secondary,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: palette.foreground, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

/// Asks for an existing recovery key or passphrase with FLAG_SECURE held
/// until the dialog route has fully gone (reverse animation included).
Future<String?> askRecoveryCredential(
  BuildContext context, {
  SetSecureWindow? setSecureWindow,
  String title = 'Enter your recovery key',
  String description =
      'Make sure nobody can see this screen. If you have a security key or '
      'security phrase, this will work too.',
  String action = 'Continue',
}) async {
  final setSecure = setSecureWindow ?? SecureWindow.setEnabled;
  var protected = false;
  try {
    await setSecure(true);
    protected = true;
    if (!context.mounted) return null;
    final route = DialogRoute<String>(
      context: context,
      builder: (_) => _RecoveryCredentialDialog(
        title: title,
        description: description,
        action: action,
      ),
    );
    final credential = await Navigator.of(context).push(route);
    await route.completed;
    return credential == null || credential.trim().isEmpty ? null : credential;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Screen protection is unavailable.')),
      );
    }
    return null;
  } finally {
    if (protected) {
      try {
        await setSecure(false);
      } catch (_) {
        // Leaving FLAG_SECURE on is safer than exposing a credential.
      }
    }
  }
}

class _RecoveryCredentialDialog extends StatefulWidget {
  const _RecoveryCredentialDialog({
    required this.title,
    required this.description,
    required this.action,
  });
  final String title;
  final String description;
  final String action;

  @override
  State<_RecoveryCredentialDialog> createState() =>
      _RecoveryCredentialDialogState();
}

class _RecoveryCredentialDialogState extends State<_RecoveryCredentialDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.description),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('security.recoveryCredential'),
          controller: _controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          keyboardType: TextInputType.visiblePassword,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Recovery key or passphrase',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _controller.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _controller.text),
        child: Text(widget.action),
      ),
    ],
  );
}

/// Shows a freshly generated recovery phrase and requires the user to save
/// and re-type it. [onReady] reports whether both steps are complete.
class RecoveryPhraseConfirmation extends StatefulWidget {
  const RecoveryPhraseConfirmation({
    super.key,
    required this.phrase,
    required this.palette,
    required this.onReady,
    this.enabled = true,
  });
  final String phrase;
  final AppPalette palette;
  final ValueChanged<bool> onReady;
  final bool enabled;

  @override
  State<RecoveryPhraseConfirmation> createState() =>
      _RecoveryPhraseConfirmationState();
}

class _RecoveryPhraseConfirmationState
    extends State<RecoveryPhraseConfirmation> {
  final _confirmation = TextEditingController();
  bool _saved = false;
  bool _lastReady = false;

  void _update() {
    final ready = _saved && _confirmation.text.trim() == widget.phrase;
    setState(() {});
    if (ready != _lastReady) {
      _lastReady = ready;
      widget.onReady(ready);
    }
  }

  @override
  void dispose() {
    _confirmation.clear();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: p.raised,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.stroke),
          ),
          child: SelectableText(
            widget.phrase,
            key: const ValueKey('security.newPhrase'),
            style: TextStyle(
              color: p.foreground,
              fontSize: 17,
              letterSpacing: 1,
            ),
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _saved,
          onChanged: widget.enabled
              ? (value) {
                  _saved = value ?? false;
                  _update();
                }
              : null,
          title: const Text('I saved this phrase outside Parallax'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        TextField(
          key: const ValueKey('security.phraseConfirmation'),
          controller: _confirmation,
          enabled: widget.enabled,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          onChanged: (_) => _update(),
          decoration: const InputDecoration(
            labelText: 'Re-enter the phrase to confirm',
          ),
        ),
      ],
    );
  }
}

/// Shows the resulting recovery key and requires acknowledgement.
class RecoveryKeyResult extends StatefulWidget {
  const RecoveryKeyResult({
    super.key,
    required this.palette,
    required this.recoveryKey,
    required this.onDone,
    this.message,
  });
  final AppPalette palette;
  final String recoveryKey;
  final String? message;
  final VoidCallback onDone;

  @override
  State<RecoveryKeyResult> createState() => _RecoveryKeyResultState();
}

class _RecoveryKeyResultState extends State<RecoveryKeyResult> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.message != null) ...[
          Text(widget.message!, style: TextStyle(color: p.foreground)),
          const SizedBox(height: 14),
        ],
        Text(
          'Recovery key (works instead of the phrase you saved):',
          style: TextStyle(color: p.muted),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: p.raised,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.stroke),
          ),
          child: SelectableText(
            widget.recoveryKey,
            style: TextStyle(
              color: p.foreground,
              fontSize: 17,
              letterSpacing: 1,
            ),
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _acknowledged,
          onChanged: (value) => setState(() => _acknowledged = value ?? false),
          title: const Text('I saved my recovery credentials'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        FilledButton(
          onPressed: _acknowledged ? widget.onDone : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Holds FLAG_SECURE for the lifetime of a credential screen.
mixin SecureScreenState<T extends StatefulWidget> on State<T> {
  SetSecureWindow? get secureWindowOverride;
  bool secureReady = false;
  String? secureError;
  bool _secureHeld = false;

  Future<void> _set(bool enabled) =>
      (secureWindowOverride ?? SecureWindow.setEnabled)(enabled);

  void protectScreen() {
    unawaited(() async {
      try {
        await _set(true);
        _secureHeld = true;
        if (!mounted) {
          _releaseSecure();
          return;
        }
        setState(() => secureReady = true);
      } catch (_) {
        if (mounted) {
          setState(
            () => secureError =
                'Screen protection is unavailable, so this step did not start.',
          );
        }
      }
    }());
  }

  void _releaseSecure() {
    if (!_secureHeld) return;
    _secureHeld = false;
    unawaited(Future.sync(() => _set(false)).catchError((Object _) {}));
  }

  @override
  void dispose() {
    _releaseSecure();
    super.dispose();
  }
}

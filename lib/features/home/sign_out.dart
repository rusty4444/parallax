import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import 'app_lock/app_lock_controller.dart';
import 'home_features.dart';
import 'settings_widgets.dart';

/// What the sign-out confirmation warns about (Element X LogoutView).
enum SignOutRisk { none, noBackup, unknown }

SignOutRisk signOutRiskFor(CryptoStatus? status) {
  if (status == null) return SignOutRisk.unknown;
  if (!status.initialized || !status.keyBackupEnabled) {
    return SignOutRisk.noBackup;
  }
  return SignOutRisk.none;
}

/// Checks key backup, confirms, then signs out. Returns true once signed out.
/// The app lock PIN is removed with the session, as in Element X.
Future<bool> runSignOutFlow(
  BuildContext context, {
  required ChatBackend backend,
  AppLockController? appLock,
}) async {
  final owner = BackendSessionOwner(backend);
  try {
    final status = backend
        .cryptoStatus()
        .timeout(const Duration(seconds: 15))
        .then<CryptoStatus?>((value) => value, onError: (Object _) => null);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _SignOutDialog(status: status),
    );
    if (confirmed != true || !context.mounted || !owner.isCurrent) {
      return false;
    }
    try {
      await backend.logout();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t sign out. Try again.')),
        );
      }
      return false;
    }
    await appLock?.clear();
    return true;
  } finally {
    owner.release();
  }
}

class _SignOutDialog extends StatelessWidget {
  const _SignOutDialog({required this.status});
  final Future<CryptoStatus?> status;

  @override
  Widget build(BuildContext context) => FutureBuilder<CryptoStatus?>(
    future: status,
    builder: (context, snapshot) {
      final checking = snapshot.connectionState != ConnectionState.done;
      final risk = signOutRiskFor(snapshot.data);
      final (title, body) = checking
          ? ('Sign out?', 'Checking your key backup…')
          : switch (risk) {
              SignOutRisk.none => (
                'Sign out?',
                'Make sure you always have access to another verified device '
                    'or your recovery key to avoid losing your encrypted chat '
                    'history.',
              ),
              SignOutRisk.noBackup => (
                'You’re about to lose access to your encrypted chats',
                'Key backup is not turned on. If you sign out, you’ll need a '
                    'recovery key to confirm your digital identity and restore '
                    'your encrypted chats the next time you sign in. Set up '
                    'recovery in Settings → Encryption first.',
              ),
              SignOutRisk.unknown => (
                'Sign out?',
                'Parallax couldn’t check your key backup. Make sure you have '
                    'your recovery key before signing out, or you may lose '
                    'access to encrypted history.',
              ),
            };
      return AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: checking ? null : () => Navigator.pop(context, true),
            child: Text(
              risk == SignOutRisk.none || checking
                  ? 'Sign out'
                  : 'Sign out anyway',
            ),
          ),
        ],
      );
    },
  );
}

/// Element X "Delete account" (features/deactivation) with password UIA.
class DeactivateAccountScreen extends StatefulWidget {
  const DeactivateAccountScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.features,
    this.appLock,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final AccountFeatures features;
  final AppLockController? appLock;

  @override
  State<DeactivateAccountScreen> createState() =>
      _DeactivateAccountScreenState();
}

class _DeactivateAccountScreenState extends State<DeactivateAccountScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  final _password = TextEditingController();
  bool _erase = false;
  bool _busy = false;
  String? _error;
  AccountManagement? _management;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    try {
      final management = await widget.features.accountManagement();
      if (mounted && _owner.isCurrent) _management = management;
    } catch (_) {
      // Fall back to the password flow; the server decides.
    } finally {
      if (mounted) setState(() => _checked = true);
    }
  }

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _owner.release();
    super.dispose();
  }

  Future<void> _deactivate() async {
    if (_busy || _password.text.isEmpty || !_owner.isCurrent) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete account'),
        content: const Text(
          'Please confirm that you want to delete your account. '
          'This action cannot be undone.',
        ),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_owner.isCurrent) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.features.deactivateAccount(
        password: _password.text,
        eraseMessages: _erase,
      );
    } on UnsupportedAuthentication {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              'Your homeserver needs a different confirmation step. Delete '
              'your account from your provider’s account page instead.';
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t delete your account. Check your password.';
        });
      }
      return;
    }
    _password.clear();
    // The account is gone: clear the local session (server calls may fail).
    try {
      await widget.backend.logout();
    } catch (_) {
      // The homeserver already revoked every session.
    }
    await widget.appLock?.clear();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final error = Theme.of(context).colorScheme.error;
    final delegated = _management?.delegated ?? false;
    Widget bullet(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.remove_circle_outline_rounded, size: 18, color: error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: p.foreground)),
          ),
        ],
      ),
    );
    return SettingsPage(
      palette: p,
      eyebrow: 'Danger zone',
      title: 'Delete account',
      children: [
        Text.rich(
          TextSpan(
            text: 'Deleting your account is ',
            children: [
              TextSpan(
                text: 'irreversible',
                style: TextStyle(color: error, fontWeight: FontWeight.w800),
              ),
              const TextSpan(text: ', it will:'),
            ],
          ),
          style: TextStyle(color: p.foreground, fontSize: 16),
        ),
        const SizedBox(height: 14),
        bullet(
          'Permanently disable your account (you can’t log back in, and your '
          'ID can’t be reused).',
        ),
        bullet('Remove you from all chat rooms.'),
        bullet('Delete your account information from your identity server.'),
        bullet(
          'Make your messages invisible to future members if you choose to '
          'delete them. Existing members can still see them.',
        ),
        const SizedBox(height: 10),
        if (!_checked)
          const Center(child: CircularProgressIndicator())
        else if (delegated)
          SettingsGroup(
            palette: p,
            footer:
                'Your account is managed by your provider, so it must be '
                'deleted there.',
            children: [
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('Open account page'),
                onTap: () {
                  final url = _management?.deactivateUrl();
                  if (url != null) openExternalLink(context, url);
                },
              ),
            ],
          )
        else ...[
          SettingsGroup(
            palette: p,
            children: [
              SwitchListTile(
                title: const Text('Delete all my messages'),
                subtitle: const Text(
                  'Warning: future users may see incomplete conversations.',
                ),
                value: _erase,
                onChanged: _busy ? null : (v) => setState(() => _erase = v),
              ),
            ],
          ),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: const InputDecoration(labelText: 'Password'),
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: TextStyle(color: error)),
            ),
          const SizedBox(height: 18),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: error,
              foregroundColor: Theme.of(context).colorScheme.onError,
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: _busy || _password.text.isEmpty ? null : _deactivate,
            icon: const Icon(Icons.delete_forever_outlined),
            label: Text(_busy ? 'Deleting…' : 'Delete account'),
          ),
        ],
      ],
    );
  }
}

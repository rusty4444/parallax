import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'crypto_setup_policy.dart';
import 'crypto_setup_screen.dart';
import 'feature_settings_scope.dart';
import 'features/home/settings_widgets.dart';
import 'hooks/registry.dart';
import 'secure_window.dart';
import 'widgets.dart';

/// Settings → Security: this device's encryption identity (set up, repair,
/// restore, backed-up history), verification with another device, then the
/// security module's key storage, recovery, room keys and reset.
class SecuritySettingsPage extends StatefulWidget {
  const SecuritySettingsPage({
    super.key,
    required this.backend,
    required this.palette,
    this.setSecureWindow,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final Future<void> Function(bool enabled)? setSecureWindow;

  @override
  State<SecuritySettingsPage> createState() => _SecuritySettingsPageState();
}

class _SecuritySettingsPageState extends State<SecuritySettingsPage> {
  late final _owner = BackendSessionOwner(widget.backend);
  late Future<CryptoStatus> _cryptoFuture;

  /// Other devices, loaded the first time the (collapsed) list is opened:
  /// the lookup queries the server's device keys.
  Future<List<VerificationDevice>>? _devicesFuture;
  bool _devicesExpanded = false;
  bool _restoring = false;
  bool _credentialDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _cryptoFuture = widget.backend.cryptoStatus();
  }

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  void _refreshCrypto() => setState(() {
    _cryptoFuture = widget.backend.cryptoStatus();
    if (_devicesFuture != null) _devicesFuture = widget.backend.ownDevices();
  });

  void _refreshDevices() =>
      setState(() => _devicesFuture = widget.backend.ownDevices());

  void _toggleDevices() => setState(() {
    _devicesExpanded = !_devicesExpanded;
    if (_devicesExpanded) _devicesFuture ??= widget.backend.ownDevices();
  });

  Future<String?> _askRecoveryCredential({
    String title = 'Restore encryption identity',
    String description =
        'Enter your existing recovery key or passphrase. '
        'It will not be saved by Parallax. Never share it.',
  }) async {
    if (!mounted || !_owner.isCurrent || _credentialDialogOpen) return null;
    _credentialDialogOpen = true;
    final setSecure = widget.setSecureWindow ?? SecureWindow.setEnabled;
    var protected = false;
    try {
      await setSecure(true);
      protected = true;
      if (!mounted || !_owner.isCurrent) return null;
      final route = DialogRoute<String>(
        context: context,
        builder: (_) => _RecoveryDialog(title: title, description: description),
      );
      final credential = await Navigator.of(context).push(route);
      // Navigator.push completes at pop, while the dialog can still be visible
      // during its reverse animation. Keep FLAG_SECURE through route disposal.
      await route.completed;
      return credential;
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Screen protection is unavailable.')),
        );
      }
      return null;
    } finally {
      if (protected) {
        try {
          await setSecure(false);
        } catch (_) {
          // Leaving FLAG_SECURE enabled is safer than exposing a credential.
        }
      }
      _credentialDialogOpen = false;
    }
  }

  Future<void> _beginCryptoSetup() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CryptoSetupScreen(
          backend: widget.backend,
          palette: widget.palette,
          setSecureWindow: widget.setSecureWindow,
        ),
      ),
    );
    if (mounted && _owner.isCurrent) _refreshCrypto();
  }

  Future<void> _repairCrypto() async {
    if (!mounted || !_owner.isCurrent || _restoring) return;
    final credential = await _askRecoveryCredential(
      title: 'Repair incomplete identity',
      description:
          'Enter the existing recovery key or passphrase. '
          'This keeps the current secret storage key and never resets it.',
    );
    if (credential == null ||
        credential.trim().isEmpty ||
        !mounted ||
        !_owner.isCurrent) {
      return;
    }
    setState(() => _restoring = true);
    try {
      await widget.backend.repairCryptoIdentity(credential);
      if (mounted && _owner.isCurrent) {
        _refreshCrypto();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Encryption identity repaired.')),
        );
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _refreshCrypto();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Couldn’t repair the identity. Keep your existing recovery key; '
              'nothing was reset.',
            ),
          ),
        );
      }
    } finally {
      if (mounted && _owner.isCurrent) setState(() => _restoring = false);
    }
  }

  /// "Verify with another device": collapsed until tapped, so a long list
  /// of sessions doesn't fill the screen and isn't fetched on every visit.
  Widget _devicesSection(AppPalette p) => Material(
    color: p.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: p.stroke),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const ValueKey('devices-toggle'),
          leading: const Icon(Icons.devices_other_rounded),
          title: const Text('Verify with another device'),
          subtitle: const Text('Your other signed-in devices'),
          trailing: AnimatedRotation(
            turns: _devicesExpanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 200),
            child: const Icon(Icons.expand_more_rounded),
          ),
          onTap: _toggleDevices,
        ),
        if (_devicesExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: FutureBuilder<List<VerificationDevice>>(
              future: _devicesFuture,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return TextButton(
                    onPressed: _refreshDevices,
                    child: const Text('Retry loading devices'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('Loading your other devices…'),
                  );
                }
                final devices = snapshot.data!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (devices.isEmpty)
                      const Text(
                        'No other device found. Sign in on a second client first.',
                      )
                    else
                      for (final device in devices)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(device.name),
                          subtitle: Text(
                            device.verified
                                ? '${device.id} · Verified'
                                : '${device.id} · Not verified',
                          ),
                          trailing: const Icon(Icons.verified_user_outlined),
                          onTap: () => _verifyDevice(device),
                        ),
                    TextButton(
                      onPressed: _refreshDevices,
                      child: const Text('Refresh devices'),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    ),
  );

  Future<void> _verifyDevice(VerificationDevice device) async {
    final userId = widget.backend.userId;
    if (userId == null) return;
    try {
      await widget.backend.startVerification(userId, deviceId: device.id);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t start device verification. Try again.'),
          ),
        );
      }
    }
  }

  Future<void> _restoreCrypto() async {
    if (!mounted || !_owner.isCurrent || _restoring) return;
    final credential = await _askRecoveryCredential();
    if (credential == null ||
        credential.isEmpty ||
        !mounted ||
        !_owner.isCurrent) {
      return;
    }
    setState(() => _restoring = true);
    try {
      await widget.backend.restoreCryptoIdentity(credential);
      if (mounted && _owner.isCurrent) {
        _refreshCrypto();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Encryption identity restored on this device.'),
          ),
        );
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recovery failed. Check your key or passphrase.'),
          ),
        );
      }
    } finally {
      if (mounted && _owner.isCurrent) setState(() => _restoring = false);
    }
  }

  Future<void> _restoreHistory() async {
    if (!mounted || !_owner.isCurrent || _restoring) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore message history?'),
        content: const Text(
          'Downloading backed-up encryption keys may take '
          'time and use mobile data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_owner.isCurrent) return;
    setState(() => _restoring = true);
    try {
      await widget.backend.restoreBackedUpKeys();
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backed-up message keys restored.')),
        );
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t restore backed-up keys.')),
        );
      }
    } finally {
      if (mounted && _owner.isCurrent) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return SettingsPage(
      palette: p,
      eyebrow: 'Keep it yours',
      title: 'Security',
      children: [
        Eyebrow('Encryption', palette: p),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.stroke),
          ),
          child: FutureBuilder<CryptoStatus>(
            future: _cryptoFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snapshot.hasError
                          ? 'Status unavailable'
                          : 'Checking encryption identity…',
                      style: TextStyle(
                        color: p.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (snapshot.hasError)
                      TextButton(
                        onPressed: _refreshCrypto,
                        child: const Text('Retry'),
                      ),
                  ],
                );
              }
              final status = snapshot.data!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    switch (status.setupAvailability) {
                      CryptoSetupAvailability.connected =>
                        'Identity connected on this device',
                      CryptoSetupAvailability.restore =>
                        'Recovery required on this device',
                      CryptoSetupAvailability.create =>
                        'Set up encryption for this new account',
                      CryptoSetupAvailability.repair =>
                        'Finish setting up your existing identity',
                      CryptoSetupAvailability.needsSingleDevice =>
                        'Other devices are signed in',
                      CryptoSetupAvailability.blocked =>
                        'Existing identity needs careful recovery',
                    },
                    style: TextStyle(
                      color: p.foreground,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    status.initialized
                        ? 'Key backup: ${status.keyBackupEnabled ? 'on' : 'off'} · '
                              'Cross-signing: ${status.crossSigningEnabled ? 'on' : 'off'}'
                        : switch (status.setupAvailability) {
                            CryptoSetupAvailability.create =>
                              'Create secret storage, cross-signing and key backup. '
                                  'You must save a recovery phrase first.',
                            CryptoSetupAvailability.repair =>
                              'Use your existing recovery credential to '
                                  'complete setup without rotating keys.',
                            CryptoSetupAvailability.needsSingleDevice =>
                              'New identity setup is only available when '
                                  'this is your sole signed-in device. '
                                  'Sign out other devices, then refresh.',
                            CryptoSetupAvailability.blocked =>
                              'Existing keys or backup cannot be repaired '
                                  'safely here. Keep your recovery phrase; '
                                  'this app will not rotate them automatically.',
                            _ => 'Encryption identity is incomplete.',
                          },
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                  if (status.setupAvailability ==
                      CryptoSetupAvailability.create) ...[
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _restoring ? null : _beginCryptoSetup,
                      icon: const Icon(Icons.add_moderator_outlined),
                      label: const Text('Set up encryption'),
                    ),
                  ],
                  if (status.setupAvailability ==
                      CryptoSetupAvailability.repair) ...[
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _restoring ? null : _repairCrypto,
                      icon: const Icon(Icons.healing_outlined),
                      label: Text(
                        _restoring ? 'Repairing…' : 'Repair with existing key',
                      ),
                    ),
                  ],
                  if (status.setupAvailability ==
                      CryptoSetupAvailability.restore) ...[
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _restoring ? null : _restoreCrypto,
                      icon: const Icon(Icons.key_rounded),
                      label: Text(
                        _restoring ? 'Restoring…' : 'Enter recovery key',
                      ),
                    ),
                  ],
                  if (status.connected && status.keyBackupEnabled) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _restoring ? null : _restoreHistory,
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: const Text('Restore backed-up history'),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        _devicesSection(p),
        ...securitySettingsSectionsFor(
          context,
          SettingsHookContext(backend: widget.backend, palette: p),
        ),
      ],
    );
  }
}

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog({
    this.title = 'Restore encryption identity',
    this.description =
        'Enter your existing recovery key or passphrase. '
        'It will not be saved by Parallax. Never share it.',
  });
  final String title;
  final String description;

  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
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
          controller: _controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
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
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Restore'),
      ),
    ],
  );
}

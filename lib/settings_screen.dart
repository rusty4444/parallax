import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'hooks/registry.dart';
import 'appearance_settings_screen.dart';
import 'feature_settings_scope.dart';
import 'chat_backend.dart';
import 'crypto_setup_policy.dart';
import 'crypto_setup_screen.dart';
import 'push_settings_screen.dart';
import 'secure_window.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.style,
    required this.onThemeChanged,
    this.setSecureWindow,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final VisualTheme style;
  final ValueChanged<VisualTheme> onThemeChanged;
  final Future<void> Function(bool enabled)? setSecureWindow;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  late VisualTheme _style = widget.style;
  late Future<CryptoStatus> _cryptoFuture;
  late Future<List<VerificationDevice>> _devicesFuture;
  bool _restoring = false;
  bool _credentialDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _cryptoFuture = widget.backend.cryptoStatus();
    _devicesFuture = widget.backend.ownDevices();
  }

  void _refreshCrypto() => setState(() {
    _cryptoFuture = widget.backend.cryptoStatus();
    _devicesFuture = widget.backend.ownDevices();
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
          palette: paletteFor(_style),
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

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This removes your local session from this device. '
          'You can sign in again at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_owner.isCurrent) return;
    try {
      await widget.backend.logout();
      if (mounted && _owner.isCurrent) Navigator.pop(context);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t sign out. Try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteFor(_style);
    final features = FeatureSettingsScope.maybeOf(context);
    final preferences = features?.preferences;
    final notifications = features?.notifications;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 34),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const SizedBox(height: 18),
              Eyebrow('Make it yours', palette: p),
              const SizedBox(height: 4),
              Text(
                'Settings',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 38,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.7,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: p.stroke),
                ),
                child: Row(
                  children: [
                    BrandMark(palette: p),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.backend.userId ?? 'Matrix account',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.foreground,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'CONNECTED TO MATRIX',
                            style: TextStyle(
                              color: p.secondary,
                              fontSize: 10,
                              letterSpacing: 1.1,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Eyebrow('Appearance', palette: p),
              if (notifications != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Push notifications'),
                  subtitle: const Text(
                    'Off by default · use your own services',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          PushSettingsScreen(notifications: notifications),
                    ),
                  ),
                ),
              if (preferences != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.text_fields_rounded),
                  title: const Text('Reading and media preferences'),
                  subtitle: const Text(
                    'Text size, compact layout, media previews and read receipts',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          AppearanceSettingsScreen(preferences: preferences),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Text(
                'Pick your frequency',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 13),
              for (final style in VisualTheme.values) ...[
                _ThemeCard(
                  style: style,
                  palette: p,
                  selected: style == _style,
                  onTap: () {
                    setState(() => _style = style);
                    widget.onThemeChanged(style);
                  },
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 28),
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
                              _restoring
                                  ? 'Repairing…'
                                  : 'Repair with existing key',
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
              FutureBuilder<List<VerificationDevice>>(
                future: _devicesFuture,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return TextButton(
                      onPressed: _refreshCrypto,
                      child: const Text('Retry loading devices'),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Text('Loading your other devices…');
                  }
                  final devices = snapshot.data!;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Verify with another device',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      if (devices.isEmpty)
                        const Text(
                          'No other device found. Sign in on a second client first.',
                        )
                      else
                        for (final device in devices)
                          ListTile(
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
                        onPressed: _refreshCrypto,
                        child: const Text('Refresh devices'),
                      ),
                    ],
                  );
                },
              ),
              ...settingsSectionsFor(
                context,
                SettingsHookContext(backend: widget.backend, palette: p),
              ),
              const SizedBox(height: 28),
              OutlinedButton.icon(
                onPressed: _logout,
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Sign out'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: p.foreground,
                  side: BorderSide(color: p.stroke),
                  minimumSize: const Size.fromHeight(54),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Parallax 0.4.0 · Every angle of the conversation.',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
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

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.style,
    required this.palette,
    required this.selected,
    required this.onTap,
  });
  final VisualTheme style;
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = paletteFor(style);
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? palette.accent : palette.stroke,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 53,
                height: 53,
                decoration: BoxDecoration(
                  color: preview.background,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: preview.stroke),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 22,
                      decoration: BoxDecoration(
                        color: preview.accent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Container(
                      width: 12,
                      height: 13,
                      decoration: BoxDecoration(
                        color: preview.secondary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      style.label,
                      style: TextStyle(
                        color: palette.foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      style.caption,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: palette.accent),
            ],
          ),
        ),
      ),
    );
  }
}

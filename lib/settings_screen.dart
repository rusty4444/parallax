import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'features/home/about_screen.dart';
import 'features/home/app_lock/app_lock_gate.dart';
import 'features/home/app_lock/app_lock_settings_screen.dart';
import 'features/home/blocked_users_screen.dart';
import 'features/home/home_features.dart';
import 'features/home/notification_settings_screen.dart';
import 'features/home/profile_screen.dart';
import 'features/home/sessions_screen.dart';
import 'features/home/settings_widgets.dart';
import 'features/home/sign_out.dart';
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
    this.followSystemTheme = false,
    this.onFollowSystemTheme,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final VisualTheme style;
  final ValueChanged<VisualTheme> onThemeChanged;
  final Future<void> Function(bool enabled)? setSecureWindow;

  /// "Match system" is selected; null [onFollowSystemTheme] hides the option.
  final bool followSystemTheme;
  final ValueChanged<bool>? onFollowSystemTheme;

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
  late bool _followSystem = widget.followSystemTheme;
  late Future<CryptoStatus> _cryptoFuture;
  late Future<List<VerificationDevice>> _devicesFuture;
  late final AccountFeatures? _account = accountFeaturesOf(widget.backend);
  Future<HomeProfile>? _profileFuture;
  Future<AccountManagement>? _managementFuture;
  bool _restoring = false;
  bool _credentialDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _cryptoFuture = widget.backend.cryptoStatus();
    _devicesFuture = widget.backend.ownDevices();
    _refreshAccount();
  }

  void _refreshAccount() {
    final account = _account;
    if (account == null) return;
    _profileFuture = account.ownProfile();
    _managementFuture = account.accountManagement();
  }

  Future<void> _push(Widget Function(AppPalette palette) page) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => page(paletteFor(_style))),
    );
    if (mounted && _owner.isCurrent) setState(_refreshAccount);
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
    if (!mounted || !_owner.isCurrent) return;
    final signedOut = await runSignOutFlow(
      context,
      backend: widget.backend,
      appLock: AppLockScope.maybeOf(context),
    );
    if (signedOut && mounted && _owner.isCurrent) Navigator.pop(context);
  }

  Widget _profileCard(AppPalette p) {
    Widget card({
      required Widget avatar,
      required String title,
      String? subtitle,
      VoidCallback? onTap,
    }) => Material(
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: p.stroke),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              avatar,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted, fontSize: 13),
                      ),
                    ],
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
              if (onTap != null)
                Icon(Icons.chevron_right_rounded, color: p.muted),
            ],
          ),
        ),
      ),
    );
    final account = _account;
    final userId = widget.backend.userId ?? 'Matrix account';
    if (account == null) {
      return card(
        avatar: BrandMark(palette: p),
        title: userId,
      );
    }
    return FutureBuilder<HomeProfile>(
      future: _profileFuture,
      builder: (context, snapshot) {
        final profile = snapshot.data ?? HomeProfile(userId: userId);
        return card(
          avatar: ProfileAvatar(
            profile: profile,
            backend: widget.backend,
            palette: p,
          ),
          title: profile.label,
          subtitle: profile.label == profile.userId ? null : profile.userId,
          onTap: () => _push(
            (palette) => ProfileScreen(
              backend: widget.backend,
              palette: palette,
              features: account,
            ),
          ),
        );
      },
    );
  }

  Widget _accountTile(AccountFeatures account) =>
      FutureBuilder<AccountManagement>(
        future: _managementFuture,
        builder: (context, snapshot) {
          final management = snapshot.data;
          if (management?.url case final url?) {
            return ListTile(
              leading: const Icon(Icons.manage_accounts_outlined),
              title: const Text('Manage account'),
              subtitle: Text(url.host),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: () => openExternalLink(context, url),
            );
          }
          return ListTile(
            leading: const Icon(Icons.person_outline_rounded),
            title: const Text('Profile and password'),
            subtitle: const Text('Display name, avatar and password'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _push(
              (palette) => ProfileScreen(
                backend: widget.backend,
                palette: palette,
                features: account,
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final p = paletteFor(_style);
    final features = FeatureSettingsScope.maybeOf(context);
    final preferences = features?.preferences;
    final notifications = features?.notifications;
    final appLock = AppLockScope.maybeOf(context);
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
              _profileCard(p),
              const SizedBox(height: 22),
              if (_account case final account?)
                SettingsGroup(
                  palette: p,
                  title: 'Account',
                  children: [
                    _accountTile(account),
                    ListTile(
                      leading: const Icon(Icons.devices_rounded),
                      title: const Text('Devices'),
                      subtitle: const Text('This and other sessions'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _push(
                        (palette) => SessionsScreen(
                          backend: widget.backend,
                          palette: palette,
                          features: account,
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.block_rounded),
                      title: const Text('Blocked users'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _push(
                        (palette) => BlockedUsersScreen(
                          backend: widget.backend,
                          palette: palette,
                          features: account,
                        ),
                      ),
                    ),
                  ],
                ),
              SettingsGroup(
                palette: p,
                title: 'Notifications',
                children: [
                  if (_account case final account?)
                    ListTile(
                      leading: const Icon(Icons.tune_rounded),
                      title: const Text('Notifications'),
                      subtitle: const Text(
                        'Direct and group chats, mentions, invitations, calls',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _push(
                        (palette) => NotificationSettingsScreen(
                          backend: widget.backend,
                          palette: palette,
                          features: account,
                        ),
                      ),
                    ),
                  if (notifications != null)
                    ListTile(
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
                ],
              ),
              SettingsGroup(
                palette: p,
                title: 'Privacy & security',
                children: [
                  if (appLock != null)
                    ListTile(
                      leading: const Icon(Icons.lock_outline_rounded),
                      title: const Text('Screen lock'),
                      subtitle: Text(
                        appLock.pinSet
                            ? appLock.biometricEnabled
                                  ? 'PIN and biometric unlock'
                                  : 'PIN'
                            : 'Off',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _push(
                        (palette) => AppLockSettingsScreen(
                          controller: appLock,
                          palette: palette,
                        ),
                      ),
                    ),
                  if (preferences != null)
                    ListTile(
                      leading: const Icon(Icons.text_fields_rounded),
                      title: const Text('Reading and media preferences'),
                      subtitle: const Text(
                        'Text size, media previews, read receipts and typing',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AppearanceSettingsScreen(
                            preferences: preferences,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Eyebrow('Appearance', palette: p),
              const SizedBox(height: 8),
              Text(
                'Pick your frequency',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 13),
              if (widget.onFollowSystemTheme != null) ...[
                _ThemeCard(
                  key: const ValueKey('theme-system'),
                  style: visualThemeForBrightness(
                    MediaQuery.platformBrightnessOf(context),
                  ),
                  palette: p,
                  selected: _followSystem,
                  label: 'Match system',
                  caption: 'Parallax or Parallax Day, following your device',
                  onTap: () {
                    setState(() {
                      _followSystem = true;
                      _style = visualThemeForBrightness(
                        MediaQuery.platformBrightnessOf(context),
                      );
                    });
                    widget.onFollowSystemTheme!(true);
                  },
                ),
                const SizedBox(height: 10),
              ],
              for (final style in VisualTheme.values) ...[
                _ThemeCard(
                  style: style,
                  palette: p,
                  selected: !_followSystem && style == _style,
                  onTap: () {
                    setState(() {
                      _style = style;
                      _followSystem = false;
                    });
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
              SettingsGroup(
                palette: p,
                title: 'About & help',
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: const Text('About Parallax'),
                    subtitle: const Text('Version, licences and legal'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        _push((palette) => AboutScreen(palette: palette)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.bug_report_outlined),
                    title: const Text('Report a problem'),
                    trailing: const Icon(Icons.open_in_new_rounded),
                    onTap: () => openExternalLink(context, reportProblemUrl),
                  ),
                ],
              ),
              const SizedBox(height: 10),
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
              if (_account case final account?) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => _push(
                    (palette) => DeactivateAccountScreen(
                      backend: widget.backend,
                      palette: palette,
                      features: account,
                      appLock: appLock,
                    ),
                  ),
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Delete account'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                'Parallax $parallaxVersion · Every angle of the conversation.',
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
    super.key,
    required this.style,
    required this.palette,
    required this.selected,
    required this.onTap,
    this.label,
    this.caption,
  });
  final VisualTheme style;
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;
  final String? label;
  final String? caption;

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
                      label ?? style.label,
                      style: TextStyle(
                        color: palette.foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      caption ?? style.caption,
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

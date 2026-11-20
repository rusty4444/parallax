import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'features/home/about_screen.dart';
import 'features/home/app_lock/app_lock_gate.dart';
import 'features/home/home_features.dart';
import 'features/home/notification_settings_screen.dart';
import 'features/home/profile_screen.dart';
import 'features/home/settings_widgets.dart';
import 'features/home/sign_out.dart';
import 'hooks/registry.dart';
import 'appearance_settings_screen.dart';
import 'feature_settings_scope.dart';
import 'chat_backend.dart';
import 'crypto_setup_policy.dart';
import 'security_settings_page.dart';
import 'settings_pages.dart';
import 'widgets.dart';

/// Top-level Settings: the profile card, then a menu of category pages
/// (Account, Notifications, Appearance, Chats, Media, Privacy, Security,
/// Advanced, About & help) and Sign out. Every setting lives on a category
/// page; nothing is configured directly on this screen.
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
  late final AccountFeatures? _account = accountFeaturesOf(widget.backend);
  Future<HomeProfile>? _profileFuture;

  @override
  void initState() {
    super.initState();
    _cryptoFuture = widget.backend.cryptoStatus();
    _refreshAccount();
  }

  void _refreshAccount() {
    _profileFuture = _account?.ownProfile();
  }

  /// Opens a category page in the current theme, then refreshes the profile
  /// card (and, after [refreshCrypto] pages, the Security summary).
  Future<void> _push(
    Widget Function(AppPalette palette) page, {
    bool refreshCrypto = false,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => page(paletteFor(_style))),
    );
    if (!mounted || !_owner.isCurrent) return;
    setState(() {
      _refreshAccount();
      if (refreshCrypto) _cryptoFuture = widget.backend.cryptoStatus();
    });
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

  /// One menu row that opens a category page.
  Widget _category({
    required Key key,
    required IconData icon,
    required String title,
    required Widget subtitle,
    required VoidCallback onTap,
    Color? iconColor,
  }) => ListTile(
    key: key,
    leading: Icon(icon, color: iconColor),
    title: Text(title),
    subtitle: subtitle,
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );

  /// Security row: says when this device's encryption needs attention.
  Widget _securityRow() => FutureBuilder<CryptoStatus>(
    future: _cryptoFuture,
    builder: (context, snapshot) {
      final availability = snapshot.data?.setupAvailability;
      final attention =
          availability != null &&
          availability != CryptoSetupAvailability.connected;
      return _category(
        key: const ValueKey('settings.security'),
        icon: attention ? Icons.gpp_maybe_outlined : Icons.shield_outlined,
        iconColor: attention ? Theme.of(context).colorScheme.error : null,
        title: 'Security',
        subtitle: Text(switch (availability) {
          CryptoSetupAvailability.restore => 'Recovery required on this device',
          CryptoSetupAvailability.create =>
            'Set up encryption for this account',
          CryptoSetupAvailability.repair => 'Finish setting up your identity',
          CryptoSetupAvailability.needsSingleDevice ||
          CryptoSetupAvailability.blocked => 'Encryption needs attention',
          _ => 'Keys, recovery, verification',
        }),
        onTap: () => _push(
          (palette) => SecuritySettingsPage(
            backend: widget.backend,
            palette: palette,
            setSecureWindow: widget.setSecureWindow,
          ),
          refreshCrypto: true,
        ),
      );
    },
  );

  void _setTheme(VisualTheme style) {
    if (mounted) {
      setState(() {
        _style = style;
        _followSystem = false;
      });
    }
    widget.onThemeChanged(style);
  }

  void _setFollowSystem(bool follow) {
    if (mounted) {
      setState(() {
        _followSystem = follow;
        if (follow) {
          _style = visualThemeForBrightness(
            MediaQuery.platformBrightnessOf(context),
          );
        }
      });
    }
    widget.onFollowSystemTheme?.call(follow);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteFor(_style);
    final features = FeatureSettingsScope.maybeOf(context);
    final preferences = features?.preferences;
    final notifications = features?.notifications;
    final account = _account;
    final hooks = SettingsHookContext(backend: widget.backend, palette: p);
    final hasAccountPage =
        account != null ||
        accountDeviceSettingsRowsFor(context, hooks).isNotEmpty;
    final hasPrivacyPage = PrivacySettingsPage.hasContent(
      context,
      backend: widget.backend,
      palette: p,
      preferences: preferences,
      account: account,
    );
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          minimum: (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
              ? const EdgeInsets.only(top: kDesktopTitleBarHeight)
              : EdgeInsets.zero,
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
              SettingsGroup(
                palette: p,
                children: [
                  if (hasAccountPage)
                    _category(
                      key: const ValueKey('settings.account'),
                      icon: Icons.person_outline_rounded,
                      title: 'Account',
                      subtitle: const Text('Profile, devices, deletion'),
                      onTap: () => _push(
                        (palette) => AccountSettingsPage(
                          backend: widget.backend,
                          palette: palette,
                          account: account,
                        ),
                        refreshCrypto: true,
                      ),
                    ),
                  _category(
                    key: const ValueKey('settings.notifications'),
                    icon: Icons.notifications_outlined,
                    title: 'Notifications',
                    subtitle: notifications == null
                        ? const Text('Chats, mentions and calls')
                        : ListenableBuilder(
                            listenable: notifications,
                            builder: (context, _) => Text(
                              NotificationSettingsScreen.deliverySummary(
                                notifications,
                              ),
                            ),
                          ),
                    onTap: () => _push(
                      (palette) => NotificationSettingsScreen(
                        backend: widget.backend,
                        palette: palette,
                        features: account,
                        deviceRows: notificationSettingsRowsFor(
                          context,
                          SettingsHookContext(
                            backend: widget.backend,
                            palette: palette,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _category(
                    key: const ValueKey('settings.appearance'),
                    icon: Icons.palette_outlined,
                    title: 'Appearance',
                    subtitle: Text(
                      'Theme: ${_followSystem ? 'Match system' : _style.label}',
                    ),
                    onTap: () => _push(
                      (_) => AppearanceSettingsScreen(
                        preferences: preferences,
                        style: _style,
                        onThemeChanged: _setTheme,
                        followSystemTheme: _followSystem,
                        onFollowSystemTheme: widget.onFollowSystemTheme == null
                            ? null
                            : _setFollowSystem,
                      ),
                    ),
                  ),
                  _category(
                    key: const ValueKey('settings.chats'),
                    icon: Icons.chat_bubble_outline_rounded,
                    title: 'Chats',
                    subtitle: const Text('Undo send, reactions, emoji'),
                    onTap: () => _push(
                      (palette) => ChatsSettingsPage(
                        backend: widget.backend,
                        palette: palette,
                        preferences: preferences,
                      ),
                    ),
                  ),
                  _category(
                    key: const ValueKey('settings.media'),
                    icon: Icons.perm_media_outlined,
                    title: 'Media',
                    subtitle: const Text('Thumbnails and upload quality'),
                    onTap: () => _push(
                      (palette) => MediaSettingsPage(
                        backend: widget.backend,
                        palette: palette,
                        preferences: preferences,
                      ),
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                palette: p,
                children: [
                  if (hasPrivacyPage)
                    _category(
                      key: const ValueKey('settings.privacy'),
                      icon: Icons.visibility_off_outlined,
                      title: 'Privacy',
                      subtitle: const Text('Screen lock, read receipts'),
                      onTap: () => _push(
                        (palette) => PrivacySettingsPage(
                          backend: widget.backend,
                          palette: palette,
                          preferences: preferences,
                          account: account,
                        ),
                      ),
                    ),
                  _securityRow(),
                ],
              ),
              SettingsGroup(
                palette: p,
                children: [
                  _category(
                    key: const ValueKey('settings.advanced'),
                    icon: Icons.tune_rounded,
                    title: 'Advanced',
                    subtitle: const Text('Calls, links and server setup'),
                    onTap: () => _push(
                      (palette) => AdvancedSettingsPage(
                        backend: widget.backend,
                        palette: palette,
                      ),
                    ),
                  ),
                  _category(
                    key: const ValueKey('settings.about'),
                    icon: Icons.info_outline_rounded,
                    title: 'About & help',
                    subtitle: const Text('Version, licences, feedback'),
                    onTap: () =>
                        _push((palette) => AboutScreen(palette: palette)),
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

// Settings category pages. The top-level Settings screen
// (lib/settings_screen.dart) is a menu; every setting lives on one of these
// pages, on Appearance (lib/appearance_settings_screen.dart), Notifications
// (lib/features/home/notification_settings_screen.dart) or Security
// (lib/security_settings_page.dart). Feature modules add their rows through
// the per-page hooks in lib/hooks/registry.dart.
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'appearance_preferences.dart';
import 'appearance_settings_screen.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'features/home/app_lock/app_lock_gate.dart';
import 'features/home/app_lock/app_lock_settings_screen.dart';
import 'features/home/blocked_users_screen.dart';
import 'features/home/home_features.dart';
import 'features/home/profile_screen.dart';
import 'features/home/sessions_screen.dart';
import 'features/home/settings_widgets.dart';
import 'features/home/sign_out.dart';
import 'hooks/registry.dart';

/// Settings → Account: profile and password (or the provider's account page),
/// signed-in devices, linking a new device, and deleting the account.
class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({
    super.key,
    required this.backend,
    required this.palette,
    this.account,
  });

  final ChatBackend backend;
  final AppPalette palette;

  /// Profile, devices and deletion are hidden when null.
  final AccountFeatures? account;

  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  late final _owner = BackendSessionOwner(widget.backend);
  Future<AccountManagement>? _managementFuture;

  @override
  void initState() {
    super.initState();
    _managementFuture = widget.account?.accountManagement();
  }

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted && _owner.isCurrent) {
      final management = widget.account?.accountManagement();
      // Block body: an arrow would return the Future to setState.
      setState(() {
        _managementFuture = management;
      });
    }
  }

  Widget _profileTile(AccountFeatures account) =>
      FutureBuilder<AccountManagement>(
        future: _managementFuture,
        builder: (context, snapshot) {
          if (snapshot.data?.url case final url?) {
            // Delegated (OIDC) accounts change their password with the
            // provider; the profile itself is on the Settings profile card.
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
              ProfileScreen(
                backend: widget.backend,
                palette: widget.palette,
                features: account,
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final account = widget.account;
    final error = Theme.of(context).colorScheme.error;
    return SettingsPage(
      palette: p,
      eyebrow: 'Who you are',
      title: 'Account',
      children: [
        if (account != null)
          SettingsGroup(
            palette: p,
            title: 'Profile',
            children: [_profileTile(account)],
          ),
        SettingsGroup(
          palette: p,
          title: 'Devices',
          children: [
            if (account != null)
              ListTile(
                leading: const Icon(Icons.devices_rounded),
                title: const Text('Devices'),
                subtitle: const Text('This and other sessions'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _push(
                  SessionsScreen(
                    backend: widget.backend,
                    palette: p,
                    features: account,
                  ),
                ),
              ),
            ...accountDeviceSettingsRowsFor(
              context,
              SettingsHookContext(backend: widget.backend, palette: p),
            ),
          ],
        ),
        if (account != null)
          SettingsGroup(
            palette: p,
            title: 'Danger zone',
            footer:
                'Deleting your account can’t be undone. To switch accounts, '
                'sign out from the main Settings screen instead.',
            children: [
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: error),
                title: Text('Delete account', style: TextStyle(color: error)),
                subtitle: const Text(
                  'Permanently deactivate your account on this homeserver',
                ),
                onTap: () => _push(
                  DeactivateAccountScreen(
                    backend: widget.backend,
                    palette: p,
                    features: account,
                    appLock: AppLockScope.maybeOf(context),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Settings → Chats: double-tap reaction and haptics, then the feature
/// modules' sending (undo send), chat effects, emoji and saved messages.
class ChatsSettingsPage extends StatelessWidget {
  const ChatsSettingsPage({
    super.key,
    required this.backend,
    required this.palette,
    this.preferences,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final AppearancePreferences? preferences;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final preferences = this.preferences;
    return SettingsPage(
      palette: p,
      eyebrow: 'Say it your way',
      title: 'Chats',
      children: [
        if (preferences != null)
          ListenableBuilder(
            listenable: preferences,
            builder: (context, _) => SettingsGroup(
              palette: p,
              title: 'Touch',
              children: PreferenceRows(
                context,
                preferences,
                palette: p,
              ).touch(),
            ),
          ),
        ...chatSettingsSectionsFor(
          context,
          SettingsHookContext(backend: backend, palette: p),
        ),
      ],
    );
  }
}

/// Settings → Media: when chats load media, and upload quality.
class MediaSettingsPage extends StatelessWidget {
  const MediaSettingsPage({
    super.key,
    required this.backend,
    required this.palette,
    this.preferences,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final AppearancePreferences? preferences;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final preferences = this.preferences;
    return SettingsPage(
      palette: p,
      eyebrow: 'Photos, videos and files',
      title: 'Media',
      children: [
        if (preferences != null)
          ListenableBuilder(
            listenable: preferences,
            builder: (context, _) => SettingsGroup(
              palette: p,
              title: 'In chats',
              children: [
                PreferenceRows(
                  context,
                  preferences,
                  palette: p,
                ).mediaPreviews(),
              ],
            ),
          ),
        ...mediaSettingsSectionsFor(
          context,
          SettingsHookContext(backend: backend, palette: p),
        ),
      ],
    );
  }
}

/// Settings → Privacy: screen lock, what others see (read receipts and
/// typing), invites and blocked users, and the on-device search index.
class PrivacySettingsPage extends StatelessWidget {
  const PrivacySettingsPage({
    super.key,
    required this.backend,
    required this.palette,
    this.preferences,
    this.account,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final AppearancePreferences? preferences;

  /// Blocked users are hidden when null.
  final AccountFeatures? account;

  /// Whether the page has anything to show for this session.
  static bool hasContent(
    BuildContext context, {
    required ChatBackend backend,
    required AppPalette palette,
    AppearancePreferences? preferences,
    AccountFeatures? account,
  }) =>
      preferences != null ||
      account != null ||
      AppLockScope.maybeOf(context) != null ||
      privacySettingsSectionsFor(
        context,
        SettingsHookContext(backend: backend, palette: palette),
      ).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final preferences = this.preferences;
    final account = this.account;
    final appLock = AppLockScope.maybeOf(context);
    Widget page(PreferenceRows? rows) => SettingsPage(
      palette: p,
      eyebrow: 'Your business',
      title: 'Privacy',
      children: [
        if (appLock != null)
          SettingsGroup(
            palette: p,
            title: 'This device',
            children: [
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
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AppLockSettingsScreen(controller: appLock, palette: p),
                  ),
                ),
              ),
            ],
          ),
        if (rows != null)
          SettingsGroup(
            palette: p,
            title: 'Activity',
            children: rows.activity(),
          ),
        SettingsGroup(
          palette: p,
          title: 'Invites and blocking',
          children: [
            ?rows?.inviteAvatars(),
            if (account != null)
              ListTile(
                leading: const Icon(Icons.block_rounded),
                title: const Text('Blocked users'),
                subtitle: const Text('People whose messages you don’t see'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => BlockedUsersScreen(
                      backend: backend,
                      palette: p,
                      features: account,
                    ),
                  ),
                ),
              ),
          ],
        ),
        ...privacySettingsSectionsFor(
          context,
          SettingsHookContext(backend: backend, palette: p),
        ),
      ],
    );
    if (preferences == null) return page(null);
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) =>
          page(PreferenceRows(context, preferences, palette: p)),
    );
  }
}

/// Settings → Advanced: the Element Call service and opening Matrix links.
class AdvancedSettingsPage extends StatelessWidget {
  const AdvancedSettingsPage({
    super.key,
    required this.backend,
    required this.palette,
  });

  final ChatBackend backend;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) => SettingsPage(
    palette: palette,
    eyebrow: 'Under the hood',
    title: 'Advanced',
    children: advancedSettingsSectionsFor(
      context,
      SettingsHookContext(backend: backend, palette: palette),
    ),
  );
}

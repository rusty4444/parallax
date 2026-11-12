import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_avatar.dart';
import 'home_features.dart';
import 'matrix_home_features.dart';
import 'settings_widgets.dart';

/// Round avatar for a user profile (reuses the room avatar loader).
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.profile,
    required this.backend,
    required this.palette,
    this.size = 52,
  });
  final HomeProfile profile;
  final ChatBackend backend;
  final AppPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) => RoomAvatar(
    key: ValueKey(profile.avatarUrl),
    room: ChatRoom(
      id: profile.userId,
      name: profile.label,
      preview: '',
      lastActivity: null,
      avatarUrl: profile.avatarUrl,
    ),
    backend: backend,
    palette: palette,
    size: size,
  );
}

/// Edit display name and avatar; manage account or change password
/// (Element X `features/preferences` user profile + account).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.features,
    this.pickImage,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final AccountFeatures features;

  /// Injected for tests; defaults to the gallery picker.
  final Future<XFile?> Function()? pickImage;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  final _name = TextEditingController();
  HomeProfile? _profile;
  AccountManagement? _management;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _name.dispose();
    _owner.release();
    super.dispose();
  }

  bool _current(int generation) =>
      mounted && _owner.isCurrent && generation == _generation;

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await widget.features.ownProfile();
      if (!_current(generation)) return;
      _profile = profile;
      _name.text = profile.displayName ?? '';
      final management = await widget.features.accountManagement();
      if (!_current(generation)) return;
      _management = management;
    } catch (_) {
      if (_current(generation)) {
        _error = 'Couldn’t load your profile. Check your connection.';
      }
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<bool> _run(Future<void> Function() action, String failure) async {
    if (_saving || !_owner.isCurrent) return false;
    final generation = _generation;
    setState(() => _saving = true);
    try {
      await action();
      if (!_current(generation)) return false;
      unawaited(_load());
      return true;
    } catch (_) {
      if (_current(generation)) _snack(failure);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveName() async {
    final value = _name.text.trim();
    if (value.isEmpty || value == _profile?.displayName) return;
    await _run(
      () => widget.features.setDisplayName(value),
      'Couldn’t update your display name.',
    );
  }

  Future<void> _changeAvatar() async {
    final XFile? file;
    try {
      file =
          await (widget.pickImage?.call() ??
              ImagePicker().pickImage(
                source: ImageSource.gallery,
                maxWidth: 1024,
                maxHeight: 1024,
                imageQuality: 88,
                requestFullMetadata: false,
              ));
    } catch (_) {
      if (mounted) _snack('Couldn’t open your photos.');
      return;
    }
    if (file == null || !mounted || !_owner.isCurrent) return;
    final length = await file.length();
    if (!mounted) return;
    if (length > maxAvatarBytes) {
      _snack('Choose an image smaller than 10 MB.');
      return;
    }
    final bytes = await file.readAsBytes();
    final lower = file.name.toLowerCase();
    final mime = lower.endsWith('.png')
        ? 'image/png'
        : lower.endsWith('.webp')
        ? 'image/webp'
        : lower.endsWith('.gif')
        ? 'image/gif'
        : 'image/jpeg';
    await _run(
      () => widget.features.setAvatar(bytes, name: file!.name, mimeType: mime),
      'Couldn’t update your avatar.',
    );
  }

  Future<bool> _removeAvatar() => _run(
    () => widget.features.setAvatar(null),
    'Couldn’t remove your avatar.',
  );

  Future<void> _changePassword() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (result == null || !mounted) return;
    final changed = await _run(
      () => widget.features.changePassword(
        oldPassword: result.$1,
        newPassword: result.$2,
      ),
      'Couldn’t change your password. Check your current password.',
    );
    if (changed && mounted) _snack('Password changed.');
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final profile = _profile;
    final management = _management;
    return SettingsPage(
      palette: p,
      eyebrow: 'Account',
      title: 'Profile',
      children: [
        if (_loading && profile == null)
          const Center(child: CircularProgressIndicator())
        else if (profile == null)
          SettingsGroup(
            palette: p,
            children: [
              ListTile(
                title: Text(_error ?? 'Profile unavailable'),
                trailing: TextButton(
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
              ),
            ],
          )
        else ...[
          Center(
            child: ProfileAvatar(
              profile: profile,
              backend: widget.backend,
              palette: p,
              size: 96,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: _saving ? null : _changeAvatar,
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Change photo'),
              ),
              if (profile.avatarUrl != null)
                TextButton.icon(
                  onPressed: _saving ? null : _removeAvatar,
                  icon: const Icon(Icons.hide_image_outlined),
                  label: const Text('Remove photo'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _name,
            maxLength: 256,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Display name',
              suffixIcon: IconButton(
                tooltip: 'Save display name',
                onPressed: _saving ? null : _saveName,
                icon: const Icon(Icons.check_rounded),
              ),
            ),
            onSubmitted: (_) => _saveName(),
          ),
          SettingsGroup(
            palette: p,
            children: [
              ListTile(
                leading: const Icon(Icons.alternate_email_rounded),
                title: const Text('Matrix ID'),
                subtitle: SelectableText(profile.userId),
                trailing: IconButton(
                  tooltip: 'Copy Matrix ID',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: profile.userId),
                    );
                    if (mounted) _snack('Matrix ID copied');
                  },
                ),
              ),
            ],
          ),
          SettingsGroup(
            palette: p,
            title: 'Account',
            footer: management == null
                ? null
                : management.delegated
                ? 'Your account is managed by your provider. Change your '
                      'password, email and sessions there.'
                : management.canChangePassword
                ? null
                : 'Your homeserver does not allow password changes here.',
            children: [
              if (management?.url case final url?)
                ListTile(
                  leading: const Icon(Icons.manage_accounts_outlined),
                  title: const Text('Manage account'),
                  subtitle: Text(url.host),
                  trailing: const Icon(Icons.open_in_new_rounded),
                  onTap: () => openExternalLink(context, url),
                ),
              if (management != null &&
                  !management.delegated &&
                  management.canChangePassword)
                ListTile(
                  leading: const Icon(Icons.password_rounded),
                  title: const Text('Change password'),
                  onTap: _saving ? null : _changePassword,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    for (final controller in [_old, _new, _confirm]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  String? get _problem {
    if (_new.text.isEmpty) return null;
    if (_new.text.length < 8) return 'Use at least 8 characters.';
    if (_confirm.text.isNotEmpty && _confirm.text != _new.text) {
      return 'Passwords don’t match.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    TextField field(TextEditingController controller, String label) =>
        TextField(
          controller: controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(labelText: label),
          onChanged: (_) => setState(() {}),
        );
    final ready =
        _old.text.isNotEmpty &&
        _new.text.length >= 8 &&
        _new.text == _confirm.text;
    return AlertDialog(
      title: const Text('Change password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            field(_old, 'Current password'),
            const SizedBox(height: 10),
            field(_new, 'New password'),
            const SizedBox(height: 10),
            field(_confirm, 'Confirm new password'),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _problem!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              'Your other sessions stay signed in.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: ready
              ? () => Navigator.pop(context, (_old.text, _new.text))
              : null,
          child: const Text('Change password'),
        ),
      ],
    );
  }
}

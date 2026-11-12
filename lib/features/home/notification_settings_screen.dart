import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../push_settings_screen.dart';
import 'home_features.dart';
import 'settings_widgets.dart';

/// Global notification rules (Element X NotificationSettingsView): default
/// mode for direct and group chats, @room mentions, invitations and calls.
/// Delivery to this device is configured on the push settings screen.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.features,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final AccountFeatures features;

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  NotificationDefaults? _state;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
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
      final state = await widget.features.notificationDefaults();
      if (_current(generation)) _state = state;
    } catch (_) {
      if (_current(generation)) {
        _error = 'Couldn’t load notification settings.';
      }
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  Future<void> _write(Future<void> Function() change) async {
    if (_saving || !_owner.isCurrent) return;
    setState(() => _saving = true);
    try {
      await change();
      if (!mounted || !_owner.isCurrent) return;
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'An error occurred while updating the notification setting.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    // Re-read: the server is authoritative.
    if (mounted && _owner.isCurrent) await _load();
  }

  Future<void> _chooseMode({required bool direct}) async {
    final state = _state;
    if (state == null) return;
    final current = direct ? state.directChats : state.groupChats;
    final choice = await showModalBottomSheet<NotificationDefaultMode>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: RadioGroup<NotificationDefaultMode>(
          groupValue: current,
          onChanged: (value) => Navigator.pop(sheetContext, value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  direct
                      ? 'On direct chats, notify me for'
                      : 'On group chats, notify me for',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const RadioListTile(
                value: NotificationDefaultMode.allMessages,
                title: Text('All messages'),
              ),
              const RadioListTile(
                value: NotificationDefaultMode.mentionsAndKeywords,
                title: Text('Mentions and keywords only'),
                subtitle: Text(
                  'In encrypted chats your homeserver can’t see mentions, so '
                  'you may not be notified for some of them.',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || choice == current || !mounted) return;
    await _write(
      () => widget.features.setDefaultNotificationMode(
        directChats: direct,
        allMessages: choice == NotificationDefaultMode.allMessages,
      ),
    );
  }

  String _label(NotificationDefaultMode mode) => switch (mode) {
    NotificationDefaultMode.allMessages => 'All messages',
    NotificationDefaultMode.mentionsAndKeywords => 'Mentions and keywords',
  };

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final push = FeatureSettingsScope.maybeOf(context)?.notifications;
    final state = _state;
    return SettingsPage(
      palette: p,
      eyebrow: 'Stay in the loop',
      title: 'Notifications',
      children: [
        SettingsGroup(
          palette: p,
          footer:
              'Parallax delivers notifications itself by staying connected '
              'in the background. The rules below apply to all your devices.',
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Enable notifications on this device'),
              subtitle: Text(
                push == null
                    ? 'Push setup is unavailable right now'
                    : 'On or off, background activity and delivery',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: push == null
                  ? null
                  : () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => PushSettingsScreen(notifications: push),
                      ),
                    ),
            ),
          ],
        ),
        if (_loading && state == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (state == null)
          SettingsGroup(
            palette: p,
            children: [
              ListTile(
                title: Text(_error ?? 'Unavailable'),
                trailing: TextButton(
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
              ),
            ],
          )
        else ...[
          if (state.mismatch)
            SettingsGroup(
              palette: p,
              children: const [
                ListTile(
                  leading: Icon(Icons.info_outline_rounded),
                  title: Text('Configuration mismatch'),
                  subtitle: Text(
                    'Encrypted and unencrypted chats currently use different '
                    'settings. Choosing a mode below applies it to both.',
                  ),
                ),
              ],
            ),
          SettingsGroup(
            palette: p,
            title: 'Notify me for',
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: const Text('Direct chats'),
                subtitle: Text(_label(state.directChats)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _saving ? null : () => _chooseMode(direct: true),
              ),
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Group chats'),
                subtitle: Text(_label(state.groupChats)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _saving ? null : () => _chooseMode(direct: false),
              ),
            ],
          ),
          SettingsGroup(
            palette: p,
            title: 'Mentions',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.campaign_outlined),
                title: const Text('Mentions of @room'),
                value: state.roomMentions,
                onChanged: _saving
                    ? null
                    : (value) => _write(
                        () => widget.features.setNotificationToggle(
                          NotificationToggle.roomMentions,
                          value,
                        ),
                      ),
              ),
            ],
          ),
          SettingsGroup(
            palette: p,
            title: 'Additional settings',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.mail_outline_rounded),
                title: const Text('Invitations'),
                value: state.invitations,
                onChanged: _saving
                    ? null
                    : (value) => _write(
                        () => widget.features.setNotificationToggle(
                          NotificationToggle.invitations,
                          value,
                        ),
                      ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.call_outlined),
                title: const Text('Audio and video calls'),
                value: state.calls,
                onChanged: _saving
                    ? null
                    : (value) => _write(
                        () => widget.features.setNotificationToggle(
                          NotificationToggle.calls,
                          value,
                        ),
                      ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

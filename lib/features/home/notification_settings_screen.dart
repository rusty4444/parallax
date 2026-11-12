import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../push_notifications.dart';
import '../../push_settings_screen.dart';
import 'home_features.dart';
import 'settings_widgets.dart';

/// Settings → Notifications. "This device" links to delivery (the push
/// settings screen) and holds [deviceRows] (notification content). Below it
/// are the account's global rules (Element X NotificationSettingsView):
/// default mode for direct and group chats, @room mentions, invitations and
/// calls. Without [features] only the device settings are shown.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({
    super.key,
    required this.backend,
    required this.palette,
    this.features,
    this.deviceRows = const [],
  });

  final ChatBackend backend;
  final AppPalette palette;
  final AccountFeatures? features;

  /// Extra rows in the "This device" group, such as notification content.
  final List<Widget> deviceRows;

  /// Delivery summary for this device, also shown on the Settings menu.
  static String deliverySummary(PushNotifications push) =>
      push.configuration.isInApp
      ? (push.enabled ? 'On · built in, no Google or push service' : 'Off')
      : '${push.provider.label} · ${push.enabled ? 'on' : 'off'}';

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
    if (widget.features == null) {
      _loading = false;
    } else {
      unawaited(_load());
    }
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
    final features = widget.features;
    if (features == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = await features.notificationDefaults();
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
    final features = widget.features;
    if (choice == null || choice == current || !mounted || features == null) {
      return;
    }
    await _write(
      () => features.setDefaultNotificationMode(
        directChats: direct,
        allMessages: choice == NotificationDefaultMode.allMessages,
      ),
    );
  }

  String _label(NotificationDefaultMode mode) => switch (mode) {
    NotificationDefaultMode.allMessages => 'All messages',
    NotificationDefaultMode.mentionsAndKeywords => 'Mentions and keywords',
  };

  Widget _deliveryRow(PushNotifications? push) {
    Widget tile(String subtitle) => ListTile(
      key: const ValueKey('notifications.device'),
      leading: const Icon(Icons.notifications_active_outlined),
      title: const Text('Enable notifications on this device'),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: push == null
          ? null
          : () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => PushSettingsScreen(notifications: push),
              ),
            ),
    );
    if (push == null) return tile('Push setup is unavailable right now');
    return ListenableBuilder(
      listenable: push,
      builder: (context, _) =>
          tile(NotificationSettingsScreen.deliverySummary(push)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final push = FeatureSettingsScope.maybeOf(context)?.notifications;
    final features = widget.features;
    final state = _state;
    return SettingsPage(
      palette: p,
      eyebrow: 'Stay in the loop',
      title: 'Notifications',
      children: [
        SettingsGroup(
          palette: p,
          title: 'This device',
          children: [_deliveryRow(push), ...widget.deviceRows],
        ),
        if (features == null)
          const SizedBox.shrink()
        else if (_loading && state == null)
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
            footer:
                'These rules are saved to your account, so they apply on all '
                'your devices.',
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
                        () => features.setNotificationToggle(
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
                        () => features.setNotificationToggle(
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
                        () => features.setNotificationToggle(
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

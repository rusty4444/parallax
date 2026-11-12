import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import 'admin_ui.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_models.dart';

/// Element X per-room notification settings, stored as the account's push
/// rules (a `room` rule, or an `override` rule to mute).
class RoomNotificationsScreen extends StatefulWidget {
  const RoomNotificationsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  @override
  State<RoomNotificationsScreen> createState() =>
      _RoomNotificationsScreenState();
}

class _RoomNotificationsScreenState extends State<RoomNotificationsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  RoomNotificationSettings? _settings;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _owner.release();
    super.dispose();
  }

  Future<void> _load() async {
    final admin = _admin;
    final generation = ++_generation;
    if (admin == null) {
      setState(() => _error = 'Notification settings are unavailable.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await admin.notificationSettings(widget.roomId);
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() => _settings = settings);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() {
          _settings = null;
          _error = 'An error occurred while loading notification settings.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _set(RoomNotificationMode? mode) async {
    final admin = _admin;
    if (admin == null || _busy) return;
    setState(() => _busy = true);
    try {
      await admin.setNotificationMode(widget.roomId, mode);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(
          context,
          mode == null
              ? 'Failed restoring the default mode, please try again.'
              : 'Failed setting the mode, please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _owner.isCurrent) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final settings = _settings;
    final idle = !_busy && !_loading;
    return AdminPage(
      palette: p,
      title: 'Notifications',
      busy: _loading || _busy,
      body: settings == null
          ? (_loading
                ? const SizedBox.shrink()
                : AdminPlaceholder(
                    palette: p,
                    icon: Icons.notifications_off_outlined,
                    title: 'Notification settings unavailable',
                    message: _error,
                    onRetry: _admin == null ? null : _load,
                  ))
          : ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                AdminSection(
                  palette: p,
                  footer: 'Turning this on will override your default setting.',
                  children: [
                    SwitchListTile(
                      title: Text(
                        'Allow custom setting',
                        style: TextStyle(
                          color: p.foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      value: !settings.isDefault,
                      onChanged: idle
                          ? (custom) =>
                                _set(custom ? settings.defaultMode : null)
                          : null,
                    ),
                  ],
                ),
                if (settings.isDefault)
                  AdminSection(
                    palette: p,
                    title: 'Default setting',
                    footer:
                        'You can change the default in your global '
                        'notification settings.',
                    children: [
                      AdminTile(
                        palette: p,
                        icon: Icons.notifications_none_rounded,
                        title: settings.defaultMode.label,
                      ),
                    ],
                  )
                else
                  AdminSection(
                    palette: p,
                    title: 'In this room, notify me for',
                    children: [
                      RadioGroup<RoomNotificationMode>(
                        groupValue: settings.customMode,
                        onChanged: (mode) {
                          if (idle && mode != null) _set(mode);
                        },
                        child: Column(
                          children: [
                            for (final mode in RoomNotificationMode.values)
                              RadioListTile<RoomNotificationMode>(
                                value: mode,
                                enabled: idle,
                                title: Text(
                                  mode.label,
                                  style: TextStyle(color: p.foreground),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                if (!settings.isDefault)
                  AdminSection(
                    palette: p,
                    children: [
                      AdminTile(
                        palette: p,
                        icon: Icons.restart_alt_rounded,
                        title: 'Remove custom setting',
                        destructive: true,
                        onTap: idle ? () => _set(null) : null,
                      ),
                    ],
                  ),
              ],
            ),
    );
  }
}

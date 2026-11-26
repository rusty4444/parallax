// "Notification content" settings (Element X notification settings): show
// message content (default on) and media previews (default on). Stored in the
// private notification store so background isolates honour them too.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../settings_sync/settings_sync.dart';
import 'notification_features.dart';
import 'notification_model.dart';
import 'notification_renderer.dart';
import 'notification_store.dart';
import 'rich_push_handler.dart';

class NotificationContentSection extends StatefulWidget {
  const NotificationContentSection({
    super.key,
    required this.palette,
    required this.backend,
    this.openStore,
    this.surface,
  });

  final AppPalette palette;
  final ChatBackend backend;

  /// Defaults to [NotificationStore.open].
  final Future<NotificationStore> Function()? openStore;

  /// Defaults to the plugin; used to clear rich notifications when content
  /// is turned off.
  final NotificationSurface Function()? surface;

  @override
  State<NotificationContentSection> createState() =>
      _NotificationContentSectionState();
}

class _NotificationContentSectionState
    extends State<NotificationContentSection> {
  NotificationStore? _store;
  NotificationPreferences _preferences = const NotificationPreferences();
  bool _loaded = false;
  bool _available = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final store = await (widget.openStore ?? NotificationStore.open)();
      final preferences = await store.readPreferences();
      if (!mounted) return;
      setState(() {
        _store = store;
        _preferences = preferences;
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _available = false;
      });
    }
  }

  Future<void> _save(NotificationPreferences next) async {
    final store = _store;
    if (store == null || _saving) return;
    final previous = _preferences;
    setState(() {
      _preferences = next;
      _saving = true;
    });
    try {
      await store.writePreferences(next);
      SettingsEdits.changed();
      if (previous.showContent && !next.showContent) {
        await _clearRichNotifications(store);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _preferences = previous);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Couldn’t save notification settings.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Content turned off: remove notifications that already show it.
  Future<void> _clearRichNotifications(NotificationStore store) async {
    final features = notificationFeaturesOf(widget.backend);
    final user = features?.userId;
    final device = features?.deviceId;
    if (user == null || device == null) {
      await store.clearHistory();
      return;
    }
    await RichPushHandler(
      store: store,
      surface: (widget.surface ?? PluginNotificationSurface.new)(),
      resolve: (_, _) => Future.value(),
      userId: user,
      deviceId: device,
    ).clearAll();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final enabled = _loaded && _available && !_saving;
    final content = _preferences.showContent;
    // Rows for the Settings "Notifications" group (its card and heading).
    const divider = Divider(height: 1, indent: 16, endIndent: 16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('notifications.showContent'),
          secondary: const Icon(Icons.chat_bubble_outline_rounded),
          title: const Text('Show message content'),
          subtitle: const Text(
            'Sender, message text and room name. When off, '
            'notifications only say you have a new message.',
          ),
          value: content,
          activeThumbColor: p.accent,
          onChanged: enabled
              ? (value) =>
                    unawaited(_save(_preferences.copyWith(showContent: value)))
              : null,
        ),
        divider,
        SwitchListTile(
          key: const ValueKey('notifications.showMedia'),
          secondary: const Icon(Icons.image_outlined),
          title: const Text('Show media previews in notifications'),
          subtitle: const Text(
            'Photos, stickers and video thumbnails, downloaded and '
            'decrypted on this device.',
          ),
          value: content && _preferences.showMediaPreviews,
          activeThumbColor: p.accent,
          onChanged: enabled && content
              ? (value) => unawaited(
                  _save(_preferences.copyWith(showMediaPreviews: value)),
                )
              : null,
        ),
        divider,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Text(
            _available
                ? 'Push notifications carry only room and event IDs. '
                      'Parallax fetches and decrypts each message on this '
                      'device before showing it. On a secure lock screen, '
                      'Android hides notification content when you choose to '
                      'hide sensitive notifications in system settings.'
                : 'Notification settings are unavailable on this device.',
            style: TextStyle(color: p.muted, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

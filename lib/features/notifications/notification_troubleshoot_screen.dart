import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_events.dart';
import '../platform/background_connection.dart';

enum _Status { ok, warn, fail, info, pending }

class _Check {
  _Check(this.title);
  final String title;
  _Status status = _Status.pending;
  String detail = '';
  String? fixLabel;
  Future<void> Function()? onFix;
}

/// Settings → Notifications → Troubleshoot notifications.
class NotificationTroubleshootScreen extends StatefulWidget {
  const NotificationTroubleshootScreen({
    super.key,
    required this.backend,
    required this.palette,
  });

  final ChatBackend backend;
  final AppPalette palette;

  @override
  State<NotificationTroubleshootScreen> createState() =>
      _NotificationTroubleshootScreenState();
}

class _NotificationTroubleshootScreenState
    extends State<NotificationTroubleshootScreen> {
  final _connection = const MethodChannelBackgroundConnection();
  late final List<_Check> _checks = [
    _Check('Notification permission'),
    _Check('Background connection'),
    _Check('Battery optimisation'),
    _Check('Homeserver pushers'),
  ];
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_runAll());
  }

  Future<void> _runAll() async {
    await _checkPermission();
    await _checkConnection();
    await _checkBattery();
    await _checkPushers();
  }

  void _update(
    int i,
    _Status status,
    String detail, {
    String? fixLabel,
    Future<void> Function()? onFix,
  }) {
    if (!mounted) return;
    setState(() {
      _checks[i]
        ..status = status
        ..detail = detail
        ..fixLabel = fixLabel
        ..onFix = onFix;
    });
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

  Future<void> _checkPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      _update(0, _Status.info, 'Managed by the platform on this device.');
      return;
    }
    try {
      final enabled = await _android?.areNotificationsEnabled() ?? false;
      if (enabled) {
        _update(0, _Status.ok, 'Notifications are allowed.');
      } else {
        _update(
          0,
          _Status.fail,
          'Notifications are blocked for Parallax.',
          fixLabel: 'Allow',
          onFix: () async {
            await _android?.requestNotificationsPermission();
            await _checkPermission();
          },
        );
      }
    } catch (_) {
      _update(0, _Status.info, 'Could not read the permission state.');
    }
  }

  Future<void> _checkConnection() async {
    try {
      final running = await _connection.isRunning();
      if (running) {
        _update(1, _Status.ok, 'The background connection is running.');
      } else {
        _update(
          1,
          _Status.warn,
          'The background connection is not running.',
          fixLabel: 'Start',
          onFix: () async {
            await _connection.start();
            await _checkConnection();
          },
        );
      }
    } catch (_) {
      _update(1, _Status.info, 'Not applicable on this platform.');
    }
  }

  Future<void> _checkBattery() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      _update(2, _Status.info, 'No battery optimisation on this platform.');
      return;
    }
    try {
      final exempt = await _connection.isIgnoringBatteryOptimizations();
      if (exempt) {
        _update(2, _Status.ok, 'Parallax is exempt from battery optimisation.');
      } else {
        _update(
          2,
          _Status.warn,
          'Android may stop Parallax in the background.',
          fixLabel: 'Exempt',
          onFix: () async {
            await _connection.requestIgnoreBatteryOptimizations();
            await _checkBattery();
          },
        );
      }
    } catch (_) {
      _update(2, _Status.info, 'Could not read battery optimisation state.');
    }
  }

  Future<void> _checkPushers() async {
    final sdk = widget.backend is MatrixSdkAccess
        ? (widget.backend as MatrixSdkAccess).sdkClient
        : null;
    if (sdk == null) {
      _update(3, _Status.info, 'Sign in to check pushers.');
      return;
    }
    try {
      final pushers = await sdk.getPushers();
      final count = pushers?.length ?? 0;
      if (count > 0) {
        _update(
          3,
          _Status.ok,
          '$count pusher(s) registered with your homeserver.',
        );
      } else {
        _update(
          3,
          _Status.info,
          'No pushers registered — the built-in connection delivers notifications.',
        );
      }
    } catch (_) {
      _update(
        3,
        _Status.warn,
        'Could not reach the homeserver to list pushers.',
      );
    }
  }

  Future<void> _testNotification() async {
    setState(() => _testing = true);
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.show(
        id: 0x7E57,
        title: 'Parallax test notification',
        body: 'If you can see this, notifications are working.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'parallax_troubleshoot_test',
            'Troubleshooting test',
            channelDescription:
                'Test notifications from the troubleshooting screen',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {
      // Best effort.
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  IconData _icon(_Status s) => switch (s) {
    _Status.ok => Icons.check_circle_rounded,
    _Status.warn => Icons.warning_amber_rounded,
    _Status.fail => Icons.error_rounded,
    _Status.info => Icons.info_outline_rounded,
    _Status.pending => Icons.hourglass_top_rounded,
  };

  Color _color(_Status s) {
    final p = widget.palette;
    return switch (s) {
      _Status.ok => Colors.green,
      _Status.warn => Colors.orange,
      _Status.fail => p.accent,
      _Status.info => p.muted,
      _Status.pending => p.muted,
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('Troubleshoot notifications'),
        backgroundColor: p.background,
        actions: [
          IconButton(
            key: const ValueKey('notif-troubleshoot-refresh'),
            tooltip: 'Re-run checks',
            onPressed: () {
              for (final c in _checks) {
                c.status = _Status.pending;
              }
              setState(() {});
              unawaited(_runAll());
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Live checks of how this device receives notifications.',
            style: TextStyle(color: p.muted),
          ),
          const SizedBox(height: 16),
          for (final check in _checks)
            Card(
              color: p.surface,
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: p.stroke),
              ),
              child: ListTile(
                leading: Icon(_icon(check.status), color: _color(check.status)),
                title: Text(check.title, style: TextStyle(color: p.foreground)),
                subtitle: check.detail.isEmpty
                    ? null
                    : Text(
                        check.detail,
                        style: TextStyle(color: p.muted, fontSize: 12.5),
                      ),
                trailing: check.fixLabel == null
                    ? null
                    : TextButton(
                        onPressed: () => unawaited(check.onFix?.call()),
                        child: Text(check.fixLabel!),
                      ),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('notif-troubleshoot-test'),
            onPressed: _testing ? null : _testNotification,
            icon: const Icon(Icons.notifications_active_outlined),
            label: Text(_testing ? 'Sending…' : 'Send test notification'),
          ),
        ],
      ),
    );
  }
}

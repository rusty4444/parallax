// Hook implementations for the bug-report / rageshake module.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_theme.dart';
import '../../hooks/hook_types.dart';
import '../home/about_screen.dart' show parallaxVersion, parallaxBuild;
import '../settings_sync/settings_sync.dart';
import 'bug_report_screen.dart';
import 'diagnostic_log.dart';

class BugReportPreferences {
  static const _key = 'parallax.bug_report.v1.shake';
  static const _channel = MethodChannel('parallax/shake');

  static Future<bool> shakeEnabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setShakeEnabled(bool value) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, value);
    } catch (_) {}
    SettingsEdits.changed();
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': value});
    } on MissingPluginException {
      // Not on Android; the toggle is inert elsewhere.
    } on PlatformException {
      // Best effort.
    }
  }
}

/// Wraps the signed-in app: installs the diagnostic log buffer and routes a
/// detected shake to the problem-report screen.
Widget wrapWithBugReport(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => _BugReportHost(navigatorKey: ctx.navigatorKey, child: child);

class _BugReportHost extends StatefulWidget {
  const _BugReportHost({required this.navigatorKey, required this.child});
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<_BugReportHost> createState() => _BugReportHostState();
}

class _BugReportHostState extends State<_BugReportHost> {
  static const _channel = MethodChannel('parallax/shake');

  @override
  void initState() {
    super.initState();
    DiagnosticLogBuffer.instance.install();
    _channel.setMethodCallHandler(_handle);
    unawaited(_applyShake());
  }

  Future<void> _applyShake() async {
    final enabled = await BugReportPreferences.shakeEnabled();
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // Other platforms.
    } on PlatformException {
      // Best effort.
    }
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method == 'shake') {
      final navigator = widget.navigatorKey.currentState;
      if (navigator != null) {
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => BugReportScreen(
                palette: _fallbackPalette,
                appVersion: '$parallaxVersion ($parallaxBuild)',
              ),
            ),
          ),
        );
      }
    }
    return null;
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// The shake route has no inherited palette; use the brand default.
final AppPalette _fallbackPalette = paletteFor(defaultVisualTheme);

/// Settings → Advanced → problem report and shake-to-report.
List<Widget> bugReportAdvancedSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  return [
    ListTile(
      key: const ValueKey('bug-report-row'),
      leading: const Icon(Icons.bug_report_outlined),
      title: const Text('Report a problem'),
      subtitle: const Text('Describe an issue and attach sanitised logs'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BugReportScreen(
            palette: ctx.palette,
            appVersion: '$parallaxVersion ($parallaxBuild)',
          ),
        ),
      ),
    ),
    const _ShakeToggle(key: ValueKey('bug-shake-toggle')),
  ];
}

class _ShakeToggle extends StatefulWidget {
  const _ShakeToggle({super.key});

  @override
  State<_ShakeToggle> createState() => _ShakeToggleState();
}

class _ShakeToggleState extends State<_ShakeToggle> {
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final enabled = await BugReportPreferences.shakeEnabled();
    if (mounted) setState(() => _enabled = enabled);
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    value: _enabled,
    secondary: const Icon(Icons.vibration_rounded),
    title: const Text('Shake to report a problem'),
    subtitle: const Text('Open the report screen when you shake the phone'),
    onChanged: (value) async {
      setState(() => _enabled = value);
      await BugReportPreferences.setShakeEnabled(value);
    },
  );
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app_theme.dart';
import '../../../widgets.dart';
import '../settings_widgets.dart';
import 'app_lock_controller.dart';
import 'pin_pad.dart';

/// Screen lock settings (Element X LockScreenSettingsView / setup flow).
class AppLockSettingsScreen extends StatelessWidget {
  const AppLockSettingsScreen({
    super.key,
    required this.controller,
    required this.palette,
  });

  final AppLockController controller;
  final AppPalette palette;

  Future<void> _setUp(BuildContext context, {bool change = false}) async {
    if (change) {
      final verified = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PinEntryPage(
            palette: palette,
            title: 'Enter your current PIN',
            onPin: (pin) async {
              if (await controller.verifyPin(pin)) return null;
              // Out of attempts: the lock screen takes over and signs out.
              if (controller.remainingAttempts == 0) controller.lock();
              return controller.remainingAttempts == 0
                  ? 'Too many wrong attempts.'
                  : 'Wrong PIN. ${controller.remainingAttempts} '
                        '${controller.remainingAttempts == 1 ? 'chance' : 'chances'} left';
            },
          ),
        ),
      );
      if (verified != true || !context.mounted) return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PinSetupFlow(controller: controller, palette: palette),
      ),
    );
    if (saved != true || !context.mounted) return;
    await controller.refreshBiometricAvailability();
    if (!context.mounted || change || !controller.biometricAvailable) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.fingerprint_rounded, size: 40),
        title: const Text('Allow biometric unlock'),
        content: const Text(
          'Save yourself some time and use biometric unlock to open the app '
          'each time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('I’d rather use PIN'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Allow biometric unlock'),
          ),
        ],
      ),
    );
    if (allow == true) await controller.setBiometricEnabled(true);
  }

  Future<void> _remove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove PIN?'),
        content: const Text('Are you sure you want to remove PIN?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.removePin();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => SettingsPage(
      palette: palette,
      eyebrow: 'Privacy & security',
      title: 'Screen lock',
      children: [
        if (!controller.pinSet) ...[
          Text(
            'Lock Parallax to add extra security to your chats. Choose '
            'something memorable: if you forget this PIN, you’ll be signed '
            'out.',
            style: TextStyle(color: palette.muted, height: 1.4),
          ),
          const SizedBox(height: 22),
          AccentButton(
            palette: palette,
            label: 'Set up PIN',
            icon: Icons.pin_outlined,
            onPressed: () => _setUp(context),
          ),
        ] else
          SettingsGroup(
            palette: palette,
            footer:
                'Parallax locks after two minutes in the background. After '
                '${AppLockConfig.maxAttempts} wrong PINs you are signed out.',
            children: [
              ListTile(
                leading: const Icon(Icons.pin_outlined),
                title: const Text('Change PIN'),
                onTap: () => _setUp(context, change: true),
              ),
              if (controller.biometricAvailable)
                SwitchListTile(
                  secondary: const Icon(Icons.fingerprint_rounded),
                  title: const Text('Allow biometric unlock'),
                  value: controller.biometricEnabled,
                  onChanged: (value) async {
                    final ok = await controller.setBiometricEnabled(value);
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Biometric unlock wasn’t confirmed.'),
                        ),
                      );
                    }
                  },
                ),
              ListTile(
                leading: Icon(
                  Icons.lock_open_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Remove PIN',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () => _remove(context),
              ),
            ],
          ),
        if (controller.loadError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              controller.loadError!,
              style: TextStyle(color: palette.accent),
            ),
          ),
      ],
    ),
  );
}

/// Choose then confirm a new PIN. Pops true once saved.
class PinSetupFlow extends StatefulWidget {
  const PinSetupFlow({
    super.key,
    required this.controller,
    required this.palette,
  });
  final AppLockController controller;
  final AppPalette palette;

  @override
  State<PinSetupFlow> createState() => _PinSetupFlowState();
}

class _PinSetupFlowState extends State<PinSetupFlow> {
  String? _first;
  String? _message;

  Future<void> _entered(String pin) async {
    final first = _first;
    if (first == null) {
      switch (AppLockController.validatePin(pin)) {
        case PinProblem.forbidden:
          setState(
            () => _message =
                'You cannot choose this as your PIN code for security reasons. '
                'Choose a different PIN.',
          );
          return;
        case PinProblem.length:
          setState(() => _message = 'Enter ${AppLockConfig.pinLength} digits.');
          return;
        case null:
          setState(() {
            _first = pin;
            _message = null;
          });
          return;
      }
    }
    if (pin != first) {
      setState(() {
        _first = null;
        _message = 'PINs don’t match. Please enter the same PIN twice.';
      });
      return;
    }
    try {
      await widget.controller.setPin(pin);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _first = null;
          _message = 'Couldn’t save your PIN. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PinEntryView(
    palette: widget.palette,
    title: _first == null ? 'Choose PIN' : 'Confirm PIN',
    subtitle:
        _message ??
        (_first == null
            ? 'Lock Parallax to add extra security to your chats.'
            : 'Enter the same PIN again.'),
    error: _message != null,
    onCompleted: _entered,
  );
}

/// A full-screen PIN prompt; [onPin] returns an error message or null to pop
/// with true.
class PinEntryPage extends StatefulWidget {
  const PinEntryPage({
    super.key,
    required this.palette,
    required this.title,
    required this.onPin,
  });
  final AppPalette palette;
  final String title;
  final Future<String?> Function(String pin) onPin;

  @override
  State<PinEntryPage> createState() => _PinEntryPageState();
}

class _PinEntryPageState extends State<PinEntryPage> {
  String? _error;

  Future<void> _submit(String pin) async {
    final error = await widget.onPin(pin);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => PinEntryView(
    palette: widget.palette,
    title: widget.title,
    subtitle: _error ?? 'Your PIN keeps Parallax private.',
    error: _error != null,
    onCompleted: _submit,
  );
}

class PinEntryView extends StatelessWidget {
  const PinEntryView({
    super.key,
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.onCompleted,
    this.error = false,
  });
  final AppPalette palette;
  final String title;
  final String subtitle;
  final bool error;
  final Future<void> Function(String pin) onCompleted;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: GlowBackdrop(
      palette: palette,
      child: SafeArea(
        minimum: (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
            ? const EdgeInsets.only(top: kDesktopTitleBarHeight)
            : EdgeInsets.zero,
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back',
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_outline_rounded,
                        size: 40,
                        color: palette.secondary,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        title,
                        style: TextStyle(
                          color: palette.foreground,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: error ? palette.accent : palette.muted,
                        ),
                      ),
                      const SizedBox(height: 28),
                      PinPad(
                        key: ValueKey(title),
                        palette: palette,
                        onCompleted: onCompleted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

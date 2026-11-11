import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_theme.dart';
import '../../../chat_backend.dart';
import '../../../widgets.dart';
import 'app_lock_controller.dart';
import 'pin_pad.dart';

/// Gives settings routes access to the signed-in app lock.
class AppLockScope extends InheritedNotifier<AppLockController> {
  const AppLockScope({
    super.key,
    required AppLockController controller,
    required super.child,
  }) : super(notifier: controller);

  AppLockController get controller => notifier!;

  static AppLockController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLockScope>()?.controller;
}

/// Covers the signed-in app with the PIN/biometric lock screen while locked.
/// The app underneath stays mounted (navigation is preserved) but offstage,
/// with tickers paused.
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.backend,
    required this.palette,
    required this.child,
    this.controller,
    this.createController,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final Widget child;

  /// A borrowed controller (never disposed by the gate).
  final AppLockController? controller;

  /// Creates the controller the gate owns; defaults to platform storage.
  final AppLockController Function()? createController;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  late final AppLockController _controller =
      widget.controller ?? (widget.createController ?? AppLockController.new)();
  late final bool _owns = widget.controller == null;

  bool _wasLocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_lockChanged);
    unawaited(_controller.load());
  }

  void _lockChanged() {
    final locked = _controller.locked;
    // Close the keyboard of whatever was focused under the lock screen.
    if (locked && !_wasLocked) FocusManager.instance.primaryFocus?.unfocus();
    _wasLocked = locked;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _controller.didChangeAppLifecycleState(state);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_lockChanged);
    if (_owns) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppLockScope(
    controller: _controller,
    child: ListenableBuilder(
      listenable: _controller,
      builder: (context, child) {
        final locked = _controller.loaded && _controller.locked;
        return Stack(
          fit: StackFit.expand,
          children: [
            TickerMode(
              enabled: !locked,
              child: Offstage(offstage: locked, child: child),
            ),
            // Visually cover content until the saved lock state is known (a
            // secure-storage read, normally a few milliseconds). Pointer
            // events pass through so a stalled read cannot trap the user.
            if (!_controller.loaded)
              IgnorePointer(
                child: ExcludeSemantics(
                  child: ColoredBox(
                    color: widget.palette.background,
                    child: Center(child: BrandMark(palette: widget.palette)),
                  ),
                ),
              )
            else if (_controller.locked)
              AppLockScreen(
                controller: _controller,
                backend: widget.backend,
                palette: widget.palette,
              ),
          ],
        );
      },
      child: widget.child,
    ),
  );
}

/// Element X lock screen: PIN entry, biometric unlock and "Forgot PIN?".
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({
    super.key,
    required this.controller,
    required this.backend,
    required this.palette,
  });
  final AppLockController controller;
  final ChatBackend backend;
  final AppPalette palette;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  bool _wrong = false;
  bool _confirmSignOut = false;
  bool _signingOut = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Element X prompts for biometrics as soon as the lock screen shows.
    if (widget.controller.biometricEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _biometric());
    }
  }

  Future<void> _biometric() async {
    if (!mounted || _signingOut) return;
    await widget.controller.unlockWithBiometrics();
  }

  Future<void> _submit(String pin) async {
    final ok = await widget.controller.verifyPin(pin);
    if (!mounted) return;
    setState(() => _wrong = !ok);
    if (!ok && widget.controller.remainingAttempts == 0) {
      await _signOut();
    }
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() {
      _signingOut = true;
      _error = null;
    });
    try {
      await widget.backend.logout();
      // Only remove the PIN once the session is gone, so a failed sign-out
      // cannot leave the app unlocked.
      await widget.controller.clear();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _signingOut = false;
        _error = 'Couldn’t sign out. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final remaining = widget.controller.remainingAttempts;
    final subtitle = _signingOut
        ? 'Signing out…'
        : remaining == 0
        ? 'Too many wrong attempts. You need to sign in again.'
        : _wrong
        ? 'Wrong PIN. You have $remaining more '
              '${remaining == 1 ? 'chance' : 'chances'}'
        : 'Enter your PIN to unlock Parallax';
    return Material(
      color: p.background,
      child: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BrandMark(palette: p, size: 64),
                  const SizedBox(height: 18),
                  Text(
                    'Parallax is locked',
                    style: TextStyle(
                      color: p.foreground,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _wrong || remaining == 0 ? p.accent : p.muted,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.accent),
                    ),
                  ],
                  const SizedBox(height: 28),
                  if (_confirmSignOut || remaining == 0)
                    _SignOutPanel(
                      palette: p,
                      busy: _signingOut,
                      forced: remaining == 0,
                      onCancel: () => setState(() => _confirmSignOut = false),
                      onSignOut: _signOut,
                    )
                  else ...[
                    PinPad(
                      palette: p,
                      enabled: !_signingOut,
                      onCompleted: _submit,
                      onBiometric: widget.controller.biometricEnabled
                          ? _biometric
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _signingOut
                          ? null
                          : () => setState(() => _confirmSignOut = true),
                      child: const Text('Forgot PIN?'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SignOutPanel extends StatelessWidget {
  const _SignOutPanel({
    required this.palette,
    required this.busy,
    required this.forced,
    required this.onCancel,
    required this.onSignOut,
  });
  final AppPalette palette;
  final bool busy;
  final bool forced;
  final VoidCallback onCancel;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 420),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: palette.stroke),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          forced ? 'This device is being removed' : 'Forgot your PIN?',
          style: TextStyle(
            color: palette.foreground,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'You’ll need to sign in again and create a new PIN to proceed. '
          'Make sure you have your recovery key so you can read encrypted '
          'history afterwards.',
          style: TextStyle(color: palette.muted, height: 1.4),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy ? null : onSignOut,
          child: Text(busy ? 'Signing out…' : 'Sign out'),
        ),
        if (!forced)
          TextButton(
            onPressed: busy ? null : onCancel,
            child: const Text('Cancel'),
          ),
      ],
    ),
  );
}

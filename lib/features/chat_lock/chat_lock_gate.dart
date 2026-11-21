import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'chat_lock_store.dart';

/// Provides the per-chat lock store to the signed-in UI.
class ChatLockScope extends InheritedNotifier<ChatLockStore> {
  const ChatLockScope({
    super.key,
    required ChatLockStore store,
    required super.child,
  }) : super(notifier: store);

  ChatLockStore get store => notifier!;

  static ChatLockStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatLockScope>()?.store;
}

/// Reveals [child] only once a locked chat has been unlocked this session.
class ChatLockGate extends StatelessWidget {
  const ChatLockGate({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.palette,
    required this.child,
  });

  final String roomId;
  final String roomName;
  final AppPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final store = ChatLockScope.maybeOf(context);
    if (store == null) return child;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.needsUnlock(roomId)) return child;
        return ChatUnlockScreen(
          store: store,
          roomId: roomId,
          roomName: roomName,
          palette: palette,
        );
      },
    );
  }
}

/// Biometric/PIN prompt shown in place of a locked chat's content.
class ChatUnlockScreen extends StatefulWidget {
  const ChatUnlockScreen({
    super.key,
    required this.store,
    required this.roomId,
    required this.roomName,
    required this.palette,
  });

  final ChatLockStore store;
  final String roomId;
  final String roomName;
  final AppPalette palette;

  @override
  State<ChatUnlockScreen> createState() => _ChatUnlockScreenState();
}

class _ChatUnlockScreenState extends State<ChatUnlockScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(widget.store.refreshCredential());
    // Offer biometrics immediately when available.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometrics());
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _tryBiometrics() async {
    if (!mounted || !widget.store.biometricAvailable || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.store.unlockWithBiometrics(widget.roomId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _error = 'Biometric unlock failed. Use your PIN.';
    });
  }

  Future<void> _unlockWithPin() async {
    final pin = _pin.text.trim();
    if (pin.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.store.unlockWithPin(widget.roomId, pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) {
        _error = 'Wrong PIN. Try again.';
        _pin.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final store = widget.store;
    return Scaffold(
      backgroundColor: p.background,
      body: GlowBackdrop(
        palette: p,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_rounded, color: p.secondary, size: 52),
                const SizedBox(height: 16),
                Text(
                  widget.roomName,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text('This chat is locked', style: TextStyle(color: p.muted)),
                const SizedBox(height: 24),
                if (store.biometricAvailable)
                  AccentButton(
                    palette: p,
                    label: 'Unlock with biometrics',
                    icon: Icons.fingerprint_rounded,
                    onPressed: _busy ? null : _tryBiometrics,
                  ),
                if (store.biometricAvailable && store.pinSet)
                  const SizedBox(height: 16),
                if (store.pinSet) ...[
                  TextField(
                    key: const ValueKey('chat-lock-pin'),
                    controller: _pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    enabled: !_busy,
                    onSubmitted: (_) => _unlockWithPin(),
                    decoration: const InputDecoration(
                      labelText: 'PIN',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  AccentButton(
                    key: const ValueKey('chat-lock-unlock'),
                    palette: p,
                    label: _busy ? 'Unlocking…' : 'Unlock',
                    icon: Icons.lock_open_rounded,
                    onPressed: _busy ? null : _unlockWithPin,
                  ),
                ],
                if (!store.canLock)
                  Text(
                    'Set up an app lock PIN in Settings → Security to lock '
                    'chats.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.muted),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: TextStyle(color: p.accent)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

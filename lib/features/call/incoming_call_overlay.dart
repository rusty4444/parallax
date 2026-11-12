// In-app incoming call UI (Element X: IncomingCallScreen). Rings only while
// Parallax is in the foreground and signed in; background/push ringing is
// out of scope.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../widgets.dart';
import 'active_call.dart';
import 'call_features.dart';
import 'call_ringer.dart';
import 'call_screen.dart';

typedef AnswerCall = void Function(IncomingCall call);

class IncomingCallOverlay extends StatefulWidget {
  const IncomingCallOverlay({
    super.key,
    required this.backend,
    required this.palette,
    required this.navigatorKey,
    required this.child,
    this.ringer,
    this.onAnswer,
    this.clock = DateTime.now,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final CallRinger? ringer;

  /// Overrides opening the call screen (tests).
  final AnswerCall? onAnswer;
  final DateTime Function() clock;

  @override
  State<IncomingCallOverlay> createState() => _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends State<IncomingCallOverlay> {
  late final CallRinger _ringer = widget.ringer ?? AudioCallRinger();
  CallFeatures? _features;
  String? _account;
  StreamSubscription<IncomingCall>? _rings;
  StreamSubscription<String>? _changes;
  IncomingCall? _ringing;
  Timer? _expiry;
  bool _sawActive = false;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_resolve);
    ActiveCall.roomId.addListener(_onActiveCall);
    _resolve();
  }

  @override
  void didUpdateWidget(IncomingCallOverlay old) {
    super.didUpdateWidget(old);
    if (!identical(old.backend, widget.backend)) {
      old.backend.removeListener(_resolve);
      widget.backend.addListener(_resolve);
      _resolve();
    }
  }

  void _resolve() {
    final ready = widget.backend.connection != SessionStatus.signedOut;
    final features = ready ? callFeaturesOf(widget.backend) : null;
    final account = widget.backend.userId;
    if (identical(features, _features) && account == _account) return;
    _dismiss();
    unawaited(_rings?.cancel());
    _features = features;
    _account = account;
    _rings = features?.incomingCalls.listen(_onRing);
  }

  void _onActiveCall() {
    // Joining any call (here or from the timeline) stops the ring.
    if (ActiveCall.inCall) _dismiss();
  }

  void _onRing(IncomingCall call) {
    if (!mounted || ActiveCall.inCall || _ringing != null) return;
    final left = call.expiresAt.difference(widget.clock());
    if (left <= Duration.zero) return;
    setState(() {
      _ringing = call;
      _sawActive = false;
    });
    _expiry = Timer(left, _dismiss);
    _changes = _features?.callChanges
        .where((room) => room == call.roomId)
        .listen((_) => _checkCall());
    _checkCall();
    unawaited(_ringer.start());
  }

  void _checkCall() {
    final call = _ringing;
    final features = _features;
    if (call == null || features == null) return;
    final summary = features.roomCall(call.roomId);
    if (summary.includesMe) {
      // Answered on another of this user's devices.
      _dismiss();
    } else if (summary.active) {
      _sawActive = true;
    } else if (_sawActive) {
      // The caller hung up before anyone answered.
      _dismiss();
    }
  }

  void _dismiss() {
    _expiry?.cancel();
    _expiry = null;
    unawaited(_changes?.cancel());
    _changes = null;
    if (_ringing == null) return;
    unawaited(_ringer.stop());
    if (mounted) setState(() => _ringing = null);
  }

  void _answer() {
    final call = _ringing;
    _dismiss();
    if (call == null) return;
    final custom = widget.onAnswer;
    if (custom != null) {
      custom(call);
      return;
    }
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    unawaited(
      openCallScreen(
        navigator.context,
        backend: widget.backend,
        roomId: call.roomId,
        palette: widget.palette,
        navigator: navigator,
        audioOnly: call.audioOnly,
      ),
    );
  }

  void _decline() {
    final call = _ringing;
    final features = _features;
    _dismiss();
    if (call == null || features == null) return;
    unawaited(
      features.declineCall(call.roomId, call.eventId).catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    widget.backend.removeListener(_resolve);
    ActiveCall.roomId.removeListener(_onActiveCall);
    unawaited(_rings?.cancel());
    _expiry?.cancel();
    unawaited(_changes?.cancel());
    unawaited(_ringer.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = _ringing;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (call != null)
          Positioned.fill(
            child: IncomingCallView(
              call: call,
              palette: widget.palette,
              onAnswer: _answer,
              onDecline: _decline,
            ),
          ),
      ],
    );
  }
}

class IncomingCallView extends StatelessWidget {
  const IncomingCallView({
    super.key,
    required this.call,
    required this.palette,
    required this.onAnswer,
    required this.onDecline,
  });

  final IncomingCall call;
  final AppPalette palette;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final showRoom =
        call.roomName.trim().isNotEmpty && call.roomName != call.senderName;
    return Material(
      color: p.background,
      child: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 72, 24, 56),
            child: Column(
              children: [
                Eyebrow(
                  call.audioOnly ? 'Incoming voice call' : 'Incoming call',
                  palette: p,
                ),
                const SizedBox(height: 28),
                InitialAvatar(name: call.senderName, palette: p, size: 112),
                const SizedBox(height: 24),
                Text(
                  call.senderName,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  showRoom ? call.roomName : 'Incoming Element Call',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.muted, fontSize: 16),
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _RoundAction(
                      label: 'Decline',
                      icon: Icons.call_end_rounded,
                      background: ParallaxBrand.crimson,
                      foreground: Colors.white,
                      palette: p,
                      onPressed: onDecline,
                    ),
                    _RoundAction(
                      label: 'Answer',
                      icon: call.audioOnly
                          ? Icons.call_rounded
                          : Icons.videocam_rounded,
                      background: p.secondary,
                      foreground: p.background,
                      palette: p,
                      onPressed: onAnswer,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.palette,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final AppPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Semantics(
        button: true,
        label: label,
        child: SizedBox(
          width: 72,
          height: 72,
          child: FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: background,
              foregroundColor: foreground,
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
            ),
            child: Icon(icon, size: 32),
          ),
        ),
      ),
      const SizedBox(height: 12),
      ExcludeSemantics(
        child: GestureDetector(
          onTap: onPressed,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              label,
              style: TextStyle(
                color: palette.foreground,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

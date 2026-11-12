// Full-screen Element Call (Element X: ElementCallActivity / CallScreenView
// with CallScreenPresenter).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../platform_permissions.dart';
import '../../widgets.dart';
import 'active_call.dart';
import 'call_features.dart';
import 'call_web_host.dart';
import 'widget_driver.dart';

/// Keeps the screen awake during a call. Injectable for tests.
abstract interface class CallScreenKeepAwake {
  Future<void> set(bool enabled);
}

class WakelockKeepAwake implements CallScreenKeepAwake {
  const WakelockKeepAwake();
  @override
  Future<void> set(bool enabled) => WakelockPlus.toggle(enable: enabled);
}

/// Opens the call screen for [roomId] unless another call is on screen.
Future<void> openCallScreen(
  BuildContext context, {
  required ChatBackend backend,
  required String roomId,
  required AppPalette palette,
  NavigatorState? navigator,
  bool audioOnly = false,
}) async {
  final current = ActiveCall.roomId.value;
  if (current != null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          current == roomId
              ? 'This call is already open.'
              : 'You’re already in a call. Leave it first.',
        ),
      ),
    );
    return;
  }
  final nav = navigator ?? Navigator.of(context);
  await nav.push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => CallScreen(
        backend: backend,
        roomId: roomId,
        palette: palette,
        audioOnly: audioOnly,
      ),
    ),
  );
}

enum _Phase { starting, loading, ready, failed }

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.backend,
    required this.roomId,
    required this.palette,
    this.audioOnly = false,
    this.permissions = const PlatformPermissions(),
    this.webHostFactory = createWebViewCallHost,
    this.keepAwake = const WakelockKeepAwake(),
    this.loadTimeout = const Duration(seconds: 30),
    this.hangupGrace = const Duration(seconds: 2),
    this.negotiationFallback = const Duration(seconds: 3),
  });

  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;
  final bool audioOnly;
  final PlatformPermissions permissions;
  final CallWebHostFactory webHostFactory;
  final CallScreenKeepAwake keepAwake;
  final Duration loadTimeout;
  final Duration hangupGrace;
  final Duration negotiationFallback;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  var _phase = _Phase.starting;
  String? _error;
  String? _notice;
  CallWidgetDriver? _driver;
  CallWebHost? _host;
  Timer? _loadTimer;
  Timer? _negotiationFallback;
  Timer? _noticeTimer;
  bool _claimed = false;
  bool _closing = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _claimed = ActiveCall.enter(widget.roomId);
    widget.backend.addListener(_onBackendChanged);
    unawaited(_keepAwake(true));
  }

  /// Sign-out or an account switch ends the call screen immediately.
  void _onBackendChanged() {
    if (!mounted || _closing || _owner.isCurrent) return;
    _driver?.dispose();
    _host?.dispose();
    _close();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final options = CallLaunchOptions(
      language:
          Localizations.maybeLocaleOf(context)?.toLanguageTag() ?? 'en-AU',
      theme: widget.palette.isDark ? 'dark' : 'light',
      fontScale: MediaQuery.textScalerOf(context).scale(14) / 14,
      audioOnly: widget.audioOnly,
    );
    unawaited(_start(options));
  }

  bool get _current => mounted && _owner.isCurrent && !_closing;

  Future<void> _keepAwake(bool enabled) async {
    try {
      await widget.keepAwake.set(enabled);
    } catch (_) {
      // Missing plugin or platform refusal: the call still works.
    }
  }

  Future<void> _start(CallLaunchOptions options) async {
    if (!_claimed) {
      _fail('You’re already in another call. Leave it first.');
      return;
    }
    final features = callFeaturesOf(widget.backend);
    if (features == null) {
      _fail('Calls aren’t available for this account.');
      return;
    }
    Map<String, bool> granted;
    try {
      granted = await widget.permissions.request([
        PlatformPermissions.microphone,
        PlatformPermissions.camera,
      ]);
    } catch (_) {
      granted = const {};
    }
    if (!_current) return;
    final microphone = granted[PlatformPermissions.microphone] ?? false;
    final camera = granted[PlatformPermissions.camera] ?? false;
    if (!microphone) {
      _fail(
        'Parallax needs microphone access for calls. Allow it in Android '
        'settings, then try again.',
      );
      return;
    }
    final CallLaunch launch;
    try {
      launch = await features.prepareCall(widget.roomId, options);
    } catch (error) {
      if (_current) _fail(_describe(error));
      return;
    }
    if (!_current) {
      launch.matrix.dispose();
      return;
    }
    final host = widget.webHostFactory(
      page: launch.url,
      background: widget.palette.background,
      allowCamera: camera,
      allowMicrophone: microphone,
      onMessage: (message) => _driver?.handleMessage(message),
      onLoadError: _onLoadError,
      onPageFinished: _onPageFinished,
    );
    _host = host;
    _driver = CallWidgetDriver(
      widgetId: launch.widgetId,
      matrix: launch.matrix,
      allowedCapabilities: launch.allowedCapabilities,
      send: (json) => unawaited(host.post(json)),
      onContentLoaded: _onContentLoaded,
      onClose: _close,
    );
    setState(() => _phase = _Phase.loading);
    if (!camera) _showNotice('Camera access is off, so others won’t see you.');
    _loadTimer = Timer(widget.loadTimeout, () {
      if (_current && _phase == _Phase.loading) {
        _fail('Element Call took too long to load. Check your connection.');
      }
    });
    try {
      await host.load(launch.url);
    } catch (_) {
      if (_current) _fail('Element Call couldn’t be opened.');
    }
  }

  void _showNotice(String text) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  String _describe(Object error) => switch (error) {
    StateError(:final message) => message,
    _ => 'Couldn’t start the call. Check your connection and try again.',
  };

  void _onContentLoaded() {
    _loadTimer?.cancel();
    _negotiationFallback?.cancel();
    if (_current && _phase == _Phase.loading) {
      setState(() => _phase = _Phase.ready);
    }
  }

  /// Shows Element Call once its page has loaded (it renders its own
  /// progress from there) and, if `content_loaded` never arrives, starts
  /// the widget API handshake from this side.
  void _onPageFinished() {
    if (!_current || _phase != _Phase.loading) return;
    _loadTimer?.cancel();
    setState(() => _phase = _Phase.ready);
    _negotiationFallback?.cancel();
    _negotiationFallback = Timer(widget.negotiationFallback, () {
      if (_current) _driver?.startIfIdle();
    });
  }

  void _onLoadError(String description) {
    // Once Element Call is running it recovers from sub-resource errors
    // itself (Element X ignores WebView errors after the first message).
    if (_current && _phase == _Phase.loading) {
      _fail('Element Call couldn’t be loaded ($description).');
    }
  }

  void _fail(String message) {
    _loadTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _error = message;
    });
  }

  /// Element X: hang up through the widget when joined, then close after a
  /// short grace period even if Element Call never answers.
  Future<void> _leave() async {
    if (_closing) return;
    final driver = _driver;
    if (driver != null && driver.negotiated && _phase == _Phase.ready) {
      _showNotice('Leaving the call…');
      await Future.any([
        driver.hangUp(),
        Future<void>.delayed(widget.hangupGrace),
      ]);
    }
    _close();
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    _loadTimer?.cancel();
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route == null) return;
    // pop() bypasses PopScope. A dialog above (e.g. "Leave the call?") is
    // closed too when Element Call closes itself.
    if (!route.isActive) return;
    navigator.popUntil((r) => r == route);
    navigator.pop();
  }

  Future<void> _confirmLeave() async {
    if (_phase != _Phase.ready) {
      _close();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave the call?'),
        content: const Text('You can rejoin while the call is still going.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) await _leave();
  }

  @override
  void dispose() {
    widget.backend.removeListener(_onBackendChanged);
    _loadTimer?.cancel();
    _negotiationFallback?.cancel();
    _noticeTimer?.cancel();
    _driver?.dispose();
    _host?.dispose();
    if (_claimed) ActiveCall.leave(widget.roomId);
    unawaited(_keepAwake(false));
    _owner.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final host = _host;
    return PopScope(
      canPop: _closing || _phase == _Phase.failed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: Scaffold(
        backgroundColor: p.background,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (host != null && _phase != _Phase.failed) host.build(context),
              if (_phase == _Phase.starting || _phase == _Phase.loading)
                _CallStatusPanel(
                  palette: p,
                  title: 'Connecting to Element Call…',
                  onClose: _close,
                ),
              if (_phase == _Phase.failed)
                _CallStatusPanel(
                  palette: p,
                  title: 'Call unavailable',
                  message: _error,
                  onClose: _close,
                  failed: true,
                ),
              if (_notice != null && _phase != _Phase.failed)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: _Notice(palette: p, text: _notice!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallStatusPanel extends StatelessWidget {
  const _CallStatusPanel({
    required this.palette,
    required this.title,
    required this.onClose,
    this.message,
    this.failed = false,
  });

  final AppPalette palette;
  final String title;
  final String? message;
  final VoidCallback onClose;
  final bool failed;

  @override
  Widget build(BuildContext context) => GlowBackdrop(
    palette: palette,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Eyebrow('Element Call', palette: palette),
            const SizedBox(height: 18),
            if (failed)
              Icon(Icons.videocam_off_rounded, size: 46, color: palette.accent)
            else
              CircularProgressIndicator(color: palette.accent),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.foreground,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 10),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.muted, height: 1.4),
              ),
            ],
            const SizedBox(height: 24),
            failed
                ? AccentButton(
                    palette: palette,
                    label: 'Close',
                    icon: Icons.close_rounded,
                    onPressed: onClose,
                  )
                : TextButton(onPressed: onClose, child: const Text('Cancel')),
          ],
        ),
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.palette, required this.text});
  final AppPalette palette;
  final String text;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.stroke),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: palette.foreground, fontSize: 13),
      ),
    ),
  );
}

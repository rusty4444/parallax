import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../crypto_setup_policy.dart';
import '../../crypto_setup_screen.dart';
import '../../widgets.dart';
import 'reset_identity_screen.dart';
import 'security_features.dart';
import 'security_policy.dart';
import 'security_ui.dart';

/// Post-login session verification gate (Element X ftue
/// ChooseSelfVerificationMode + verifysession).
///
/// While the check runs, or if it fails (offline), the app stays usable.
/// Once the account is known to have an identity this device is not part of,
/// a full-screen "Confirm your digital identity" covers the app. Unlike
/// Element X, "Later" is allowed for this app session, with the trade-offs
/// spelled out; the gate returns at the next launch.
class SecurityGate extends StatefulWidget {
  const SecurityGate({
    super.key,
    required this.backend,
    required this.security,
    required this.palette,
    required this.child,
    this.setSecureWindow,
    this.openUrl,
    this.retryDelay = const Duration(seconds: 15),
  });

  final ChatBackend backend;
  final SecurityFeatures security;
  final AppPalette palette;
  final Widget child;
  final SetSecureWindow? setSecureWindow;
  final ExternalUrlOpener? openUrl;
  final Duration retryDelay;

  @override
  State<SecurityGate> createState() => _SecurityGateState();
}

class _SecurityGateState extends State<SecurityGate> {
  final _gateNavigator = GlobalKey<NavigatorState>();
  // MaterialApp's HeroController belongs to the app navigator; a nested
  // navigator must not share it.
  final _heroController = MaterialApp.createMaterialHeroController();
  final _revision = ValueNotifier<int>(0);
  String? _sessionKey;
  int _generation = 0;
  SessionSecurityState? _state;
  bool _loading = false;
  int _failures = 0;
  Timer? _retry;
  bool _wasLocked = false;
  bool _released = false;
  bool _showVerified = false;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_changed);
    widget.security.securityChanges.addListener(_changed);
    _changed(notify: false);
  }

  @override
  void didUpdateWidget(covariant SecurityGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      oldWidget.backend.removeListener(_changed);
      widget.backend.addListener(_changed);
    }
    if (!identical(oldWidget.security, widget.security)) {
      oldWidget.security.securityChanges.removeListener(_changed);
      widget.security.securityChanges.addListener(_changed);
      _sessionKey = null;
      // The framework rebuilds after didUpdateWidget; refresh state quietly.
      _changed(notify: false);
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    widget.backend.removeListener(_changed);
    widget.security.securityChanges.removeListener(_changed);
    _revision.dispose();
    _heroController.dispose();
    super.dispose();
  }

  void _changed({bool notify = true}) {
    if (!mounted) return;
    final security = widget.security;
    final key = security.sessionKey;
    if (key != _sessionKey) {
      _sessionKey = key;
      _generation++;
      _retry?.cancel();
      _state = null;
      _failures = 0;
      _wasLocked = false;
      _released = false;
      _showVerified = false;
      if (key != null) unawaited(_load());
    }
    security.observeKnownIdentities();
    final step = _step;
    final locked =
        step == SecurityGateStep.confirmIdentity ||
        step == SecurityGateStep.setUpEncryption;
    if (_wasLocked && !locked && !_released) {
      if (security.thisDeviceVerified) {
        _showVerified = true;
      } else {
        _released = true;
      }
    }
    final signature = (step, _showVerified, _released, _state);
    final changed = signature != _lastSignature;
    _lastSignature = signature;
    _wasLocked = locked || _showVerified;
    // Sync notifications are frequent; rebuild only when the gate changes or
    // is showing (its buttons depend on live state).
    if (notify && (changed || _wasLocked)) _refresh();
  }

  Object? _lastSignature;

  void _refresh() {
    if (!mounted) return;
    _revision.value++;
    setState(() {});
  }

  SecurityGateStep get _step => _released
      ? SecurityGateStep.unlocked
      : decideSecurityGate(
          encryptionAvailable: widget.security.encryptionAvailable,
          deviceVerified: widget.security.thisDeviceVerified,
          deferred: widget.security.verificationDeferred,
          state: _state,
        );

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final generation = _generation;
    try {
      final state = await widget.security.loadSessionState();
      if (!mounted || generation != _generation) return;
      _state = state;
      _failures = 0;
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _failures++;
      // Never trap an offline user; retry a few times in the background.
      if (_failures <= 3) {
        _retry?.cancel();
        _retry = Timer(widget.retryDelay * _failures, () {
          if (mounted && generation == _generation) unawaited(_load());
        });
      }
    } finally {
      if (generation == _generation) _loading = false;
    }
    if (mounted && generation == _generation) _changed();
  }

  void _continueAfterVerified() {
    _showVerified = false;
    _released = true;
    _wasLocked = false;
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final step = _step;
    final locked =
        _showVerified ||
        step == SecurityGateStep.confirmIdentity ||
        step == SecurityGateStep.setUpEncryption;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: locked,
          child: TickerMode(enabled: !locked, child: widget.child),
        ),
        if (locked)
          Positioned.fill(
            child: HeroControllerScope(
              controller: _heroController,
              child: Navigator(
                key: _gateNavigator,
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => ValueListenableBuilder<int>(
                    valueListenable: _revision,
                    builder: (context, _, _) => _showVerified
                        ? _DeviceVerifiedPage(
                            palette: widget.palette,
                            onContinue: _continueAfterVerified,
                          )
                        : SecurityConfirmationPage(
                            backend: widget.backend,
                            security: widget.security,
                            palette: widget.palette,
                            state: _state,
                            onRefresh: _load,
                            onLater: widget.security.deferVerification,
                            setSecureWindow: widget.setSecureWindow,
                            openUrl: widget.openUrl,
                          ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _DeviceVerifiedPage extends StatelessWidget {
  const _DeviceVerifiedPage({required this.palette, required this.onContinue});
  final AppPalette palette;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: GlowBackdrop(
          palette: p,
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.verified_user_rounded,
                        color: p.secondary,
                        size: 56,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Device verified',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: p.foreground,
                          fontSize: 29,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Now you can read or send messages securely, and '
                        'anyone you chat with can also trust this device.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: p.muted, height: 1.4),
                      ),
                      const SizedBox(height: 28),
                      AccentButton(
                        palette: p,
                        label: 'Continue',
                        onPressed: onContinue,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Confirm your digital identity" / "Set up secure messaging" content, used
/// by the gate and by Settings → "Verify this device".
class SecurityConfirmationPage extends StatefulWidget {
  const SecurityConfirmationPage({
    super.key,
    required this.backend,
    required this.security,
    required this.palette,
    required this.state,
    required this.onRefresh,
    this.onLater,
    this.onClose,
    this.setSecureWindow,
    this.openUrl,
  });

  final ChatBackend backend;
  final SecurityFeatures security;
  final AppPalette palette;
  final SessionSecurityState? state;
  final Future<void> Function() onRefresh;

  /// Shown as "Later" (with a warning) when non-null.
  final VoidCallback? onLater;

  /// Shown as a back button when non-null (settings route).
  final VoidCallback? onClose;
  final SetSecureWindow? setSecureWindow;
  final ExternalUrlOpener? openUrl;

  @override
  State<SecurityConfirmationPage> createState() =>
      _SecurityConfirmationPageState();
}

class _SecurityConfirmationPageState extends State<SecurityConfirmationPage> {
  bool _busy = false;
  bool _waitingForDevice = false;
  String? _message;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error ??=
              'That didn’t work. Check your connection and try '
              'again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useAnotherDevice() => _run(() async {
    await widget.security.startSelfVerification();
    if (mounted) setState(() => _waitingForDevice = true);
  });

  Future<void> _useRecoveryKey() async {
    if (_busy) return;
    final credential = await askRecoveryCredential(
      context,
      setSecureWindow: widget.setSecureWindow,
    );
    if (credential == null || !mounted) return;
    await _run(() async {
      try {
        await widget.security.confirmWithRecoveryKey(credential);
      } catch (_) {
        if (mounted) {
          setState(
            () => _error =
                'Incorrect recovery key, or the identity couldn’t be '
                'confirmed. Please try again.',
          );
        }
        rethrow;
      }
      if (!mounted) return;
      if (!widget.security.thisDeviceVerified) {
        setState(
          () => _message =
              'Recovery key confirmed. Waiting for this device’s new '
              'signature to sync…',
        );
        await widget.onRefresh();
      }
    });
  }

  Future<void> _setUp() async {
    if (_busy) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CryptoSetupScreen(
          backend: widget.backend,
          palette: widget.palette,
          setSecureWindow: widget.setSecureWindow,
        ),
      ),
    );
    if (mounted) await widget.onRefresh();
  }

  Future<void> _reset() async {
    if (_busy) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ResetIdentityScreen(
          security: widget.security,
          palette: widget.palette,
          setSecureWindow: widget.setSecureWindow,
          openUrl: widget.openUrl,
        ),
      ),
    );
    if (mounted) await widget.onRefresh();
  }

  Future<void> _later() async {
    final onLater = widget.onLater;
    if (onLater == null || _busy) return;
    final skip = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm later?'),
        content: const Text(
          'Element X requires this step; Parallax lets you continue for now. '
          'Until you confirm, this device can’t read encrypted history from '
          'your other devices or key storage, and people you chat with may '
          'see it as unverified. You’ll be asked again next time you open '
          'Parallax, or confirm any time in Settings → Security.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue without confirming'),
          ),
        ],
      ),
    );
    if (skip == true && mounted) onLater();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final state = widget.state;
    final hasIdentity = state?.accountHasIdentity ?? true;
    final availability = state?.setupAvailability;
    return PopScope(
      canPop: widget.onClose != null && !_busy,
      child: Scaffold(
        body: GlowBackdrop(
          palette: p,
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 20, 28, 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.onClose != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            tooltip: 'Back',
                            onPressed: _busy ? null : widget.onClose,
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: p.raised,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: p.stroke),
                          ),
                          child: Icon(
                            hasIdentity
                                ? Icons.lock_person_outlined
                                : Icons.add_moderator_outlined,
                            color: p.secondary,
                            size: 32,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Eyebrow('Secure messaging', palette: p),
                      const SizedBox(height: 8),
                      Text(
                        hasIdentity
                            ? 'Confirm your digital identity'
                            : 'Set up secure messaging',
                        style: TextStyle(
                          color: p.foreground,
                          fontSize: 31,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        hasIdentity
                            ? 'Choose how to verify to set up secure '
                                  'messaging.'
                            : _setupDescription(availability),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 15,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (_waitingForDevice) ...[
                        SecurityCard(
                          palette: p,
                          child: Text(
                            'Open the app on another verified device and '
                            'accept the request. Make sure both devices stay '
                            'open while you compare emojis.',
                            style: TextStyle(color: p.foreground),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_message != null) ...[
                        Text(_message!, style: TextStyle(color: p.foreground)),
                        const SizedBox(height: 12),
                      ],
                      if (_error != null) ...[
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (state == null)
                        const Center(child: CircularProgressIndicator())
                      else
                        ..._actions(p, state),
                      if (_busy) ...[
                        const SizedBox(height: 16),
                        const Center(child: CircularProgressIndicator()),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _setupDescription(CryptoSetupAvailability? availability) =>
      switch (availability) {
        CryptoSetupAvailability.create =>
          'Your account doesn’t have a digital identity yet. Create one to '
              'verify your devices and back up your message keys. You’ll '
              'save a recovery phrase first.',
        CryptoSetupAvailability.needsSingleDevice =>
          'Other devices are signed in to your account. A new identity can '
              'only be created when this is your only signed-in device. Sign '
              'out the others, then check again.',
        CryptoSetupAvailability.repair =>
          'Part of your identity already exists. Enter your recovery key or '
              'passphrase to finish setting it up without replacing it.',
        _ =>
          'Existing keys can’t be completed safely here. Keep any recovery '
              'phrase you have. If none of your devices or keys can be '
              'recovered, you can reset your digital identity.',
      };

  List<Widget> _actions(AppPalette p, SessionSecurityState state) {
    final buttons = <Widget>[];
    void gap() => buttons.add(const SizedBox(height: 12));
    if (state.accountHasIdentity) {
      if (state.canUseAnotherDevice) {
        buttons.add(
          AccentButton(
            palette: p,
            label: 'Use another device',
            icon: Icons.devices_rounded,
            onPressed: _busy ? null : _useAnotherDevice,
          ),
        );
        gap();
      }
      if (state.canUseRecoveryKey) {
        buttons.add(
          state.canUseAnotherDevice
              ? OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: _busy ? null : _useRecoveryKey,
                  icon: const Icon(Icons.key_rounded),
                  label: const Text('Use recovery key'),
                )
              : AccentButton(
                  palette: p,
                  label: 'Use recovery key',
                  icon: Icons.key_rounded,
                  onPressed: _busy ? null : _useRecoveryKey,
                ),
        );
        gap();
      }
      if (!state.canUseAnotherDevice && !state.canUseRecoveryKey) {
        buttons.add(
          Text(
            'You don’t have access to any other verified devices or a '
            'recovery key, so you’ll need to reset your digital identity to '
            'use secure messaging on this device.',
            style: TextStyle(color: p.foreground),
          ),
        );
        gap();
      }
      buttons.add(
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
          onPressed: _busy ? null : _reset,
          child: const Text('Can’t confirm?'),
        ),
      );
    } else {
      switch (state.setupAvailability) {
        case CryptoSetupAvailability.create:
          buttons.add(
            AccentButton(
              palette: p,
              label: 'Set up encryption',
              icon: Icons.add_moderator_outlined,
              onPressed: _busy ? null : _setUp,
            ),
          );
        case CryptoSetupAvailability.repair:
          buttons.add(
            AccentButton(
              palette: p,
              label: 'Use recovery key',
              icon: Icons.key_rounded,
              onPressed: _busy ? null : _useRecoveryKey,
            ),
          );
        case CryptoSetupAvailability.needsSingleDevice:
          buttons.add(
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _busy ? null : () => _run(widget.onRefresh),
              child: const Text('Check again'),
            ),
          );
        default:
          buttons.add(
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _busy ? null : _reset,
              child: const Text('Reset digital identity'),
            ),
          );
      }
    }
    if (widget.onLater != null) {
      gap();
      buttons.add(
        TextButton(
          onPressed: _busy ? null : _later,
          child: const Text('Later'),
        ),
      );
    }
    return buttons;
  }
}

/// Settings route: confirm this device outside the post-login gate. Pops
/// with `true` once this device is verified.
class ConfirmIdentityScreen extends StatefulWidget {
  const ConfirmIdentityScreen({
    super.key,
    required this.backend,
    required this.security,
    required this.palette,
    this.setSecureWindow,
    this.openUrl,
  });
  final ChatBackend backend;
  final SecurityFeatures security;
  final AppPalette palette;
  final SetSecureWindow? setSecureWindow;
  final ExternalUrlOpener? openUrl;

  @override
  State<ConfirmIdentityScreen> createState() => _ConfirmIdentityScreenState();
}

class _ConfirmIdentityScreenState extends State<ConfirmIdentityScreen> {
  SessionSecurityState? _state;
  int _generation = 0;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_changed);
    widget.security.securityChanges.addListener(_changed);
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    widget.backend.removeListener(_changed);
    widget.security.securityChanges.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted || _closing) return;
    if (widget.security.thisDeviceVerified) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('Device verified')));
        Navigator.of(context).pop(true);
      });
      // A post-frame callback alone does not schedule a frame.
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final state = await widget.security.loadSessionState();
      if (!mounted || generation != _generation) return;
      setState(() => _state = state);
      _changed();
    } catch (_) {
      if (!mounted || generation != _generation) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Couldn’t check your identity. Try again.'),
        ),
      );
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) => SecurityConfirmationPage(
    backend: widget.backend,
    security: widget.security,
    palette: widget.palette,
    state: _state,
    onRefresh: _load,
    onClose: () => Navigator.of(context).maybePop(),
    setSecureWindow: widget.setSecureWindow,
    openUrl: widget.openUrl,
  );
}

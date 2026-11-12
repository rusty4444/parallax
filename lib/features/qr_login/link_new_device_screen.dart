// "Link new device" (Element X features/linknewdevice, mobile path): this
// signed-in device shows a QR code, the new device scans it, the user types
// the two digits shown there, approves the sign-in in the browser and this
// device sends its encryption secrets.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../widgets.dart';
import '../security/security_ui.dart';
import 'qr_code_data.dart';
import 'qr_grant_flow.dart';
import 'qr_login_features.dart';
import 'qr_messages.dart';
import 'qr_widgets.dart';
import 'rendezvous.dart';

typedef RecoveryCredentialPrompt = Future<String?> Function(BuildContext);

Future<String?> _askRecoveryKey(BuildContext context) => askRecoveryCredential(
  context,
  description:
      'Parallax shares your encryption keys with the new device so it is '
      'verified straight away. Make sure nobody can see this screen.',
);

class LinkNewDeviceScreen extends StatefulWidget {
  const LinkNewDeviceScreen({
    super.key,
    required this.backend,
    required this.palette,
    this.askRecoveryKey = _askRecoveryKey,
    this.delay = defaultQrDelay,
    this.onQrShown,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final RecoveryCredentialPrompt askRecoveryKey;
  final Future<void> Function(Duration) delay;

  /// Tests: receives each QR payload as it is shown.
  final ValueChanged<QrCodeData>? onQrShown;

  @override
  State<LinkNewDeviceScreen> createState() => _LinkNewDeviceScreenState();
}

enum _Stage {
  intro,
  preparing,
  showQr,
  enterNumber,
  approve,
  syncing,
  secretsError,
  error,
}

class _LinkNewDeviceScreenState extends State<LinkNewDeviceScreen> {
  _Stage _stage = _Stage.intro;
  QrSecretsBundle? _secrets;
  Uint8List? _qr;
  Completer<int>? _checkCode;
  Uri? _approval;
  QrGrantError? _error;
  QrCancellation? _cancellation;
  int _run = 0;
  final _digits = TextEditingController();
  String? _digitsError;

  QrLoginFeatures? get _features => qrLoginFeaturesOf(widget.backend);

  @override
  void dispose() {
    _cancellation?.cancel();
    _digits.dispose();
    _secrets = null;
    super.dispose();
  }

  Future<void> _begin() async {
    final features = _features;
    if (features == null || !features.canLinkNewDevice) return;
    if (_secrets == null) {
      final key = await widget.askRecoveryKey(context);
      if (!mounted || key == null) return;
      setState(() => _stage = _Stage.preparing);
      try {
        final secrets = await features.exportSecrets(key);
        if (!mounted) return;
        _secrets = secrets;
      } catch (_) {
        if (mounted) setState(() => _stage = _Stage.secretsError);
        return;
      }
    }
    unawaited(_startGrant(features, _secrets!));
  }

  Future<void> _startGrant(
    QrLoginFeatures features,
    QrSecretsBundle secrets,
  ) async {
    final account = features.grantAccount();
    if (account == null) {
      setState(() {
        _stage = _Stage.error;
        _error = QrGrantError.unknown;
      });
      return;
    }
    _cancellation?.cancel();
    final cancellation = QrCancellation();
    _cancellation = cancellation;
    final run = ++_run;
    setState(() {
      _stage = _Stage.preparing;
      _qr = null;
    });
    final client = features.newRendezvousClient();
    try {
      await QrGrantFlow(
        client: client,
        account: account,
        secrets: secrets,
        delay: widget.delay,
        onStep: (step) {
          if (!mounted || run != _run) return;
          _onStep(step, cancellation);
        },
      ).run(cancellation);
    } finally {
      client.close();
    }
  }

  void _onStep(QrGrantStep step, QrCancellation cancellation) {
    switch (step) {
      case QrGrantStarting():
        break;
      case QrGrantQrReady(:final data):
        widget.onQrShown?.call(data);
        setState(() {
          _stage = _Stage.showQr;
          _qr = data.encode();
        });
      case QrGrantQrScanned(:final checkCode):
        _digits.clear();
        setState(() {
          _stage = _Stage.enterNumber;
          _checkCode = checkCode;
          _digitsError = null;
        });
      case QrGrantWaitingForAuth(:final verificationUri):
        setState(() {
          _stage = _Stage.approve;
          _approval = verificationUri;
        });
      case QrGrantSyncingSecrets():
        setState(() => _stage = _Stage.syncing);
      case QrGrantDone():
        _secrets = null;
        Navigator.of(context).pop(true);
      case QrGrantFailed(:final error):
        if (cancellation.cancelled) return;
        setState(() {
          _stage = _Stage.error;
          _error = error;
        });
    }
  }

  void _submitDigits() {
    final value = _digits.text.trim();
    if (!RegExp(r'^\d{2}$').hasMatch(value)) {
      setState(() => _digitsError = 'Enter 2-digit code');
      return;
    }
    final completer = _checkCode;
    if (completer == null || completer.isCompleted) return;
    setState(() => _stage = _Stage.approve);
    completer.complete(int.parse(value));
  }

  void _cancel() {
    _cancellation?.cancel();
    _run++;
    Navigator.of(context).maybePop(false);
  }

  void _retry() {
    _run++;
    _cancellation?.cancel();
    final features = _features;
    final secrets = _secrets;
    if (features != null && secrets != null) {
      unawaited(_startGrant(features, secrets));
    } else {
      setState(() => _stage = _Stage.intro);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return PopScope(
      canPop: _stage == _Stage.intro || _stage == _Stage.error,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: switch (_stage) {
        _Stage.intro => QrStepPage(
          palette: p,
          icon: Icons.devices_rounded,
          title: 'Link new device',
          subtitle:
              'Sign in on another phone by scanning a QR code shown here. The '
              'new device is verified and can read your message history.',
          onBack: _cancel,
          content: QrNumberedSteps(
            palette: p,
            steps: const [
              'Open Parallax or Element X on the other device',
              'Select “Sign in with QR code”',
              'Scan the QR code shown here with the other device',
            ],
          ),
          buttons: [
            AccentButton(
              palette: p,
              label: 'Show QR code',
              icon: Icons.qr_code_2_rounded,
              onPressed: _begin,
            ),
          ],
        ),
        _Stage.preparing => QrStepPage(
          palette: p,
          icon: Icons.qr_code_2_rounded,
          title: 'Link new device',
          content: QrWaiting(palette: p, label: 'Loading QR code…'),
          buttons: [QrOutlinedButton(label: 'Cancel', onPressed: _cancel)],
        ),
        _Stage.showQr => QrStepPage(
          palette: p,
          icon: Icons.qr_code_2_rounded,
          title: 'Open Parallax or Element X on the other device',
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: QrImageView.withQr(
                    qr: QrCode.fromUint8List(
                      data: _qr!,
                      errorCorrectLevel: QrErrorCorrectLevel.L,
                    ),
                    semanticsLabel: 'Sign-in QR code',
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              QrNumberedSteps(
                palette: p,
                steps: const [
                  'Open Parallax or Element X on the other device',
                  'Select “Sign in with QR code”',
                  'Scan the QR code shown here with the other device',
                ],
              ),
            ],
          ),
          buttons: [QrOutlinedButton(label: 'Cancel', onPressed: _cancel)],
        ),
        _Stage.enterNumber => QrStepPage(
          palette: p,
          icon: Icons.pin_rounded,
          title: 'Enter the number shown on your other device',
          subtitle:
              'This will verify that the connection to your other device is '
              'secure.',
          content: TextField(
            controller: _digits,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 2,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: p.foreground,
              fontSize: 28,
              letterSpacing: 12,
              fontWeight: FontWeight.w700,
            ),
            onSubmitted: (_) => _submitDigits(),
            decoration: InputDecoration(
              labelText: 'Enter 2-digit code',
              errorText: _digitsError,
              counterText: '',
            ),
          ),
          buttons: [
            AccentButton(
              palette: p,
              label: 'Continue',
              onPressed: _submitDigits,
            ),
            QrOutlinedButton(label: 'Cancel', onPressed: _cancel),
          ],
        ),
        _Stage.approve => QrStepPage(
          palette: p,
          icon: Icons.open_in_browser_rounded,
          title: 'Finish in your browser',
          subtitle:
              'Confirm the new sign-in with your account provider. If it '
              'shows a code, check that it matches the one on your other '
              'device.',
          content: QrWaiting(palette: p),
          buttons: [
            if (_approval != null)
              QrOutlinedButton(
                label: 'Open browser again',
                onPressed: () => unawaited(openExternalHttpsUrl(_approval!)),
              ),
            QrOutlinedButton(label: 'Cancel', onPressed: _cancel),
          ],
        ),
        _Stage.syncing => QrStepPage(
          palette: p,
          icon: Icons.lock_rounded,
          title: 'Link new device',
          content: QrWaiting(palette: p, label: 'Sharing your encryption keys'),
        ),
        _Stage.secretsError => QrStepPage(
          palette: p,
          icon: Icons.error_rounded,
          iconColor: Theme.of(context).colorScheme.error,
          title: 'Couldn’t read your encryption keys',
          subtitle:
              'Check your recovery key and try again. Linking a device needs '
              'recovery to be set up in Settings → Security.',
          buttons: [
            AccentButton(
              palette: p,
              label: 'Try again',
              icon: Icons.refresh_rounded,
              onPressed: () => setState(() => _stage = _Stage.intro),
            ),
            QrOutlinedButton(label: 'Cancel', onPressed: _cancel),
          ],
        ),
        _Stage.error => LinkNewDeviceErrorPage(
          palette: p,
          error: _error ?? QrGrantError.unknown,
          onRetry: _retry,
          onCancel: _cancel,
        ),
      },
    );
  }
}

/// Element X linknewdevice `ErrorView`.
class LinkNewDeviceErrorPage extends StatelessWidget {
  const LinkNewDeviceErrorPage({
    super.key,
    required this.palette,
    required this.error,
    required this.onRetry,
    required this.onCancel,
  });

  final AppPalette palette;
  final QrGrantError error;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  static (String, String) texts(QrGrantError error) => switch (error) {
    QrGrantError.cancelled => (
      'Sign in request cancelled',
      'The sign in was cancelled on the other device.',
    ),
    QrGrantError.declined => (
      'Sign in declined',
      'The sign in was declined on the other device.',
    ),
    QrGrantError.expired ||
    QrGrantError.notFound ||
    QrGrantError.deviceNotFound => (
      'The sign in was not completed in time',
      'Sign in expired. Please try again.',
    ),
    QrGrantError.unsupportedProtocol => (
      'QR code not supported',
      'Your account provider doesn’t support signing into a new device with '
          'a QR code.',
    ),
    QrGrantError.connectionInsecure => (
      'Connection not secure',
      'A secure connection could not be made to the new device. Your '
          'existing devices are still safe and you don’t need to worry about '
          'them.',
    ),
    QrGrantError.invalidCheckCode => (
      'The numbers don’t match',
      'Please try again and make sure that you’ve entered the 2-digit code '
          'correctly. If the numbers still don’t match then contact your '
          'account provider.',
    ),
    QrGrantError.connectionLost => (
      'Something went wrong',
      'This may be due to network or server issues. Please check your '
          'internet connection.',
    ),
    QrGrantError.missingSecretsBackup ||
    QrGrantError.deviceIdAlreadyInUse ||
    QrGrantError.unknown => (
      'Something went wrong',
      'An unexpected error occurred. Please try again.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final (title, subtitle) = texts(error);
    return QrStepPage(
      palette: palette,
      icon: Icons.error_rounded,
      iconColor: Theme.of(context).colorScheme.error,
      title: title,
      subtitle: subtitle,
      buttons: [
        AccentButton(
          palette: palette,
          label: 'Try again',
          icon: Icons.refresh_rounded,
          onPressed: onRetry,
        ),
        QrOutlinedButton(label: 'Cancel', onPressed: onCancel),
      ],
    );
  }
}

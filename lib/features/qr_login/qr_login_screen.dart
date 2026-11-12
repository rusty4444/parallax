// "Sign in with QR code" screens (Element X features/login qrcode: intro,
// scan, confirmation and error screens, with Element X wording).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../platform_permissions.dart';
import '../../widgets.dart';
import 'qr_code_data.dart';
import 'qr_login_features.dart';
import 'qr_login_flow.dart';
import 'qr_widgets.dart';
import 'rendezvous.dart';

/// Builds the camera view; calls [onScanned] with the raw QR payload bytes.
typedef QrScannerBuilder =
    Widget Function(BuildContext context, ValueChanged<Uint8List> onScanned);

/// Asks for the camera permission; returns whether it is granted.
typedef CameraPermissionRequest = Future<bool> Function();

Future<bool> requestCameraPermission() async {
  try {
    final result = await const PlatformPermissions().request([
      PlatformPermissions.camera,
    ]);
    return result[PlatformPermissions.camera] ?? false;
  } catch (_) {
    return false;
  }
}

Widget mobileQrScanner(BuildContext context, ValueChanged<Uint8List> onScan) =>
    _MobileQrScanner(onScanned: onScan);

/// Opens the QR sign-in flow. Returns true once signed in.
Future<bool> showQrLogin(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
}) async {
  final result = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => QrLoginScreen(backend: backend, palette: palette),
    ),
  );
  return result ?? false;
}

class QrLoginScreen extends StatefulWidget {
  const QrLoginScreen({
    super.key,
    required this.backend,
    required this.palette,
    this.scannerBuilder = mobileQrScanner,
    this.requestCamera = requestCameraPermission,
    this.delay = defaultQrDelay,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final QrScannerBuilder scannerBuilder;
  final CameraPermissionRequest requestCamera;
  final Future<void> Function(Duration) delay;

  @override
  State<QrLoginScreen> createState() => _QrLoginScreenState();
}

enum _Stage {
  intro,
  noCamera,
  scanning,
  connecting,
  checkCode,
  userCode,
  finishing,
  error,
}

enum _ScanProblem { wrongCode, notSignedIn }

class _QrLoginScreenState extends State<QrLoginScreen> {
  _Stage _stage = _Stage.intro;
  _ScanProblem? _scanProblem;
  QrLoginError? _error;
  String? _code;
  QrCancellation? _cancellation;
  int _run = 0;
  bool _requesting = false;

  QrLoginFeatures? get _features => qrLoginFeaturesOf(widget.backend);
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_backendChanged);
  }

  @override
  void didUpdateWidget(covariant QrLoginScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      oldWidget.backend.removeListener(_backendChanged);
      widget.backend.addListener(_backendChanged);
    }
  }

  @override
  void dispose() {
    widget.backend.removeListener(_backendChanged);
    _cancellation?.cancel();
    super.dispose();
  }

  /// However the sign-in ended (even if a late cancel lost the race with
  /// the session commit), leave this flow once the app is signed in.
  void _backendChanged() {
    if (!mounted || _closing) return;
    if (widget.backend.connection == SessionStatus.ready) {
      _closing = true;
      _cancellation?.cancel();
      Navigator.of(context).pop(true);
    }
  }

  void _reset() {
    _cancellation?.cancel();
    _cancellation = null;
    _run++;
    setState(() {
      _stage = _Stage.intro;
      _scanProblem = null;
      _error = null;
      _code = null;
    });
  }

  Future<void> _readyToScan() async {
    if (_requesting) return;
    _requesting = true;
    try {
      final granted = await widget.requestCamera();
      if (!mounted || _stage != _Stage.intro && _stage != _Stage.noCamera) {
        return;
      }
      setState(() {
        _stage = granted ? _Stage.scanning : _Stage.noCamera;
        _scanProblem = null;
      });
    } finally {
      _requesting = false;
    }
  }

  void _scanned(Uint8List bytes) {
    if (_stage != _Stage.scanning || _scanProblem != null) return;
    final QrCodeData data;
    try {
      data = QrCodeData.decodeScanned(bytes);
    } on QrCodeDecodeException {
      setState(() => _scanProblem = _ScanProblem.wrongCode);
      return;
    }
    if (data.intent == QrCodeIntent.login) {
      // Element X: a code from a device that is not signed in.
      setState(() => _scanProblem = _ScanProblem.notSignedIn);
      return;
    }
    unawaited(_start(data));
  }

  Future<void> _start(QrCodeData data) async {
    final features = _features;
    if (features == null || !features.canSignInWithQrCode) {
      setState(() {
        _stage = _Stage.error;
        _error = QrLoginError.unknown;
      });
      return;
    }
    final run = ++_run;
    final cancellation = QrCancellation();
    _cancellation = cancellation;
    setState(() => _stage = _Stage.connecting);
    final client = features.newRendezvousClient();
    try {
      await QrLoginFlow(
        client: client,
        account: features.loginAccount,
        delay: widget.delay,
        onStep: (step) {
          if (!mounted || run != _run) return;
          _onStep(step, cancellation);
        },
      ).run(data, cancellation);
    } finally {
      client.close();
    }
  }

  void _onStep(QrLoginStep step, QrCancellation cancellation) {
    switch (step) {
      case QrLoginStarting():
        break;
      case QrLoginEstablishingSecureChannel(:final checkCode):
        setState(() {
          _stage = _Stage.checkCode;
          _code = checkCode;
        });
      case QrLoginWaitingForToken(:final userCode):
        setState(() {
          _stage = _Stage.userCode;
          _code = userCode;
        });
      case QrLoginSyncingSecrets():
        setState(() => _stage = _Stage.finishing);
      case QrLoginFinished():
        // pop, not maybePop: PopScope blocks back while signing in.
        if (_closing) return;
        _closing = true;
        Navigator.of(context).pop(true);
      case QrLoginFailed(:final error):
        if (cancellation.cancelled) return; // we cancelled ourselves
        if (error == QrLoginError.otherDeviceNotSignedIn) {
          setState(() {
            _stage = _Stage.scanning;
            _scanProblem = _ScanProblem.notSignedIn;
          });
          return;
        }
        setState(() {
          _stage = _Stage.error;
          _error = error;
        });
    }
  }

  void _close() => Navigator.of(context).maybePop(false);

  @override
  Widget build(BuildContext context) {
    final busy = switch (_stage) {
      _Stage.connecting ||
      _Stage.checkCode ||
      _Stage.userCode ||
      _Stage.finishing => true,
      _ => false,
    };
    return PopScope(
      canPop: !busy && _stage != _Stage.scanning,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_stage == _Stage.finishing) return; // signing in; let it finish
        _reset();
      },
      child: _page(context),
    );
  }

  Widget _page(BuildContext context) {
    final p = widget.palette;
    switch (_stage) {
      case _Stage.intro:
        return QrStepPage(
          palette: p,
          icon: Icons.computer_rounded,
          title:
              'Open Element or Parallax on another device to get the QR '
              'code',
          subtitle: 'Only available if your account provider supports it.',
          onBack: _close,
          content: QrNumberedSteps(
            palette: p,
            steps: const [
              'Open Element on a desktop device, or Parallax on another '
                  'phone',
              'Click on your avatar (in Parallax, open Settings)',
              'Select “Link new device”',
              'Scan the QR code with this device',
            ],
          ),
          buttons: [
            AccentButton(
              palette: p,
              label: 'Ready to scan',
              icon: Icons.qr_code_scanner_rounded,
              onPressed: _requesting ? null : _readyToScan,
            ),
          ],
        );
      case _Stage.noCamera:
        return QrStepPage(
          palette: p,
          icon: Icons.no_photography_outlined,
          title: 'Allow camera access to scan the QR code',
          subtitle:
              'You need to give permission for Parallax to use your device’s '
              'camera in order to continue.',
          onBack: _reset,
          buttons: [
            AccentButton(
              palette: p,
              label: 'Try again',
              icon: Icons.photo_camera_outlined,
              onPressed: _requesting ? null : _readyToScan,
            ),
          ],
        );
      case _Stage.scanning || _Stage.connecting:
        return _ScanPage(
          palette: p,
          connecting: _stage == _Stage.connecting,
          problem: _scanProblem,
          scanner: widget.scannerBuilder(context, _scanned),
          onBack: _reset,
          onTryAgain: () => setState(() {
            _stage = _Stage.scanning;
            _scanProblem = null;
          }),
        );
      case _Stage.checkCode:
        return QrStepPage(
          palette: p,
          icon: Icons.computer_rounded,
          title: 'Enter the number below on your other device',
          subtitle:
              'You’ll be asked to enter the two digits shown on this device.',
          content: Column(
            children: [
              QrDigits(palette: p, code: _code ?? ''),
              const SizedBox(height: 32),
              QrWaiting(palette: p),
            ],
          ),
          buttons: [QrOutlinedButton(label: 'Cancel', onPressed: _reset)],
        );
      case _Stage.userCode || _Stage.finishing:
        return QrStepPage(
          palette: p,
          icon: Icons.lock_rounded,
          title: 'Your verification code',
          subtitle:
              'Your account provider may ask for the following code to '
              'verify the sign in.',
          content: Column(
            children: [
              QrDigits(palette: p, code: _code ?? ''),
              const SizedBox(height: 32),
              QrWaiting(palette: p),
            ],
          ),
          buttons: [
            if (_stage == _Stage.userCode)
              QrOutlinedButton(label: 'Cancel', onPressed: _reset),
          ],
        );
      case _Stage.error:
        return QrLoginErrorPage(
          palette: p,
          error: _error ?? QrLoginError.unknown,
          onRetry: _reset,
          onCancel: _close,
        );
    }
  }
}

class _ScanPage extends StatelessWidget {
  const _ScanPage({
    required this.palette,
    required this.connecting,
    required this.problem,
    required this.scanner,
    required this.onBack,
    required this.onTryAgain,
  });

  final AppPalette palette;
  final bool connecting;
  final _ScanProblem? problem;
  final Widget scanner;
  final VoidCallback onBack;
  final VoidCallback onTryAgain;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final error = Theme.of(context).colorScheme.error;
    return QrStepPage(
      palette: p,
      icon: Icons.qr_code_scanner_rounded,
      title: 'Scan the QR code',
      onBack: onBack,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: p.raised,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: p.accent, width: 2),
              ),
              // Keep the camera running while connecting; the flow ignores
              // further codes.
              child: problem == null ? scanner : const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 18),
          if (connecting)
            QrWaiting(palette: p, label: 'Establishing a secure connection')
          else if (problem != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_rounded, color: error, size: 20),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    problem == _ScanProblem.wrongCode
                        ? 'Wrong QR code'
                        : 'Other device not signed in',
                    style: TextStyle(color: error, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              problem == _ScanProblem.wrongCode
                  ? 'Use the QR code shown on the other device.'
                  : 'Sign in to your other device and then try again, or use '
                        'another device that’s already signed in.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, height: 1.4),
            ),
            const SizedBox(height: 16),
            AccentButton(
              palette: p,
              label: 'Try again',
              icon: Icons.refresh_rounded,
              onPressed: onTryAgain,
            ),
          ],
        ],
      ),
    );
  }
}

/// Element X `QrCodeErrorView`.
class QrLoginErrorPage extends StatelessWidget {
  const QrLoginErrorPage({
    super.key,
    required this.palette,
    required this.error,
    required this.onRetry,
    required this.onCancel,
  });

  final AppPalette palette;
  final QrLoginError error;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  static (String, String) texts(QrLoginError error) => switch (error) {
    QrLoginError.cancelled => (
      'Sign in request cancelled',
      'The sign in was cancelled on the other device.',
    ),
    QrLoginError.declined => (
      'Sign in declined',
      'The sign in was declined on the other device.',
    ),
    QrLoginError.expired || QrLoginError.notFound => (
      'The sign in was not completed in time',
      'Sign in expired. Please try again.',
    ),
    QrLoginError.linkingNotSupported => (
      'QR code not supported',
      'Your other device does not support signing in to Parallax with a QR '
          'code.',
    ),
    QrLoginError.providerNotSupported => (
      'QR code not supported',
      'Your account provider doesn’t support signing into a new device with '
          'a QR code.',
    ),
    QrLoginError.connectionInsecure => (
      'Connection not secure',
      'A secure connection could not be made to the new device. Your '
          'existing devices are still safe and you don’t need to worry about '
          'them.',
    ),
    QrLoginError.connectionLost => (
      'Something went wrong',
      'This may be due to network or server issues. Please check your '
          'internet connection.',
    ),
    QrLoginError.otherDeviceNotSignedIn => (
      'Other device not signed in',
      'Sign in to your other device and then try again, or use another '
          'device that’s already signed in.',
    ),
    QrLoginError.oauthMetadataInvalid ||
    QrLoginError.unsupportedQrCodeType ||
    QrLoginError.unknown => (
      'Something went wrong',
      'An unexpected error occurred. Please try again.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final (title, subtitle) = texts(error);
    return QrStepPage(
      palette: p,
      icon: Icons.error_rounded,
      iconColor: Theme.of(context).colorScheme.error,
      title: title,
      subtitle: subtitle,
      content: error == QrLoginError.connectionInsecure
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'What now?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: p.foreground,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 12),
                QrNumberedSteps(
                  palette: p,
                  steps: const [
                    'Try signing in again with a QR code in case this was a '
                        'network problem',
                    'If you encounter the same problem, try a different wifi '
                        'network or use your mobile data instead of wifi',
                    'If that doesn’t work, sign in manually',
                  ],
                ),
              ],
            )
          : null,
      buttons: [
        AccentButton(
          palette: p,
          label: 'Try again',
          icon: Icons.refresh_rounded,
          onPressed: onRetry,
        ),
        QrOutlinedButton(label: 'Cancel', onPressed: onCancel),
      ],
    );
  }
}

class _MobileQrScanner extends StatefulWidget {
  const _MobileQrScanner({required this.onScanned});
  final ValueChanged<Uint8List> onScanned;

  @override
  State<_MobileQrScanner> createState() => _MobileQrScannerState();
}

class _MobileQrScannerState extends State<_MobileQrScanner> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobileScanner(
    controller: _controller,
    onDetect: (capture) {
      for (final barcode in capture.barcodes) {
        // The login payload is binary: use the decoded byte segment.
        final decoded = barcode.rawDecodedBytes;
        final bytes = switch (decoded) {
          DecodedBarcodeBytes(:final bytes) => bytes,
          DecodedVisionBarcodeBytes(:final bytes) => bytes,
          null => null,
        };
        if (bytes != null && bytes.isNotEmpty) {
          widget.onScanned(bytes);
          return;
        }
      }
    },
  );
}

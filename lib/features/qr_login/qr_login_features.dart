// Module interface for QR code sign-in and "Link new device", resolved per
// backend with an Expando like the other feature modules.
import 'package:http/http.dart' as http;

import '../../chat_backend.dart';
import '../../matrix_backend.dart';
import 'matrix_qr_login.dart';
import 'qr_grant_flow.dart';
import 'qr_login_flow.dart';
import 'qr_messages.dart';

abstract interface class QrLoginFeatures {
  /// "Sign in with QR code" can be offered: no session (not even a signed
  /// out one that needs reauthentication) and no other sign-in running.
  bool get canSignInWithQrCode;

  /// Account operations for the new-device flow.
  QrLoginAccount get loginAccount;

  /// "Link new device" can be offered: signed in with encryption.
  bool get canLinkNewDevice;

  /// Account operations for the existing-device (grant) flow, pinned to the
  /// current session, or null when it cannot run.
  QrGrantAccount? grantAccount();

  /// Reads the secrets for `m.login.secrets`, unlocking secret storage with
  /// the recovery key (the SDK does not cache the master key).
  Future<QrSecretsBundle> exportSecrets(String recoveryKeyOrPassphrase);

  /// A transport for the rendezvous session (closed by the caller).
  http.Client newRendezvousClient();
}

final _cache = Expando<QrLoginFeatures>('parallax.qr_login');

/// Test seam: replaces the resolved features for [backend].
void debugSetQrLoginFeatures(ChatBackend backend, QrLoginFeatures? features) {
  _cache[backend] = features;
}

QrLoginFeatures? qrLoginFeaturesOf(ChatBackend backend) {
  final cached = _cache[backend];
  if (cached != null) return cached;
  if (backend is! MatrixBackend) return null;
  return _cache[backend] = MatrixQrLogin(backend);
}

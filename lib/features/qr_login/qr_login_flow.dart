// "Sign in with QR code" on the new device (MSC4108, scanning side).
//
// Follows matrix-rust-sdk `qrcode/login.rs` (`LoginWithQrCode`, MSC4108
// variant) step by step, with the progress steps and error mapping of the
// Element X FFI (`QrLoginProgress`, `HumanQrLoginError`):
//
//  1. connect to the rendezvous session from the QR code and establish the
//     ECIES channel (we trust it because we scanned the code);
//  2. show the check code so the other device can confirm the channel;
//  3. start the OAuth 2.0 device authorization grant on the homeserver from
//     the QR code and send `m.login.protocol`;
//  4. wait for `m.login.protocol_accepted`, show the user code, poll for the
//     token, commit the session;
//  5. send `m.login.success`, receive `m.login.secrets` and import them.
import 'dart:async';

import 'package:http/http.dart' as http;

import '../../matrix_auth_service.dart';
import 'qr_code_data.dart';
import 'qr_messages.dart';
import 'rendezvous.dart';
import 'secure_channel.dart';

/// Element X `QrLoginException`, plus the two cases Element X folds into
/// "unknown" that deserve their own wording here.
enum QrLoginError {
  cancelled,
  connectionInsecure,
  declined,
  expired,
  notFound,
  otherDeviceNotSignedIn,
  linkingNotSupported,

  /// The homeserver's account provider has no device authorization grant.
  providerNotSupported,
  oauthMetadataInvalid,
  unsupportedQrCodeType,

  /// The rendezvous or authorization server could not be reached.
  connectionLost,
  unknown,
}

class QrLoginException implements Exception {
  const QrLoginException(this.error);
  final QrLoginError error;
  @override
  String toString() => 'QrLoginException(${error.name})';
}

/// Element X `QrCodeLoginStep`.
sealed class QrLoginStep {
  const QrLoginStep();
}

class QrLoginStarting extends QrLoginStep {
  const QrLoginStarting();
}

class QrLoginEstablishingSecureChannel extends QrLoginStep {
  const QrLoginEstablishingSecureChannel(this.checkCode);

  /// Two digits, shown so they can be entered on the other device.
  final String checkCode;
}

class QrLoginWaitingForToken extends QrLoginStep {
  const QrLoginWaitingForToken(this.userCode);
  final String userCode;
}

class QrLoginSyncingSecrets extends QrLoginStep {
  const QrLoginSyncingSecrets();
}

class QrLoginFinished extends QrLoginStep {
  const QrLoginFinished({required this.verified});

  /// False when the session was created but the other device's secrets
  /// could not be imported: the app then asks to confirm the identity.
  final bool verified;
}

class QrLoginFailed extends QrLoginStep {
  const QrLoginFailed(this.error);
  final QrLoginError error;
}

/// The account side of the QR login: OAuth device authorization, session
/// commit and secrets import. Implemented by the Matrix backend.
abstract interface class QrLoginAccount {
  /// Signs in to [serverNameOrUrl] with the device authorization grant.
  /// [onGrant] runs once the authorization server issued the device code
  /// (the flow forwards it to the other device and waits for acceptance);
  /// [afterCommit] runs once the session is committed, before the signed-in
  /// UI is shown.
  Future<void> signInWithDeviceAuthorization(
    String serverNameOrUrl, {
    required Future<void> Function(DeviceAuthorizationGrant grant) onGrant,
    required Future<void> Function() afterCommit,
    required QrCancellation cancellation,
  });

  /// Imports `m.login.secrets` and marks this device as verified.
  Future<void> importSecrets(QrSecretsBundle bundle);
}

class QrLoginFlow {
  QrLoginFlow({
    required this.client,
    required this.account,
    required this.onStep,
    this.delay = defaultQrDelay,
    this.secretsTimeout = const Duration(minutes: 2),
    this.ecdhSeed,
  });

  final http.Client client;
  final QrLoginAccount account;
  final void Function(QrLoginStep step) onStep;
  final Future<void> Function(Duration) delay;
  final Duration secretsTimeout;

  /// Tests only: a fixed ephemeral key.
  final List<int>? ecdhSeed;

  /// Runs the whole flow. Never throws: the outcome is the last step.
  Future<QrLoginStep> run(QrCodeData data, QrCancellation cancellation) async {
    QrSecureChannel? channel;
    var committed = false;
    var verified = false;
    try {
      onStep(const QrLoginStarting());
      // Element X: a 2024-style code without a server means the other device
      // is not signed in.
      if (data.intent == QrCodeIntent.login ||
          (data.format == QrCodeFormat.msc4108 &&
              (data.serverName?.trim().isEmpty ?? true))) {
        throw const QrLoginException(QrLoginError.otherDeviceNotSignedIn);
      }
      channel = await QrSecureChannel.fromQrCode(
        client,
        data,
        ourIntent: QrCodeIntent.login,
        cancellation: cancellation,
        delay: delay,
        seed: ecdhSeed,
      );
      final secure = channel;
      onStep(QrLoginEstablishingSecureChannel(secure.checkCode.display));

      await account.signInWithDeviceAuthorization(
        data.serverName!.trim(),
        cancellation: cancellation,
        onGrant: (grant) async {
          await secure.sendJson(
            qrProtocolMessage(
              grant: DeviceAuthorizationGrantData(
                verificationUri: grant.verificationUri,
                verificationUriComplete: grant.verificationUriComplete,
              ),
              deviceId: grant.deviceId,
            ),
            cancellation: cancellation,
          );
          final reply = await secure.receiveJson(cancellation: cancellation);
          switch (reply['type']) {
            case QrMessageType.protocolAccepted:
              break;
            case QrMessageType.failure:
              throw QrLoginException(_failureError(reply['reason']));
            default:
              await _sendQuietly(
                secure,
                qrFailure(QrFailureReason.unexpectedMessageReceived),
              );
              throw const QrLoginException(QrLoginError.unknown);
          }
          cancellation.check();
          onStep(QrLoginWaitingForToken(grant.userCode));
        },
        afterCommit: () async {
          committed = true;
          onStep(const QrLoginSyncingSecrets());
          verified = await _receiveSecrets(secure, cancellation);
        },
      );
      onStep(QrLoginFinished(verified: verified));
      return QrLoginFinished(verified: verified);
    } catch (error) {
      if (committed) {
        // The session exists; only verification is missing.
        final step = QrLoginFinished(verified: verified);
        onStep(step);
        return step;
      }
      final mapped = mapQrLoginError(error);
      final secure = channel;
      // Tell the other device why we stopped, as Rust does for the token
      // errors (and for a local cancellation, as matrix-js-sdk does).
      final notice = switch (error) {
        DeviceAuthorizationException(:final failure) => switch (failure) {
          DeviceAuthorizationFailure.declined => {
            'type': QrMessageType.declined,
          },
          DeviceAuthorizationFailure.expired => qrFailure(
            QrFailureReason.authorizationExpired,
          ),
          DeviceAuthorizationFailure.unsupported => qrFailure(
            QrFailureReason.unsupportedProtocol,
          ),
          DeviceAuthorizationFailure.cancelled => qrFailure(
            QrFailureReason.userCancelled,
          ),
        },
        RendezvousException(failure: RendezvousFailure.cancelled) => qrFailure(
          QrFailureReason.userCancelled,
        ),
        _ => null,
      };
      if (secure != null && notice != null) {
        await _sendQuietly(secure, notice);
      }
      final step = QrLoginFailed(mapped);
      onStep(step);
      return step;
    }
  }

  /// `m.login.success` then `m.login.secrets`. Returns whether the device
  /// is now verified.
  Future<bool> _receiveSecrets(
    QrSecureChannel channel,
    QrCancellation cancellation,
  ) async {
    try {
      await channel.sendJson({
        'type': QrMessageType.success,
      }, cancellation: cancellation);
      final message = await channel
          .receiveJson(cancellation: cancellation)
          .timeout(secretsTimeout);
      if (message['type'] != QrMessageType.secrets) {
        if (message['type'] != QrMessageType.failure) {
          await _sendQuietly(
            channel,
            qrFailure(QrFailureReason.unexpectedMessageReceived),
          );
        }
        return false;
      }
      final bundle = QrSecretsBundle.parse(message);
      await account.importSecrets(bundle);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _sendQuietly(
    QrSecureChannel channel,
    Map<String, Object?> message,
  ) async {
    try {
      await channel.sendJson(message).timeout(const Duration(seconds: 10));
    } catch (_) {
      // The other device times out on its own.
    }
  }

  static QrLoginError _failureError(Object? reason) =>
      switch (QrFailureReason.parse(reason)) {
        QrFailureReason.unsupportedProtocol => QrLoginError.linkingNotSupported,
        QrFailureReason.authorizationExpired => QrLoginError.expired,
        QrFailureReason.userCancelled => QrLoginError.cancelled,
        _ => QrLoginError.unknown,
      };
}

/// Maps any failure to the Element X error the UI shows.
QrLoginError mapQrLoginError(Object error) => switch (error) {
  QrLoginException(:final error) => error,
  QrCodeDecodeException() => QrLoginError.unknown,
  SecureChannelException(:final failure) => switch (failure) {
    SecureChannelFailure.invalidIntent => QrLoginError.otherDeviceNotSignedIn,
    SecureChannelFailure.unsupportedQrCodeType =>
      QrLoginError.unsupportedQrCodeType,
    SecureChannelFailure.insecure ||
    SecureChannelFailure.invalidCheckCode => QrLoginError.connectionInsecure,
    SecureChannelFailure.messageDecode => QrLoginError.unknown,
  },
  RendezvousException(:final failure) => switch (failure) {
    RendezvousFailure.notFound => QrLoginError.notFound,
    RendezvousFailure.cancelled => QrLoginError.cancelled,
    RendezvousFailure.network => QrLoginError.connectionLost,
    RendezvousFailure.http ||
    RendezvousFailure.protocol => QrLoginError.unknown,
  },
  DeviceAuthorizationException(:final failure) => switch (failure) {
    DeviceAuthorizationFailure.declined => QrLoginError.declined,
    DeviceAuthorizationFailure.expired => QrLoginError.expired,
    DeviceAuthorizationFailure.unsupported => QrLoginError.providerNotSupported,
    DeviceAuthorizationFailure.cancelled => QrLoginError.cancelled,
  },
  MatrixAuthException(statusCode: null) => QrLoginError.connectionLost,
  FormatException() => QrLoginError.oauthMetadataInvalid,
  TimeoutException() => QrLoginError.connectionLost,
  _ => QrLoginError.unknown,
};

// "Link new device" on the signed-in device (MSC4108 grant, QR shown here).
//
// Follows matrix-rust-sdk `qrcode/grant.rs` (`GrantLoginWithGeneratedQrCode`,
// MSC4108 variant) with the Element X `LinkMobileStep`s and error mapping:
//
//  1. create a rendezvous session on our homeserver and show a
//     "reciprocate" QR code carrying our homeserver URL;
//  2. when the new device scans it, reply OK and ask for the two-digit code
//     it shows; only a matching code makes the channel trusted;
//  3. receive `m.login.protocol` (device authorization grant + device ID),
//     check the device ID is unused, send `m.login.protocol_accepted` and
//     open the verification URL so the user approves the sign-in;
//  4. wait for `m.login.success`, wait for the new device to appear, then
//     send `m.login.secrets`.
//
// As in Rust, the MSC4108 variant does not send `m.login.protocols`: the
// new device takes the homeserver from the QR code.
import 'dart:async';

import 'package:http/http.dart' as http;

import 'qr_code_data.dart';
import 'qr_messages.dart';
import 'rendezvous.dart';
import 'secure_channel.dart';

/// Element X `ErrorType` for linking.
enum QrGrantError {
  cancelled,
  connectionInsecure,
  declined,
  deviceIdAlreadyInUse,
  deviceNotFound,
  expired,
  invalidCheckCode,
  missingSecretsBackup,
  notFound,
  unsupportedProtocol,
  connectionLost,
  unknown,
}

class QrGrantException implements Exception {
  const QrGrantException(this.error);
  final QrGrantError error;
  @override
  String toString() => 'QrGrantException(${error.name})';
}

sealed class QrGrantStep {
  const QrGrantStep();
}

class QrGrantStarting extends QrGrantStep {
  const QrGrantStarting();
}

class QrGrantQrReady extends QrGrantStep {
  const QrGrantQrReady(this.data);
  final QrCodeData data;
}

/// The QR code was scanned: enter the two digits shown on the new device.
class QrGrantQrScanned extends QrGrantStep {
  const QrGrantQrScanned(this.checkCode);

  /// Completes with the digits typed in (or an error to cancel).
  final Completer<int> checkCode;
}

/// Approve the sign-in at [verificationUri] (the browser is opened for it).
class QrGrantWaitingForAuth extends QrGrantStep {
  const QrGrantWaitingForAuth(this.verificationUri);
  final Uri verificationUri;
}

class QrGrantSyncingSecrets extends QrGrantStep {
  const QrGrantSyncingSecrets();
}

class QrGrantDone extends QrGrantStep {
  const QrGrantDone();
}

class QrGrantFailed extends QrGrantStep {
  const QrGrantFailed(this.error);
  final QrGrantError error;
}

/// The signed-in account, pinned to one session.
abstract interface class QrGrantAccount {
  Uri get homeserver;

  /// Whether [deviceId] is already one of this account's devices.
  Future<bool> deviceExists(String deviceId);

  /// Whether [uri] is on this account's authorization server.
  Future<bool> trustsVerificationUri(Uri uri);

  /// Opens the approval page (the OAuth server's verification URL).
  Future<bool> openVerificationUri(Uri uri);
}

class QrGrantFlow {
  QrGrantFlow({
    required this.client,
    required this.account,
    required this.secrets,
    required this.onStep,
    this.delay = defaultQrDelay,
    this.deviceCreationTimeout = const Duration(seconds: 10),
    this.maxQrRotations = 5,
    this.ecdhSeed,
  });

  final http.Client client;
  final QrGrantAccount account;
  final QrSecretsBundle secrets;
  final void Function(QrGrantStep step) onStep;
  final Future<void> Function(Duration) delay;
  final Duration deviceCreationTimeout;
  final int maxQrRotations;
  final List<int>? ecdhSeed;

  Future<QrGrantStep> run(QrCancellation cancellation) async {
    QrSecureChannel? trusted;
    try {
      onStep(const QrGrantStarting());
      PendingSecureChannel? pending;
      for (var rotation = 0; pending == null; rotation++) {
        final generated = await GeneratedSecureChannel.create(
          client,
          account.homeserver,
          serverName: account.homeserver.toString(),
          cancellation: cancellation,
          delay: delay,
          seed: ecdhSeed,
        );
        onStep(QrGrantQrReady(generated.qrCodeData));
        try {
          pending = await generated.connect(cancellation: cancellation);
        } on RendezvousException catch (e) {
          // Element X rotates an unscanned code when its session expires.
          if (e.failure != RendezvousFailure.notFound ||
              rotation + 1 >= maxQrRotations) {
            rethrow;
          }
        }
      }
      final entered = Completer<int>();
      onStep(QrGrantQrScanned(entered));
      final digits = await Future.any([
        entered.future,
        cancellation.whenCancelled.then<int>(
          (_) => throw const RendezvousException(RendezvousFailure.cancelled),
        ),
      ]);
      final channel = pending.confirm(digits);
      trusted = channel;

      final message = await channel.receiveJson(cancellation: cancellation);
      switch (message['type']) {
        case QrMessageType.protocol:
          break;
        case QrMessageType.failure:
          throw QrGrantException(_failureError(message['reason']));
        default:
          throw const QrGrantException(QrGrantError.unknown);
      }
      final ({DeviceAuthorizationGrantData grant, String deviceId})? protocol;
      try {
        protocol = parseQrProtocol(message);
      } on FormatException {
        await _sendQuietly(
          channel,
          qrFailure(QrFailureReason.unexpectedMessageReceived),
        );
        throw const QrGrantException(QrGrantError.unknown);
      }
      if (protocol == null) {
        await _sendQuietly(
          channel,
          qrFailure(QrFailureReason.unsupportedProtocol),
        );
        throw const QrGrantException(QrGrantError.unsupportedProtocol);
      }
      if (await account.deviceExists(protocol.deviceId)) {
        await _sendQuietly(
          channel,
          qrFailure(QrFailureReason.deviceAlreadyExists),
        );
        throw const QrGrantException(QrGrantError.deviceIdAlreadyInUse);
      }
      final approval = protocol.grant.approvalUri;
      if (!await account.trustsVerificationUri(approval)) {
        await _sendQuietly(
          channel,
          qrFailure(QrFailureReason.unsupportedProtocol),
        );
        throw const QrGrantException(QrGrantError.unknown);
      }
      cancellation.check();
      await channel.sendJson({
        'type': QrMessageType.protocolAccepted,
      }, cancellation: cancellation);
      onStep(QrGrantWaitingForAuth(approval));
      await account.openVerificationUri(approval);

      final outcome = await channel.receiveJson(cancellation: cancellation);
      switch (outcome['type']) {
        case QrMessageType.success:
          break;
        case QrMessageType.declined:
          throw const QrGrantException(QrGrantError.declined);
        case QrMessageType.failure:
          throw QrGrantException(_failureError(outcome['reason']));
        default:
          throw const QrGrantException(QrGrantError.unknown);
      }

      final deadline = DateTime.now().add(deviceCreationTimeout);
      while (!await account.deviceExists(protocol.deviceId)) {
        if (DateTime.now().isAfter(deadline)) {
          await _sendQuietly(
            channel,
            qrFailure(QrFailureReason.deviceNotFound),
          );
          throw const QrGrantException(QrGrantError.deviceNotFound);
        }
        await cancellation.sleep(const Duration(milliseconds: 500), delay);
      }
      onStep(const QrGrantSyncingSecrets());
      await channel.sendJson(secrets.toMessage(), cancellation: cancellation);
      onStep(const QrGrantDone());
      return const QrGrantDone();
    } catch (error) {
      final mapped = mapQrGrantError(error);
      if (trusted != null && mapped == QrGrantError.cancelled) {
        await _sendQuietly(trusted, qrFailure(QrFailureReason.userCancelled));
      }
      final step = QrGrantFailed(mapped);
      onStep(step);
      return step;
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

  static QrGrantError _failureError(Object? reason) =>
      switch (QrFailureReason.parse(reason)) {
        QrFailureReason.unsupportedProtocol => QrGrantError.unsupportedProtocol,
        QrFailureReason.authorizationExpired => QrGrantError.expired,
        QrFailureReason.userCancelled => QrGrantError.cancelled,
        QrFailureReason.deviceAlreadyExists =>
          QrGrantError.deviceIdAlreadyInUse,
        QrFailureReason.deviceNotFound => QrGrantError.deviceNotFound,
        _ => QrGrantError.unknown,
      };
}

QrGrantError mapQrGrantError(Object error) => switch (error) {
  QrGrantException(:final error) => error,
  SecureChannelException(:final failure) => switch (failure) {
    SecureChannelFailure.invalidCheckCode => QrGrantError.invalidCheckCode,
    SecureChannelFailure.insecure => QrGrantError.connectionInsecure,
    _ => QrGrantError.unknown,
  },
  RendezvousException(:final failure) => switch (failure) {
    RendezvousFailure.notFound => QrGrantError.notFound,
    RendezvousFailure.cancelled => QrGrantError.cancelled,
    RendezvousFailure.network => QrGrantError.connectionLost,
    _ => QrGrantError.unknown,
  },
  TimeoutException() => QrGrantError.connectionLost,
  _ => QrGrantError.unknown,
};

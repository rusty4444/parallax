// Messages exchanged over the MSC4108 secure channel, in the layout used by
// matrix-rust-sdk `qrcode/messages.rs` (MSC4108 variant) and matrix-js-sdk.
import 'qr_code_data.dart' show decodeUnpaddedBase64;

abstract final class QrMessageType {
  static const protocols = 'm.login.protocols';
  static const protocol = 'm.login.protocol';
  static const protocolAccepted = 'm.login.protocol_accepted';
  static const success = 'm.login.success';
  static const declined = 'm.login.declined';
  static const failure = 'm.login.failure';
  static const secrets = 'm.login.secrets';
}

const deviceAuthorizationGrantProtocol = 'device_authorization_grant';

/// `m.login.failure` reasons (snake_case on the wire).
enum QrFailureReason {
  authorizationExpired('authorization_expired'),
  deviceAlreadyExists('device_already_exists'),
  deviceNotFound('device_not_found'),
  unexpectedMessageReceived('unexpected_message_received'),
  unsupportedProtocol('unsupported_protocol'),
  userCancelled('user_cancelled'),
  unknown('unknown');

  const QrFailureReason(this.wire);
  final String wire;

  static QrFailureReason parse(Object? value) => values.firstWhere(
    (reason) => reason.wire == value && reason != unknown,
    orElse: () => unknown,
  );
}

Map<String, Object?> qrFailure(QrFailureReason reason) => {
  'type': QrMessageType.failure,
  'reason': reason.wire,
};

/// The device authorization grant the new device sends in
/// `m.login.protocol` (MSC4108 nests it under the protocol name).
class DeviceAuthorizationGrantData {
  const DeviceAuthorizationGrantData({
    required this.verificationUri,
    this.verificationUriComplete,
  });
  final Uri verificationUri;
  final Uri? verificationUriComplete;

  /// Rust opens `verification_uri_complete` when present.
  Uri get approvalUri => verificationUriComplete ?? verificationUri;

  Map<String, Object?> toJson() => {
    'verification_uri': verificationUri.toString(),
    if (verificationUriComplete != null)
      'verification_uri_complete': verificationUriComplete.toString(),
  };
}

Map<String, Object?> qrProtocolMessage({
  required DeviceAuthorizationGrantData grant,
  required String deviceId,
}) => {
  'type': QrMessageType.protocol,
  'protocol': deviceAuthorizationGrantProtocol,
  deviceAuthorizationGrantProtocol: grant.toJson(),
  'device_id': deviceId,
};

/// Parses `m.login.protocol` (MSC4108 nested layout, also the flat MSC4388
/// layout like Rust does). Returns null for an unknown protocol.
({DeviceAuthorizationGrantData grant, String deviceId})? parseQrProtocol(
  Map<String, Object?> message,
) {
  if (message['protocol'] != deviceAuthorizationGrantProtocol) return null;
  final deviceId = message['device_id'];
  final nested = message[deviceAuthorizationGrantProtocol];
  final data = nested is Map ? nested : message;
  final uri = _httpsUri(data['verification_uri']);
  final complete = data['verification_uri_complete'] == null
      ? null
      : _httpsUri(data['verification_uri_complete']);
  if (deviceId is! String ||
      deviceId.isEmpty ||
      deviceId.length > 255 ||
      uri == null ||
      (data['verification_uri_complete'] != null && complete == null)) {
    throw const FormatException('Invalid m.login.protocol');
  }
  return (
    grant: DeviceAuthorizationGrantData(
      verificationUri: uri,
      verificationUriComplete: complete,
    ),
    deviceId: deviceId,
  );
}

Uri? _httpsUri(Object? value) {
  if (value is! String || value.length > 2048) return null;
  final uri = Uri.tryParse(value);
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}

/// `m.login.secrets` (matrix-sdk-crypto `SecretsBundle`): the private
/// cross-signing keys and, optionally, the key backup decryption key. All
/// keys are unpadded base64.
class QrSecretsBundle {
  QrSecretsBundle({
    required this.masterKey,
    required this.selfSigningKey,
    required this.userSigningKey,
    this.backup,
  });

  final String masterKey;
  final String selfSigningKey;
  final String userSigningKey;
  final QrBackupSecret? backup;

  static const backupAlgorithm = 'm.megolm_backup.v1.curve25519-aes-sha2';

  static QrSecretsBundle parse(Map<String, Object?> message) {
    final cross = message['cross_signing'];
    if (cross is! Map) throw const FormatException('Missing cross_signing');
    String key(Map source, String name) {
      final value = source[name];
      if (value is! String) throw FormatException('Missing $name');
      final bytes = decodeUnpaddedBase64(value);
      if (bytes.length != 32) throw FormatException('Invalid $name');
      return value;
    }

    final backupJson = message['backup'];
    QrBackupSecret? backup;
    if (backupJson is Map) {
      final version = backupJson['backup_version'];
      if (backupJson['algorithm'] != backupAlgorithm ||
          version is! String ||
          version.isEmpty ||
          version.length > 255) {
        throw const FormatException('Invalid backup');
      }
      backup = QrBackupSecret(key: key(backupJson, 'key'), version: version);
    } else if (backupJson != null) {
      throw const FormatException('Invalid backup');
    }
    return QrSecretsBundle(
      masterKey: key(cross, 'master_key'),
      selfSigningKey: key(cross, 'self_signing_key'),
      userSigningKey: key(cross, 'user_signing_key'),
      backup: backup,
    );
  }

  Map<String, Object?> toMessage() => {
    'type': QrMessageType.secrets,
    'cross_signing': {
      'master_key': masterKey,
      'self_signing_key': selfSigningKey,
      'user_signing_key': userSigningKey,
    },
    if (backup != null)
      'backup': {
        'algorithm': backupAlgorithm,
        'key': backup!.key,
        'backup_version': backup!.version,
      },
  };
}

class QrBackupSecret {
  const QrBackupSecret({required this.key, required this.version});
  final String key;
  final String version;
}

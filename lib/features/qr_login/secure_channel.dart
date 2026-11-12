// MSC4108 secure channel: an ECIES channel over a rendezvous session.
//
// Mirrors matrix-rust-sdk `secure_channel/mod.rs` (ECIES variant):
// - the scanning device S sends MATRIX_QR_CODE_LOGIN_INITIATE encrypted to
//   the QR code's key and expects MATRIX_QR_CODE_LOGIN_OK back; S knows the
//   channel is secure once that reply decrypts (it trusted the QR code);
// - the device G that showed the QR code replies OK but must confirm the
//   two-digit check code, read from S's screen, before trusting the channel.
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ecies.dart';
import 'qr_code_data.dart';
import 'rendezvous.dart';

const loginInitiateMessage = 'MATRIX_QR_CODE_LOGIN_INITIATE';
const loginOkMessage = 'MATRIX_QR_CODE_LOGIN_OK';

enum SecureChannelFailure {
  /// A message did not decrypt or was not the one the protocol requires.
  insecure,

  /// The check code typed on this device does not match.
  invalidCheckCode,

  /// Both devices have the same intent (e.g. a new device scanned another
  /// new device's code, so "the other device is not signed in").
  invalidIntent,

  /// The QR code uses a layout this app cannot connect to (MSC4388).
  unsupportedQrCodeType,

  /// A JSON payload could not be decoded.
  messageDecode,
}

class SecureChannelException implements Exception {
  const SecureChannelException(this.failure);
  final SecureChannelFailure failure;
  @override
  String toString() => 'SecureChannelException(${failure.name})';
}

class QrSecureChannel {
  QrSecureChannel._(this._rendezvous, this._ecies);

  final RendezvousChannel _rendezvous;
  final EstablishedEcies _ecies;

  CheckCode get checkCode => _ecies.checkCode;
  Uri get rendezvousUrl => _rendezvous.url;

  /// S: connect to the session from a scanned QR code. [ourIntent] is this
  /// device's role: a QR code with the same intent is rejected.
  static Future<QrSecureChannel> fromQrCode(
    http.Client client,
    QrCodeData data, {
    required QrCodeIntent ourIntent,
    QrCancellation? cancellation,
    Future<void> Function(Duration) delay = defaultQrDelay,
    List<int>? seed,
  }) async {
    if (data.intent == ourIntent) {
      throw const SecureChannelException(SecureChannelFailure.invalidIntent);
    }
    if (data.format != QrCodeFormat.msc4108) {
      throw const SecureChannelException(
        SecureChannelFailure.unsupportedQrCodeType,
      );
    }
    final url = Uri.tryParse(data.rendezvousUrl ?? '');
    if (!isSafeRendezvousUrl(url)) {
      throw const RendezvousException(RendezvousFailure.protocol);
    }
    final rendezvous = await RendezvousChannel.connect(
      client,
      url!,
      cancellation: cancellation,
      delay: delay,
    );
    final Ecies ecies;
    final EstablishedEcies established;
    final EciesInitialMessage initial;
    try {
      ecies = await Ecies.create(seed: seed);
      (established, initial) = await ecies.establishOutbound(
        data.publicKey,
        utf8.encode(loginInitiateMessage),
      );
    } on EciesException {
      throw const SecureChannelException(SecureChannelFailure.insecure);
    }
    await rendezvous.send(initial.encode(), cancellation: cancellation);
    final channel = QrSecureChannel._(rendezvous, established);
    final reply = await channel._receiveText(cancellation: cancellation);
    if (reply != loginOkMessage) {
      throw const SecureChannelException(SecureChannelFailure.insecure);
    }
    return channel;
  }

  Future<void> sendJson(
    Map<String, Object?> message, {
    QrCancellation? cancellation,
  }) async {
    final sealed = await _ecies.encrypt(utf8.encode(jsonEncode(message)));
    await _rendezvous.send(sealed.encode(), cancellation: cancellation);
  }

  Future<Map<String, Object?>> receiveJson({
    QrCancellation? cancellation,
  }) async {
    final text = await _receiveText(cancellation: cancellation);
    try {
      final value = jsonDecode(text);
      if (value is Map<String, Object?> && value['type'] is String) {
        return value;
      }
    } on FormatException {
      // fall through
    }
    throw const SecureChannelException(SecureChannelFailure.messageDecode);
  }

  Future<String> _receiveText({QrCancellation? cancellation}) async {
    final raw = await _rendezvous.receive(cancellation: cancellation);
    final Uint8List plain;
    try {
      plain = await _ecies.decrypt(EciesMessage.decode(raw));
    } on EciesException {
      throw const SecureChannelException(SecureChannelFailure.insecure);
    }
    try {
      return utf8.decode(plain);
    } on FormatException {
      throw const SecureChannelException(SecureChannelFailure.messageDecode);
    }
  }

  Future<void> close() => _rendezvous.close();
}

/// G: a rendezvous session with a QR code shown, waiting to be scanned.
class GeneratedSecureChannel {
  GeneratedSecureChannel._(this._rendezvous, this._ecies, this.qrCodeData);

  final RendezvousChannel _rendezvous;
  final Ecies _ecies;
  final QrCodeData qrCodeData;

  /// Creates a session on [homeserver]. A [serverName] makes it a
  /// "reciprocate" code (this device is signed in and offers to sign another
  /// device in); without one it is a "login" code.
  static Future<GeneratedSecureChannel> create(
    http.Client client,
    Uri homeserver, {
    String? serverName,
    QrCancellation? cancellation,
    Future<void> Function(Duration) delay = defaultQrDelay,
    List<int>? seed,
  }) async {
    final rendezvous = await RendezvousChannel.create(
      client,
      homeserver,
      cancellation: cancellation,
      delay: delay,
    );
    final ecies = await Ecies.create(seed: seed);
    return GeneratedSecureChannel._(
      rendezvous,
      ecies,
      QrCodeData.msc4108(
        publicKey: ecies.publicKey,
        rendezvousUrl: rendezvous.url.toString(),
        serverName: serverName,
      ),
    );
  }

  /// Waits for the other device to scan and send the initiate message, then
  /// replies OK. The channel is not trusted until [PendingSecureChannel.confirm].
  Future<PendingSecureChannel> connect({QrCancellation? cancellation}) async {
    final raw = await _rendezvous.receive(cancellation: cancellation);
    final EstablishedEcies established;
    final Uint8List plaintext;
    try {
      (established, plaintext) = await _ecies.establishInbound(
        EciesInitialMessage.decode(raw),
      );
    } on EciesException {
      throw const SecureChannelException(SecureChannelFailure.insecure);
    }
    if (utf8.decode(plaintext, allowMalformed: true) != loginInitiateMessage) {
      throw const SecureChannelException(SecureChannelFailure.insecure);
    }
    final channel = QrSecureChannel._(_rendezvous, established);
    final ok = await established.encrypt(utf8.encode(loginOkMessage));
    await _rendezvous.send(ok.encode(), cancellation: cancellation);
    return PendingSecureChannel._(channel);
  }

  Future<void> close() => _rendezvous.close();
}

class PendingSecureChannel {
  PendingSecureChannel._(this._channel);
  final QrSecureChannel _channel;

  /// Accepts the channel only if [digits] is the code shown on the other
  /// device (vodozemac `DigitMode::AllowLeadingZero`).
  QrSecureChannel confirm(int digits) {
    if (digits != _channel.checkCode.digits) {
      throw const SecureChannelException(SecureChannelFailure.invalidCheckCode);
    }
    return _channel;
  }

  Future<void> close() => _channel.close();
}

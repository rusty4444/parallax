import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;

import 'send_cancellation.dart';

/// Fails closed at the final Matrix HTTP boundary if an encrypted send loses
/// crypto availability during an SDK await or tries to send plaintext content.
class MatrixSendGuard extends http.BaseClient {
  MatrixSendGuard(
    this._inner, {
    required this.encryptionAvailable,
    required this.isEncryptedRoom,
  });

  final http.Client _inner;
  final bool Function() encryptionAvailable;
  final bool Function(String roomId) isEncryptedRoom;
  static final Object _encryptedRoomKey = Object();
  static final Object _ownerKey = Object();
  static final Object _recipientCheckKey = Object();
  static final Object _sendStateKey = Object();
  static final Object _cancellationKey = Object();
  int _protectedSends = 0;

  static Future<T> owned<T>(
    bool Function() ownerCurrent,
    Future<T> Function() action,
  ) {
    if (!ownerCurrent()) throw StateError('Send belongs to an old session');
    return runZoned(action, zoneValues: {_ownerKey: ownerCurrent});
  }

  static Future<T> cancellable<T>(
    SendCancellation cancellation,
    Future<T> Function() action,
  ) => runZoned(action, zoneValues: {_cancellationKey: cancellation});

  void _checkCancellation(SendCancellation? cancellation) {
    if (cancellation?.isCancelled == true) {
      // The SDK retries ordinary transport exceptions. A forbidden outcome
      // stops its send loop; the outbox translates it back to cancellation.
      throw matrix.MatrixException.fromJson({
        'errcode': 'M_FORBIDDEN',
        'error': 'This send was cancelled locally.',
      });
    }
  }

  static void invalidateCurrentSend() {
    final state = Zone.current[_sendStateKey] as _ProtectedSendState?;
    if (state != null) state.invalid = true;
  }

  Future<T> protect<T>(
    String roomId,
    Future<T> Function() action, {
    required bool Function() ownerCurrent,
    required Future<void> Function() validateRecipients,
  }) async {
    if (!encryptionAvailable() || !ownerCurrent()) {
      throw StateError('Encrypted send is unavailable');
    }
    _protectedSends++;
    final state = _ProtectedSendState();
    try {
      return await runZoned(
        action,
        zoneValues: {
          _encryptedRoomKey: roomId,
          _ownerKey: ownerCurrent,
          _recipientCheckKey: validateRecipients,
          _sendStateKey: state,
        },
      );
    } finally {
      _protectedSends--;
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final cancellation = Zone.current[_cancellationKey] as SendCancellation?;
    _checkCancellation(cancellation);
    final protectedRoom = Zone.current[_encryptedRoomKey] as String?;
    final sendState = Zone.current[_sendStateKey] as _ProtectedSendState?;
    if (sendState?.invalid == true) {
      throw StateError('Encrypted key delivery failed; message not sent');
    }
    final ownerCurrent = Zone.current[_ownerKey] as bool Function()?;
    if (ownerCurrent != null && !ownerCurrent()) {
      throw StateError('Send belongs to an old session');
    }
    if ((protectedRoom != null || _protectedSends > 0) &&
        !encryptionAvailable()) {
      throw StateError('Encryption became unavailable before transmission');
    }

    final segments = request.url.pathSegments;
    final sendIndex = segments.indexOf('send');
    final roomIndex = segments.indexOf('rooms');
    if (roomIndex >= 0 &&
        sendIndex == roomIndex + 2 &&
        sendIndex + 1 < segments.length) {
      final roomId = segments[roomIndex + 1];
      final eventType = segments[sendIndex + 1];
      if ((protectedRoom == roomId || isEncryptedRoom(roomId)) &&
          eventType != 'm.room.encrypted' &&
          eventType != 'm.room.redaction') {
        throw StateError('Refusing plaintext event in encrypted room');
      }
    }
    final toDevice = segments.contains('sendToDevice');
    final roomSend = roomIndex >= 0 && sendIndex == roomIndex + 2;
    if (protectedRoom != null && (toDevice || roomSend)) {
      final check =
          Zone.current[_recipientCheckKey] as Future<void> Function()?;
      if (check == null) throw StateError('No approved recipient snapshot');
      await check();
      if (sendState?.invalid == true ||
          ownerCurrent == null ||
          !ownerCurrent() ||
          !encryptionAvailable()) {
        throw StateError('Encrypted send changed while checking recipients');
      }
    }
    _checkCancellation(cancellation);
    return await _inner.send(
      cancellation == null
          ? request
          : _CancellableRequest(request, cancellation.whenCancelled),
    );
  }

  @override
  void close() => _inner.close();
}

class _ProtectedSendState {
  bool invalid = false;
}

class _CancellableRequest extends http.BaseRequest with http.Abortable {
  _CancellableRequest(this.source, Future<void> cancellation)
    : abortTrigger = source is http.Abortable && source.abortTrigger != null
          ? Future.any([source.abortTrigger!, cancellation])
          : cancellation,
      super(source.method, source.url) {
    headers.addAll(source.headers);
    contentLength = source.contentLength;
    followRedirects = source.followRedirects;
    maxRedirects = source.maxRedirects;
    persistentConnection = source.persistentConnection;
  }

  final http.BaseRequest source;
  @override
  final Future<void> abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return source.finalize();
  }
}

// MSC4108 rendezvous session transport, matching matrix-rust-sdk
// `rendezvous_channel/msc_4108.rs` and matrix-js-sdk
// `MSC4108RendezvousSession`:
//
// - create: POST {homeserver}/_matrix/client/unstable/org.matrix.msc4108/
//   rendezvous (text/plain, empty) -> 200 {"url": ...} + ETag
// - connect (scanner): GET url -> the initial (empty) message + ETag
// - send: PUT url, text/plain, If-Match: <etag> -> new ETag
// - receive: GET url, If-None-Match: <etag>; 304 = nothing new yet, poll
//   again after a second; 200 text/plain with a body = the next message
// - 404 = the session is gone (expired or cancelled)
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const msc4108RendezvousPath =
    '_matrix/client/unstable/org.matrix.msc4108/rendezvous';

enum RendezvousFailure {
  /// 404: the session expired or the other device cancelled it.
  notFound,

  /// The server refused or failed a request.
  http,

  /// The connection failed or timed out.
  network,

  /// The server's response did not follow the protocol.
  protocol,

  /// This side gave up (user cancelled or the owner went away).
  cancelled,
}

class RendezvousException implements Exception {
  const RendezvousException(this.failure, [this.statusCode]);
  final RendezvousFailure failure;
  final int? statusCode;
  @override
  String toString() => 'RendezvousException(${failure.name}, $statusCode)';
}

/// Cooperative cancellation shared by the QR flows.
class QrCancellation {
  final _completer = Completer<void>();
  bool get cancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void check() {
    if (cancelled) {
      throw const RendezvousException(RendezvousFailure.cancelled);
    }
  }

  /// Waits [duration] unless cancelled first.
  Future<void> sleep(
    Duration duration,
    Future<void> Function(Duration) delay,
  ) async {
    await Future.any([delay(duration), whenCancelled]);
    check();
  }
}

Future<void> defaultQrDelay(Duration duration) =>
    Future<void>.delayed(duration);

/// Only HTTPS URLs without credentials, query-free fragments are allowed for
/// the rendezvous session (it carries ciphertext, but a plaintext transport
/// would still let a network attacker disrupt or observe the exchange).
bool isSafeRendezvousUrl(Uri? uri) =>
    uri != null &&
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment;

class RendezvousChannel {
  RendezvousChannel._(this._http, this.url, this._etag, this._delay);

  final http.Client _http;
  final Uri url;
  String _etag;
  final Future<void> Function(Duration) _delay;

  static const pollInterval = Duration(seconds: 1);
  static const requestTimeout = Duration(seconds: 30);

  /// MSC4108 messages are short; Synapse caps them at 10 KiB by default.
  static const maxMessageBytes = 64 * 1024;

  /// Creates a new session on [homeserver] (the side that shows a QR code).
  static Future<RendezvousChannel> create(
    http.Client client,
    Uri homeserver, {
    QrCancellation? cancellation,
    Future<void> Function(Duration) delay = defaultQrDelay,
  }) async {
    if (!isSafeRendezvousUrl(homeserver)) {
      throw const RendezvousException(RendezvousFailure.protocol);
    }
    final base = homeserver.path.endsWith('/')
        ? homeserver
        : homeserver.replace(path: '${homeserver.path}/');
    final endpoint = base.resolve(msc4108RendezvousPath);
    final response = await _send(
      client,
      'POST',
      endpoint,
      body: '',
      headers: {'content-type': 'text/plain'},
      cancellation: cancellation,
    );
    if (response.status == 404 || response.status == 405) {
      // The homeserver doesn't offer MSC4108 rendezvous.
      throw RendezvousException(RendezvousFailure.notFound, response.status);
    }
    _requireSuccess(response);
    final etag = response.headers['etag'];
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.body));
    } on FormatException {
      throw const RendezvousException(RendezvousFailure.protocol);
    }
    final url = json is Map ? Uri.tryParse('${json['url']}') : null;
    if (etag == null || etag.isEmpty || !isSafeRendezvousUrl(url)) {
      throw const RendezvousException(RendezvousFailure.protocol);
    }
    return RendezvousChannel._(client, url!, etag, delay);
  }

  /// Joins an existing session from a scanned QR code: reads the initial
  /// (empty) message to learn the current ETag.
  static Future<RendezvousChannel> connect(
    http.Client client,
    Uri url, {
    QrCancellation? cancellation,
    Future<void> Function(Duration) delay = defaultQrDelay,
  }) async {
    if (!isSafeRendezvousUrl(url)) {
      throw const RendezvousException(RendezvousFailure.protocol);
    }
    final response = await _send(
      client,
      'GET',
      url,
      cancellation: cancellation,
    );
    if (response.status == 404) {
      throw const RendezvousException(RendezvousFailure.notFound, 404);
    }
    _requireSuccess(response);
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw const RendezvousException(RendezvousFailure.protocol);
    }
    return RendezvousChannel._(client, url, etag, delay);
  }

  Future<void> send(String message, {QrCancellation? cancellation}) async {
    final response = await _send(
      _http,
      'PUT',
      url,
      body: message,
      headers: {'content-type': 'text/plain', 'if-match': _etag},
      cancellation: cancellation,
    );
    if (response.status == 404) {
      throw const RendezvousException(RendezvousFailure.notFound, 404);
    }
    _requireSuccess(response);
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw const RendezvousException(RendezvousFailure.protocol);
    }
    _etag = etag;
  }

  /// Polls until the other device writes a new message.
  Future<String> receive({QrCancellation? cancellation}) async {
    while (true) {
      cancellation?.check();
      final response = await _send(
        _http,
        'GET',
        url,
        headers: {'if-none-match': _etag},
        cancellation: cancellation,
      );
      final status = response.status;
      if (status == 404) {
        throw const RendezvousException(RendezvousFailure.notFound, 404);
      }
      if (status == 304) {
        final etag = response.headers['etag'];
        if (etag != null && etag.isNotEmpty) _etag = etag;
        await _pause(cancellation);
        continue;
      }
      _requireSuccess(response);
      final etag = response.headers['etag'];
      if (etag == null || etag.isEmpty) {
        throw const RendezvousException(RendezvousFailure.protocol);
      }
      _etag = etag;
      final type = response.headers['content-type'] ?? 'text/plain';
      if (response.body.isEmpty || !type.startsWith('text/plain')) {
        // Nothing for us yet (for example our own write was echoed as empty).
        await _pause(cancellation);
        continue;
      }
      try {
        return utf8.decode(response.body);
      } on FormatException {
        throw const RendezvousException(RendezvousFailure.protocol);
      }
    }
  }

  /// Best-effort removal of the session (used when cancelling).
  Future<void> close() async {
    try {
      await _send(_http, 'DELETE', url);
    } catch (_) {
      // The session expires on its own.
    }
  }

  Future<void> _pause(QrCancellation? cancellation) async {
    if (cancellation == null) {
      await _delay(pollInterval);
    } else {
      await cancellation.sleep(pollInterval, _delay);
    }
  }

  static void _requireSuccess(_Response response) {
    if (response.status < 200 || response.status >= 300) {
      throw RendezvousException(RendezvousFailure.http, response.status);
    }
  }

  static Future<_Response> _send(
    http.Client client,
    String method,
    Uri url, {
    String? body,
    Map<String, String> headers = const {},
    QrCancellation? cancellation,
  }) async {
    cancellation?.check();
    final request = http.Request(method, url)
      ..followRedirects = false
      ..headers.addAll(headers);
    if (body != null) request.bodyBytes = utf8.encode(body);
    try {
      final response = await client.send(request).timeout(requestTimeout);
      cancellation?.check();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxMessageBytes) {
          throw const RendezvousException(RendezvousFailure.protocol);
        }
        bytes.add(chunk);
      }
      cancellation?.check();
      return _Response(response.statusCode, {
        for (final entry in response.headers.entries)
          entry.key.toLowerCase(): entry.value,
      }, bytes.toBytes());
    } on RendezvousException {
      rethrow;
    } on TimeoutException {
      throw const RendezvousException(RendezvousFailure.network);
    } on http.ClientException {
      throw const RendezvousException(RendezvousFailure.network);
    }
  }
}

class _Response {
  _Response(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
}

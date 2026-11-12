// Test doubles for the QR login module: an in-memory MSC4108 rendezvous
// server behind an http MockClient, and scripted accounts.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parallax/features/qr_login/qr_grant_flow.dart';
import 'package:parallax/features/qr_login/qr_login_flow.dart';
import 'package:parallax/features/qr_login/qr_messages.dart';
import 'package:parallax/features/qr_login/rendezvous.dart';
import 'package:parallax/matrix_auth_service.dart';

/// Behaves like Synapse's MSC4108 rendezvous endpoint (ETag/If-Match/
/// If-None-Match, 304 while unchanged, 404 once gone).
class FakeRendezvousServer {
  FakeRendezvousServer({this.host = 'hs.example'});
  final String host;
  final sessions = <String, _Session>{};
  final requests = <http.BaseRequest>[];
  var _next = 0;

  /// Rejects requests that do not look like the protocol.
  final violations = <String>[];

  late final http.Client client = MockClient(_handle);

  Uri get homeserver => Uri.parse('https://$host');

  /// Puts raw text into a session as if the other party wrote it.
  void inject(String id, String text) {
    final session = sessions[id]!;
    session.content = text;
    session.etag++;
  }

  void expire(String id) => sessions.remove(id);
  void expireAll() => sessions.clear();

  String idOf(Uri url) => url.pathSegments.last;

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    if (request.followRedirects) violations.add('redirects enabled');
    if (request.url.scheme != 'https') violations.add('not https');
    final path = request.url.path;
    if (request.method == 'POST' &&
        path == '/_matrix/client/unstable/org.matrix.msc4108/rendezvous') {
      if (!(request.headers['content-type'] ?? '').startsWith('text/plain')) {
        violations.add('POST without text/plain');
      }
      final id = 'rz${_next++}';
      sessions[id] = _Session();
      return http.Response(
        jsonEncode({'url': 'https://rz.example/rendezvous/$id'}),
        201,
        headers: {
          'etag': '1',
          'content-type': 'application/json',
          'expires': 'Wed, 07 Sep 2022 14:28:51 GMT',
        },
      );
    }
    if (request.url.host == 'rz.example' && path.startsWith('/rendezvous/')) {
      final session = sessions[request.url.pathSegments.last];
      if (session == null) {
        return http.Response(
          jsonEncode({'errcode': 'M_NOT_FOUND', 'error': 'gone'}),
          404,
        );
      }
      switch (request.method) {
        case 'GET':
          final ifNoneMatch = request.headers['if-none-match'];
          if (ifNoneMatch == '${session.etag}') {
            return http.Response('', 304, headers: {'etag': '${session.etag}'});
          }
          return http.Response(
            session.content,
            200,
            headers: {'etag': '${session.etag}', 'content-type': 'text/plain'},
          );
        case 'PUT':
          if (request.headers['if-match'] != '${session.etag}') {
            violations.add('PUT with stale If-Match');
            return http.Response('', 412, headers: {'etag': '${session.etag}'});
          }
          if (!(request.headers['content-type'] ?? '').startsWith(
            'text/plain',
          )) {
            violations.add('PUT without text/plain');
          }
          session.content = request.body;
          session.etag++;
          session.writes.add(request.body);
          return http.Response('', 202, headers: {'etag': '${session.etag}'});
        case 'DELETE':
          sessions.remove(request.url.pathSegments.last);
          return http.Response('', 204);
      }
    }
    return http.Response('{"errcode":"M_UNRECOGNIZED"}', 404);
  }
}

class _Session {
  String content = '';
  int etag = 1;
  final writes = <String>[];
}

/// Yields to the event loop instead of sleeping.
Future<void> fastDelay(Duration _) => Future<void>.delayed(Duration.zero);

enum FakeAuthorizationOutcome { approve, decline, expire }

/// The new device's account side: device authorization is simulated; the
/// test (or a linked [FakeGrantAccount]) decides the outcome.
class FakeLoginAccount implements QrLoginAccount {
  FakeLoginAccount({this.outcome = FakeAuthorizationOutcome.approve});
  FakeAuthorizationOutcome outcome;
  String? server;
  final approved = Completer<void>();
  final committed = Completer<void>();
  QrSecretsBundle? imported;
  Object? importError;
  bool waitForApproval = true;
  DeviceAuthorizationGrant grant = DeviceAuthorizationGrant(
    deviceId: 'NEWDEVICE',
    userCode: 'ABCD-1234',
    verificationUri: Uri.parse('https://auth.example/link'),
    verificationUriComplete: Uri.parse(
      'https://auth.example/link?code=ABCD-1234',
    ),
  );

  void approve() {
    if (!approved.isCompleted) approved.complete();
  }

  @override
  Future<void> signInWithDeviceAuthorization(
    String serverNameOrUrl, {
    required Future<void> Function(DeviceAuthorizationGrant grant) onGrant,
    required Future<void> Function() afterCommit,
    required QrCancellation cancellation,
  }) async {
    server = serverNameOrUrl;
    await onGrant(grant);
    if (waitForApproval) {
      await Future.any([approved.future, cancellation.whenCancelled]);
    }
    if (cancellation.cancelled) {
      throw const DeviceAuthorizationException(
        DeviceAuthorizationFailure.cancelled,
      );
    }
    switch (outcome) {
      case FakeAuthorizationOutcome.decline:
        throw const DeviceAuthorizationException(
          DeviceAuthorizationFailure.declined,
        );
      case FakeAuthorizationOutcome.expire:
        throw const DeviceAuthorizationException(
          DeviceAuthorizationFailure.expired,
        );
      case FakeAuthorizationOutcome.approve:
        committed.complete();
        await afterCommit();
    }
  }

  @override
  Future<void> importSecrets(QrSecretsBundle bundle) async {
    if (importError != null) throw importError!;
    imported = bundle;
  }
}

class FakeGrantAccount implements QrGrantAccount {
  FakeGrantAccount({required this.homeserver, this.login});
  @override
  final Uri homeserver;

  /// When set, opening the approval page approves that login and creates
  /// its device (as the browser + authorization server would).
  final FakeLoginAccount? login;
  final devices = <String>{'EXISTING'};
  final opened = <Uri>[];

  @override
  Future<bool> deviceExists(String deviceId) async =>
      devices.contains(deviceId);

  @override
  Future<bool> openVerificationUri(Uri uri) async {
    opened.add(uri);
    final login = this.login;
    if (login != null) {
      if (login.outcome == FakeAuthorizationOutcome.approve) {
        devices.add(login.grant.deviceId);
      }
      login.approve();
    }
    return true;
  }
}

QrSecretsBundle testSecrets() => QrSecretsBundle(
  masterKey: 'rTtSv67XGS6k/rg6/yTG/m573cyFTPFRqluFhQY+hSw',
  selfSigningKey: '4jbPt7jh5D2iyM4U+3IDa+WthgJB87IQN1ATdkau+xk',
  userSigningKey: 'YkFKtkjcsTxF6UAzIIG/l6Nog/G2RigCRfWj3cjNWeM',
  backup: const QrBackupSecret(
    key: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    version: '2',
  ),
);

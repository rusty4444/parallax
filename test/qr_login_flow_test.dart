// Protocol state machines: the new-device login flow and the existing-device
// grant flow run against each other through an in-memory MSC4108
// rendezvous server, plus scripted counterparts for the error paths.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/qr_login/ecies.dart';
import 'package:parallax/features/qr_login/matrix_qr_login.dart'
    show isTrustedVerificationUri;
import 'package:parallax/features/qr_login/qr_code_data.dart';
import 'package:parallax/features/qr_login/qr_grant_flow.dart';
import 'package:parallax/features/qr_login/qr_login_flow.dart';
import 'package:parallax/features/qr_login/qr_messages.dart';
import 'package:parallax/features/qr_login/rendezvous.dart';
import 'package:parallax/features/qr_login/secure_channel.dart';
import 'package:parallax/matrix_auth_service.dart';

import 'qr_login_fakes.dart';

class _Run {
  _Run(this.server, {FakeAuthorizationOutcome? outcome})
    : login = FakeLoginAccount(
        outcome: outcome ?? FakeAuthorizationOutcome.approve,
      ) {
    grantAccount = FakeGrantAccount(
      homeserver: server.homeserver,
      login: login,
    );
  }
  final FakeRendezvousServer server;
  final FakeLoginAccount login;
  late final FakeGrantAccount grantAccount;
  final loginSteps = <QrLoginStep>[];
  final grantSteps = <QrGrantStep>[];
  final loginCancel = QrCancellation();
  final grantCancel = QrCancellation();
  final qr = Completer<QrCodeData>();

  /// Digits typed on the existing device; null = what the new device shows.
  int? typedCode;

  Future<(QrLoginStep, QrGrantStep)> run() async {
    final grant = QrGrantFlow(
      client: server.client,
      account: grantAccount,
      secrets: testSecrets(),
      delay: fastDelay,
      onStep: (step) {
        grantSteps.add(step);
        if (step is QrGrantQrReady && !qr.isCompleted) qr.complete(step.data);
        if (step is QrGrantQrScanned) {
          // The user reads the code off the new device and types it.
          unawaited(
            _shownCode(
              loginSteps,
            ).then((shown) => step.checkCode.complete(typedCode ?? shown)),
          );
        }
      },
    ).run(grantCancel);
    final data = await qr.future;
    final loginRun = QrLoginFlow(
      client: server.client,
      account: login,
      delay: fastDelay,
      onStep: loginSteps.add,
    ).run(data, loginCancel);
    return (await loginRun, await grant);
  }
}

/// Waits until the new device shows its check code.
Future<int> _shownCode(List<QrLoginStep> steps) async {
  while (steps.whereType<QrLoginEstablishingSecureChannel>().isEmpty) {
    await Future<void>.delayed(Duration.zero);
  }
  return int.parse(
    steps.whereType<QrLoginEstablishingSecureChannel>().last.checkCode,
  );
}

void main() {
  late FakeRendezvousServer server;
  setUp(() => server = FakeRendezvousServer());

  group('login flow against the grant flow', () {
    test('happy path: check code, device grant, secrets', () async {
      final run = _Run(server);
      final (login, grant) = await run.run();
      expect(login, isA<QrLoginFinished>());
      expect((login as QrLoginFinished).verified, isTrue);
      expect(grant, isA<QrGrantDone>());

      // Login side steps, as Element X's QrCodeLoginStep.
      expect(run.loginSteps.map((s) => s.runtimeType).toList(), [
        QrLoginStarting,
        QrLoginEstablishingSecureChannel,
        QrLoginWaitingForToken,
        QrLoginSyncingSecrets,
        QrLoginFinished,
      ]);
      final code = run.loginSteps
          .whereType<QrLoginEstablishingSecureChannel>()
          .single
          .checkCode;
      expect(code, matches(RegExp(r'^\d\d$')));
      expect(
        run.loginSteps.whereType<QrLoginWaitingForToken>().single.userCode,
        'ABCD-1234',
      );

      // The new device used the homeserver URL from the QR code.
      expect(run.login.server, 'https://hs.example');
      // The existing device opened verification_uri_complete.
      expect(run.grantAccount.opened, [
        Uri.parse('https://auth.example/link?code=ABCD-1234'),
      ]);
      // Secrets arrived intact.
      final imported = run.login.imported!;
      expect(imported.masterKey, testSecrets().masterKey);
      expect(imported.selfSigningKey, testSecrets().selfSigningKey);
      expect(imported.userSigningKey, testSecrets().userSigningKey);
      expect(imported.backup!.version, '2');

      expect(run.grantSteps.map((s) => s.runtimeType).toList(), [
        QrGrantStarting,
        QrGrantQrReady,
        QrGrantQrScanned,
        QrGrantWaitingForAuth,
        QrGrantSyncingSecrets,
        QrGrantDone,
      ]);
      expect(server.violations, isEmpty);
      // Nothing but ciphertext crossed the rendezvous server.
      final writes = server.sessions.values.expand((s) => s.writes).join('\n');
      expect(writes, isNot(contains('m.login')));
      expect(writes, isNot(contains(testSecrets().masterKey)));
    });

    test('wrong check code: the existing device refuses the channel', () async {
      final run = _Run(server)..typedCode = 100; // never a valid code
      final grantDone = Completer<QrGrantStep>();
      final grant = QrGrantFlow(
        client: server.client,
        account: run.grantAccount,
        secrets: testSecrets(),
        delay: fastDelay,
        onStep: (step) {
          if (step is QrGrantQrReady && !run.qr.isCompleted) {
            run.qr.complete(step.data);
          }
          if (step is QrGrantQrScanned) step.checkCode.complete(100);
          if (step is QrGrantFailed) grantDone.complete(step);
        },
      ).run(run.grantCancel);
      final login = QrLoginFlow(
        client: server.client,
        account: run.login,
        delay: fastDelay,
        onStep: run.loginSteps.add,
      ).run(await run.qr.future, run.loginCancel);
      final failed = await grantDone.future as QrGrantFailed;
      expect(failed.error, QrGrantError.invalidCheckCode);
      await grant;
      // The new device keeps waiting until the session expires.
      server.expireAll();
      final result = await login as QrLoginFailed;
      expect(result.error, QrLoginError.notFound);
      expect(run.login.imported, isNull);
    });

    test('declined on the other device', () async {
      final run = _Run(server, outcome: FakeAuthorizationOutcome.decline);
      final (login, grant) = await run.run();
      expect((login as QrLoginFailed).error, QrLoginError.declined);
      expect((grant as QrGrantFailed).error, QrGrantError.declined);
      expect(run.login.imported, isNull);
    });

    test('device code expired', () async {
      final run = _Run(server, outcome: FakeAuthorizationOutcome.expire);
      final (login, grant) = await run.run();
      expect((login as QrLoginFailed).error, QrLoginError.expired);
      expect((grant as QrGrantFailed).error, QrGrantError.expired);
    });

    test('device ID already in use is refused', () async {
      final run = _Run(server);
      run.grantAccount.devices.add('NEWDEVICE');
      final (login, grant) = await run.run();
      expect((grant as QrGrantFailed).error, QrGrantError.deviceIdAlreadyInUse);
      expect((login as QrLoginFailed).error, QrLoginError.unknown);
    });

    test('an approval URL off the account provider is refused', () async {
      final run = _Run(server);
      run.grantAccount.trustApproval = false;
      final (login, grant) = await run.run();
      expect((grant as QrGrantFailed).error, QrGrantError.unknown);
      expect(run.grantAccount.opened, isEmpty);
      // The new device is told the protocol was not accepted.
      expect((login as QrLoginFailed).error, QrLoginError.linkingNotSupported);
    });

    test('secrets import failure still finishes the sign-in', () async {
      final run = _Run(server);
      run.login.importError = StateError('no keys');
      final (login, grant) = await run.run();
      expect(login, isA<QrLoginFinished>());
      expect((login as QrLoginFinished).verified, isFalse);
      expect(grant, isA<QrGrantDone>());
    });

    test('cancelling on the new device tells the other device', () async {
      final run = _Run(server);
      run.login.waitForApproval = true;
      run.grantAccount.devices.clear();
      // Approve nothing: the grant flow waits for m.login.success.
      final grantAccount = FakeGrantAccount(homeserver: server.homeserver);
      final grantDone = Completer<QrGrantStep>();
      final qr = Completer<QrCodeData>();
      final loginSteps = <QrLoginStep>[];
      unawaited(
        QrGrantFlow(
          client: server.client,
          account: grantAccount,
          secrets: testSecrets(),
          delay: fastDelay,
          onStep: (step) {
            if (step is QrGrantQrReady && !qr.isCompleted) {
              qr.complete(step.data);
            }
            if (step is QrGrantQrScanned) {
              unawaited(_shownCode(loginSteps).then(step.checkCode.complete));
            }
            if (step is QrGrantFailed || step is QrGrantDone) {
              grantDone.complete(step);
            }
          },
        ).run(QrCancellation()),
      );
      final cancel = QrCancellation();
      final login = QrLoginFlow(
        client: server.client,
        account: run.login,
        delay: fastDelay,
        onStep: (step) {
          loginSteps.add(step);
          if (step is QrLoginWaitingForToken) cancel.cancel();
        },
      ).run(await qr.future, cancel);
      expect((await login as QrLoginFailed).error, QrLoginError.cancelled);
      expect(
        (await grantDone.future as QrGrantFailed).error,
        QrGrantError.cancelled,
      );
    });
  });

  group('login flow edge cases', () {
    QrLoginFlow flow(FakeLoginAccount account, List<QrLoginStep> steps) =>
        QrLoginFlow(
          client: server.client,
          account: account,
          delay: fastDelay,
          onStep: steps.add,
        );

    test('a login QR code means the other device is not signed in', () async {
      final steps = <QrLoginStep>[];
      final data = QrCodeData.msc4108(
        publicKey: Uint8List(32)..[0] = 9,
        rendezvousUrl: 'https://rz.example/rendezvous/x',
      );
      final result = await flow(
        FakeLoginAccount(),
        steps,
      ).run(data, QrCancellation());
      expect(
        (result as QrLoginFailed).error,
        QrLoginError.otherDeviceNotSignedIn,
      );
      expect(server.requests, isEmpty);
    });

    test('MSC4388 codes are reported as unsupported', () async {
      final data = QrCodeData.msc4388(
        publicKey: Uint8List(32)..[0] = 9,
        intent: QrCodeIntent.reciprocate,
        rendezvousId: 'abc',
        baseUrl: 'https://hs.example',
      );
      final result = await flow(
        FakeLoginAccount(),
        [],
      ).run(data, QrCancellation());
      expect(
        (result as QrLoginFailed).error,
        QrLoginError.unsupportedQrCodeType,
      );
      expect(server.requests, isEmpty);
    });

    test('an expired rendezvous session maps to "expired"', () async {
      final data = QrCodeData.msc4108(
        publicKey: (await Ecies.create()).publicKey,
        rendezvousUrl: 'https://rz.example/rendezvous/missing',
        serverName: 'hs.example',
      );
      final result = await flow(
        FakeLoginAccount(),
        [],
      ).run(data, QrCancellation());
      expect((result as QrLoginFailed).error, QrLoginError.notFound);
    });

    test('a non-HTTPS rendezvous URL is refused before connecting', () async {
      final data = QrCodeData.msc4108(
        publicKey: (await Ecies.create()).publicKey,
        rendezvousUrl: 'http://rz.example/rendezvous/x',
        serverName: 'hs.example',
      );
      final result = await flow(
        FakeLoginAccount(),
        [],
      ).run(data, QrCancellation());
      expect((result as QrLoginFailed).error, QrLoginError.unknown);
      expect(server.requests, isEmpty);
    });

    test('an undecryptable reply is an insecure connection', () async {
      // The QR device publishes a key, but a third party answers.
      final generated = await GeneratedSecureChannel.create(
        server.client,
        server.homeserver,
        serverName: 'https://hs.example',
        delay: fastDelay,
      );
      final id = server.idOf(Uri.parse(generated.qrCodeData.rendezvousUrl!));
      final result = flow(
        FakeLoginAccount(),
        [],
      ).run(generated.qrCodeData, QrCancellation());
      // Wait for the initiate message, then reply with garbage ciphertext.
      while (server.sessions[id]!.writes.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      server.inject(id, encodeUnpaddedBase64(List.filled(40, 7)));
      expect(
        (await result as QrLoginFailed).error,
        QrLoginError.connectionInsecure,
      );
    });

    test('the other device reporting unsupported protocol', () async {
      final generated = await GeneratedSecureChannel.create(
        server.client,
        server.homeserver,
        serverName: 'https://hs.example',
        delay: fastDelay,
      );
      final steps = <QrLoginStep>[];
      final result = flow(
        FakeLoginAccount(),
        steps,
      ).run(generated.qrCodeData, QrCancellation());
      final pending = await generated.connect();
      while (steps.whereType<QrLoginEstablishingSecureChannel>().isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final channel = pending.confirm(
        int.parse(
          steps.whereType<QrLoginEstablishingSecureChannel>().single.checkCode,
        ),
      );
      final protocol = await channel.receiveJson();
      expect(protocol['type'], QrMessageType.protocol);
      expect(protocol['protocol'], deviceAuthorizationGrantProtocol);
      expect(protocol['device_id'], 'NEWDEVICE');
      expect(
        (protocol[deviceAuthorizationGrantProtocol] as Map)['verification_uri'],
        'https://auth.example/link',
      );
      await channel.sendJson(qrFailure(QrFailureReason.unsupportedProtocol));
      expect(
        (await result as QrLoginFailed).error,
        QrLoginError.linkingNotSupported,
      );
    });

    test('the grant rotates an unscanned, expired QR code', () async {
      final ready = <QrCodeData>[];
      final cancel = QrCancellation();
      final grant = QrGrantFlow(
        client: server.client,
        account: FakeGrantAccount(homeserver: server.homeserver),
        secrets: testSecrets(),
        delay: fastDelay,
        maxQrRotations: 2,
        onStep: (step) {
          if (step is QrGrantQrReady) {
            ready.add(step.data);
            server.expireAll();
          }
        },
      ).run(cancel);
      final result = await grant as QrGrantFailed;
      expect(ready, hasLength(2));
      expect(ready[0].rendezvousUrl, isNot(ready[1].rendezvousUrl));
      expect(ready.every((d) => d.intent == QrCodeIntent.reciprocate), isTrue);
      expect(ready.first.serverName, 'https://hs.example');
      expect(result.error, QrGrantError.notFound);
    });
  });

  test('approval URLs must be on the account provider host', () {
    final provider = [
      Uri.parse('https://example.com/'),
      Uri.parse('https://auth.example.com/authorize'),
    ];
    expect(
      isTrustedVerificationUri(
        Uri.parse('https://auth.example.com/link?code=ABCD'),
        provider,
      ),
      isTrue,
    );
    for (final bad in [
      'https://auth.example.com.evil.test/link',
      'http://auth.example.com/link',
      'https://user@auth.example.com/link',
      'https://auth.example.com:8443/link',
      'https://auth.example.com/link#x',
    ]) {
      expect(isTrustedVerificationUri(Uri.parse(bad), provider), isFalse);
    }
    expect(
      isTrustedVerificationUri(Uri.parse('https://example.com/link'), []),
      isFalse,
    );
  });

  group('error mapping (Element X HumanQrLoginError)', () {
    test('maps channel, transport and authorization failures', () {
      expect(
        mapQrLoginError(
          const SecureChannelException(SecureChannelFailure.invalidIntent),
        ),
        QrLoginError.otherDeviceNotSignedIn,
      );
      expect(
        mapQrLoginError(
          const SecureChannelException(SecureChannelFailure.insecure),
        ),
        QrLoginError.connectionInsecure,
      );
      expect(
        mapQrLoginError(const RendezvousException(RendezvousFailure.notFound)),
        QrLoginError.notFound,
      );
      expect(
        mapQrLoginError(const RendezvousException(RendezvousFailure.network)),
        QrLoginError.connectionLost,
      );
      expect(
        mapQrLoginError(
          const DeviceAuthorizationException(
            DeviceAuthorizationFailure.unsupported,
          ),
        ),
        QrLoginError.providerNotSupported,
      );
      expect(
        mapQrLoginError(const FormatException('metadata')),
        QrLoginError.oauthMetadataInvalid,
      );
      expect(mapQrLoginError(StateError('x')), QrLoginError.unknown);
      expect(
        mapQrGrantError(
          const SecureChannelException(SecureChannelFailure.invalidCheckCode),
        ),
        QrGrantError.invalidCheckCode,
      );
    });
  });

  group('messages', () {
    test('protocol message matches the Rust MSC4108 layout', () {
      final message = qrProtocolMessage(
        grant: DeviceAuthorizationGrantData(
          verificationUri: Uri.parse(
            'https://id.matrix.org/device/abcde?code=ABCDE',
          ),
          verificationUriComplete: Uri.parse(
            'https://id.matrix.org/device/abcde',
          ),
        ),
        deviceId: 'wjLpTLRqbqBzLs63aYaEv2Boi6cFEbbM/sSRQ2oAKk4',
      );
      expect(message, {
        'type': 'm.login.protocol',
        'protocol': 'device_authorization_grant',
        'device_authorization_grant': {
          'verification_uri_complete': 'https://id.matrix.org/device/abcde',
          'verification_uri': 'https://id.matrix.org/device/abcde?code=ABCDE',
        },
        'device_id': 'wjLpTLRqbqBzLs63aYaEv2Boi6cFEbbM/sSRQ2oAKk4',
      });
      final parsed = parseQrProtocol(
        jsonDecode(jsonEncode(message)) as Map<String, Object?>,
      )!;
      expect(parsed.deviceId, 'wjLpTLRqbqBzLs63aYaEv2Boi6cFEbbM/sSRQ2oAKk4');
      // The flat MSC4388 layout is understood too, like Rust.
      final flat = parseQrProtocol({
        'type': 'm.login.protocol',
        'protocol': 'device_authorization_grant',
        'verification_uri': 'https://id.matrix.org/device/abcde',
        'device_id': 'ABCDEFGH',
      })!;
      expect(
        flat.grant.approvalUri.toString(),
        'https://id.matrix.org/device/abcde',
      );
      expect(
        parseQrProtocol({
          'type': 'm.login.protocol',
          'protocol': 'org.example.future',
          'device_id': 'X',
        }),
        isNull,
      );
      expect(
        () => parseQrProtocol({
          'type': 'm.login.protocol',
          'protocol': 'device_authorization_grant',
          'device_authorization_grant': {'verification_uri': 'http://x'},
          'device_id': 'X',
        }),
        throwsFormatException,
      );
    });

    test('secrets bundle matches the Rust test vector', () {
      final json = {
        'type': 'm.login.secrets',
        'cross_signing': {
          'master_key': 'rTtSv67XGS6k/rg6/yTG/m573cyFTPFRqluFhQY+hSw',
          'self_signing_key': '4jbPt7jh5D2iyM4U+3IDa+WthgJB87IQN1ATdkau+xk',
          'user_signing_key': 'YkFKtkjcsTxF6UAzIIG/l6Nog/G2RigCRfWj3cjNWeM',
        },
        'backup': {
          'algorithm': 'm.megolm_backup.v1.curve25519-aes-sha2',
          'backup_version': '2',
          'key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        },
      };
      final bundle = QrSecretsBundle.parse(json);
      expect(bundle.toMessage(), json);
      expect(
        () => QrSecretsBundle.parse({
          'type': 'm.login.secrets',
          'cross_signing': {'master_key': 'AAAA'},
        }),
        throwsFormatException,
      );
      expect(
        QrFailureReason.parse('user_cancelled'),
        QrFailureReason.userCancelled,
      );
      expect(QrFailureReason.parse('nonsense'), QrFailureReason.unknown);
    });
  });
}

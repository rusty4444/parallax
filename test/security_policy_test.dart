import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/crypto_setup_policy.dart';
import 'package:parallax/features/security/security_features.dart';
import 'package:parallax/features/security/security_policy.dart';

SessionSecurityState _state({
  bool encryption = true,
  bool identity = true,
  bool verified = false,
}) => SessionSecurityState(
  encryptionAvailable: encryption,
  accountHasIdentity: identity,
  deviceVerified: verified,
  setupAvailability: identity
      ? CryptoSetupAvailability.restore
      : CryptoSetupAvailability.create,
);

void main() {
  group('decideSecurityGate', () {
    SecurityGateStep decide({
      bool encryption = true,
      bool verified = false,
      bool deferred = false,
      SessionSecurityState? state,
    }) => decideSecurityGate(
      encryptionAvailable: encryption,
      deviceVerified: verified,
      deferred: deferred,
      state: state,
    );

    test('never blocks without encryption', () {
      expect(decide(encryption: false), SecurityGateStep.unlocked);
      expect(
        decide(state: _state(encryption: false)),
        SecurityGateStep.unlocked,
      );
    });

    test('a verified device passes immediately, even before loading', () {
      expect(decide(verified: true), SecurityGateStep.unlocked);
      expect(decide(state: _state(verified: true)), SecurityGateStep.unlocked);
    });

    test('keeps the app usable while checking', () {
      expect(decide(), SecurityGateStep.checking);
    });

    test('existing identity asks to confirm this device', () {
      expect(decide(state: _state()), SecurityGateStep.confirmIdentity);
    });

    test('new account routes to encryption setup', () {
      expect(
        decide(state: _state(identity: false)),
        SecurityGateStep.setUpEncryption,
      );
    });

    test('deferral unlocks until the next session', () {
      expect(
        decide(deferred: true, state: _state()),
        SecurityGateStep.unlocked,
      );
    });
  });

  group('chooseResetAuthStep', () {
    final homeserver = Uri.parse('https://matrix.example.org');
    ResetAuthStep choose(
      Set<String> stages, {
      Map<String, Object?> params = const {},
      String? session = 'abc',
      bool hasPassword = true,
      bool passwordTried = false,
      Uri? server,
    }) => chooseResetAuthStep(
      stages: stages,
      params: params,
      session: session,
      homeserver: server ?? homeserver,
      hasPassword: hasPassword,
      passwordTried: passwordTried,
    );

    test('answers the password stage once', () {
      expect(choose({passwordStage}), isA<PasswordAuthStep>());
      final again = choose({passwordStage}, passwordTried: true);
      expect(again, isA<UnsupportedAuthStep>());
    });

    test('opens the MAS approval page only over https', () {
      final step = choose(
        {crossSigningResetStage},
        params: {
          crossSigningResetStage: {
            'url': 'https://account.example.org/reset?action=x',
          },
        },
      );
      expect(step, isA<BrowserAuthStep>());
      expect(
        (step as BrowserAuthStep).url.toString(),
        'https://account.example.org/reset?action=x',
      );
      for (final unsafe in [
        'http://account.example.org/reset',
        'https://user@account.example.org/reset',
        'javascript:alert(1)',
      ]) {
        expect(
          choose(
            {crossSigningResetStage},
            params: {
              crossSigningResetStage: {'url': unsafe},
            },
          ),
          isA<UnsupportedAuthStep>(),
          reason: unsafe,
        );
      }
    });

    test('uses the spec web fallback for SSO accounts', () {
      final step = choose({ssoStage, passwordStage}, hasPassword: false);
      expect(step, isA<BrowserAuthStep>());
      expect(
        (step as BrowserAuthStep).url.toString(),
        'https://matrix.example.org/_matrix/client/v3/auth/m.login.sso/'
        'fallback/web?session=abc',
      );
    });

    test('refuses a fallback without a session or https homeserver', () {
      expect(
        choose({ssoStage}, session: null, hasPassword: false),
        isA<UnsupportedAuthStep>(),
      );
      expect(
        choose(
          {ssoStage},
          hasPassword: false,
          server: Uri.parse('http://insecure.example.org'),
        ),
        isA<UnsupportedAuthStep>(),
      );
      expect(choose({}), isA<UnsupportedAuthStep>());
    });
  });

  test('reset needs the exact confirmation word', () {
    expect(resetConfirmed('RESET'), isTrue);
    expect(resetConfirmed(' RESET '), isTrue);
    expect(resetConfirmed('reset'), isFalse);
    expect(resetConfirmed('RESE'), isFalse);
  });
}

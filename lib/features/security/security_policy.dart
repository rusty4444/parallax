import 'security_features.dart';

/// What the post-login security gate shows.
enum SecurityGateStep {
  /// Still checking (or the check failed): the app stays usable.
  checking,

  /// Nothing to do: verified, no encryption, or deferred by the user.
  unlocked,

  /// The account has an identity; confirm this device (Element X
  /// ChooseSelfVerificationMode).
  confirmIdentity,

  /// The account has no identity yet; set up encryption.
  setUpEncryption,
}

/// Pure gate decision. [deviceVerified] is the cheap local check, which
/// unlocks immediately once verification from another device lands.
SecurityGateStep decideSecurityGate({
  required bool encryptionAvailable,
  required bool deviceVerified,
  required bool deferred,
  SessionSecurityState? state,
}) {
  if (!encryptionAvailable || deviceVerified || deferred) {
    return SecurityGateStep.unlocked;
  }
  if (state == null) return SecurityGateStep.checking;
  if (!state.encryptionAvailable || state.deviceVerified) {
    return SecurityGateStep.unlocked;
  }
  return state.accountHasIdentity
      ? SecurityGateStep.confirmIdentity
      : SecurityGateStep.setUpEncryption;
}

/// How to answer one user-interactive-auth prompt during identity reset.
sealed class ResetAuthStep {
  const ResetAuthStep();
}

class PasswordAuthStep extends ResetAuthStep {
  const PasswordAuthStep();
}

class BrowserAuthStep extends ResetAuthStep {
  const BrowserAuthStep(this.url);
  final Uri url;
}

class UnsupportedAuthStep extends ResetAuthStep {
  const UnsupportedAuthStep(this.reason);
  final String reason;
}

const passwordStage = 'm.login.password';
const ssoStage = 'm.login.sso';
const crossSigningResetStage = 'org.matrix.cross_signing_reset';

bool isSafeApprovalUrl(Uri? url) =>
    url != null &&
    url.scheme == 'https' &&
    url.host.isNotEmpty &&
    url.userInfo.isEmpty &&
    url.fragment.isEmpty;

/// Chooses the next UIA action for `/keys/device_signing/upload`:
/// password when supplied (once), the MAS cross-signing reset approval page,
/// or the spec's web fallback for any other stage (SSO accounts).
ResetAuthStep chooseResetAuthStep({
  required Set<String> stages,
  required Map<String, Object?> params,
  required String? session,
  required Uri homeserver,
  required bool hasPassword,
  required bool passwordTried,
}) {
  if (stages.isEmpty) {
    return const UnsupportedAuthStep('The server offered no way to confirm.');
  }
  if (stages.contains(crossSigningResetStage)) {
    final info = params[crossSigningResetStage];
    final raw = info is Map ? info['url'] : null;
    final url = raw is String ? Uri.tryParse(raw) : null;
    return isSafeApprovalUrl(url)
        ? BrowserAuthStep(url!)
        : const UnsupportedAuthStep(
            'The server asked for approval at an unsafe address.',
          );
  }
  if (stages.contains(passwordStage) && hasPassword) {
    return passwordTried
        ? const UnsupportedAuthStep('Your account password was not accepted.')
        : const PasswordAuthStep();
  }
  if (session == null || session.isEmpty || homeserver.scheme != 'https') {
    return const UnsupportedAuthStep('The server needs a confirmation step.');
  }
  final stage = stages.contains(ssoStage)
      ? ssoStage
      : (stages.toList()..sort()).first;
  final base = homeserver.path.replaceAll(RegExp(r'/+$'), '');
  final url = homeserver.replace(
    path:
        '$base/_matrix/client/v3/auth/${Uri.encodeComponent(stage)}'
        '/fallback/web',
    queryParameters: {'session': session},
  );
  return isSafeApprovalUrl(url)
      ? BrowserAuthStep(url)
      : const UnsupportedAuthStep('The server needs a confirmation step.');
}

/// Typed confirmation required before a destructive reset.
const resetConfirmationWord = 'RESET';

bool resetConfirmed(String typed) => typed.trim() == resetConfirmationWord;

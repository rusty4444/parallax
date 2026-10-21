import 'package:matrix/matrix.dart' as matrix;

/// A successful HTTP response can still contain per-homeserver key failures.
/// Do not reuse cached trust when a member's key list was not returned.
bool keyQueryComplete(matrix.QueryKeysResponse response, Set<String> userIds) {
  if (response.failures?.isNotEmpty == true) return false;
  final deviceKeys = response.deviceKeys;
  if (deviceKeys == null) return false;
  return userIds.every(deviceKeys.containsKey);
}

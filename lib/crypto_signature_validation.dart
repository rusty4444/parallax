import 'dart:convert';

import 'package:matrix/encryption/utils/json_signature_check_extension.dart';
import 'package:matrix/matrix.dart' as matrix;

/// Verify a retained subkey's signature under the *current* master. The SDK
/// checker removes fields from its input, so pass a deep copy rather than
/// mutating the SDK's cached key object.
bool isSubkeySignedByMaster(
  matrix.MatrixCrossSigningKey subkey, {
  required String userId,
  required String masterPublicKey,
}) {
  final signedJson =
      jsonDecode(jsonEncode(subkey.toJson())) as Map<String, dynamic>;
  return signedJson.checkJsonSignature(
    masterPublicKey,
    userId,
    masterPublicKey,
  );
}

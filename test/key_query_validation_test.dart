import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:matrixpress/key_query_validation.dart';

void main() {
  const user = '@friend:example.org';
  final device = matrix.MatrixDeviceKeys(user, 'DEVICE', const [], const {
    'ed25519:DEVICE': 'key',
  }, const {});

  test('requires a returned device list for every recipient', () {
    expect(
      keyQueryComplete(
        matrix.QueryKeysResponse(
          deviceKeys: {
            user: {'DEVICE': device},
          },
        ),
        {user},
      ),
      isTrue,
    );
    expect(
      keyQueryComplete(matrix.QueryKeysResponse(deviceKeys: {user: {}}), {
        user,
      }),
      isTrue,
    );
    expect(
      keyQueryComplete(matrix.QueryKeysResponse(deviceKeys: {}), {user}),
      isFalse,
    );
  });

  test(
    'a federation failure invalidates cached trust even with device keys',
    () {
      final result = matrix.QueryKeysResponse(
        deviceKeys: {
          user: {'DEVICE': device},
        },
        failures: {'example.org': {}},
      );
      expect(keyQueryComplete(result, {user}), isFalse);
    },
  );
}

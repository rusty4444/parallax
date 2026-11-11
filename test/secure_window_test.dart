import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/secure_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('parallax/secure_window');

  test('recovery flow toggles Android screen protection', () async {
    final seen = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'setSecure');
          seen.add((call.arguments as Map)['enabled'] as bool);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await SecureWindow.setEnabled(true);
    await SecureWindow.setEnabled(false);
    expect(seen, [true, false]);
  });
}

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/platform/background_connection.dart';
import 'package:parallax/features/platform/platform_intents.dart';
import 'package:parallax/push_notifications.dart';

Map<String, Object?> _share(String path) => {
  'kind': 'share',
  'files': [
    {'path': path, 'name': 'a.png', 'mimeType': 'image/png', 'size': 10},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Windows share cache paths', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('accepts drive-letter paths with backslashes', () {
      final intent =
          parsePlatformIntent(
                _share(
                  r'C:\Users\sam\AppData\Local\Temp\parallax\shared_intents\1\a.png',
                ),
              )
              as ShareIntent;
      expect(intent.files.single.name, 'a.png');
    });

    test('accepts UNC paths', () {
      final intent =
          parsePlatformIntent(
                _share(r'\\server\share\parallax\shared_intents\1\a.png'),
              )
              as ShareIntent;
      expect(intent.files.single.name, 'a.png');
    });

    test('refuses traversal in either separator', () {
      final intent =
          parsePlatformIntent(
                _share(r'C:\temp\parallax\shared_intents\..\..\secret'),
              )
              as ShareIntent;
      expect(intent.files, isEmpty);
      expect(intent.skipped, 1);
      final forward =
          parsePlatformIntent(
                _share(r'C:\temp\parallax\shared_intents\1\..\secret'),
              )
              as ShareIntent;
      expect(forward.files, isEmpty);
      expect(forward.skipped, 1);
    });

    test('refuses paths outside the share cache', () {
      final intent =
          parsePlatformIntent(_share(r'C:\Users\sam\secret.png'))
              as ShareIntent;
      expect(intent.files, isEmpty);
      expect(intent.skipped, 1);
    });

    test('refuses relative paths', () {
      final intent =
          parsePlatformIntent(_share(r'parallax\shared_intents\1\a.png'))
              as ShareIntent;
      expect(intent.files, isEmpty);
      expect(intent.skipped, 1);
    });
  });

  group('Android share cache paths are unchanged', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('still accepts POSIX cache paths', () {
      final intent =
          parsePlatformIntent(
                _share('/data/user/0/app/cache/shared_intents/1/a.png'),
              )
              as ShareIntent;
      expect(intent.files.single.name, 'a.png');
    });

    test('refuses Windows drive paths', () {
      final intent =
          parsePlatformIntent(
                _share(r'C:\temp\parallax\shared_intents\1\a.png'),
              )
              as ShareIntent;
      expect(intent.files, isEmpty);
      expect(intent.skipped, 1);
    });
  });

  group('Windows background connection', () {
    const channel = MethodChannel('parallax/background_connection');
    final calls = <String>[];

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return call.method == 'start' ? true : null;
          });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('start and stop reach the runner', () async {
      const platform = MethodChannelBackgroundConnection();
      expect(await platform.start(), isTrue);
      await platform.stop();
      expect(calls, ['start', 'stop']);
    });

    test('battery exemption is a desktop no-op', () async {
      const platform = MethodChannelBackgroundConnection();
      expect(await platform.isIgnoringBatteryOptimizations(), isTrue);
      expect(await platform.requestIgnoreBatteryOptimizations(), isTrue);
      expect(calls, isEmpty);
    });
  });

  group('Windows notification details', () {
    test('generic alerts carry Windows details without actions', () {
      const envelope = PushEnvelope(
        registrationId: 'r',
        roomId: '!room:example.org',
      );
      final details = genericPushNotificationDetails(envelope);
      expect(details.windows, isNotNull);
      expect(details.windows!.actions, isEmpty);
    });

    test('message alerts offer Mark as read', () {
      const envelope = PushEnvelope(
        registrationId: 'r',
        roomId: '!room:example.org',
        eventId: r'$event',
      );
      final details = genericPushNotificationDetails(envelope);
      expect(details.windows!.actions.single.arguments, pushMarkReadActionId);
      expect(details.windows!.actions.single.content, 'Mark as read');
    });
  });
}

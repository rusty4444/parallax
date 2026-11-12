import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/notifications/notification_features.dart';
import 'package:parallax/features/platform/background_connection.dart';
import 'package:parallax/push_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal driver for the delivery choice: records what was started.
class _Driver
    implements PushDriver, PushDistributorSource, PushGatewayResolver {
  _Driver(this.name, this.log);
  final String name;
  final List<String> log;
  List<String> installed = const [];
  bool failToken = false;
  @override
  Future<List<String>> distributors() async => installed;
  @override
  Future<PushConfiguration> resolveGateway(
    String token,
    PushConfiguration configuration,
  ) async => configuration.withGateway(
    Uri.parse('https://ntfy.example.org/_matrix/push/v1/notify'),
  );
  @override
  Stream<String> get tokenChanges => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get messages => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get openedMessages => const Stream.empty();
  @override
  Future<void> initialize(PushConfiguration configuration) async =>
      log.add('$name.init');
  @override
  Future<PushPermission> requestPermission() async => PushPermission.authorized;
  @override
  Future<String?> getToken() async {
    if (failToken) {
      throw const PushSetupException('Choose a distributor.');
    }
    return 'https://ntfy.example.org/up$name';
  }

  @override
  Future<void> showNotification(PushEnvelope envelope) async {}
  @override
  Future<void> deactivate() async => log.add('$name.stop');
}

class _Store implements PushStateStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? value) async => this.value = value;
}

class _Connection implements BackgroundConnectionPlatform {
  bool allowStart = true;
  int starts = 0;
  int stops = 0;
  @override
  Future<bool> start() async {
    starts++;
    return allowStart;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => true;
}

void main() {
  group('syncedNotificationFor', () {
    test('passes ordinary events through', () {
      expect(
        syncedNotificationFor(
          roomId: '!r:example.org',
          eventId: r'$abc',
          type: 'm.room.message',
        ),
        (roomId: '!r:example.org', eventId: r'$abc'),
      );
    });

    test('gives the SDK’s synthetic invite a stable event ID', () {
      expect(
        syncedNotificationFor(
          roomId: '!r:example.org',
          eventId: 'invite_for_!r:example.org',
          type: 'm.room.member',
        ),
        (roomId: '!r:example.org', eventId: r'$invite:!r:example.org'),
      );
      final envelope = PushEnvelope.parse({
        'registration_id': 'A' * 32,
        'room_id': '!r:example.org',
        'event_id': r'$invite:!r:example.org',
      }, 'A' * 32);
      expect(envelope, isNotNull);
    });

    test('drops beacons, call membership and unusable IDs', () {
      for (final type in [
        'org.matrix.msc3672.beacon',
        'm.beacon',
        'm.call.member',
        'org.matrix.msc3401.call.member',
      ]) {
        expect(
          syncedNotificationFor(
            roomId: '!r:example.org',
            eventId: r'$abc',
            type: type,
          ),
          isNull,
        );
      }
      expect(
        syncedNotificationFor(
          roomId: '!r:example.org',
          eventId: 'local-echo',
          type: 'm.room.message',
        ),
        isNull,
      );
    });
  });

  group('startDefaultNotifications', () {
    late List<String> log;
    late _Driver builtIn;
    late _Driver unifiedPush;
    late PushNotifications push;
    late List<PushRegistration> pushers;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      log = [];
      pushers = [];
      builtIn = _Driver('builtIn', log);
      unifiedPush = _Driver('up', log);
      push = PushNotifications(
        driver: _Driver('firebase', log),
        inAppDriver: builtIn,
        unifiedPushDriver: unifiedPush,
        store: _Store(),
        configuration: const PushConfiguration.inApp(),
      );
      await push.setSession(
        PushSession(
          userId: '@me:example.org',
          deviceId: 'DEVICE',
          registerPusher: (r) async => pushers.add(r),
          removePusher: (_) async {},
          onNavigate: (_) async {},
        ),
      );
    });
    tearDown(() => push.shutdown());

    Future<bool> start({bool unifiedPushFailed = false}) =>
        startDefaultNotifications(
          push,
          isCurrent: () => true,
          unifiedPushFailed: unifiedPushFailed,
        );

    test(
      'uses the built-in connection when no distributor is installed',
      () async {
        expect(await start(), isFalse);
        expect(push.active, isTrue);
        expect(push.provider, PushProvider.inApp);
        expect(pushers, isEmpty);
        expect(log, ['builtIn.init']);
      },
    );

    test(
      'uses UnifiedPush automatically when a distributor is installed',
      () async {
        unifiedPush.installed = ['io.heckel.ntfy'];
        expect(await start(), isFalse);
        expect(push.active, isTrue);
        expect(push.provider, PushProvider.unifiedPush);
        expect(pushers.single.pusher.appId, unifiedPushAppId);
        expect(log, ['up.init']);
      },
    );

    test('switches to UnifiedPush once one is installed', () async {
      await start();
      expect(push.provider, PushProvider.inApp);
      unifiedPush.installed = ['io.heckel.ntfy'];
      await start();
      expect(push.provider, PushProvider.unifiedPush);
      expect(push.active, isTrue);
      expect(log, ['builtIn.init', 'builtIn.stop', 'up.init']);
    });

    test(
      'falls back to the built-in connection when UnifiedPush fails',
      () async {
        unifiedPush
          ..installed = [
            'io.heckel.ntfy',
            'org.unifiedpush.distributor.nextpush',
          ]
          ..failToken = true;
        expect(await start(), isTrue);
        expect(push.active, isTrue);
        expect(push.provider, PushProvider.inApp);
        expect(pushers, isEmpty);
        // Not retried in this process once it failed.
        expect(await start(unifiedPushFailed: true), isFalse);
        expect(push.provider, PushProvider.inApp);
      },
    );

    test(
      'respects the built-in choice and turning notifications off',
      () async {
        unifiedPush.installed = ['io.heckel.ntfy'];
        await InAppNotificationPreferences.setDelivery(
          NotificationDelivery.builtIn,
        );
        await start();
        expect(push.provider, PushProvider.inApp);
        await push.disable();
        await InAppNotificationPreferences.setTurnedOff(true);
        await start();
        expect(push.enabled, isFalse);
      },
    );
  });

  group('InAppPushDriver', () {
    test('starts the background connection only for a token', () async {
      final connection = _Connection();
      final driver = InAppPushDriver(platform: connection);
      expect(connection.starts, 0);
      expect(await driver.getToken(), inAppPushToken);
      expect(connection.starts, 1);
      expect(driver.connected, isTrue);
      await driver.deactivate();
      expect(connection.stops, 1);
      expect(driver.connected, isFalse);
    });

    test('reports when Android refuses the background connection', () async {
      final connection = _Connection()..allowStart = false;
      final driver = InAppPushDriver(platform: connection);
      await driver.getToken();
      expect(driver.connected, isFalse);
    });

    test('rejects a push-service configuration', () async {
      final driver = InAppPushDriver(platform: _Connection());
      expect(
        () => driver.initialize(const PushConfiguration.unifiedPush()),
        throwsStateError,
      );
    });
  });
}

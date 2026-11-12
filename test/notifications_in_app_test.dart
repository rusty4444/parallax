import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/notifications/notification_features.dart';
import 'package:parallax/features/platform/background_connection.dart';
import 'package:parallax/push_notifications.dart';

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

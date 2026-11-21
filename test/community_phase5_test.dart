import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/call/call_widget_url.dart';
import 'package:parallax/features/rooms_admin/rooms_admin_models.dart';
import 'package:parallax/features/widgets_host/widgets_host.dart';

void main() {
  group('widget URL validation', () {
    test('accepts plain HTTPS URLs', () {
      expect(parseWidgetUrl('https://example.com/widget')?.host, 'example.com');
      expect(parseWidgetUrl('  https://example.com/w  ')?.scheme, 'https');
    });

    test('rejects non-HTTPS, malformed and credential-bearing URLs', () {
      expect(parseWidgetUrl('http://example.com'), isNull);
      expect(parseWidgetUrl('javascript:alert(1)'), isNull);
      expect(parseWidgetUrl('https://user:pass@example.com'), isNull);
      expect(parseWidgetUrl(''), isNull);
      expect(parseWidgetUrl('not a url'), isNull);
    });
  });

  group('Element Call URL screen sharing', () {
    ElementCallUrlParams params({required bool screenSharing}) =>
        ElementCallUrlParams(
          baseUrl: Uri.parse('https://call.element.io'),
          widgetId: 'w1',
          userId: '@me:example.org',
          deviceId: 'DEV',
          roomId: '!room:example.org',
          homeserver: Uri.parse('https://example.org'),
          encrypted: true,
          intent: CallIntent.startCall,
          screenSharing: screenSharing,
        );

    test('hides screen sharing by default', () {
      final url = buildElementCallUrl(params(screenSharing: false));
      expect(elementCallFragmentParams(url)['hideScreensharing'], 'true');
    });

    test('offers screen sharing when enabled', () {
      final url = buildElementCallUrl(params(screenSharing: true));
      expect(elementCallFragmentParams(url)['hideScreensharing'], 'false');
    });
  });

  group('room creation options', () {
    test('broadcast and voice room flags default off and carry through', () {
      const plain = RoomCreationOptions(name: 'Room');
      expect(plain.broadcastChannel, isFalse);
      expect(plain.voiceRoom, isFalse);
      const special = RoomCreationOptions(
        name: 'Channel',
        broadcastChannel: true,
        voiceRoom: true,
      );
      expect(special.broadcastChannel, isTrue);
      expect(special.voiceRoom, isTrue);
    });
  });
}

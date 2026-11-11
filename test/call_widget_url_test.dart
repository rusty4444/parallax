import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/call/call_widget_url.dart';
import 'package:parallax/features/call/matrix_call_features.dart';

ElementCallUrlParams _params({
  String base = 'https://call.element.io',
  bool encrypted = true,
  CallIntent intent = CallIntent.startCall,
  String displayName = 'Sam Russell & co',
  double? fontScale,
}) => ElementCallUrlParams(
  baseUrl: Uri.parse(base),
  widgetId: 'w1',
  userId: '@sam:example.org',
  deviceId: 'ABCDEF',
  roomId: '!room:example.org',
  homeserver: Uri.parse('https://matrix.example.org'),
  encrypted: encrypted,
  intent: intent,
  displayName: displayName,
  language: 'en-AU',
  theme: 'dark',
  fontScale: fontScale,
);

void main() {
  test('intent table matches Element X', () {
    expect(
      callIntentFor(direct: false, hasActiveCall: false),
      CallIntent.startCall,
    );
    expect(
      callIntentFor(direct: false, hasActiveCall: true),
      CallIntent.joinExisting,
    );
    expect(
      callIntentFor(direct: true, hasActiveCall: false),
      CallIntent.startCallDm,
    );
    expect(
      callIntentFor(direct: true, hasActiveCall: true),
      CallIntent.joinExistingDm,
    );
    expect(
      callIntentFor(direct: true, hasActiveCall: false, audioOnly: true),
      CallIntent.startCallDmVoice,
    );
    expect(
      callIntentFor(direct: true, hasActiveCall: true, audioOnly: true),
      CallIntent.joinExistingDmVoice,
    );
    // Element Call's wire values.
    expect(CallIntent.joinExistingDmVoice.value, 'join_existing_dm_voice');
    expect(CallIntent.startCall.value, 'start_call');
  });

  test('builds a fragment-only widget URL on the hosted /room page', () {
    final url = buildElementCallUrl(_params());
    expect(url.scheme, 'https');
    expect(url.host, 'call.element.io');
    expect(url.path, '/room');
    expect(url.hasQuery, isFalse, reason: 'parameters stay client-side');
    final params = elementCallFragmentParams(url);
    expect(params, {
      'userId': '@sam:example.org',
      'roomId': '!room:example.org',
      'widgetId': 'w1',
      'displayName': 'Sam Russell & co',
      'lang': 'en-AU',
      'theme': 'dark',
      'clientId': parallaxCallClientId,
      'deviceId': 'ABCDEF',
      'baseUrl': 'https://matrix.example.org',
      'parentUrl': 'https://call.element.io/room',
      'confineToRoom': 'true',
      'appPrompt': 'false',
      'header': 'none',
      'hideHeader': 'true',
      'preload': 'false',
      'hideScreensharing': 'true',
      'perParticipantE2EE': 'true',
      'intent': 'start_call',
    });
    // Reserved characters are percent-encoded inside the fragment.
    expect(url.fragment, contains('displayName=Sam%20Russell%20%26%20co'));
    expect(url.fragment, contains('userId=%40sam%3Aexample.org'));
  });

  test('unencrypted rooms disable per-participant E2EE', () {
    final params = elementCallFragmentParams(
      buildElementCallUrl(
        _params(encrypted: false, intent: CallIntent.joinExistingDm),
      ),
    );
    expect(params['perParticipantE2EE'], 'false');
    expect(params['intent'], 'join_existing_dm');
  });

  test('explicit paths are kept and fontScale is only sent when scaled', () {
    final embedded = buildElementCallUrl(
      _params(base: 'https://calls.example.org/ec/index.html', fontScale: 1.3),
    );
    expect(embedded.path, '/ec/index.html');
    final params = elementCallFragmentParams(embedded);
    expect(params['fontScale'], '1.3');
    expect(params['parentUrl'], 'https://calls.example.org/ec/index.html');
    expect(
      elementCallFragmentParams(
        buildElementCallUrl(_params(fontScale: 1.0)),
      ).containsKey('fontScale'),
      isFalse,
    );
  });

  test('only plain HTTPS base URLs are accepted', () {
    expect(
      parseElementCallBaseUrl('https://call.example.org'),
      Uri.parse('https://call.example.org'),
    );
    expect(parseElementCallBaseUrl(' https://call.example.org/x '), isNotNull);
    for (final bad in [
      null,
      '',
      'http://call.example.org',
      'https://user:pw@call.example.org',
      'https://call.example.org/?a=b',
      'https://call.example.org/#frag',
      'javascript:alert(1)',
      'https:///nohost',
    ]) {
      expect(parseElementCallBaseUrl(bad), isNull, reason: '$bad');
    }
  });

  test('well-known discovery reads io.element.call and MatrixRTC foci', () {
    final discovery = parseCallDiscovery({
      'io.element.call': {'url': 'https://call.example.org'},
      'org.matrix.msc4143.rtc_foci': [
        {
          'type': 'livekit',
          'livekit_service_url': 'https://livekit-jwt.example.org',
        },
        {'type': 'livekit', 'livekit_service_url': 'http://insecure.example'},
        {'type': 'other', 'url': 'https://ignored.example'},
      ],
    });
    expect(discovery.elementCallUrl, Uri.parse('https://call.example.org'));
    expect(discovery.rtcFocusHosts, ['livekit-jwt.example.org']);

    final none = parseCallDiscovery({
      'io.element.call': {'url': 'http://downgrade.example'},
    });
    expect(none.elementCallUrl, isNull);
    expect(none.rtcFocusHosts, isEmpty);
  });
}

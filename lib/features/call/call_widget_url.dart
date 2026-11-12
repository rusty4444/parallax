// Element Call widget URL construction.
//
// Mirrors the matrix-rust-sdk `new_virtual_element_call_widget` +
// `generate_webview_url` pair used by Element X (DefaultCallWidgetProvider /
// DefaultCallWidgetSettingsProvider): every parameter lives in the URL
// fragment (`#?…`) so nothing reaches the Element Call web server.

/// The hosted Element Call deployment used when neither the user nor the
/// homeserver configures one.
const defaultElementCallUrl = 'https://call.element.io';

/// Identifies Parallax to Element Call (`clientId`).
const parallaxCallClientId = 'net.samrusselltech.parallax';

/// Element Call's `intent` URL parameter. Values must match Element Call's
/// `UrlParams.ts` (snake_case).
enum CallIntent {
  startCall('start_call'),
  joinExisting('join_existing'),
  startCallDm('start_call_dm'),
  joinExistingDm('join_existing_dm'),
  startCallDmVoice('start_call_dm_voice'),
  joinExistingDmVoice('join_existing_dm_voice');

  const CallIntent(this.value);
  final String value;

  bool get joinsExisting =>
      this == joinExisting ||
      this == joinExistingDm ||
      this == joinExistingDmVoice;
}

/// Same decision table as Element X's DefaultCallWidgetSettingsProvider.
CallIntent callIntentFor({
  required bool direct,
  required bool hasActiveCall,
  bool audioOnly = false,
}) {
  if (direct && hasActiveCall) {
    return audioOnly
        ? CallIntent.joinExistingDmVoice
        : CallIntent.joinExistingDm;
  }
  if (hasActiveCall) return CallIntent.joinExisting;
  if (direct) {
    return audioOnly ? CallIntent.startCallDmVoice : CallIntent.startCallDm;
  }
  return CallIntent.startCall;
}

/// Validates a user- or homeserver-supplied Element Call base URL. Returns
/// the normalised URL, or null when it is not an acceptable HTTPS origin.
Uri? parseElementCallBaseUrl(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty || text.length > 2048) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

/// The page that hosts the widget. Hosted Element Call serves widget mode at
/// `/room` (as Element Web uses); an explicit path (for example an embedded
/// `index.html` package) is kept as configured.
Uri elementCallPageUrl(Uri baseUrl) {
  final path = baseUrl.path;
  if (path.isEmpty || path == '/') return baseUrl.replace(path: '/room');
  return baseUrl;
}

/// Everything Element Call needs in its URL. All values are client data;
/// none are secrets (the OpenID token is requested later over the widget
/// API, never placed in the URL).
class ElementCallUrlParams {
  const ElementCallUrlParams({
    required this.baseUrl,
    required this.widgetId,
    required this.userId,
    required this.deviceId,
    required this.roomId,
    required this.homeserver,
    required this.encrypted,
    required this.intent,
    this.displayName = '',
    this.language = 'en-AU',
    this.theme = 'dark',
    this.clientId = parallaxCallClientId,
    this.fontScale,
  });

  final Uri baseUrl;
  final String widgetId;
  final String userId;
  final String deviceId;
  final String roomId;
  final Uri homeserver;
  final bool encrypted;
  final CallIntent intent;
  final String displayName;
  final String language;
  final String theme;
  final String clientId;
  final double? fontScale;
}

/// Builds the WebView URL. Parameter order follows the Rust SDK so URLs are
/// easy to compare against Element X logs.
Uri buildElementCallUrl(ElementCallUrlParams p) {
  final page = elementCallPageUrl(p.baseUrl);
  final params = <(String, String)>[
    ('userId', p.userId),
    ('roomId', p.roomId),
    ('widgetId', p.widgetId),
    ('displayName', p.displayName),
    ('lang', p.language),
    ('theme', p.theme),
    ('clientId', p.clientId),
    ('deviceId', p.deviceId),
    ('baseUrl', p.homeserver.toString()),
    // The WebView posts to itself, so the parent is the widget page.
    ('parentUrl', page.toString()),
    ('confineToRoom', 'true'),
    ('appPrompt', 'false'),
    ('header', 'none'),
    ('hideHeader', 'true'),
    ('preload', 'false'),
    // Android WebView has no getDisplayMedia, so screen sharing cannot work.
    ('hideScreensharing', 'true'),
    ('perParticipantE2EE', p.encrypted ? 'true' : 'false'),
    ('intent', p.intent.value),
    if (p.fontScale case final scale? when (scale - 1).abs() > 0.01)
      ('fontScale', _trimDouble(scale)),
  ];
  final fragment = params
      .map((e) => '${e.$1}=${Uri.encodeComponent(e.$2)}')
      .join('&');
  return page.replace(fragment: '?$fragment');
}

String _trimDouble(double value) {
  final text = value.toStringAsFixed(2);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Reads the URL fragment parameters back (tests and diagnostics).
Map<String, String> elementCallFragmentParams(Uri url) {
  final fragment = url.fragment;
  final query = fragment.startsWith('?') ? fragment.substring(1) : fragment;
  if (query.isEmpty) return const {};
  return {
    for (final part in query.split('&'))
      if (part.isNotEmpty)
        Uri.decodeComponent(part.split('=').first): Uri.decodeComponent(
          part.contains('=') ? part.substring(part.indexOf('=') + 1) : '',
        ),
  };
}

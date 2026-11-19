// WebView host for the Element Call widget (Element X's
// WebViewWidgetMessageInterceptor + CallScreenView WebView setup).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'windows_call_web_host.dart';

/// JavaScript channel the injected listener posts to (same name as Element
/// X's `LISTENER_NAME`).
const widgetBridgeChannel = 'elementX';

/// Injected at page start: forwards widget API traffic meant for the client
/// (fromWidget requests and toWidget responses) to [widgetBridgeChannel].
/// Messages from other origins (for example embedded frames) are ignored.
const widgetBridgeScript =
    '''
(function () {
  if (window.__parallaxWidgetBridge) return;
  window.__parallaxWidgetBridge = true;
  window.addEventListener('message', function (event) {
    if (event.origin !== window.location.origin) return;
    var data = event.data;
    if (!data || typeof data !== 'object') return;
    var forClient = (data.api === 'fromWidget' && !data.response) ||
      (data.api === 'toWidget' && data.response);
    if (!forClient) return;
    try { $widgetBridgeChannel.postMessage(JSON.stringify(data)); } catch (e) {}
  });
})();
''';

/// Wraps a widget API message for delivery into the page.
String postToWidgetScript(String json) =>
    'window.postMessage($json, window.location.origin);';

/// Whether [uri] is on the same HTTPS origin as [page].
bool sameCallOrigin(Uri uri, Uri page) =>
    uri.scheme == 'https' &&
    uri.host.toLowerCase() == page.host.toLowerCase() &&
    uri.port == page.port;

/// The platform-facing half of the call screen, injectable for tests.
abstract interface class CallWebHost {
  Widget build(BuildContext context);
  Future<void> load(Uri url);

  /// Delivers one serialised widget API message into the page.
  Future<void> post(String json);
  void dispose();
}

typedef CallWebHostFactory =
    CallWebHost Function({
      required Uri page,
      required Color background,
      required bool allowCamera,
      required bool allowMicrophone,
      required void Function(String message) onMessage,
      required void Function(String description) onLoadError,
      required void Function() onPageFinished,
    });

CallWebHost createWebViewCallHost({
  required Uri page,
  required Color background,
  required bool allowCamera,
  required bool allowMicrophone,
  required void Function(String message) onMessage,
  required void Function(String description) onLoadError,
  required void Function() onPageFinished,
}) => WebViewCallHost(
  page: page,
  background: background,
  allowCamera: allowCamera,
  allowMicrophone: allowMicrophone,
  onMessage: onMessage,
  onLoadError: onLoadError,
  onPageFinished: onPageFinished,
);

/// The platform's call host: WebView2 on Windows, the Android WebView on
/// the phone. Tests inject their own host through the same factory type.
CallWebHost createPlatformCallWebHost({
  required Uri page,
  required Color background,
  required bool allowCamera,
  required bool allowMicrophone,
  required void Function(String message) onMessage,
  required void Function(String description) onLoadError,
  required void Function() onPageFinished,
}) {
  if (!kIsWeb && Platform.isWindows) {
    return createWindowsWebViewCallHost(
      page: page,
      background: background,
      allowCamera: allowCamera,
      allowMicrophone: allowMicrophone,
      onMessage: onMessage,
      onLoadError: onLoadError,
      onPageFinished: onPageFinished,
    );
  }
  return WebViewCallHost(
    page: page,
    background: background,
    allowCamera: allowCamera,
    allowMicrophone: allowMicrophone,
    onMessage: onMessage,
    onLoadError: onLoadError,
    onPageFinished: onPageFinished,
  );
}

class WebViewCallHost implements CallWebHost {
  WebViewCallHost({
    required this.page,
    required Color background,
    required this.allowCamera,
    required this.allowMicrophone,
    required this.onMessage,
    required this.onLoadError,
    required this.onPageFinished,
  }) {
    // Element Call plays remote audio/video inline without a user gesture;
    // WKWebView defaults forbid both. Only pass WebKit params when the real
    // platform is WebKit (tests install a fake platform).
    final PlatformWebViewControllerCreationParams creationParams =
        !kIsWeb &&
            (Platform.isIOS || Platform.isMacOS) &&
            WebViewPlatform.instance is WebKitWebViewPlatform
        ? WebKitWebViewControllerCreationParams(
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
          )
        : const PlatformWebViewControllerCreationParams();
    _controller = WebViewController.fromPlatformCreationParams(
      creationParams,
      onPermissionRequest: _onPermissionRequest,
    );
    _ready = _configure(background);
  }

  final Uri page;
  final bool allowCamera;
  final bool allowMicrophone;
  final void Function(String message) onMessage;
  final void Function(String description) onLoadError;
  final void Function() onPageFinished;
  late final WebViewController _controller;
  late final Future<void> _ready;
  Future<void> _outbox = Future.value();
  bool _disposed = false;

  Future<void> _configure(Color background) async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setBackgroundColor(background);
    await _controller.addJavaScriptChannel(
      widgetBridgeChannel,
      onMessageReceived: (message) {
        if (!_disposed) onMessage(message.message);
      },
    );
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (_) => _injectBridge(),
        // Re-inject (idempotent) in case page start raced the first frame.
        onPageFinished: (url) {
          _injectBridge();
          final uri = Uri.tryParse(url);
          if (!_disposed && uri != null && sameCallOrigin(uri, page)) {
            onPageFinished();
          }
        },
        onNavigationRequest: _onNavigationRequest,
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? false) onLoadError(error.description);
        },
        onHttpError: (error) {
          final uri = error.request?.uri;
          final status = error.response?.statusCode ?? 0;
          if (uri != null &&
              status >= 400 &&
              uri.removeFragment() == page.removeFragment()) {
            onLoadError('HTTP $status');
          }
        },
      ),
    );
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setMediaPlaybackRequiresUserGesture(false);
      await platform.setAllowFileAccess(false);
      await platform.setAllowContentAccess(false);
      await platform.setGeolocationEnabled(false);
    }
  }

  void _injectBridge() {
    if (_disposed) return;
    unawaited(
      _controller.runJavaScript(widgetBridgeScript).catchError((Object _) {}),
    );
  }

  FutureOr<NavigationDecision> _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    if (!request.isMainFrame) {
      // Sub-frames stay inside the page; only HTTPS is allowed.
      return uri.scheme == 'https'
          ? NavigationDecision.navigate
          : NavigationDecision.prevent;
    }
    if (sameCallOrigin(uri, page)) return NavigationDecision.navigate;
    // Links out of Element Call (help, feedback …) open in the browser.
    if (uri.scheme == 'https' || uri.scheme == 'mailto') {
      unawaited(
        launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        ).catchError((Object _) => false),
      );
    }
    return NavigationDecision.prevent;
  }

  void _onPermissionRequest(WebViewPermissionRequest request) {
    // Grant only camera/microphone, and only what Android already granted.
    final allowed = {
      if (allowCamera) WebViewPermissionResourceType.camera,
      if (allowMicrophone) WebViewPermissionResourceType.microphone,
    };
    final grant =
        !_disposed &&
        request.types.isNotEmpty &&
        request.types.every(allowed.contains);
    unawaited(
      (grant ? request.grant() : request.deny()).catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);

  @override
  Future<void> load(Uri url) async {
    await _ready;
    if (_disposed) return;
    await _controller.loadRequest(url);
  }

  @override
  Future<void> post(String json) {
    // Preserve message order across asynchronous platform calls.
    _outbox = _outbox.then((_) async {
      if (_disposed) return;
      try {
        await _controller.runJavaScript(postToWidgetScript(json));
      } catch (_) {
        // The page may be navigating; the widget API times the request out.
      }
    });
    return _outbox;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(
      _controller.loadRequest(Uri.parse('about:blank')).catchError((_) {}),
    );
  }
}

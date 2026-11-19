// WebView2 host for the Element Call widget on Windows: the counterpart of
// the Android WebView host in call_web_host.dart. The same widget-API bridge
// is injected at document creation; messages ride chrome.webview.postMessage
// instead of a JavaScript channel object, and external links are intercepted
// in the page because WebView2 has no per-navigation veto callback.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';

import 'call_web_host.dart';

/// Injected at document creation on every page: forwards widget API traffic
/// meant for the client, and hands out-of-origin link clicks to the host so
/// they open in the browser (same policy as the Android navigation delegate).
const _windowsBridgeScript = '''
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
    try { window.chrome.webview.postMessage(JSON.stringify(data)); } catch (e) {}
  });
  document.addEventListener('click', function (event) {
    var node = event.target;
    var anchor = node && node.closest ? node.closest('a[href]') : null;
    if (!anchor) return;
    var href = anchor.href || '';
    if (href.indexOf(window.location.origin + '/') === 0 ||
        href === window.location.origin) return;
    if (/^(https:|mailto:)/i.test(href)) {
      event.preventDefault();
      try {
        window.chrome.webview.postMessage(
          JSON.stringify({ __parallaxOpenExternal: href }));
      } catch (e) {}
    }
  }, true);
})();
''';

/// The WebView2 environment is process-wide and initialised once. Its user
/// data lives under the app's local profile, never next to the executable.
Future<void>? _environment;
Future<void> _ensureEnvironment() {
  return _environment ??= () async {
    final local = Platform.environment['LOCALAPPDATA'];
    try {
      await WebviewController.initializeEnvironment(
        userDataPath: local == null ? null : '$local\\Parallax\\WebView2',
      );
    } on PlatformException {
      // Already initialised (hot restart): the existing environment stands.
    }
  }();
}

CallWebHost createWindowsWebViewCallHost({
  required Uri page,
  required Color background,
  required bool allowCamera,
  required bool allowMicrophone,
  required void Function(String message) onMessage,
  required void Function(String description) onLoadError,
  required void Function() onPageFinished,
}) => WindowsWebViewCallHost(
  page: page,
  background: background,
  allowCamera: allowCamera,
  allowMicrophone: allowMicrophone,
  onMessage: onMessage,
  onLoadError: onLoadError,
  onPageFinished: onPageFinished,
);

class WindowsWebViewCallHost implements CallWebHost {
  WindowsWebViewCallHost({
    required this.page,
    required Color background,
    required this.allowCamera,
    required this.allowMicrophone,
    required this.onMessage,
    required this.onLoadError,
    required this.onPageFinished,
  }) {
    _ready = _configure(background);
  }

  final Uri page;
  final bool allowCamera;
  final bool allowMicrophone;
  final void Function(String message) onMessage;
  final void Function(String description) onLoadError;
  final void Function() onPageFinished;

  final WebviewController _controller = WebviewController();
  late final Future<void> _ready;
  final _subscriptions = <StreamSubscription<Object?>>[];
  Future<void> _outbox = Future.value();
  String _lastUrl = '';
  bool _disposed = false;

  Future<void> _configure(Color background) async {
    await _ensureEnvironment();
    await _controller.initialize();
    await _controller.setBackgroundColor(background);
    await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    await _controller.addScriptToExecuteOnDocumentCreated(_windowsBridgeScript);
    _subscriptions.add(_controller.url.listen((url) {
      _lastUrl = url;
    }));
    _subscriptions.add(_controller.loadingState.listen((state) {
      if (_disposed || state != LoadingState.navigationCompleted) return;
      final uri = Uri.tryParse(_lastUrl);
      if (uri != null && sameCallOrigin(uri, page)) onPageFinished();
    }));
    _subscriptions.add(_controller.onLoadError.listen((status) {
      if (!_disposed) onLoadError(status.name);
    }));
    _subscriptions.add(_controller.webMessage.listen((message) {
      if (_disposed) return;
      if (message is Map && message['__parallaxOpenExternal'] is String) {
        final uri = Uri.tryParse(message['__parallaxOpenExternal'] as String);
        if (uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'mailto')) {
          unawaited(
            launchUrl(uri, mode: LaunchMode.externalApplication)
                .catchError((Object _) => false),
          );
        }
        return;
      }
      onMessage(jsonEncode(message));
    }));
  }

  Future<WebviewPermissionDecision> _onPermission(
    String url,
    WebviewPermissionKind kind,
    bool isUserInitiated,
  ) async {
    // Grant only camera/microphone, and only what the OS already granted —
    // the same rule as the Android host.
    final allowed = {
      if (allowCamera) WebviewPermissionKind.camera,
      if (allowMicrophone) WebviewPermissionKind.microphone,
    };
    return !_disposed && allowed.contains(kind)
        ? WebviewPermissionDecision.allow
        : WebviewPermissionDecision.deny;
  }

  @override
  Widget build(BuildContext context) => Webview(
    _controller,
    permissionRequested: _onPermission,
  );

  @override
  Future<void> load(Uri url) async {
    await _ready;
    if (_disposed) return;
    await _controller.loadUrl(url.toString());
  }

  @override
  Future<void> post(String json) {
    // Preserve message order across asynchronous platform calls.
    _outbox = _outbox.then((_) async {
      if (_disposed) return;
      try {
        await _controller.executeScript(postToWidgetScript(json));
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
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_controller.dispose().catchError((Object _) {}));
  }
}
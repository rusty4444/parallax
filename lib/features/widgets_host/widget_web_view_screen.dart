import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:webview_flutter/webview_flutter.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_events.dart';
import '../call/call_web_host.dart'
    show widgetBridgeChannel, widgetBridgeScript, postToWidgetScript;
import 'widgets_host.dart';

/// Opens a Matrix widget in a sandboxed WebView. Capabilities are denied by
/// default; the widget must ask, and the user must explicitly approve each
/// sensitive grant (account access / OpenID) before anything is shared.
class WidgetWebViewScreen extends StatefulWidget {
  const WidgetWebViewScreen({
    super.key,
    required this.backend,
    required this.widget,
    required this.palette,
  });

  final ChatBackend backend;
  final MatrixWidget widget;
  final AppPalette palette;

  @override
  State<WidgetWebViewScreen> createState() => _WidgetWebViewScreenState();
}

class _WidgetWebViewScreenState extends State<WidgetWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;
  bool _consented = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(widget.palette.background)
      ..addJavaScriptChannel(
        widgetBridgeChannel,
        onMessageReceived: (message) => _onMessage(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _controller.runJavaScript(widgetBridgeScript);
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) {
              setState(() {
                _error = 'Couldn’t load the widget.';
                _loading = false;
              });
            }
          },
        ),
      );
    unawaited(_controller.loadRequest(widget.widget.url));
  }

  matrix.Client? get _client {
    final backend = widget.backend;
    return backend is MatrixSdkAccess
        ? (backend as MatrixSdkAccess).sdkClient
        : null;
  }

  void _post(Map<String, Object?> message) {
    unawaited(
      _controller.runJavaScript(postToWidgetScript(jsonEncode(message))),
    );
  }

  void _respond(
    String requestId,
    String action,
    Map<String, Object?> response,
  ) {
    _post({
      'api': 'toWidget',
      'action': action,
      'requestId': requestId,
      'response': response,
      'widgetId': widget.widget.id,
    });
  }

  void _respondError(String requestId, String action, String message) {
    _respond(requestId, action, {
      'error': {'message': message},
    });
  }

  Future<void> _onMessage(String raw) async {
    Map<String, Object?> data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      data = Map<String, Object?>.from(decoded);
    } catch (_) {
      return;
    }
    if (data['api'] != 'fromWidget') return;
    final action = data['action'] as String? ?? '';
    final requestId = data['requestId'] as String? ?? '';

    switch (action) {
      case 'content_loaded':
        _respond(requestId, action, {});
      case 'capabilities':
        final approved = await _askConsent(
          'Allow this widget to read room information?',
          'The widget "${widget.widget.name}" wants to interact with this '
              'room. Only grant access to widgets you trust.',
        );
        if (approved) {
          _consented = true;
          _respond(requestId, action, {
            'capabilities': [
              'org.matrix.msc2762.timeline.read',
              'org.matrix.msc2762.state.read',
            ],
          });
        } else {
          _respond(requestId, action, {'capabilities': []});
        }
      case 'get_openid':
        final approved = await _askConsent(
          'Share your account token with this widget?',
          'The widget "${widget.widget.name}" is requesting an OpenID token '
              'that identifies your account. Only approve trusted widgets.',
        );
        if (!approved) {
          _respondError(requestId, action, 'User denied the request');
          return;
        }
        final client = _client;
        if (client == null || client.userID == null) {
          _respondError(requestId, action, 'Not signed in');
          return;
        }
        try {
          final token = await client.request(
            matrix.RequestType.POST,
            '/client/v3/user/${Uri.encodeComponent(client.userID!)}/openid/request_token',
            data: {},
          );
          _respond(requestId, action, Map<String, Object?>.from(token));
        } catch (_) {
          _respondError(requestId, action, 'Could not get an OpenID token');
        }
      default:
        // Everything else (sending events, state writes, to-device) is refused
        // unless the widget is explicitly trusted; this host is read-only.
        _respondError(requestId, action, 'This action is not supported here');
    }
  }

  Future<bool> _askConsent(String title, String body) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: Text(widget.widget.name),
        backgroundColor: p.background,
      ),
      body: Stack(
        children: [
          if (_error != null)
            Center(
              child: Text(_error!, style: TextStyle(color: p.muted)),
            )
          else
            WebViewWidget(controller: _controller),
          if (_loading)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(color: p.accent, minHeight: 2),
            ),
          if (!_consented && _error == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Container(
                  color: p.raised.withValues(alpha: 0.95),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined, size: 16, color: p.secondary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Sandboxed widget — access is denied until you approve it.',
                          style: TextStyle(color: p.muted, fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

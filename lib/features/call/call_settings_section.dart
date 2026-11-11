import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'call_features.dart';
import 'call_settings_store.dart';
import 'call_widget_url.dart';

/// Settings → Calls: Element Call URL override and MatrixRTC discovery.
class CallSettingsSection extends StatefulWidget {
  const CallSettingsSection({
    super.key,
    required this.features,
    required this.palette,
    this.store,
  });

  final CallFeatures features;
  final AppPalette palette;

  /// Defaults to [CallSettingsStore.instance].
  final CallSettingsStore? store;

  @override
  State<CallSettingsSection> createState() => _CallSettingsSectionState();
}

class _CallSettingsSectionState extends State<CallSettingsSection> {
  late final CallSettingsStore _store =
      widget.store ?? CallSettingsStore.instance;
  final _controller = TextEditingController();
  Future<CallServiceInfo>? _info;
  String? _error;
  bool _saving = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final custom = await _store.load();
      if (!mounted || generation != _generation) return;
      _controller.text = custom?.toString() ?? '';
    } catch (_) {
      // Preferences unavailable: show discovery only.
    }
    if (!mounted || generation != _generation) return;
    final info = widget.features.callServiceInfo();
    setState(() {
      _info = info;
    });
  }

  Future<void> _save(String? value) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _store.setCustomBaseUrl(value);
      if (!mounted) return;
      if (value == null) _controller.clear();
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            value == null || value.trim().isEmpty
                ? 'Element Call URL reset.'
                : 'Element Call URL saved. New calls will use it.',
          ),
        ),
      );
      await _load();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t save the URL.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        Eyebrow('Calls', palette: p),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.stroke),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Element Call',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Voice and video calls run Element Call inside Parallax, '
                'so they work with Element X and Element Web. Incoming '
                'calls ring only while Parallax is open.',
                style: TextStyle(color: p.muted, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 14),
              FutureBuilder<CallServiceInfo>(
                future: _info,
                builder: (context, snapshot) {
                  final info = snapshot.data;
                  if (info == null) {
                    return Text(
                      snapshot.hasError
                          ? 'Call service status unavailable.'
                          : 'Checking your homeserver’s call service…',
                      style: TextStyle(color: p.muted, fontSize: 13),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StatusLine(
                        palette: p,
                        icon: Icons.link_rounded,
                        text: switch (info.source) {
                          CallUrlSource.custom =>
                            'Using your Element Call URL: ${info.baseUrl.host}',
                          CallUrlSource.homeserver =>
                            'Using your homeserver’s Element Call: '
                                '${info.baseUrl.host}',
                          CallUrlSource.defaultUrl =>
                            'Using ${info.baseUrl.host} (default)',
                        },
                      ),
                      const SizedBox(height: 6),
                      _StatusLine(
                        palette: p,
                        icon: info.rtcFocusHosts.isEmpty
                            ? Icons.warning_amber_rounded
                            : Icons.check_circle_outline_rounded,
                        text: info.rtcFocusHosts.isNotEmpty
                            ? 'MatrixRTC service: '
                                  '${info.rtcFocusHosts.join(', ')}'
                            : info.discoveryFailed
                            ? 'Couldn’t check your homeserver’s MatrixRTC '
                                  'service.'
                            : 'Your homeserver doesn’t advertise a MatrixRTC '
                                  '(LiveKit) service, so calls may not connect.',
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: 'Element Call URL',
                  hintText: defaultElementCallUrl,
                  helperText:
                      'Leave empty to use your homeserver’s setting '
                      'or call.element.io.',
                  helperMaxLines: 2,
                  errorText: _error,
                ),
                onSubmitted: _save,
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => _save(null),
                    child: const Text('Reset'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : () => _save(_controller.text),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.palette,
    required this.icon,
    required this.text,
  });

  final AppPalette palette;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 17, color: palette.secondary),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: TextStyle(color: palette.foreground, fontSize: 13),
        ),
      ),
    ],
  );
}

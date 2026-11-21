import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'retention_features.dart';
import 'retention_model.dart';

/// Choose how long messages stay in a room before they disappear
/// (MSC1763 `m.room.retention`).
class RetentionScreen extends StatefulWidget {
  const RetentionScreen({
    super.key,
    required this.features,
    required this.roomId,
    required this.roomName,
    required this.palette,
  });

  final RetentionFeatures features;
  final String roomId;
  final String roomName;
  final AppPalette palette;

  @override
  State<RetentionScreen> createState() => _RetentionScreenState();
}

class _RetentionScreenState extends State<RetentionScreen> {
  RoomRetention? _loaded;
  Duration? _selected;
  bool _custom = false;
  final _customHours = TextEditingController(text: '48');
  bool _saving = false;
  String? _error;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _customHours.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final retention = await widget.features.retentionOf(widget.roomId);
      if (!mounted) return;
      final isPreset = retentionPresets.any(
        (p) => p.$2 == retention.maxLifetime,
      );
      setState(() {
        _loaded = retention;
        _selected = retention.maxLifetime;
        _custom = retention.enabled && !isPreset;
        if (_custom) {
          _customHours.text =
              '${retention.maxLifetime!.inHours.clamp(1, 8760)}';
        }
      });
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Couldn’t read the current setting.');
    }
  }

  Duration? get _effective {
    if (!_custom) return _selected;
    final hours = int.tryParse(_customHours.text.trim());
    if (hours == null || hours < 1) return null;
    return Duration(hours: hours.clamp(1, 8760));
  }

  Future<void> _save() async {
    final value = _effective;
    if (_custom && value == null) {
      setState(() => _error = 'Enter a number of hours between 1 and 8760.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.features.setRetention(widget.roomId, value);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Couldn’t save. Check your permissions and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final loading = _loaded == null && _error == null;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('Disappearing messages'),
        backgroundColor: p.background,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Messages in ${widget.roomName} disappear after the chosen time.',
            style: TextStyle(color: p.muted),
          ),
          const SizedBox(height: 12),
          if (loading)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(color: p.accent)),
            )
          else ...[
            RadioGroup<Duration?>(
              groupValue: _custom ? const Duration(days: 36500) : _selected,
              onChanged: (v) {
                if (_saving) return;
                setState(() {
                  _dirty = true;
                  if (v == const Duration(days: 36500)) {
                    _custom = true;
                  } else {
                    _custom = false;
                    _selected = v;
                  }
                });
              },
              child: Column(
                children: [
                  for (final (label, value) in retentionPresets)
                    RadioListTile<Duration?>(
                      key: ValueKey('retention-${label.replaceAll(' ', '-')}'),
                      value: value,
                      title: Text(label, style: TextStyle(color: p.foreground)),
                    ),
                  RadioListTile<Duration?>(
                    key: const ValueKey('retention-custom'),
                    value: const Duration(days: 36500),
                    title: Text(
                      'Custom',
                      style: TextStyle(color: p.foreground),
                    ),
                    subtitle: _custom
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: TextField(
                              controller: _customHours,
                              keyboardType: TextInputType.number,
                              enabled: !_saving,
                              onChanged: (_) => setState(() => _dirty = true),
                              decoration: const InputDecoration(
                                labelText: 'Hours',
                                suffixText: 'hours',
                              ),
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.raised,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.stroke),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: p.secondary, size: 20),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Disappearing messages are best-effort. Your homeserver '
                    'purges old events and Parallax hides them here, but other '
                    'clients, federated servers and screenshots can keep '
                    'copies. Don’t rely on this for sensitive secrets.',
                    style: TextStyle(color: p.muted, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: p.accent)),
          ],
          const SizedBox(height: 20),
          AccentButton(
            palette: p,
            label: _saving ? 'Saving…' : 'Apply',
            icon: Icons.check_rounded,
            onPressed: loading || _saving || !_dirty ? null : _save,
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'local_message_search.dart';

/// Privacy note shown wherever device search can be turned on or off.
const deviceSearchPrivacyNote =
    'Encrypted messages can’t be searched on the server, so Parallax keeps a '
    'search index of the messages this device decrypts. The index never '
    'leaves this device. Like Parallax’s message store, it is kept unencrypted '
    'inside the app’s private storage, and it is deleted when you sign out or '
    'turn this off. Only messages received while this is on are indexed.';

/// Asks before turning device search off (which deletes the index).
Future<bool> confirmDeviceSearchOff(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Turn off device search?'),
        content: const Text(
          'This deletes the search index stored on this device. Encrypted '
          'messages will no longer appear in message search.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    ) ??
    false;

/// Settings card: turn device search on/off and clear the index.
class DeviceSearchSettingsCard extends StatefulWidget {
  const DeviceSearchSettingsCard({
    super.key,
    required this.search,
    required this.palette,
    this.onChanged,
  });
  final LocalMessageSearch search;
  final AppPalette palette;

  /// Called after the enabled state changed or the index was cleared.
  final VoidCallback? onChanged;

  @override
  State<DeviceSearchSettingsCard> createState() =>
      _DeviceSearchSettingsCardState();
}

class _DeviceSearchSettingsCardState extends State<DeviceSearchSettingsCard> {
  bool? _enabled;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant DeviceSearchSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.search, widget.search)) {
      _enabled = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final enabled = await widget.search.isEnabled();
      if (mounted && generation == _generation) {
        setState(() => _enabled = enabled);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _enabled = false);
      }
    }
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    if (_busy) return;
    final generation = ++_generation;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      await action();
      widget.onChanged?.call();
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(failure)));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
        unawaited(_load());
      }
    }
  }

  Future<void> _toggle(bool enabled) async {
    if (!enabled && !await confirmDeviceSearchOff(context)) return;
    if (!mounted) return;
    await _run(
      () => widget.search.setEnabled(enabled),
      'Couldn’t change device search.',
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear device search index?'),
        content: const Text(
          'Messages already indexed on this device are deleted. New messages '
          'are indexed again while device search is on.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(widget.search.clear, 'Couldn’t clear the search index.');
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final enabled = _enabled;
    // Heading above the card, like the other settings sections.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Eyebrow('Message search', palette: p),
        const SizedBox(height: 10),
        Material(
          color: p.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: p.stroke),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _rows(p, enabled),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _rows(AppPalette p, bool? enabled) => [
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        'Search this device’s history',
        style: TextStyle(color: p.foreground),
      ),
      subtitle: Text(
        'Include encrypted rooms in message search',
        style: TextStyle(color: p.muted, fontSize: 12),
      ),
      value: enabled ?? false,
      onChanged: enabled == null || _busy ? null : _toggle,
    ),
    Text(
      deviceSearchPrivacyNote,
      style: TextStyle(color: p.muted, fontSize: 12, height: 1.4),
    ),
    Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: _busy || enabled != true ? null : _clear,
        icon: const Icon(Icons.delete_sweep_outlined),
        label: const Text('Clear search index'),
      ),
    ),
  ];
}

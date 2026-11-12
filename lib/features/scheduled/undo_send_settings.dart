import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'undo_send.dart';

/// Settings → Chats → Sending: the "Undo send" grace period.
class UndoSendSettingsSection extends StatefulWidget {
  const UndoSendSettingsSection({
    super.key,
    required this.palette,
    this.preferences,
  });
  final AppPalette palette;

  /// Defaults to [UndoSendPreferences.shared].
  final UndoSendPreferences? preferences;

  @override
  State<UndoSendSettingsSection> createState() =>
      _UndoSendSettingsSectionState();
}

class _UndoSendSettingsSectionState extends State<UndoSendSettingsSection> {
  UndoSendPreferences get _prefs =>
      widget.preferences ?? UndoSendPreferences.shared;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_changed);
    unawaited(_prefs.ensureLoaded());
  }

  @override
  void didUpdateWidget(UndoSendSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.preferences ?? UndoSendPreferences.shared;
    if (!identical(previous, _prefs)) {
      previous.removeListener(_changed);
      _prefs.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _prefs.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _set(int seconds) async {
    setState(() => _saving = true);
    try {
      await _prefs.setSeconds(seconds);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t save this setting.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _label(int seconds) => seconds == 0 ? 'Off' : '$seconds s';

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final seconds = _prefs.seconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Eyebrow('Sending', palette: p),
        const SizedBox(height: 10),
        Material(
          color: p.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: p.stroke),
          ),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: Icon(Icons.undo_rounded, color: p.secondary),
                  title: const Text('Undo send'),
                  subtitle: Text(
                    seconds == 0
                        ? 'Messages are sent straight away.'
                        : 'Messages wait $seconds seconds before sending, so '
                              'you can take them back. They send straight '
                              'away if you leave the app.',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<int>(
                    key: const ValueKey('scheduled.undo_send.choice'),
                    showSelectedIcon: false,
                    segments: [
                      for (final choice in UndoSendPreferences.choices)
                        ButtonSegment<int>(
                          value: choice,
                          label: Text(_label(choice)),
                        ),
                    ],
                    selected: {seconds},
                    onSelectionChanged: _saving
                        ? null
                        : (selection) => _set(selection.single),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Same spacing as SettingsGroup on the settings pages.
        const SizedBox(height: 18),
      ],
    );
  }
}

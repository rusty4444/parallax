import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_theme.dart';
import '../home/settings_widgets.dart';
import '../settings_sync/settings_sync.dart';
import 'emoji_picker_sheet.dart';

/// How the quick reaction row (long-press a message) is ordered.
enum QuickReactionMode {
  mostUsed('Most used'),
  recent('Recent'),
  manual('Manual');

  const QuickReactionMode(this.label);
  final String label;

  String get description => switch (this) {
    mostUsed => 'Your most used reactions, left to right.',
    recent => 'Your most recently used reactions first.',
    manual => 'A list you choose yourself.',
  };
}

/// The quick reaction row shows six emojis.
const manualReactionLimit = 6;

/// Persists the quick-reaction mode and the manual list on this device.
/// Storage failures never block reacting.
class QuickReactionSettings {
  QuickReactionSettings({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static const modeKey = 'parallax.quick_reaction_mode';
  static const manualKey = 'parallax.quick_reaction_manual';

  /// App-wide instance; tests may replace it.
  static QuickReactionSettings instance = QuickReactionSettings();

  final Future<SharedPreferences> Function() _preferences;

  Future<QuickReactionMode> mode() async {
    try {
      final raw = (await _preferences()).getString(modeKey);
      return QuickReactionMode.values.firstWhere(
        (m) => m.name == raw,
        orElse: () => QuickReactionMode.mostUsed,
      );
    } catch (_) {
      return QuickReactionMode.mostUsed;
    }
  }

  Future<void> setMode(QuickReactionMode mode) async {
    try {
      await (await _preferences()).setString(modeKey, mode.name);
    } catch (_) {}
    SettingsEdits.changed();
  }

  Future<List<String>> manual() async {
    try {
      final raw = (await _preferences()).getString(manualKey);
      final decoded = raw == null ? const [] : jsonDecode(raw);
      return List.unmodifiable([
        if (decoded is List)
          for (final value in decoded.take(manualReactionLimit))
            if (value is String && value.isNotEmpty) value,
      ]);
    } catch (_) {
      return const [];
    }
  }

  Future<void> setManual(List<String> emojis) async {
    try {
      await (await _preferences()).setString(
        manualKey,
        jsonEncode(emojis.take(manualReactionLimit).toList()),
      );
    } catch (_) {}
    SettingsEdits.changed();
  }
}

/// Resolves the quick reaction row for the current mode. Most used is the
/// default; recent keeps the previous behaviour; manual uses the saved list
/// (falling back to defaults when it is empty).
Future<List<String>> resolveQuickReactions({
  EmojiRecents? recents,
  QuickReactionSettings? settings,
}) async {
  final store = recents ?? EmojiRecents.instance;
  final prefs = settings ?? QuickReactionSettings.instance;
  switch (await prefs.mode()) {
    case QuickReactionMode.mostUsed:
      return store.mostUsed();
    case QuickReactionMode.recent:
      return quickEmojis(await store.load());
    case QuickReactionMode.manual:
      final manual = await prefs.manual();
      return manual.isEmpty
          ? defaultQuickEmojis.take(manualReactionLimit).toList()
          : manual;
  }
}

/// Settings → Chats: choose how the quick reaction row is ordered, and edit
/// the manual list.
class QuickReactionSettingsSection extends StatefulWidget {
  const QuickReactionSettingsSection({
    super.key,
    required this.palette,
    this.settings,
  });
  final AppPalette palette;

  /// Defaults to [QuickReactionSettings.instance].
  final QuickReactionSettings? settings;

  @override
  State<QuickReactionSettingsSection> createState() =>
      _QuickReactionSettingsSectionState();
}

class _QuickReactionSettingsSectionState
    extends State<QuickReactionSettingsSection> {
  QuickReactionSettings get _settings =>
      widget.settings ?? QuickReactionSettings.instance;
  QuickReactionMode _mode = QuickReactionMode.mostUsed;
  List<String> _manual = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final mode = await _settings.mode();
    final manual = await _settings.manual();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _manual = manual;
      _loaded = true;
    });
  }

  Future<void> _setMode(QuickReactionMode mode) async {
    setState(() => _mode = mode);
    await _settings.setMode(mode);
  }

  Future<void> _addEmoji() async {
    if (_manual.length >= manualReactionLimit) return;
    final emoji = await showEmojiPickerSheet(
      context,
      palette: widget.palette,
      forReaction: true,
    );
    if (emoji == null || !mounted || _manual.contains(emoji)) return;
    final next = [..._manual, emoji].take(manualReactionLimit).toList();
    setState(() => _manual = next);
    await _settings.setManual(next);
  }

  Future<void> _removeEmoji(String emoji) async {
    final next = _manual.where((e) => e != emoji).toList();
    setState(() => _manual = next);
    await _settings.setManual(next);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return SettingsGroup(
      key: const ValueKey('quick-reaction-settings'),
      palette: p,
      title: 'Quick reactions',
      footer: 'The emoji row shown when you long-press a message.',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: SegmentedButton<QuickReactionMode>(
            key: const ValueKey('quick-reaction-mode'),
            showSelectedIcon: false,
            segments: [
              for (final mode in QuickReactionMode.values)
                ButtonSegment(value: mode, label: Text(mode.label)),
            ],
            selected: {_mode},
            onSelectionChanged: _loaded
                ? (selection) => unawaited(_setMode(selection.first))
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            _mode.description,
            style: TextStyle(color: p.muted, fontSize: 12),
          ),
        ),
        if (_mode == QuickReactionMode.manual)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final emoji in _manual)
                  InputChip(
                    key: ValueKey('manual-reaction-$emoji'),
                    label: Text(emoji, style: const TextStyle(fontSize: 20)),
                    onDeleted: () => unawaited(_removeEmoji(emoji)),
                  ),
                if (_manual.length < manualReactionLimit)
                  ActionChip(
                    key: const ValueKey('manual-reaction-add'),
                    avatar: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add'),
                    onPressed: () => unawaited(_addEmoji()),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

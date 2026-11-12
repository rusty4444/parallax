import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_theme.dart';
import '../../widgets.dart';

/// "Show chat effects" (Element Web's `showChatEffects`), stored on this
/// device. On by default. Writes persist before the value changes.
class ChatEffectsPreferences extends ChangeNotifier {
  ChatEffectsPreferences({SharedPreferences? preferences})
    : _prefs = preferences;

  static final shared = ChatEffectsPreferences();

  static const showChatEffectsKey = 'parallax.composer.v1.show_chat_effects';

  SharedPreferences? _prefs;
  Future<void>? _loading;
  bool _showChatEffects = true;
  Future<void> _tail = Future<void>.value();

  bool get showChatEffects => _showChatEffects;

  /// Loads the saved value once. Failures keep the default and allow retry.
  Future<void> ensureLoaded() => _loading ??= _load().catchError((Object _) {
    _loading = null;
  });

  Future<void> _load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final value = prefs.get(showChatEffectsKey);
    if (value is bool && value != _showChatEffects) {
      _showChatEffects = value;
      notifyListeners();
    }
  }

  Future<void> setShowChatEffects(bool value) {
    final result = _tail.then((_) async {
      await ensureLoaded();
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      if (!await prefs.setBool(showChatEffectsKey, value)) {
        throw StateError('Could not save the chat effects preference');
      }
      if (_showChatEffects == value) return;
      _showChatEffects = value;
      notifyListeners();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// Settings section with the "Show chat effects" switch.
class ChatEffectsSettingsSection extends StatefulWidget {
  const ChatEffectsSettingsSection({
    super.key,
    required this.palette,
    this.preferences,
  });
  final AppPalette palette;

  /// Defaults to [ChatEffectsPreferences.shared].
  final ChatEffectsPreferences? preferences;

  @override
  State<ChatEffectsSettingsSection> createState() =>
      _ChatEffectsSettingsSectionState();
}

class _ChatEffectsSettingsSectionState
    extends State<ChatEffectsSettingsSection> {
  ChatEffectsPreferences get _prefs =>
      widget.preferences ?? ChatEffectsPreferences.shared;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_changed);
    unawaited(_prefs.ensureLoaded());
  }

  @override
  void didUpdateWidget(ChatEffectsSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.preferences ?? ChatEffectsPreferences.shared;
    if (!identical(previous, _prefs)) {
      previous.removeListener(_changed);
      _prefs.addListener(_changed);
      unawaited(_prefs.ensureLoaded());
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

  Future<void> _set(bool value) async {
    setState(() => _saving = true);
    try {
      await _prefs.setShowChatEffects(value);
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

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        Eyebrow('Chat effects', palette: p),
        const SizedBox(height: 10),
        Material(
          color: p.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: p.stroke),
          ),
          child: SwitchListTile(
            key: const ValueKey('show-chat-effects'),
            value: _prefs.showChatEffects,
            onChanged: _saving ? null : _set,
            secondary: Icon(Icons.celebration_outlined, color: p.secondary),
            title: const Text('Show chat effects'),
            subtitle: const Text(
              'Play animations such as confetti when a message like '
              '/confetti or 🎉 arrives. Off while your device’s reduce '
              'motion setting is on.',
            ),
          ),
        ),
      ],
    );
  }
}

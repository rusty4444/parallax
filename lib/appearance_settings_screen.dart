import 'package:flutter/material.dart';

import 'appearance_preferences.dart';
import 'app_theme.dart';
import 'features/reactions/emoji_picker_sheet.dart';
import 'features/scheduled/undo_send_settings.dart';

/// Edits an app-owned model; this route never disposes [preferences].
class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({
    super.key,
    required this.preferences,
    this.palette,
  });

  final AppearancePreferences preferences;

  /// Colours for the full emoji picker (defaults to the Parallax palette).
  final AppPalette? palette;

  /// Offered first when choosing the double-tap reaction.
  static const quickReactionChoices = [
    '❤️',
    '👍',
    '😂',
    '😮',
    '😢',
    '🙏',
    '🔥',
    '🎉',
    '👏',
    '😍',
    '💯',
    '✅',
  ];

  Future<void> _chooseQuickReaction(BuildContext context) async {
    final current = preferences.quickReaction;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Double-tap reaction',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final emoji in quickReactionChoices)
                    ChoiceChip(
                      key: ValueKey('quick-reaction-$emoji'),
                      label: Text(emoji, style: const TextStyle(fontSize: 22)),
                      selected: emoji == current,
                      showCheckmark: false,
                      onSelected: (_) => Navigator.pop(sheetContext, emoji),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('quick-reaction-more'),
                onPressed: () async {
                  final emoji = await showEmojiPickerSheet(
                    sheetContext,
                    palette: palette ?? paletteFor(VisualTheme.parallax),
                    forReaction: true,
                  );
                  if (emoji != null && sheetContext.mounted) {
                    Navigator.pop(sheetContext, emoji);
                  }
                },
                icon: const Icon(Icons.add_reaction_outlined),
                label: const Text('More emoji…'),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !context.mounted) return;
    if (!AppearancePreferences.isQuickReaction(chosen)) {
      // Custom pack emoji (mxc) and multi-emoji picks can't be a quick reaction.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a single standard emoji.')),
      );
      return;
    }
    await _save(context, () => preferences.setQuickReaction(chosen));
  }

  Future<void> _save(
    BuildContext context,
    Future<void> Function() change,
  ) async {
    try {
      await change();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn’t save this preference. Try again.'),
        ),
      );
    }
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: preferences,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _heading(context, 'Reading'),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: const Icon(Icons.text_fields_rounded),
                  title: const Text('Text size'),
                  subtitle: Text('${(preferences.textScale * 100).round()}%'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Slider(
                    value: preferences.textScale,
                    min: AppearancePreferences.minTextScale,
                    max: AppearancePreferences.maxTextScale,
                    divisions: 13,
                    label: '${(preferences.textScale * 100).round()}%',
                    semanticFormatterCallback: (value) =>
                        '${(value * 100).round()} percent',
                    onChanged: (value) =>
                        _save(context, () => preferences.setTextScale(value)),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.view_agenda_outlined),
                  title: const Text('Compact layout'),
                  subtitle: const Text('Reduce spacing in conversations.'),
                  value: preferences.compact,
                  onChanged: (value) =>
                      _save(context, () => preferences.setCompact(value)),
                ),
              ],
            ),
          ),
          _heading(context, 'Home screen'),
          Card(
            child: SwitchListTile(
              key: const ValueKey('appearance.expanded_home'),
              secondary: const Icon(Icons.dashboard_customize_outlined),
              title: const Text('Show all home options'),
              subtitle: const Text(
                'Keep search, filters, Spaces and folders above your chats. '
                'When off, they’re in the options menu at the top.',
              ),
              value: preferences.expandedHome,
              onChanged: (value) =>
                  _save(context, () => preferences.setExpandedHome(value)),
            ),
          ),
          _heading(context, 'Touch'),
          Card(
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('appearance.quick_reaction'),
                  leading: const Icon(Icons.touch_app_outlined),
                  title: const Text('Double-tap reaction'),
                  subtitle: const Text('Double-tap any message to react.'),
                  trailing: Text(
                    preferences.quickReaction,
                    style: const TextStyle(fontSize: 26),
                  ),
                  onTap: () => _chooseQuickReaction(context),
                ),
                SwitchListTile(
                  key: const ValueKey('appearance.haptics'),
                  secondary: const Icon(Icons.vibration_rounded),
                  title: const Text('Haptic feedback'),
                  subtitle: const Text(
                    'Vibrate when you long-press a message, send, react or '
                    'pick a filter. Also follows your phone’s touch feedback '
                    'setting.',
                  ),
                  value: preferences.haptics,
                  onChanged: (value) =>
                      _save(context, () => preferences.setHaptics(value)),
                ),
              ],
            ),
          ),
          _heading(context, 'Media & privacy'),
          Card(
            child: RadioGroup<MediaPreviewMode>(
              groupValue: preferences.mediaPreviewMode,
              onChanged: (value) {
                if (value == null) return;
                _save(context, () => preferences.setMediaPreviewMode(value));
              },
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: Icon(Icons.image_outlined),
                    title: Text('Show media in timeline'),
                    subtitle: Text(
                      'Hidden media can always be shown by tapping on it. '
                      'Loading media uses data.',
                    ),
                  ),
                  RadioListTile(
                    value: MediaPreviewMode.always,
                    title: Text('Always show'),
                  ),
                  RadioListTile(
                    value: MediaPreviewMode.privateRooms,
                    title: Text('Show in private rooms'),
                  ),
                  RadioListTile(
                    value: MediaPreviewMode.never,
                    title: Text('Always hide'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.no_photography_outlined),
                  title: const Text('Hide avatars in room invites'),
                  subtitle: const Text(
                    'Don’t load pictures from people and rooms that invite '
                    'you until you accept.',
                  ),
                  value: preferences.hideInviteAvatars,
                  onChanged: (value) => _save(
                    context,
                    () => preferences.setHideInviteAvatars(value),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.done_all_rounded),
                  title: const Text('Send read receipts'),
                  subtitle: const Text(
                    'Let others know when you’ve read messages. When off, '
                    'receipts stay private to your account.',
                  ),
                  value: preferences.sendReadReceipts,
                  onChanged: (value) => _save(
                    context,
                    () => preferences.setSendReadReceipts(value),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.keyboard_outlined),
                  title: const Text('Send typing notifications'),
                  subtitle: const Text(
                    'Let others see when you’re typing. Never sent in '
                    'encrypted rooms.',
                  ),
                  value: preferences.sendTypingNotifications,
                  onChanged: (value) => _save(
                    context,
                    () => preferences.setSendTypingNotifications(value),
                  ),
                ),
              ],
            ),
          ),
          // Sending → Undo send (Off, 5, 10 or 20 s).
          UndoSendSettingsSection(
            palette: palette ?? paletteFor(VisualTheme.parallax),
          ),
        ],
      ),
    ),
  );
}

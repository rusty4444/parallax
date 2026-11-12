import 'package:flutter/material.dart';

import 'appearance_preferences.dart';

/// Edits an app-owned model; this route never disposes [preferences].
class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key, required this.preferences});

  final AppearancePreferences preferences;

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
            child: SwitchListTile(
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
        ],
      ),
    ),
  );
}

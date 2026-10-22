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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: preferences,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              'Reading',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              'Media & privacy',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.image_outlined),
                  title: const Text('Auto-load media'),
                  subtitle: const Text(
                    'Load images and media previews automatically. Uses data.',
                  ),
                  value: preferences.autoLoadMedia,
                  onChanged: (value) =>
                      _save(context, () => preferences.setAutoLoadMedia(value)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.done_all_rounded),
                  title: const Text('Send read receipts'),
                  subtitle: const Text(
                    'Let others know when you’ve read messages.',
                  ),
                  value: preferences.sendReadReceipts,
                  onChanged: (value) => _save(
                    context,
                    () => preferences.setSendReadReceipts(value),
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

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'appearance_preferences.dart';
import 'features/app_fonts/app_font_picker.dart';
import 'features/home/settings_widgets.dart';
import 'features/reactions/emoji_picker_sheet.dart';
import 'l10n/app_localizations.dart';
import 'l10n/locale_controller.dart';
import 'widgets.dart';

/// Settings rows bound to the app-owned [AppearancePreferences], shared by
/// the Appearance, Chats, Media and Privacy pages. Build them inside a
/// listener on [preferences] so they show its current values. The rows never
/// dispose [preferences].
class PreferenceRows {
  const PreferenceRows(this.context, this.preferences, {required this.palette});

  final BuildContext context;
  final AppearancePreferences preferences;

  /// Colours for the full emoji picker.
  final AppPalette palette;

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

  Future<void> _save(Future<void> Function() change) async {
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

  Future<void> _chooseQuickReaction() async {
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
                    palette: palette,
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
    await _save(() => preferences.setQuickReaction(chosen));
  }

  Future<void> _chooseAppFont() async {
    final chosen = await showAppFontPicker(
      context,
      current: preferences.appFont.id,
    );
    if (chosen == null || !context.mounted) return;
    await _save(() => preferences.setAppFont(chosen));
  }

  /// Appearance → Reading: font, text size and compact layout.
  List<Widget> reading() => [
    ListTile(
      key: const ValueKey('appearance.language'),
      leading: const Icon(Icons.translate_rounded),
      title: Text(ParallaxLocalizations.of(context).language),
      subtitle: Text(
        LocaleController.instance.languageCode == null
            ? ParallaxLocalizations.of(context).systemDefault
            : ParallaxLocalizations.languageNames[LocaleController
                      .instance
                      .languageCode] ??
                  LocaleController.instance.languageCode!,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const LanguagePickerScreen()),
      ),
    ),
    ListTile(
      key: const ValueKey('appearance.app_font'),
      leading: const Icon(Icons.font_download_outlined),
      title: const Text('Font'),
      subtitle: Text(preferences.appFont.label),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: _chooseAppFont,
    ),
    Column(
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
            onChanged: (value) => _save(() => preferences.setTextScale(value)),
          ),
        ),
      ],
    ),
    SwitchListTile(
      key: const ValueKey('appearance.compact'),
      secondary: const Icon(Icons.view_agenda_outlined),
      title: const Text('Compact layout'),
      subtitle: const Text('Reduce spacing in conversations.'),
      value: preferences.compact,
      onChanged: (value) => _save(() => preferences.setCompact(value)),
    ),
  ];

  /// Appearance → Home screen: chat row style, message preview and whether
  /// search, filters, Spaces and folders stay above the chat list.
  List<Widget> homeScreen() => [
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ListTile(
          leading: Icon(Icons.view_list_rounded),
          title: Text('Chat row style'),
          subtitle: Text(
            'Cards, a flat list, or compact rows that fit more chats.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SegmentedButton<HomeRowStyle>(
            key: const ValueKey('appearance.home_row_style'),
            showSelectedIcon: false,
            segments: [
              for (final style in HomeRowStyle.values)
                ButtonSegment(value: style, label: Text(style.label)),
            ],
            selected: {preferences.homeRowStyle},
            onSelectionChanged: (selection) =>
                _save(() => preferences.setHomeRowStyle(selection.single)),
          ),
        ),
      ],
    ),
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ListTile(
          leading: Icon(Icons.short_text_rounded),
          title: Text('Message preview'),
          subtitle: Text(
            'How much of the last message each chat shows: none, '
            'one line or two.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SegmentedButton<HomePreview>(
            key: const ValueKey('appearance.home_preview'),
            showSelectedIcon: false,
            segments: [
              for (final preview in HomePreview.values)
                ButtonSegment(value: preview, label: Text(preview.label)),
            ],
            selected: {preferences.homePreview},
            onSelectionChanged: (selection) =>
                _save(() => preferences.setHomePreview(selection.single)),
          ),
        ),
      ],
    ),
    SwitchListTile(
      key: const ValueKey('appearance.expanded_home'),
      secondary: const Icon(Icons.dashboard_customize_outlined),
      title: const Text('Show all home options'),
      subtitle: const Text(
        'Keep search, filters, Spaces and folders above your '
        'chats. When off, they’re in the options menu at the top.',
      ),
      value: preferences.expandedHome,
      onChanged: (value) => _save(() => preferences.setExpandedHome(value)),
    ),
    SwitchListTile(
      key: const ValueKey('appearance.network_logos'),
      secondary: const Icon(Icons.apps_rounded),
      title: const Text('App logos instead of letters'),
      subtitle: const Text(
        'Chats without a picture show the app they come from: '
        'WhatsApp, Messenger, Google Messages, Discord, LinkedIn, '
        'Xbox or Matrix. Long-press a chat to set your own picture.',
      ),
      value: preferences.networkLogos,
      onChanged: (value) => _save(() => preferences.setNetworkLogos(value)),
    ),
  ];

  /// Chats → Touch: double-tap reaction and haptic feedback.
  List<Widget> touch() => [
    ListTile(
      key: const ValueKey('appearance.quick_reaction'),
      leading: const Icon(Icons.touch_app_outlined),
      title: const Text('Double-tap reaction'),
      subtitle: const Text('Double-tap any message to react.'),
      trailing: Text(
        preferences.quickReaction,
        style: const TextStyle(fontSize: 26),
      ),
      onTap: _chooseQuickReaction,
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
      onChanged: (value) => _save(() => preferences.setHaptics(value)),
    ),
  ];

  /// Media → In chats: when the timeline loads media automatically.
  Widget mediaPreviews() => RadioGroup<MediaPreviewMode>(
    groupValue: preferences.mediaPreviewMode,
    onChanged: (value) {
      if (value == null) return;
      _save(() => preferences.setMediaPreviewMode(value));
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
  );

  /// Privacy → Activity: read receipts and typing notifications.
  List<Widget> activity() => [
    SwitchListTile(
      key: const ValueKey('appearance.read_receipts'),
      secondary: const Icon(Icons.done_all_rounded),
      title: const Text('Send read receipts'),
      subtitle: const Text(
        'Let others know when you’ve read messages. When off, '
        'receipts stay private to your account.',
      ),
      value: preferences.sendReadReceipts,
      onChanged: (value) => _save(() => preferences.setSendReadReceipts(value)),
    ),
    SwitchListTile(
      key: const ValueKey('appearance.typing'),
      secondary: const Icon(Icons.keyboard_outlined),
      title: const Text('Send typing notifications'),
      subtitle: const Text(
        'Let others see when you’re typing. Never sent in '
        'encrypted rooms.',
      ),
      value: preferences.sendTypingNotifications,
      onChanged: (value) =>
          _save(() => preferences.setSendTypingNotifications(value)),
    ),
  ];

  /// Privacy → Invites and blocking: pictures from unaccepted invites.
  Widget inviteAvatars() => SwitchListTile(
    key: const ValueKey('appearance.hide_invite_avatars'),
    secondary: const Icon(Icons.no_photography_outlined),
    title: const Text('Hide avatars in room invites'),
    subtitle: const Text(
      'Don’t load pictures from people and rooms that invite '
      'you until you accept.',
    ),
    value: preferences.hideInviteAvatars,
    onChanged: (value) => _save(() => preferences.setHideInviteAvatars(value)),
  );
}

/// Settings → Appearance: theme, text size and home screen layout. Edits an
/// app-owned model; this route never disposes [preferences].
class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({
    super.key,
    this.preferences,
    this.style = VisualTheme.parallax,
    this.onThemeChanged,
    this.followSystemTheme = false,
    this.onFollowSystemTheme,
  });

  /// Text size and home screen rows are hidden when null.
  final AppearancePreferences? preferences;

  /// The current theme; the page is drawn in it and follows changes.
  final VisualTheme style;

  /// Theme choice; null hides the theme cards.
  final ValueChanged<VisualTheme>? onThemeChanged;

  /// "Match system" is selected; null [onFollowSystemTheme] hides the option.
  final bool followSystemTheme;
  final ValueChanged<bool>? onFollowSystemTheme;

  @override
  State<AppearanceSettingsScreen> createState() =>
      _AppearanceSettingsScreenState();
}

class _AppearanceSettingsScreenState extends State<AppearanceSettingsScreen> {
  late VisualTheme _style = widget.style;
  late bool _followSystem = widget.followSystemTheme;

  List<Widget> _themeCards(AppPalette p) {
    final onThemeChanged = widget.onThemeChanged;
    if (onThemeChanged == null) return const [];
    final onFollowSystem = widget.onFollowSystemTheme;
    return [
      Eyebrow('Theme', palette: p),
      const SizedBox(height: 10),
      if (onFollowSystem != null) ...[
        _ThemeCard(
          key: const ValueKey('theme-system'),
          style: visualThemeForBrightness(
            MediaQuery.platformBrightnessOf(context),
          ),
          palette: p,
          selected: _followSystem,
          label: 'Match system',
          caption: 'Parallax or Parallax Day, following your device',
          onTap: () {
            setState(() {
              _followSystem = true;
              _style = visualThemeForBrightness(
                MediaQuery.platformBrightnessOf(context),
              );
            });
            onFollowSystem(true);
          },
        ),
        const SizedBox(height: 10),
      ],
      for (final style in VisualTheme.values) ...[
        _ThemeCard(
          style: style,
          palette: p,
          selected: !_followSystem && style == _style,
          onTap: () {
            setState(() {
              _style = style;
              _followSystem = false;
            });
            onThemeChanged(style);
          },
        ),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 18),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteFor(_style);
    final preferences = widget.preferences;
    Widget page(PreferenceRows? rows) => SettingsPage(
      palette: p,
      eyebrow: 'Pick your frequency',
      title: 'Appearance',
      children: [
        ..._themeCards(p),
        if (rows != null) ...[
          SettingsGroup(palette: p, title: 'Reading', children: rows.reading()),
          SettingsGroup(
            palette: p,
            title: 'Home screen',
            children: rows.homeScreen(),
          ),
        ],
      ],
    );
    if (preferences == null) return page(null);
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) =>
          page(PreferenceRows(context, preferences, palette: p)),
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    super.key,
    required this.style,
    required this.palette,
    required this.selected,
    required this.onTap,
    this.label,
    this.caption,
  });
  final VisualTheme style;
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;
  final String? label;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final preview = paletteFor(style);
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? palette.accent : palette.stroke,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 53,
                height: 53,
                decoration: BoxDecoration(
                  color: preview.background,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: preview.stroke),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 22,
                      decoration: BoxDecoration(
                        color: preview.accent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Container(
                      width: 12,
                      height: 13,
                      decoration: BoxDecoration(
                        color: preview.secondary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label ?? style.label,
                      style: TextStyle(
                        color: palette.foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      caption ?? style.caption,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: palette.accent),
            ],
          ),
        ),
      ),
    );
  }
}

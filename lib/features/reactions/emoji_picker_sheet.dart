import 'dart:async';
import 'dart:convert';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as ep;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_theme.dart';
import '../../widgets.dart';

/// Shown before any emoji has been used, and to fill the recent row.
const defaultQuickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🎉', '🙏', '🔥'];
const _quickRowLength = 8;
const _recentLimit = 24;

/// Persists recently used emojis on this device (shared by reactions and the
/// composer). Storage failures never block picking an emoji.
class EmojiRecents {
  EmojiRecents({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static const storageKey = 'parallax.recent_emojis';

  /// App-wide instance; tests may replace it.
  static EmojiRecents instance = EmojiRecents();

  final Future<SharedPreferences> Function() _preferences;
  List<String>? _cache;
  Future<void>? _writes;

  Future<List<String>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      final raw = (await _preferences()).getString(storageKey);
      final decoded = raw == null ? const [] : jsonDecode(raw);
      return _cache ??= List.unmodifiable([
        if (decoded is List)
          for (final value in decoded.take(_recentLimit))
            if (value is String && _plausibleEmoji(value)) value,
      ]);
    } catch (_) {
      return const [];
    }
  }

  Future<void> record(String emoji) {
    if (!_plausibleEmoji(emoji)) return Future.value();
    final previous = _writes;
    final write = () async {
      // Serialise writes so the stored order matches the order of picks.
      if (previous != null) await previous;
      final current = await load();
      final next = List<String>.unmodifiable(
        [emoji, ...current.where((e) => e != emoji)].take(_recentLimit),
      );
      _cache = next;
      try {
        await (await _preferences()).setString(storageKey, jsonEncode(next));
      } catch (_) {
        // Recents are a convenience; keep the in-memory order.
      }
    }();
    _writes = write;
    return write;
  }

  static bool _plausibleEmoji(String value) =>
      value.isNotEmpty && value.runes.length <= 16;
}

/// Quick row: recent emojis first, topped up with defaults.
List<String> quickEmojis(List<String> recents) => [
  ...{...recents, ...defaultQuickEmojis},
].take(_quickRowLength).toList();

/// Derives a palette from the ambient theme for callers that do not pass one.
AppPalette paletteFromTheme(ThemeData theme) {
  final scheme = theme.colorScheme;
  return AppPalette(
    background: theme.scaffoldBackgroundColor,
    surface: theme.bottomSheetTheme.backgroundColor ?? scheme.surface,
    raised: scheme.surfaceContainerHighest,
    foreground: scheme.onSurface,
    muted: scheme.onSurfaceVariant,
    accent: scheme.primary,
    accentOn: scheme.onPrimary,
    secondary: scheme.secondary,
    stroke: scheme.outline,
    bubble: scheme.primary,
    bubbleText: scheme.onPrimary,
  );
}

/// Full emoji picker (categories, search, skin tones) in a bottom sheet.
/// Resolves to the chosen emoji, or null when dismissed.
Future<String?> showEmojiPickerSheet(
  BuildContext context, {
  required AppPalette palette,
  bool forReaction = false,
  EmojiRecents? recents,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: palette.surface,
  builder: (_) => EmojiPickerSheet(
    palette: palette,
    forReaction: forReaction,
    recents: recents ?? EmojiRecents.instance,
  ),
);

class EmojiPickerSheet extends StatefulWidget {
  const EmojiPickerSheet({
    super.key,
    required this.palette,
    required this.recents,
    this.forReaction = false,
  });

  final AppPalette palette;
  final EmojiRecents recents;
  final bool forReaction;

  @override
  State<EmojiPickerSheet> createState() => _EmojiPickerSheetState();
}

class _EmojiPickerSheetState extends State<EmojiPickerSheet> {
  List<String> _quick = defaultQuickEmojis;
  bool _chosen = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRecents());
  }

  Future<void> _loadRecents() async {
    final recents = await widget.recents.load();
    if (!mounted || recents.isEmpty) return;
    setState(() => _quick = quickEmojis(recents));
  }

  void _choose(String emoji) {
    if (_chosen || !mounted) return;
    _chosen = true;
    unawaited(widget.recents.record(emoji));
    Navigator.of(context).pop(emoji);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final media = MediaQuery.of(context);
    final height = (media.size.height * 0.5).clamp(260.0, 420.0);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Eyebrow(
                widget.forReaction ? 'Add a reaction' : 'Emoji',
                palette: p,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (final emoji in _quick)
                    Expanded(
                      child: Semantics(
                        button: true,
                        label: emoji,
                        child: TextButton(
                          key: ValueKey('emoji-$emoji'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(40, 48),
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () => _choose(emoji),
                          child: Text(
                            emoji,
                            style: const TextStyle(fontSize: 26),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Divider(color: p.stroke, height: 12),
            SizedBox(
              height: height,
              child: ep.EmojiPicker(
                onEmojiSelected: (_, emoji) => _choose(emoji.emoji),
                config: ep.Config(
                  height: height,
                  checkPlatformCompatibility: true,
                  emojiViewConfig: ep.EmojiViewConfig(
                    columns: 8,
                    emojiSizeMax: 28,
                    backgroundColor: p.surface,
                    gridPadding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  categoryViewConfig: ep.CategoryViewConfig(
                    // Recents are kept by [EmojiRecents] (shown above), so
                    // the package never touches its own preference key.
                    recentTabBehavior: ep.RecentTabBehavior.NONE,
                    initCategory: ep.Category.SMILEYS,
                    backgroundColor: p.surface,
                    indicatorColor: p.accent,
                    iconColor: p.muted,
                    iconColorSelected: p.accent,
                    backspaceColor: p.accent,
                    dividerColor: p.stroke,
                  ),
                  bottomActionBarConfig: ep.BottomActionBarConfig(
                    showBackspaceButton: false,
                    backgroundColor: p.raised,
                    buttonColor: p.raised,
                    buttonIconColor: p.foreground,
                  ),
                  searchViewConfig: ep.SearchViewConfig(
                    backgroundColor: p.surface,
                    buttonIconColor: p.foreground,
                    hintText: 'Search emoji',
                    inputTextStyle: TextStyle(color: p.foreground),
                    hintTextStyle: TextStyle(color: p.muted),
                  ),
                  skinToneConfig: ep.SkinToneConfig(
                    dialogBackgroundColor: p.raised,
                    indicatorColor: p.muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

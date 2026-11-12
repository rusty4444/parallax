import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_theme.dart';

/// Per-room message bubble colours. Null fields follow the theme; a null
/// text colour is chosen automatically for contrast with its bubble.
@immutable
class BubbleColours {
  const BubbleColours({this.mine, this.mineText, this.theirs, this.theirsText});

  static const none = BubbleColours();

  /// Your messages.
  final Color? mine;
  final Color? mineText;

  /// Everyone else's messages.
  final Color? theirs;
  final Color? theirsText;

  bool get isEmpty =>
      mine == null && mineText == null && theirs == null && theirsText == null;

  BubbleColours copyWith({
    Color? Function()? mine,
    Color? Function()? mineText,
    Color? Function()? theirs,
    Color? Function()? theirsText,
  }) => BubbleColours(
    mine: mine == null ? this.mine : mine(),
    mineText: mineText == null ? this.mineText : mineText(),
    theirs: theirs == null ? this.theirs : theirs(),
    theirsText: theirsText == null ? this.theirsText : theirsText(),
  );

  Map<String, String> toJson() => {
    if (mine != null) 'mine': colourToHex(mine!),
    if (mineText != null) 'mineText': colourToHex(mineText!),
    if (theirs != null) 'theirs': colourToHex(theirs!),
    if (theirsText != null) 'theirsText': colourToHex(theirsText!),
  };

  /// Unknown keys and malformed colours are ignored.
  factory BubbleColours.fromJson(Object? json) {
    if (json is! Map) return none;
    Color? read(String key) {
      final value = json[key];
      return value is String ? colourFromHex(value) : null;
    }

    return BubbleColours(
      mine: read('mine'),
      mineText: read('mineText'),
      theirs: read('theirs'),
      theirsText: read('theirsText'),
    );
  }

  /// [base] with these colours applied to bubbles. Text, timestamps and the
  /// muted reply/notice colour follow each bubble's text colour.
  AppPalette apply(AppPalette base) {
    if (isEmpty) return base;
    final mineBubble = mine ?? base.bubble;
    final mineInk =
        mineText ?? (mine == null ? base.bubbleText : readableOn(mineBubble));
    final theirBubble = theirs ?? base.surface;
    final theirInk =
        theirsText ??
        (theirs == null ? base.foreground : readableOn(theirBubble));
    return base.copyWith(
      bubble: mineBubble,
      bubbleText: mineInk,
      surface: theirBubble,
      foreground: theirInk,
      muted: theirsText == null && theirs == null
          ? base.muted
          : theirInk.withValues(alpha: 0.72),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BubbleColours &&
      other.mine == mine &&
      other.mineText == mineText &&
      other.theirs == theirs &&
      other.theirsText == theirsText;

  @override
  int get hashCode => Object.hash(mine, mineText, theirs, theirsText);
}

/// Black-ish or white, whichever reads better on [background].
Color readableOn(Color background) => background.computeLuminance() > 0.42
    ? const Color(0xFF141414)
    : const Color(0xFFFFFFFF);

String colourToHex(Color colour) {
  final rgb = colour.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// `#RRGGBB` or `RRGGBB` (opaque); null for anything else.
Color? colourFromHex(String text) {
  final hex = text.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex, radix: 16));
}

/// Bubble colours per room, kept on this device.
class RoomBubbleColourStore extends ChangeNotifier {
  RoomBubbleColourStore({SharedPreferences? preferences})
    : _prefs = preferences;

  static final shared = RoomBubbleColourStore();

  SharedPreferences? _prefs;
  final _cache = <String, BubbleColours>{};

  static String keyFor(String roomId) =>
      'parallax.bubble_colours.v1.${sha256.convert(utf8.encode(roomId))}';

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Already loaded colours (no I/O), or null before [load].
  BubbleColours? cached(String roomId) => _cache[roomId];

  Future<BubbleColours> load(String roomId) async {
    final cached = _cache[roomId];
    if (cached != null) return cached;
    var colours = BubbleColours.none;
    try {
      final raw = (await _preferences()).getString(keyFor(roomId));
      if (raw != null) colours = BubbleColours.fromJson(jsonDecode(raw));
    } catch (_) {
      // Unreadable or no storage (tests): theme colours.
    }
    return _cache[roomId] = colours;
  }

  Future<void> save(String roomId, BubbleColours colours) async {
    final prefs = await _preferences();
    final saved = colours.isEmpty
        ? await prefs.remove(keyFor(roomId))
        : await prefs.setString(keyFor(roomId), jsonEncode(colours.toJson()));
    if (!saved) throw StateError('Could not save bubble colours');
    _cache[roomId] = colours;
    notifyListeners();
  }
}

/// Bubble colours for the room shown below it.
class BubbleColoursScope extends InheritedWidget {
  const BubbleColoursScope({
    super.key,
    required this.colours,
    required super.child,
  });

  final BubbleColours colours;

  static BubbleColours of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BubbleColoursScope>()
          ?.colours ??
      BubbleColours.none;

  @override
  bool updateShouldNotify(BubbleColoursScope oldWidget) =>
      colours != oldWidget.colours;
}

/// [base] with the surrounding room's bubble colours applied.
AppPalette bubblePaletteOf(BuildContext context, AppPalette base) =>
    BubbleColoursScope.of(context).apply(base);

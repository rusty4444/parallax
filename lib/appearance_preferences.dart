import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

/// Element X "Show media in timeline" (TimelineProtection) choices.
enum MediaPreviewMode {
  /// Always load image/video previews.
  always,

  /// Load previews only in private (non-public) rooms.
  privateRooms,

  /// Never load previews automatically; tap to show.
  never,
}

/// How rows look in the home room list.
enum HomeRowStyle {
  /// Rounded cards with space between them (the original look).
  cards('Cards'),

  /// Flat full-width rows separated by thin lines.
  list('List'),

  /// Flat rows with smaller pictures and less padding, to fit more chats.
  compact('Compact');

  const HomeRowStyle(this.label);
  final String label;
}

/// How much of the last message the home room list shows.
enum HomePreview {
  /// No message preview: the room name and time only.
  none('None', 0),

  /// One line.
  small('Small', 1),

  /// Up to two lines (the original look).
  long('Long', 2);

  const HomePreview(this.label, this.maxLines);
  final String label;
  final int maxLines;
}

/// App-wide, nonsensitive display and messaging preferences.
///
/// Defaults are available immediately. Await [load] before applying saved values
/// at startup. Setters persist only their own key and notify after a successful
/// write; failed persistence is returned to the caller rather than hidden.
class AppearancePreferences extends ChangeNotifier {
  AppearancePreferences({this._prefs});

  static const minTextScale = 0.85;
  static const maxTextScale = 1.5;
  static const _textScaleKey = 'parallax.appearance.v1.text_scale';
  static const _compactKey = 'parallax.appearance.v1.compact';
  static const _autoLoadMediaKey = 'parallax.appearance.v1.auto_load_media';
  static const _mediaPreviewKey = 'parallax.appearance.v1.media_preview_mode';
  static const _sendReadReceiptsKey =
      'parallax.appearance.v1.send_read_receipts';
  static const _sendTypingKey = 'parallax.appearance.v1.send_typing';
  static const _hideInviteAvatarsKey =
      'parallax.appearance.v1.hide_invite_avatars';
  static const _expandedHomeKey = 'parallax.appearance.v1.expanded_home';
  static const _hapticsKey = 'parallax.appearance.v1.haptics';
  static const _quickReactionKey = 'parallax.appearance.v1.quick_reaction';
  static const _homeRowStyleKey = 'parallax.appearance.v1.home_row_style';
  static const _homePreviewKey = 'parallax.appearance.v1.home_preview';
  static const _networkLogosKey = 'parallax.appearance.v1.network_logos';

  /// Double-tap reaction until the user picks another.
  static const defaultQuickReaction = '❤️';

  SharedPreferences? _prefs;
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;
  double _textScale = 1;
  bool _compact = false;
  MediaPreviewMode _mediaPreviewMode = MediaPreviewMode.always;
  bool _sendReadReceipts = true;
  bool _sendTypingNotifications = true;
  bool _hideInviteAvatars = false;
  bool _expandedHome = false;
  bool _haptics = true;
  String _quickReaction = defaultQuickReaction;
  HomeRowStyle _homeRowStyle = HomeRowStyle.cards;
  HomePreview _homePreview = HomePreview.long;
  bool _networkLogos = false;

  double get textScale => _textScale;

  /// Look of the home room list rows (cards by default).
  HomeRowStyle get homeRowStyle => _homeRowStyle;

  /// Last-message preview in the home room list (two lines by default).
  HomePreview get homePreview => _homePreview;
  bool get compact => _compact;

  /// True only when previews load everywhere. Renderers that cannot tell
  /// whether a room is public treat "private rooms only" as hidden (fail safe);
  /// renderers that can should use [autoLoadMediaIn].
  bool get autoLoadMedia => _mediaPreviewMode == MediaPreviewMode.always;
  MediaPreviewMode get mediaPreviewMode => _mediaPreviewMode;
  bool get sendReadReceipts => _sendReadReceipts;
  bool get sendTypingNotifications => _sendTypingNotifications;

  /// Element X "Hide avatars in room invite requests".
  bool get hideInviteAvatars => _hideInviteAvatars;

  /// Home screen shows search, filters, Spaces and folders permanently
  /// instead of in the collapsible options menu (off by default).
  bool get expandedHome => _expandedHome;

  /// Vibrate on long presses, sends and selections (on by default).
  bool get haptics => _haptics;

  /// The emoji a double tap on a message reacts with.
  String get quickReaction => _quickReaction;

  /// Chats without a picture show their app's logo (WhatsApp, Messenger,
  /// Matrix …) instead of a letter (off by default).
  bool get networkLogos => _networkLogos;

  /// One emoji (a single grapheme of at most 32 UTF-16 units, no spaces).
  static bool isQuickReaction(String value) =>
      value.isNotEmpty &&
      value.length <= 32 &&
      value.trim() == value &&
      value.characters.length == 1;

  /// Whether media previews load automatically in a room.
  bool autoLoadMediaIn({required bool publicRoom}) =>
      switch (_mediaPreviewMode) {
        MediaPreviewMode.always => true,
        MediaPreviewMode.privateRooms => !publicRoom,
        MediaPreviewMode.never => false,
      };

  /// Loads the injected preferences or obtains SharedPreferences lazily.
  /// Loads and mutations are serialized, so an older load cannot undo a setter.
  Future<void> load() => _ordered(() async {
    final prefs = await _preferences();
    final rawScale = prefs.get(_textScaleKey);
    final scale = rawScale is num && rawScale.isFinite
        ? rawScale.toDouble().clamp(minTextScale, maxTextScale).toDouble()
        : 1.0;
    final compact = _boolOr(prefs.get(_compactKey), false);
    final rawMode = prefs.get(_mediaPreviewKey);
    // Earlier versions stored only an on/off switch; keep its meaning.
    final mode =
        MediaPreviewMode.values.where((m) => m.name == rawMode).firstOrNull ??
        (_boolOr(prefs.get(_autoLoadMediaKey), true)
            ? MediaPreviewMode.always
            : MediaPreviewMode.never);
    final sendReadReceipts = _boolOr(prefs.get(_sendReadReceiptsKey), true);
    final sendTyping = _boolOr(prefs.get(_sendTypingKey), true);
    final hideInviteAvatars = _boolOr(prefs.get(_hideInviteAvatarsKey), false);
    final expandedHome = _boolOr(prefs.get(_expandedHomeKey), false);
    final haptics = _boolOr(prefs.get(_hapticsKey), true);
    final rawReaction = prefs.get(_quickReactionKey);
    final quickReaction = rawReaction is String && isQuickReaction(rawReaction)
        ? rawReaction
        : defaultQuickReaction;
    final rawRowStyle = prefs.get(_homeRowStyleKey);
    final homeRowStyle =
        HomeRowStyle.values.where((s) => s.name == rawRowStyle).firstOrNull ??
        HomeRowStyle.cards;
    final rawPreview = prefs.get(_homePreviewKey);
    final homePreview =
        HomePreview.values.where((s) => s.name == rawPreview).firstOrNull ??
        HomePreview.long;
    final networkLogos = _boolOr(prefs.get(_networkLogosKey), false);
    final changed =
        networkLogos != _networkLogos ||
        homeRowStyle != _homeRowStyle ||
        homePreview != _homePreview ||
        scale != _textScale ||
        compact != _compact ||
        mode != _mediaPreviewMode ||
        sendReadReceipts != _sendReadReceipts ||
        sendTyping != _sendTypingNotifications ||
        hideInviteAvatars != _hideInviteAvatars ||
        expandedHome != _expandedHome ||
        haptics != _haptics ||
        quickReaction != _quickReaction;
    _textScale = scale;
    _compact = compact;
    _mediaPreviewMode = mode;
    _sendReadReceipts = sendReadReceipts;
    _sendTypingNotifications = sendTyping;
    _hideInviteAvatars = hideInviteAvatars;
    _expandedHome = expandedHome;
    _haptics = haptics;
    _quickReaction = quickReaction;
    _homeRowStyle = homeRowStyle;
    _homePreview = homePreview;
    _networkLogos = networkLogos;
    if (changed) _notifyIfActive();
  });

  Future<void> setHomeRowStyle(HomeRowStyle value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setString(_homeRowStyleKey, value.name));
    if (_homeRowStyle == value) return;
    _homeRowStyle = value;
    _notifyIfActive();
  });

  Future<void> setHomePreview(HomePreview value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setString(_homePreviewKey, value.name));
    if (_homePreview == value) return;
    _homePreview = value;
    _notifyIfActive();
  });

  /// Finite values are clamped to 0.85–1.5; NaN and infinity are rejected.
  Future<void> setTextScale(double value) => _ordered(() async {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'Text scale must be finite');
    }
    final scale = value.clamp(minTextScale, maxTextScale).toDouble();
    final prefs = await _preferences();
    _requireSaved(await prefs.setDouble(_textScaleKey, scale));
    if (_textScale == scale) return;
    _textScale = scale;
    _notifyIfActive();
  });

  Future<void> setCompact(bool value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setBool(_compactKey, value));
    if (_compact == value) return;
    _compact = value;
    _notifyIfActive();
  });

  /// Shorthand for [setMediaPreviewMode] with always/never.
  Future<void> setAutoLoadMedia(bool value) => setMediaPreviewMode(
    value ? MediaPreviewMode.always : MediaPreviewMode.never,
  );

  Future<void> setMediaPreviewMode(MediaPreviewMode mode) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setString(_mediaPreviewKey, mode.name));
    // Keep the legacy key coherent for older readers of the same store.
    _requireSaved(
      await prefs.setBool(_autoLoadMediaKey, mode == MediaPreviewMode.always),
    );
    if (_mediaPreviewMode == mode) return;
    _mediaPreviewMode = mode;
    _notifyIfActive();
  });

  Future<void> setSendReadReceipts(bool value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setBool(_sendReadReceiptsKey, value));
    if (_sendReadReceipts == value) return;
    _sendReadReceipts = value;
    _notifyIfActive();
  });

  Future<void> setSendTypingNotifications(bool value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setBool(_sendTypingKey, value));
    if (_sendTypingNotifications == value) return;
    _sendTypingNotifications = value;
    _notifyIfActive();
  });

  Future<void> setHideInviteAvatars(bool value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setBool(_hideInviteAvatarsKey, value));
    if (_hideInviteAvatars == value) return;
    _hideInviteAvatars = value;
    _notifyIfActive();
  });

  Future<void> setExpandedHome(bool value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setBool(_expandedHomeKey, value));
    if (_expandedHome == value) return;
    _expandedHome = value;
    _notifyIfActive();
  });

  Future<void> setHaptics(bool value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setBool(_hapticsKey, value));
    if (_haptics == value) return;
    _haptics = value;
    _notifyIfActive();
  });

  Future<void> setNetworkLogos(bool value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setBool(_networkLogosKey, value));
    if (_networkLogos == value) return;
    _networkLogos = value;
    _notifyIfActive();
  });

  Future<void> setQuickReaction(String value) => _ordered(() async {
    if (!isQuickReaction(value)) {
      throw ArgumentError.value(value, 'value', 'Choose one emoji');
    }
    final prefs = await _preferences();
    _requireSaved(await prefs.setString(_quickReactionKey, value));
    if (_quickReaction == value) return;
    _quickReaction = value;
    _notifyIfActive();
  });

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> _ordered(Future<void> Function() operation) {
    if (_disposed) {
      return Future<void>.error(
        StateError('AppearancePreferences is disposed'),
      );
    }
    final result = _tail.then((_) => operation());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  static bool _boolOr(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  static void _requireSaved(bool saved) {
    if (!saved) throw StateError('Could not save appearance preference');
  }

  void _notifyIfActive() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide, nonsensitive display and messaging preferences.
///
/// Defaults are available immediately. Await [load] before applying saved values
/// at startup. Setters persist only their own key and notify after a successful
/// write; failed persistence is returned to the caller rather than hidden.
class AppearancePreferences extends ChangeNotifier {
  AppearancePreferences({this._prefs});

  static const minTextScale = 0.85;
  static const maxTextScale = 1.5;
  static const _textScaleKey = 'matrixpress.appearance.v1.text_scale';
  static const _compactKey = 'matrixpress.appearance.v1.compact';
  static const _autoLoadMediaKey = 'matrixpress.appearance.v1.auto_load_media';
  static const _sendReadReceiptsKey =
      'matrixpress.appearance.v1.send_read_receipts';

  SharedPreferences? _prefs;
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;
  double _textScale = 1;
  bool _compact = false;
  bool _autoLoadMedia = true;
  bool _sendReadReceipts = true;

  double get textScale => _textScale;
  bool get compact => _compact;
  bool get autoLoadMedia => _autoLoadMedia;
  bool get sendReadReceipts => _sendReadReceipts;

  /// Loads the injected preferences or obtains SharedPreferences lazily.
  /// Loads and mutations are serialized, so an older load cannot undo a setter.
  Future<void> load() => _ordered(() async {
    final prefs = await _preferences();
    final rawScale = prefs.get(_textScaleKey);
    final scale = rawScale is num && rawScale.isFinite
        ? rawScale.toDouble().clamp(minTextScale, maxTextScale).toDouble()
        : 1.0;
    final compact = _boolOr(prefs.get(_compactKey), false);
    final autoLoadMedia = _boolOr(prefs.get(_autoLoadMediaKey), true);
    final sendReadReceipts = _boolOr(prefs.get(_sendReadReceiptsKey), true);
    final changed =
        scale != _textScale ||
        compact != _compact ||
        autoLoadMedia != _autoLoadMedia ||
        sendReadReceipts != _sendReadReceipts;
    _textScale = scale;
    _compact = compact;
    _autoLoadMedia = autoLoadMedia;
    _sendReadReceipts = sendReadReceipts;
    if (changed) _notifyIfActive();
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

  Future<void> setAutoLoadMedia(bool value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setBool(_autoLoadMediaKey, value));
    if (_autoLoadMedia == value) return;
    _autoLoadMedia = value;
    _notifyIfActive();
  });

  Future<void> setSendReadReceipts(bool value) => _ordered(() async {
    final prefs = await _preferences();
    _requireSaved(await prefs.setBool(_sendReadReceiptsKey, value));
    if (_sendReadReceipts == value) return;
    _sendReadReceipts = value;
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

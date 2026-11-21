import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_widget_url.dart';

/// App-wide Element Call preferences (Element X keeps its custom Element
/// Call URL app-wide too). Only a validated HTTPS URL is ever stored.
class CallSettingsStore extends ChangeNotifier {
  CallSettingsStore({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static final instance = CallSettingsStore();
  static const customUrlKey = 'parallax.call.element_call_url';
  static const screenSharingKey = 'parallax.call.screen_sharing';

  final Future<SharedPreferences> Function() _preferences;
  Uri? _custom;
  bool _screenSharing = false;
  bool _loaded = false;
  int _generation = 0;

  bool get loaded => _loaded;
  Uri? get customBaseUrl => _custom;
  bool get screenSharingEnabled => _screenSharing;

  Future<void> setScreenSharingEnabled(bool value) async {
    _screenSharing = value;
    notifyListeners();
    try {
      await (await _preferences()).setBool(screenSharingKey, value);
    } catch (_) {}
  }

  Future<Uri?> load() async {
    if (_loaded) return _custom;
    final generation = _generation;
    final prefs = await _preferences();
    if (generation != _generation) return _custom;
    _custom = parseElementCallBaseUrl(prefs.getString(customUrlKey));
    _screenSharing = prefs.getBool(screenSharingKey) ?? false;
    _loaded = true;
    notifyListeners();
    return _custom;
  }

  /// Saves [url] (null resets to discovery/default). Throws [FormatException]
  /// for anything but a plain HTTPS URL.
  Future<void> setCustomBaseUrl(String? url) async {
    final text = url?.trim() ?? '';
    final parsed = text.isEmpty ? null : parseElementCallBaseUrl(text);
    if (text.isNotEmpty && parsed == null) {
      throw const FormatException(
        'Enter an https:// address without a query or fragment.',
      );
    }
    final generation = ++_generation;
    final prefs = await _preferences();
    if (parsed == null) {
      await prefs.remove(customUrlKey);
    } else {
      await prefs.setString(customUrlKey, parsed.toString());
    }
    if (generation != _generation) return;
    _custom = parsed;
    _loaded = true;
    notifyListeners();
  }
}

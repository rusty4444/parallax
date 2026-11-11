import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Upload behaviour captured at send time.
@immutable
class MediaUploadOptions {
  const MediaUploadOptions({this.optimiseImages = true});

  /// Element X "Optimise image upload quality" (on by default).
  final bool optimiseImages;
}

/// App-wide, nonsensitive media preferences (Element X media settings).
///
/// Defaults apply until [ensureLoaded] completes. Writes persist before the
/// in-memory value changes, so a failed write is reported, not hidden.
class MediaPreferences extends ChangeNotifier {
  MediaPreferences({SharedPreferences? preferences}) : _prefs = preferences;

  /// Shared instance read by the upload path and the settings section.
  static final shared = MediaPreferences();

  static const optimiseImagesKey = 'parallax.media.v1.optimise_images';

  SharedPreferences? _prefs;
  Future<void>? _loading;
  bool _optimiseImages = true;
  Future<void> _tail = Future<void>.value();

  bool get optimiseImages => _optimiseImages;
  MediaUploadOptions get uploadOptions =>
      MediaUploadOptions(optimiseImages: _optimiseImages);

  /// Loads saved values once. Failures keep the defaults and allow a retry.
  Future<void> ensureLoaded() => _loading ??= _load().catchError((Object _) {
    _loading = null;
  });

  Future<void> _load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final value = prefs.get(optimiseImagesKey);
    if (value is bool && value != _optimiseImages) {
      _optimiseImages = value;
      notifyListeners();
    }
  }

  /// Current options after a bounded attempt to load saved values.
  Future<MediaUploadOptions> resolveUploadOptions() async {
    try {
      await ensureLoaded().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Defaults (optimise on) are the safe, Element X-matching fallback.
    }
    return uploadOptions;
  }

  Future<void> setOptimiseImages(bool value) {
    final result = _tail.then((_) async {
      await ensureLoaded();
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      if (!await prefs.setBool(optimiseImagesKey, value)) {
        throw StateError('Could not save the media preference');
      }
      if (_optimiseImages == value) return;
      _optimiseImages = value;
      notifyListeners();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

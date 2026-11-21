import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thrown when on-device translation is unavailable on this platform.
class TranslationUnavailable implements Exception {
  const TranslationUnavailable([
    this.message = 'On-device translation is unavailable here.',
  ]);
  final String message;
  @override
  String toString() => message;
}

/// Dart bridge to the native ML Kit translation channel (Android). On other
/// platforms the channel is absent and calls throw [TranslationUnavailable].
class TranslationTools {
  static const _channel = MethodChannel('parallax/translation');

  static Future<String?> identify(String text) async {
    try {
      return await _channel.invokeMethod<String>('identify', {'text': text});
    } on MissingPluginException {
      throw const TranslationUnavailable();
    } on PlatformException catch (error) {
      throw TranslationUnavailable(
        error.message ?? 'Language detection failed.',
      );
    }
  }

  static Future<String> translate(
    String text, {
    String source = 'auto',
    required String target,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('translate', {
        'text': text,
        'source': source,
        'target': target,
      });
      if (result == null) {
        throw const TranslationUnavailable('No translation returned.');
      }
      return result;
    } on MissingPluginException {
      throw const TranslationUnavailable();
    } on PlatformException catch (error) {
      throw TranslationUnavailable(error.message ?? 'Translation failed.');
    }
  }
}

/// Curated target languages (ML Kit on-device models).
const translationLanguages = <(String, String)>[
  ('en', 'English'),
  ('es', 'Spanish'),
  ('fr', 'French'),
  ('de', 'German'),
  ('pt', 'Portuguese'),
  ('it', 'Italian'),
  ('nl', 'Dutch'),
  ('ja', 'Japanese'),
  ('zh', 'Chinese'),
  ('ru', 'Russian'),
  ('ar', 'Arabic'),
  ('hi', 'Hindi'),
];

String languageName(String code) {
  for (final (c, name) in translationLanguages) {
    if (c == code) return name;
  }
  return code;
}

/// One-time consent: the first translation of a language downloads its model.
class TranslationConsent {
  static const _key = 'parallax.translation.v1.consented';

  static Future<bool> hasConsented() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> record() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, true);
    } catch (_) {}
  }
}

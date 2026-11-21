import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_localizations.dart';

/// The chosen app language (null = follow the system). Persisted and listened
/// to by the app shell so changing it rebuilds MaterialApp with the new locale.
class LocaleController extends ChangeNotifier {
  LocaleController._();

  static final instance = LocaleController._();

  static const _key = 'parallax.locale.v1.language';

  Locale? _locale;
  bool _loaded = false;

  /// null means "follow the system".
  Locale? get locale => _locale;
  bool get loaded => _loaded;
  String? get languageCode => _locale?.languageCode;

  Future<void> load() async {
    try {
      final code = (await SharedPreferences.getInstance()).getString(_key);
      _locale = code == null || code.isEmpty ? null : Locale(code);
    } catch (_) {
      _locale = null;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setLanguage(String? code) async {
    _locale = code == null || code.isEmpty ? null : Locale(code);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (code == null || code.isEmpty) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, code);
      }
    } catch (_) {}
  }
}

/// Settings → Appearance → Language picker.
class LanguagePickerScreen extends StatelessWidget {
  const LanguagePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = ParallaxLocalizations.of(context);
    final current = LocaleController.instance.languageCode;
    void choose(String? code) {
      LocaleController.instance.setLanguage(code);
      Navigator.pop(context);
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.language)),
      body: ListView(
        children: [
          RadioGroup<String?>(
            groupValue: current,
            onChanged: choose,
            child: Column(
              children: [
                RadioListTile<String?>(
                  key: const ValueKey('locale-system'),
                  value: null,
                  title: Text(l10n.systemDefault),
                ),
                for (final entry in ParallaxLocalizations.languageNames.entries)
                  RadioListTile<String?>(
                    key: ValueKey('locale-${entry.key}'),
                    value: entry.key,
                    title: Text(entry.value),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

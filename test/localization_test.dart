import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/l10n/app_localizations.dart';
import 'package:parallax/l10n/locale_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('all supported languages translate the core labels', () {
    for (final locale in ParallaxLocalizations.supportedLocales) {
      final l10n = ParallaxLocalizations(locale);
      expect(l10n.account, isNotEmpty);
      expect(l10n.settings, isNotEmpty);
      expect(l10n.signOut, isNotEmpty);
    }
  });

  test('translations differ from English where expected', () {
    expect(ParallaxLocalizations(const Locale('es')).account, 'Cuenta');
    expect(ParallaxLocalizations(const Locale('ja')).settings, '設定');
    expect(ParallaxLocalizations(const Locale('de')).signOut, 'Abmelden');
    expect(ParallaxLocalizations(const Locale('en')).account, 'Account');
  });

  test('unknown keys fall back to English then the key', () {
    final l10n = ParallaxLocalizations(const Locale('fr'));
    expect(l10n.t('account'), 'Compte');
    expect(l10n.t('nonexistent_key'), 'nonexistent_key');
  });

  test('locale controller persists and clears', () async {
    final controller = LocaleController.instance;
    await controller.load();
    expect(controller.locale, isNull); // system default
    await controller.setLanguage('fr');
    expect(controller.locale, const Locale('fr'));
    await controller.setLanguage(null);
    expect(controller.locale, isNull);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/transcription/transcription.dart';
import 'package:parallax/features/translation/translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('language names resolve', () {
    expect(languageName('en'), 'English');
    expect(languageName('ja'), 'Japanese');
    expect(languageName('xx'), 'xx');
  });

  test('translation consent persists', () async {
    expect(await TranslationConsent.hasConsented(), isFalse);
    await TranslationConsent.record();
    expect(await TranslationConsent.hasConsented(), isTrue);
  });

  test('transcript cache is per account and event', () async {
    await TranscriptCache.put('account-a', r'$e1', 'hello world');
    expect(await TranscriptCache.get('account-a', r'$e1'), 'hello world');
    expect(await TranscriptCache.get('account-a', r'$e2'), isNull);
    expect(await TranscriptCache.get('account-b', r'$e1'), isNull);
  });

  test('unavailable translation reports a friendly error', () async {
    // No native channel in the test environment.
    expect(
      () => TranslationTools.translate('hola', target: 'en'),
      throwsA(isA<TranslationUnavailable>()),
    );
    expect(await SpeechTools.isAvailable(), isFalse);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late AppearancePreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    preferences = AppearancePreferences(prefs: prefs);
  });

  tearDown(() => preferences.dispose());

  test('defaults are usable before and after loading', () async {
    expect(preferences.textScale, 1.0);
    expect(preferences.compact, isFalse);
    expect(preferences.autoLoadMedia, isTrue);
    expect(preferences.sendReadReceipts, isTrue);
    await preferences.load();
    expect(preferences.textScale, 1.0);
    expect(preferences.compact, isFalse);
    expect(preferences.autoLoadMedia, isTrue);
    expect(preferences.sendReadReceipts, isTrue);
  });

  test(
    'all setters persist and a recreated model restores each value',
    () async {
      await preferences.load();
      await preferences.setTextScale(1.25);
      await preferences.setCompact(true);
      await preferences.setAutoLoadMedia(false);
      await preferences.setSendReadReceipts(false);
      expect(prefs.getKeys(), hasLength(4));
      final restored = AppearancePreferences(prefs: prefs);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.textScale, 1.25);
      expect(restored.compact, isTrue);
      expect(restored.autoLoadMedia, isFalse);
      expect(restored.sendReadReceipts, isFalse);
    },
  );

  test(
    'text scale setters clamp to the supported range and persist it',
    () async {
      await preferences.setTextScale(0.1);
      expect(preferences.textScale, 0.85);
      await preferences.load();
      expect(preferences.textScale, 0.85);
      await preferences.setTextScale(9);
      expect(preferences.textScale, 1.5);
      await preferences.load();
      expect(preferences.textScale, 1.5);
    },
  );

  test(
    'nonfinite text scales fail without changing memory or storage',
    () async {
      await preferences.setTextScale(1.1);
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        await expectLater(preferences.setTextScale(value), throwsArgumentError);
        expect(preferences.textScale, 1.1);
        expect({
          for (final key in prefs.getKeys()) key: prefs.get(key),
        }, before);
      }
    },
  );

  test('notifies once per changed value and not for equal values', () async {
    await preferences.load();
    var notifications = 0;
    preferences.addListener(() => notifications++);
    await preferences.setCompact(true);
    expect(notifications, 1);
    await preferences.setCompact(true);
    expect(notifications, 1);
    await preferences.setTextScale(1.3);
    await preferences.setAutoLoadMedia(false);
    await preferences.setSendReadReceipts(false);
    expect(notifications, 4);
    await preferences.load();
    expect(notifications, 4);
  });

  test('load notifies listeners once when stored values differ', () async {
    await preferences.setTextScale(1.2);
    await preferences.setCompact(true);
    final restored = AppearancePreferences(prefs: prefs);
    addTearDown(restored.dispose);
    var notifications = 0;
    restored.addListener(() => notifications++);
    await restored.load();
    expect(notifications, 1);
    expect(restored.textScale, 1.2);
    expect(restored.compact, isTrue);
  });

  test('loading clamps persisted out-of-range scales', () async {
    await preferences.setTextScale(1.2);
    final scaleKey = prefs.getKeys().single;
    await prefs.setDouble(scaleKey, 5);
    await preferences.load();
    expect(preferences.textScale, 1.5);
    await prefs.setDouble(scaleKey, 0.2);
    await preferences.load();
    expect(preferences.textScale, 0.85);
  });

  test(
    'malformed stored values fall back safely without overwriting them',
    () async {
      await preferences.setTextScale(1.2);
      final scaleKey = prefs.getKeys().single;
      await preferences.setCompact(true);
      final compactKey = prefs.getKeys().singleWhere((key) => key != scaleKey);
      await prefs.setString(scaleKey, 'invalid');
      await prefs.setString(compactKey, 'invalid');
      await preferences.load();
      expect(preferences.textScale, 1);
      expect(preferences.compact, isFalse);
      expect(prefs.getString(scaleKey), 'invalid');
      expect(prefs.getString(compactKey), 'invalid');
      await prefs.setDouble(scaleKey, double.nan);
      await preferences.load();
      expect(preferences.textScale, 1);
    },
  );

  test('setters before load do not discard other unread preferences', () async {
    await preferences.setAutoLoadMedia(false);
    final fresh = AppearancePreferences(prefs: prefs);
    addTearDown(fresh.dispose);
    await fresh.setCompact(true);
    await fresh.load();
    expect(fresh.compact, isTrue);
    expect(fresh.autoLoadMedia, isFalse);
  });

  test('overlapping loads and setters keep invocation ordering', () async {
    await preferences.setCompact(true);
    final load = preferences.load();
    final first = preferences.setCompact(false);
    final second = preferences.setCompact(true);
    final scale = preferences.setTextScale(1.4);
    await Future.wait([load, first, second, scale]);
    expect(preferences.compact, isTrue);
    expect(preferences.textScale, 1.4);
    final restored = AppearancePreferences(prefs: prefs);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.compact, isTrue);
    expect(restored.textScale, 1.4);
  });

  test(
    'default constructor obtains SharedPreferences asynchronously',
    () async {
      final automatic = AppearancePreferences();
      addTearDown(automatic.dispose);
      await automatic.load();
      await automatic.setSendReadReceipts(false);
      final restored = AppearancePreferences();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.sendReadReceipts, isFalse);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/scheduled/schedule_presets.dart';

Map<String, DateTime> _byId(DateTime now) => {
  for (final preset in schedulePresets(now)) preset.id: preset.at,
};

void main() {
  group('schedulePresets', () {
    test('weekday morning offers all four presets', () {
      // Wednesday 11 November 2026, 10:00 local.
      final now = DateTime(2026, 11, 11, 10);
      final presets = _byId(now);
      expect(presets.keys, [
        'in_30_minutes',
        'tonight',
        'tomorrow_morning',
        'monday_morning',
      ]);
      expect(presets['in_30_minutes'], now.add(const Duration(minutes: 30)));
      expect(presets['tonight'], DateTime(2026, 11, 11, 18));
      expect(presets['tomorrow_morning'], DateTime(2026, 11, 12, 9));
      expect(presets['monday_morning'], DateTime(2026, 11, 16, 9));
      expect(presets['monday_morning']!.weekday, DateTime.monday);
    });

    test('tonight disappears from 5:55 pm', () {
      expect(_byId(DateTime(2026, 11, 11, 17, 50)), contains('tonight'));
      expect(_byId(DateTime(2026, 11, 11, 17, 56)), isNot(contains('tonight')));
      expect(_byId(DateTime(2026, 11, 11, 21)), isNot(contains('tonight')));
    });

    test('Monday is next week on a Monday and skipped on a Sunday', () {
      final monday = _byId(DateTime(2026, 11, 16, 8));
      expect(monday['monday_morning'], DateTime(2026, 11, 23, 9));
      final sunday = _byId(DateTime(2026, 11, 15, 8));
      expect(sunday, isNot(contains('monday_morning')));
      expect(sunday['tomorrow_morning'], DateTime(2026, 11, 16, 9));
    });

    test('month and year roll over by calendar fields', () {
      // Thursday 31 December 2026.
      final presets = _byId(DateTime(2026, 12, 31, 22));
      expect(presets['tomorrow_morning'], DateTime(2027, 1, 1, 9));
      expect(presets['monday_morning'], DateTime(2027, 1, 4, 9));
    });

    test('daylight-saving changes keep wall-clock presets', () {
      // Sydney DST starts 4 October 2026 (2 am → 3 am) and ends 4 April
      // 2027 (3 am → 2 am). Field checks hold in every time zone; in an
      // Australian zone these days are 23 and 25 hours long.
      final spring = _byId(DateTime(2026, 10, 3, 20));
      expect(spring['tomorrow_morning']!.day, 4);
      expect(spring['tomorrow_morning']!.hour, 9);
      expect(spring['tomorrow_morning']!.minute, 0);
      final autumn = _byId(DateTime(2027, 4, 3, 20));
      expect(autumn['tomorrow_morning']!.day, 4);
      expect(autumn['tomorrow_morning']!.hour, 9);
      expect(autumn['monday_morning']!.day, 5);
      expect(autumn['monday_morning']!.hour, 9);
      // "In 30 minutes" is an absolute duration, even across the jump.
      final night = DateTime(2026, 10, 4, 1, 45);
      expect(
        _byId(night)['in_30_minutes']!.difference(night),
        const Duration(minutes: 30),
      );
    });

    test('UTC input is interpreted in local time', () {
      final utc = DateTime.utc(2026, 11, 11, 3);
      final local = utc.toLocal();
      expect(
        _byId(utc)['tomorrow_morning'],
        DateTime(local.year, local.month, local.day + 1, 9),
      );
    });

    test('custom date and time combine in local time', () {
      final value = combineDateAndTime(DateTime(2026, 11, 20), 14, 30);
      expect(value, DateTime(2026, 11, 20, 14, 30));
      expect(value.isUtc, isFalse);
    });
  });

  group('describeSendTime', () {
    final now = DateTime(2026, 11, 12, 10);

    test('today, tomorrow, later and next year', () {
      expect(
        describeSendTime(DateTime(2026, 11, 12, 18), now: now),
        'Today, 6:00 pm',
      );
      expect(
        describeSendTime(DateTime(2026, 11, 13, 9), now: now),
        'Tomorrow, 9:00 am',
      );
      expect(
        describeSendTime(DateTime(2026, 11, 16, 9, 5), now: now),
        'Mon 16 Nov, 9:05 am',
      );
      expect(
        describeSendTime(DateTime(2027, 1, 4, 0, 30), now: now),
        'Mon 4 Jan 2027, 12:30 am',
      );
    });

    test('day distance is calendar based across daylight saving', () {
      final saturday = DateTime(2027, 4, 3, 23, 30);
      expect(
        describeSendTime(DateTime(2027, 4, 4, 23, 45), now: saturday),
        'Tomorrow, 11:45 pm',
      );
      expect(
        describeSendTime(
          DateTime(2026, 10, 4, 0, 15),
          now: DateTime(2026, 10, 3, 23),
        ),
        'Tomorrow, 12:15 am',
      );
    });

    test('noon and midnight', () {
      expect(formatClockTime(DateTime(2026, 1, 1, 12)), '12:00 pm');
      expect(formatClockTime(DateTime(2026, 1, 1, 0, 5)), '12:05 am');
    });
  });

  test('describeDuration', () {
    expect(describeDuration(const Duration(days: 7)), '7 days');
    expect(describeDuration(const Duration(hours: 24)), '24 hours');
    expect(describeDuration(const Duration(hours: 1)), '1 hour');
    expect(describeDuration(const Duration(minutes: 90)), '90 minutes');
    expect(describeDuration(const Duration(seconds: 30)), '30 seconds');
  });
}

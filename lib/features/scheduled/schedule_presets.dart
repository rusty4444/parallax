import 'package:flutter/foundation.dart';

/// A quick "Send later" choice.
@immutable
class SchedulePreset {
  const SchedulePreset(this.id, this.label, this.at);
  final String id;
  final String label;

  /// Local wall-clock time to send at.
  final DateTime at;
}

DateTime _local(DateTime value) => value.isUtc ? value.toLocal() : value;

/// Presets relative to [now]: in 30 minutes, tonight 6 pm (until 5:55 pm),
/// tomorrow 9 am and Monday 9 am (skipped when Monday is tomorrow).
///
/// Calendar presets are built from local date fields (`DateTime(y, m, d + n,
/// h)`), never by adding 24-hour durations, so they stay at the intended
/// wall-clock time across daylight-saving changes. "In 30 minutes" is an
/// absolute duration.
List<SchedulePreset> schedulePresets(DateTime now) {
  final local = _local(now);
  final presets = <SchedulePreset>[
    SchedulePreset(
      'in_30_minutes',
      'In 30 minutes',
      local.add(const Duration(minutes: 30)),
    ),
  ];
  final tonight = DateTime(local.year, local.month, local.day, 18);
  if (tonight.isAfter(local.add(const Duration(minutes: 5)))) {
    presets.add(SchedulePreset('tonight', 'Tonight, 6 pm', tonight));
  }
  presets.add(
    SchedulePreset(
      'tomorrow_morning',
      'Tomorrow, 9 am',
      DateTime(local.year, local.month, local.day + 1, 9),
    ),
  );
  // Next Monday strictly after today (a week ahead on a Monday).
  var days = (DateTime.monday - local.weekday) % DateTime.daysPerWeek;
  if (days == 0) days = DateTime.daysPerWeek;
  if (days > 1) {
    presets.add(
      SchedulePreset(
        'monday_morning',
        'Monday, 9 am',
        DateTime(local.year, local.month, local.day + days, 9),
      ),
    );
  }
  return presets;
}

/// Combines a picked date and time into a local wall-clock time.
DateTime combineDateAndTime(DateTime date, int hour, int minute) =>
    DateTime(date.year, date.month, date.day, hour, minute);

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `9:05 am` (Australian style).
String formatClockTime(DateTime value) {
  final local = _local(value);
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${local.hour < 12 ? 'am' : 'pm'}';
}

/// "Today, 6:00 pm", "Tomorrow, 9:00 am", "Mon 16 Nov, 9:00 am" (with the
/// year when it differs). Day distance uses calendar dates, so it is not
/// skewed by a 23- or 25-hour daylight-saving day.
String describeSendTime(DateTime when, {required DateTime now}) {
  final target = _local(when);
  final today = _local(now);
  final days = DateTime.utc(
    target.year,
    target.month,
    target.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  final time = formatClockTime(target);
  if (days == 0) return 'Today, $time';
  if (days == 1) return 'Tomorrow, $time';
  final date =
      '${_weekdays[target.weekday - 1]} ${target.day} '
      '${_months[target.month - 1]}';
  final year = target.year == today.year ? '' : ' ${target.year}';
  return '$date$year, $time';
}

/// "30 minutes", "24 hours", "7 days" for homeserver limits.
String describeDuration(Duration value) {
  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';
  if (value.inDays >= 2 && value.inHours % 24 == 0) {
    return plural(value.inDays, 'day');
  }
  if (value.inHours >= 1 && value.inMinutes % 60 == 0) {
    return plural(value.inHours, 'hour');
  }
  if (value.inMinutes >= 1) return plural(value.inMinutes, 'minute');
  return plural(value.inSeconds, 'second');
}

// Small formatting helpers for live location UI (Australian English).
import 'package:flutter/widgets.dart';

/// "3:45 pm", or "15:45" when the device uses 24-hour time.
String formatClockTime(DateTime time, {bool use24Hour = false}) {
  final local = time.toLocal();
  final minutes = local.minute.toString().padLeft(2, '0');
  if (use24Hour) {
    return '${local.hour.toString().padLeft(2, '0')}:$minutes';
  }
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  return '$hour:$minutes ${local.hour < 12 ? 'am' : 'pm'}';
}

/// End time relative to [now]: "3:45 pm", "tomorrow 1:15 am" or
/// "14/11 9:00 am".
String formatEndTime(DateTime end, DateTime now, {bool use24Hour = false}) {
  final local = end.toLocal();
  final today = now.toLocal();
  final clock = formatClockTime(local, use24Hour: use24Hour);
  final endDay = DateTime(local.year, local.month, local.day);
  final startDay = DateTime(today.year, today.month, today.day);
  // Round: a day across a daylight-saving change is 23 or 25 hours.
  final days = (endDay.difference(startDay).inHours / 24).round();
  if (days == 0) return clock;
  if (days == 1) return 'tomorrow $clock';
  return '${local.day}/${local.month} $clock';
}

/// "Updated just now", "Updated 4 min ago", "Updated 2 h ago".
String formatUpdatedAgo(DateTime time, DateTime now) {
  final age = now.difference(time);
  if (age < const Duration(minutes: 1)) return 'Updated just now';
  if (age < const Duration(hours: 1)) return 'Updated ${age.inMinutes} min ago';
  if (age < const Duration(days: 1)) return 'Updated ${age.inHours} h ago';
  return 'Updated ${age.inDays} d ago';
}

bool use24HourOf(BuildContext context) =>
    MediaQuery.maybeAlwaysUse24HourFormatOf(context) ?? false;

/// "1 person is sharing live location" / "3 people are sharing live location".
String peopleSharingLabel(int count) => count == 1
    ? '1 person is sharing live location'
    : '$count people are sharing live location';

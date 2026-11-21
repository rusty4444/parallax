import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/reminders/reminders.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Reminder reminder(String id, {DateTime? fireAt}) => Reminder(
    id: id,
    roomId: '!room:example.org',
    eventId: r'$event',
    snippet: 'Remember this',
    fireAt: fireAt ?? DateTime(2026, 11, 21, 15),
  );

  test('reminder json round trip', () {
    final r = reminder('a');
    final parsed = Reminder.fromJson(r.toJson());
    expect(parsed, isNotNull);
    expect(parsed!.id, 'a');
    expect(parsed.roomId, '!room:example.org');
    expect(parsed.fireAt, r.fireAt);
    expect(Reminder.fromJson({'bad': true}), isNull);
  });

  test('notification id is stable and in the reminder range', () {
    final r = reminder('a');
    expect(r.notificationId, reminder('a').notificationId);
    expect(r.notificationId & 0x52000000, 0x52000000);
  });

  test('store persists reminders per account', () async {
    final store = ReminderStore();
    await store.bindAccount('account-a');
    await store.add(reminder('a', fireAt: DateTime(2026, 11, 21, 15)));
    await store.add(reminder('b', fireAt: DateTime(2026, 11, 21, 12)));
    expect(store.reminders.map((r) => r.id), ['b', 'a']); // sorted by time

    final reopened = ReminderStore();
    await reopened.bindAccount('account-a');
    expect(reopened.reminders.length, 2);

    await reopened.remove('a');
    expect(reopened.reminders.single.id, 'b');

    final other = ReminderStore();
    await other.bindAccount('account-b');
    expect(other.reminders, isEmpty);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// A scheduled "remind me about this message" reminder.
@immutable
class Reminder {
  const Reminder({
    required this.id,
    required this.roomId,
    required this.eventId,
    required this.snippet,
    required this.fireAt,
  });

  final String id;
  final String roomId;
  final String eventId;
  final String snippet;
  final DateTime fireAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'room_id': roomId,
    'event_id': eventId,
    'snippet': snippet,
    'fire_at': fireAt.millisecondsSinceEpoch,
  };

  static Reminder? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final roomId = json['room_id'];
    final eventId = json['event_id'];
    final fireAt = json['fire_at'];
    if (id is! String ||
        roomId is! String ||
        eventId is! String ||
        fireAt is! int) {
      return null;
    }
    return Reminder(
      id: id,
      roomId: roomId,
      eventId: eventId,
      snippet: json['snippet'] is String ? json['snippet'] as String : '',
      fireAt: DateTime.fromMillisecondsSinceEpoch(fireAt),
    );
  }

  /// Stable notification id derived from the reminder id.
  int get notificationId =>
      0x52000000 |
      (sha256.convert(utf8.encode(id)).bytes[0] << 16) |
      (sha256.convert(utf8.encode(id)).bytes[1] << 8) |
      sha256.convert(utf8.encode(id)).bytes[2];
}

/// Persists reminders per account.
class ReminderStore extends ChangeNotifier {
  ReminderStore({SharedPreferences? preferences}) : _prefs = preferences;

  static final shared = ReminderStore();

  SharedPreferences? _prefs;
  String? _accountKey;
  final _reminders = <Reminder>[];

  List<Reminder> get reminders => List.unmodifiable(_reminders);

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  static String _keyFor(String accountKey) =>
      'parallax.reminders.v1.${sha256.convert(utf8.encode(accountKey))}';

  Future<void> bindAccount(String? accountKey) async {
    _accountKey = accountKey;
    _reminders.clear();
    if (accountKey != null && accountKey.isNotEmpty) {
      try {
        final raw = (await _preferences()).getString(_keyFor(accountKey));
        if (raw != null) {
          final list = jsonDecode(raw);
          if (list is List) {
            for (final item in list) {
              final reminder = Reminder.fromJson(item);
              if (reminder != null) _reminders.add(reminder);
            }
          }
        }
      } catch (_) {}
    }
    _reminders.sort((a, b) => a.fireAt.compareTo(b.fireAt));
    notifyListeners();
  }

  Future<void> _persist() async {
    final accountKey = _accountKey;
    if (accountKey == null) return;
    try {
      final prefs = await _preferences();
      if (_reminders.isEmpty) {
        await prefs.remove(_keyFor(accountKey));
      } else {
        await prefs.setString(
          _keyFor(accountKey),
          jsonEncode([for (final r in _reminders) r.toJson()]),
        );
      }
    } catch (_) {}
  }

  Future<void> add(Reminder reminder) async {
    _reminders.add(reminder);
    _reminders.sort((a, b) => a.fireAt.compareTo(b.fireAt));
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    _reminders.removeWhere((r) => r.id == id);
    notifyListeners();
    await _persist();
  }
}

/// Schedules reminder notifications and routes their taps back to the message.
class ReminderScheduler {
  ReminderScheduler._();

  static final instance = ReminderScheduler._();

  static const _channelId = 'parallax_reminders_v1';
  static const _payloadPrefix = 'parallax-reminder:';

  FlutterLocalNotificationsPlugin? _plugin;
  bool _initializing = false;

  /// Set by the signed-in wrapper to open the reminded message.
  void Function(String roomId, String eventId)? onOpen;

  Future<FlutterLocalNotificationsPlugin?> _ensure() async {
    if (_plugin != null) return _plugin;
    if (_initializing) return null;
    _initializing = true;
    try {
      tzdata.initializeTimeZones();
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload == null || !payload.startsWith(_payloadPrefix)) return;
          final parts = payload.substring(_payloadPrefix.length).split('|');
          if (parts.length == 2) onOpen?.call(parts[0], parts[1]);
        },
      );
      _plugin = plugin;
      return plugin;
    } catch (_) {
      return null;
    } finally {
      _initializing = false;
    }
  }

  Future<void> schedule(Reminder reminder) async {
    final plugin = await _ensure();
    if (plugin == null) return;
    try {
      await plugin.zonedSchedule(
        id: reminder.notificationId,
        title: 'Reminder',
        body: reminder.snippet.isEmpty
            ? 'You asked to be reminded'
            : reminder.snippet,
        scheduledDate: tz.TZDateTime.fromMillisecondsSinceEpoch(
          tz.UTC,
          reminder.fireAt.millisecondsSinceEpoch,
        ),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Reminders',
            channelDescription: 'Message reminders you set',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: '$_payloadPrefix${reminder.roomId}|${reminder.eventId}',
      );
    } catch (_) {
      // Exact alarms may be unavailable; the in-app reminders list still works.
    }
  }

  Future<void> cancel(Reminder reminder) async {
    final plugin = await _ensure();
    if (plugin == null) return;
    try {
      await plugin.cancel(id: reminder.notificationId);
    } catch (_) {}
  }
}

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../threads/timeline_navigation.dart';
import 'reminders.dart';

/// Settings → Chats → Reminders: pending message reminders.
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.store,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final ReminderStore store;

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  late final _owner = BackendSessionOwner(widget.backend);

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    _owner.release();
    super.dispose();
  }

  void _changed() {
    if (mounted && _owner.isCurrent) setState(() {});
  }

  String _when(DateTime fireAt) {
    final now = DateTime.now();
    final diff = fireAt.difference(now);
    if (diff.isNegative) return 'Due now';
    if (diff.inMinutes < 60) return 'In ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'In ${diff.inHours} h';
    return '${fireAt.day}/${fireAt.month} ${fireAt.hour.toString().padLeft(2, '0')}:${fireAt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final reminders = widget.store.reminders;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('Reminders'),
        backgroundColor: p.background,
      ),
      body: reminders.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No reminders yet.\nLong-press a message and choose “Remind me”.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: reminders.length,
              itemBuilder: (context, index) {
                final reminder = reminders[index];
                return Card(
                  key: ValueKey('reminder-${reminder.id}'),
                  color: p.surface,
                  margin: const EdgeInsets.only(bottom: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: p.stroke),
                  ),
                  child: ListTile(
                    leading: Icon(Icons.alarm_rounded, color: p.secondary),
                    title: Text(
                      reminder.snippet.isEmpty
                          ? 'Message reminder'
                          : reminder.snippet,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.foreground),
                    ),
                    subtitle: Text(
                      _when(reminder.fireAt),
                      style: TextStyle(color: p.muted),
                    ),
                    onTap: () {
                      timelineNavigationOf(
                        widget.backend,
                      )?.openRoomAt(reminder.roomId, reminder.eventId);
                    },
                    trailing: IconButton(
                      key: ValueKey('reminder-cancel-${reminder.id}'),
                      icon: Icon(Icons.close_rounded, color: p.muted),
                      onPressed: () async {
                        await ReminderScheduler.instance.cancel(reminder);
                        await widget.store.remove(reminder.id);
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}

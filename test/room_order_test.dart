import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';

void main() {
  test('projects inbox ordering from safe room summaries', () {
    final rooms = [
      ChatRoom(
        id: '!older:example.org',
        name: 'Older',
        preview: '',
        lastActivity: DateTime(2025),
      ),
      const ChatRoom(
        id: '!broken:example.org',
        name: 'Fallback',
        preview: '',
        lastActivity: null,
      ),
      ChatRoom(
        id: '!new:example.org',
        name: 'New',
        preview: '',
        lastActivity: DateTime(2026),
      ),
      const ChatRoom(
        id: '!invite:example.org',
        name: 'Invite',
        preview: '',
        lastActivity: null,
        invited: true,
      ),
    ]..sort(compareRooms);
    expect(rooms.map((r) => r.id), [
      '!invite:example.org',
      '!new:example.org',
      '!older:example.org',
      '!broken:example.org',
    ]);
  });
}

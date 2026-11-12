import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/media_preview_policy.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/timeline_kinds.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeBackend;

void main() {
  test('legacy call notify events stay out of the timeline', () {
    // Element Call sends both; Element X shows only the RTC notification.
    expect(isTimelineVisibleType('org.matrix.msc4075.call.notify'), isFalse);
    expect(
      isTimelineVisibleType('org.matrix.msc4075.rtc.notification'),
      isTrue,
    );
  });

  testWidgets('"In private rooms" media previews follow the room join rule', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = AppearancePreferences();
    addTearDown(preferences.dispose);
    await tester.runAsync(
      () => preferences.setMediaPreviewMode(MediaPreviewMode.privateRooms),
    );
    final backend = FakeBackend()
      ..roomList = [
        const ChatRoom(
          id: '!public:example.org',
          name: 'Public',
          preview: '',
          lastActivity: null,
          isPublic: true,
        ),
        const ChatRoom(
          id: '!private:example.org',
          name: 'Private',
          preview: '',
          lastActivity: null,
        ),
      ];
    final results = <String, bool>{};
    await tester.pumpWidget(
      FeatureSettingsScope(
        preferences: preferences,
        draftStore: MessageDraftStore(),
        child: Builder(
          builder: (context) {
            for (final room in backend.roomList) {
              results[room.id] = autoLoadMediaFor(context, backend, room.id);
            }
            results['!unknown:example.org'] = autoLoadMediaFor(
              context,
              backend,
              '!unknown:example.org',
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(results['!public:example.org'], isFalse);
    expect(results['!private:example.org'], isTrue);
    expect(results['!unknown:example.org'], isTrue);
  });
}

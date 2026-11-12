import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/saved/folders_screen.dart';
import 'package:parallax/features/saved/note_to_self.dart';
import 'package:parallax/features/saved/saved_features.dart';
import 'package:parallax/features/saved/saved_hooks.dart';
import 'package:parallax/features/saved/saved_messages_screen.dart';
import 'package:parallax/features/saved/saved_models.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/inbox_screen.dart';

import 'saved_fakes.dart';
import 'widget_test.dart' show FakeBackend;

final _palette = paletteFor(VisualTheme.parallax);

const _team = '!team:x.org';
const _alex = '!alex:x.org';
const _note = '!note:x.org';

ChatEntry _entry(
  String id, {
  String body = 'hello',
  String sender = '@mia:x.org',
  String? name = 'Mia',
  EntryKind? kind,
  bool redacted = false,
}) => ChatEntry(
  id: id,
  sender: sender,
  senderName: name,
  body: body,
  time: DateTime(2026, 11, 10, 9, 30),
  mine: false,
  kind: kind,
  redacted: redacted,
);

Future<void> _surface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _pumpInbox(WidgetTester tester, SavedFakeBackend backend) async {
  await _surface(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(VisualTheme.parallax),
      home: InboxScreen(
        backend: backend,
        palette: _palette,
        style: VisualTheme.parallax,
        onThemeChanged: (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

SavedFakeBackend _backend() => SavedFakeBackend()
  ..roomList = [
    savedRoom(_team, name: 'Team', unread: 3, preview: 'standup'),
    savedRoom(_alex, name: 'Alex', direct: true),
  ];

void main() {
  group('inbox: note to self', () {
    testWidgets('is pinned first with its own avatar and counts as a '
        'person', (tester) async {
      final backend = _backend()
        ..noteRoom = _note
        ..roomList = [
          ..._backend().roomList,
          savedRoom(_note, name: 'Empty room', encrypted: true),
        ];
      await _pumpInbox(tester, backend);

      expect(find.byType(NoteToSelfTile), findsOneWidget);
      expect(find.byType(NoteToSelfAvatar), findsOneWidget);
      expect(find.text('Note to self'), findsOneWidget);
      expect(find.text('Empty room'), findsNothing);
      expect(find.text('Start your note to self'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Note to self')).dy,
        lessThan(tester.getTopLeft(find.text('Team')).dy),
      );

      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      expect(find.text('Note to self'), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('Team'), findsNothing);

      await tester.tap(find.text('Note to self'));
      await tester.pumpAndSettle();
      expect(backend.activeRoomId, _note);
    });

    testWidgets('start row creates the note, or can be dismissed', (
      tester,
    ) async {
      final backend = _backend();
      await _pumpInbox(tester, backend);
      expect(find.text('Start your note to self'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(backend.promptDismissed, isTrue);
      expect(find.text('Start your note to self'), findsNothing);

      backend.promptDismissed = false;
      backend.notifyListeners();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start your note to self'));
      await tester.pumpAndSettle();
      expect(backend.noteOpens, 1);
      expect(backend.activeRoomId, _note);
      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(NoteToSelfTile), findsOneWidget);
      expect(find.text('Start your note to self'), findsNothing);
    });

    testWidgets('start row is hidden while filtering', (tester) async {
      final backend = _backend();
      await _pumpInbox(tester, backend);
      await tester.tap(find.text('Rooms'));
      await tester.pumpAndSettle();
      expect(find.text('Start your note to self'), findsNothing);
    });
  });

  group('inbox: chat folders', () {
    SavedFakeBackend withFolders() => _backend()
      ..folderData = const ChatFolders(
        folders: [
          ChatFolder(
            id: 'work',
            name: 'Work',
            icon: '💼',
            includeRooms: [_team],
          ),
          ChatFolder(
            id: 'people',
            name: 'Friends',
            include: FolderIncludes(people: true),
          ),
        ],
      );

    testWidgets('no tabs without folders', (tester) async {
      await _pumpInbox(tester, _backend());
      expect(find.byKey(const ValueKey('folder-tab-all')), findsNothing);
    });

    testWidgets('tabs filter the list and show unread badges', (tester) async {
      final backend = withFolders();
      await _pumpInbox(tester, backend);

      expect(find.byKey(const ValueKey('folder-tab-all')), findsOneWidget);
      final work = find.byKey(const ValueKey('folder-tab-work'));
      expect(
        find.descendant(of: work, matching: find.text('💼 Work')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: work, matching: find.text('1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('folder-tab-people')),
          matching: find.text('1'),
        ),
        findsNothing,
      );

      await tester.tap(find.text('Friends'));
      await tester.pumpAndSettle();
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('Team'), findsNothing);

      await tester.tap(work);
      await tester.pumpAndSettle();
      expect(find.text('Team'), findsOneWidget);
      expect(find.text('Alex'), findsNothing);

      // Combined with the existing filters.
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      expect(find.text('No chats in this folder yet'), findsNothing);
      expect(find.text('You don’t have any DMs yet'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear filters'));
      await tester.tap(find.byKey(const ValueKey('folder-tab-all')));
      await tester.pumpAndSettle();
      expect(find.text('Team'), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
    });

    testWidgets('long-press a tab to reorder or delete it', (tester) async {
      final backend = withFolders();
      await _pumpInbox(tester, backend);
      await tester.tap(find.byKey(const ValueKey('folder-tab-work')));
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const ValueKey('folder-tab-work')));
      await tester.pumpAndSettle();
      expect(find.text('Move left'), findsNothing);
      await tester.tap(find.text('Move right'));
      await tester.pumpAndSettle();
      expect(
        [for (final f in backend.folderData.folders) f.id],
        ['people', 'work'],
      );

      await tester.longPress(find.byKey(const ValueKey('folder-tab-work')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete folder'));
      await tester.pumpAndSettle();
      expect(find.text('Delete “Work”?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete folder'));
      await tester.pumpAndSettle();
      expect(backend.folderData.byId('work'), isNull);
      expect(find.byKey(const ValueKey('folder-tab-work')), findsNothing);
      // The selection falls back to All.
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('Team'), findsOneWidget);
    });

    testWidgets('room menu adds a chat to a folder and takes it out again', (
      tester,
    ) async {
      final backend = withFolders();
      await _pumpInbox(tester, backend);

      await tester.longPress(find.text('Alex'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to folder…'));
      await tester.pumpAndSettle();
      final work = find.byKey(const ValueKey('add-to-folder-work'));
      final friends = find.byKey(const ValueKey('add-to-folder-people'));
      expect(tester.widget<CheckboxListTile>(work).value, isFalse);
      expect(tester.widget<CheckboxListTile>(friends).value, isTrue);

      await tester.tap(work);
      await tester.pumpAndSettle();
      expect(backend.folderData.byId('work')!.includeRooms, [_team, _alex]);
      expect(tester.widget<CheckboxListTile>(work).value, isTrue);

      // Alex matches Friends by type, so removing excludes it explicitly.
      await tester.tap(friends);
      await tester.pumpAndSettle();
      expect(backend.folderData.byId('people')!.excludeRooms, [_alex]);
      expect(tester.widget<CheckboxListTile>(friends).value, isFalse);
    });

    testWidgets('new folder from the tab bar is created and selected', (
      tester,
    ) async {
      final backend = withFolders();
      await _pumpInbox(tester, backend);
      await tester.tap(find.byTooltip('New folder'));
      await tester.pumpAndSettle();
      expect(find.text('New folder'), findsWidgets);

      await tester.enterText(find.byType(TextField).first, 'Mates');
      await tester.pump();
      // Nothing included yet.
      expect(
        find.text('Choose at least one chat type or add a chat.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(SwitchListTile, 'People'));
      await tester.pump();
      await tester.tap(find.text('Create folder'));
      await tester.pumpAndSettle();

      final created = backend.folderData.folders.last;
      expect(created.name, 'Mates');
      expect(created.include.people, isTrue);
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(find.text('Team'), findsNothing); // The new tab is selected.
      expect(find.text('Alex'), findsOneWidget);
    });
  });

  group('saved messages screen', () {
    SavedFakeBackend withBookmarks() {
      final backend = _backend()
        ..roomList = [..._backend().roomList, savedRoom(_note, direct: true)]
        ..noteRoom = _note;
      backend.saved = BookmarkList.empty
          .withAdded(_team, r'$text', savedTs: 50)
          .withAdded(_team, r'$removed', savedTs: 40)
          .withAdded(_alex, r'$deleted', savedTs: 30)
          .withAdded('!left:x.org', r'$left', savedTs: 20)
          .withAdded(_alex, r'$offline', savedTs: 10);
      backend.events[r'$text'] = SavedEventResult.available(
        _entry(r'$text', body: 'Remember the milk'),
      );
      backend.events[r'$removed'] = SavedEventResult.available(
        _entry(r'$removed', redacted: true),
      );
      backend.failingEvents.add(r'$offline');
      return backend;
    }

    Future<List<String>> pumpSaved(
      WidgetTester tester,
      SavedFakeBackend backend,
    ) async {
      final opened = <String>[];
      await _surface(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          home: SavedMessagesScreen(
            backend: backend,
            palette: _palette,
            onOpenRoom: (_, roomId) => opened.add(roomId),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return opened;
    }

    testWidgets('shows sender, room and preview, and explains unavailable '
        'messages', (tester) async {
      final backend = withBookmarks();
      await pumpSaved(tester, backend);

      expect(find.text('Mia'), findsNWidgets(2));
      expect(find.text('Remember the milk'), findsOneWidget);
      expect(find.text('Team'), findsWidgets);
      expect(find.text('Message removed'), findsOneWidget);
      expect(find.text('Message unavailable'), findsOneWidget);
      expect(find.text('Room unavailable'), findsOneWidget);
      expect(find.text('Couldn’t load this message'), findsOneWidget);

      // Retry after a failure.
      backend.failingEvents.clear();
      backend.events[r'$offline'] = SavedEventResult.available(
        _entry(r'$offline', body: 'Back online', name: 'Alex'),
      );
      await tester.tap(find.text('Couldn’t load this message'));
      await tester.pumpAndSettle();
      expect(find.text('Back online'), findsOneWidget);
    });

    testWidgets('tapping jumps to the message and opens its room', (
      tester,
    ) async {
      final backend = withBookmarks();
      final opened = await pumpSaved(tester, backend);
      await tester.tap(find.text('Remember the milk'));
      await tester.pumpAndSettle();
      expect(backend.jumps, ['$_team \$text']);
      expect(opened, [_team]);

      // A left room cannot be opened.
      await tester.tap(find.text('Room unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('You’re no longer in this room.'), findsOneWidget);
      expect(opened, [_team]);
    });

    testWidgets('swipe removes a saved message, with undo', (tester) async {
      final backend = withBookmarks();
      await pumpSaved(tester, backend);
      await tester.drag(find.text('Remember the milk'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(backend.saved.contains(_team, r'$text'), isFalse);
      expect(find.text('Remember the milk'), findsNothing);
      expect(find.text('Removed from saved messages'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(backend.saved.contains(_team, r'$text'), isTrue);
      expect(backend.saved.bookmarks.first.eventId, r'$text');
      expect(find.text('Remember the milk'), findsOneWidget);
    });

    testWidgets('long-press offers removal; room chips filter', (tester) async {
      final backend = withBookmarks();
      await pumpSaved(tester, backend);

      await tester.tap(find.widgetWithText(ActionChip, 'Alex'));
      await tester.pumpAndSettle();
      expect(find.text('Remember the milk'), findsNothing);
      expect(find.text('Message unavailable'), findsOneWidget);

      await tester.longPress(find.text('Message unavailable'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from saved'));
      await tester.pumpAndSettle();
      expect(backend.saved.contains(_alex, r'$deleted'), isFalse);

      await tester.tap(find.widgetWithText(ActionChip, 'All rooms'));
      await tester.pumpAndSettle();
      expect(find.text('Remember the milk'), findsOneWidget);
    });

    testWidgets('empty state', (tester) async {
      await pumpSaved(tester, _backend());
      expect(find.text('No saved messages yet'), findsOneWidget);
    });

    testWidgets('the inbox bookmark icon opens it', (tester) async {
      final backend = withBookmarks();
      await _pumpInbox(tester, backend);
      await tester.tap(find.byTooltip('Saved messages'));
      await tester.pumpAndSettle();
      expect(find.byType(SavedMessagesScreen), findsOneWidget);
      expect(find.text('Remember the milk'), findsOneWidget);
    });
  });

  group('hooks', () {
    testWidgets('Save / Remove from saved message action', (tester) async {
      final backend = _backend();
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      List<MessageActionItem> actions(ChatEntry entry) => savedMessageActions(
        context,
        EntryHookContext(
          backend: backend,
          roomId: _team,
          palette: _palette,
          entry: entry,
        ),
      );

      expect(actions(_entry('local-echo')), isEmpty);
      expect(actions(_entry(r'$s', kind: EntryKind.state)), isEmpty);
      expect(actions(_entry(r'$r', redacted: true)), isEmpty);

      final save = actions(_entry(r'$m')).single;
      expect(save.label, 'Save');
      await save.onSelected(context);
      await tester.pump();
      expect(backend.saved.contains(_team, r'$m'), isTrue);
      expect(find.text('Message saved'), findsOneWidget);

      final remove = actions(_entry(r'$m')).single;
      expect(remove.label, 'Remove from saved');
      await remove.onSelected(context);
      await tester.pump();
      expect(backend.saved.isEmpty, isTrue);

      backend.failWrites = true;
      await actions(_entry(r'$m')).single.onSelected(context);
      await tester.pump();
      expect(find.text('Couldn’t update your saved messages.'), findsOneWidget);
    });

    testWidgets('Settings → Saved section links note, saved and folders', (
      tester,
    ) async {
      final backend = _backend()
        ..saved = BookmarkList.empty.withAdded(_team, r'$a', savedTs: 1)
        ..folderData = const ChatFolders(
          folders: [
            ChatFolder(
              id: 'a',
              name: 'Alpha',
              include: FolderIncludes(people: true),
            ),
            ChatFolder(id: 'b', name: 'Beta', includeRooms: [_team]),
          ],
        );
      await _surface(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: savedSettingsSections(
                  context,
                  SettingsHookContext(backend: backend, palette: _palette),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Note to self'), findsOneWidget);
      expect(find.text('1 message'), findsOneWidget);
      expect(find.text('2 folders'), findsOneWidget);

      await tester.tap(find.text('Chat folders'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatFoldersScreen), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('People'), findsOneWidget);
      expect(find.text('1 chat'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete folder').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete folder'));
      await tester.pumpAndSettle();
      expect([for (final f in backend.folderData.folders) f.id], ['b']);

      Navigator.of(tester.element(find.byType(ChatFoldersScreen))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Note to self'));
      await tester.pumpAndSettle();
      expect(backend.noteOpens, 1);
      expect(backend.activeRoomId, _note);
    });

    test('resolver returns fakes directly and nothing for plain backends', () {
      final backend = _backend();
      expect(savedFeaturesOf(backend), same(backend));
      expect(savedFeaturesOf(FakeBackend()), isNull);
    });
  });
}

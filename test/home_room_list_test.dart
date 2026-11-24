import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/home/home_features.dart';
import 'package:parallax/features/home/room_list_filters.dart';
import 'package:parallax/haptics.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/space_browser_screen.dart';
import 'package:parallax/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_fakes.dart';
import 'home_options.dart';

ChatRoom _room(
  String id, {
  String? name,
  bool direct = false,
  int unread = 0,
  int highlights = 0,
  bool favourite = false,
  bool low = false,
  bool invited = false,
  bool space = false,
  bool manual = false,
  RoomNotificationMode mode = RoomNotificationMode.allMessages,
  String preview = '',
  String? sender,
  bool previewIncludesSender = false,
  String? code,
}) => ChatRoom(
  id: id,
  name: name ?? id,
  preview: preview,
  lastActivity: null,
  isDirect: direct,
  unread: unread,
  highlightCount: highlights,
  favourite: favourite,
  lowPriority: low,
  invited: invited,
  isSpace: space,
  manuallyUnread: manual,
  notificationMode: mode,
  previewSender: sender,
  previewIncludesSender: previewIncludesSender,
  previewCode: code,
);

List<String> _ids(List<ChatRoom> rooms) => [for (final r in rooms) r.id];

void main() {
  group('room list filters', () {
    final rooms = [
      _room('low', low: true),
      _room('dm', direct: true, unread: 2),
      _room('group'),
      _room('fav', favourite: true),
      _room('invite', invited: true),
      _room('space', space: true),
      _room('mention', highlights: 1),
      _room('manual', manual: true, direct: true),
    ];

    test(
      'default list hides Spaces and orders invite, favourite, low last',
      () {
        expect(_ids(filterRoomList(rooms, const {}, const RoomListContext())), [
          'invite',
          'fav',
          'dm',
          'group',
          'mention',
          'manual',
          'low',
        ]);
      },
    );

    test('filters combine and match Element X semantics', () {
      List<String> run(Set<RoomListFilter> filters) =>
          _ids(filterRoomList(rooms, filters, const RoomListContext()));
      expect(run({RoomListFilter.unread}), ['dm', 'mention', 'manual']);
      expect(run({RoomListFilter.people}), ['dm', 'manual']);
      expect(run({RoomListFilter.unread, RoomListFilter.people}), [
        'dm',
        'manual',
      ]);
      expect(run({RoomListFilter.rooms}), ['fav', 'group', 'mention', 'low']);
      expect(run({RoomListFilter.favourites}), ['fav']);
      expect(run({RoomListFilter.lowPriority}), ['low']);
      expect(run({RoomListFilter.invites}), ['invite']);
    });

    test('favourites from another source and failed sends count', () {
      final result = filterRoomList(rooms, {
        RoomListFilter.favourites,
      }, const RoomListContext(favourites: {'group'}));
      expect(_ids(result), ['group', 'fav']);
      expect(
        _ids(
          filterRoomList(rooms, {
            RoomListFilter.unread,
          }, const RoomListContext(failedRooms: {'group'})),
        ),
        contains('group'),
      );
    });

    test('incompatible filters are deselected', () {
      var selected = toggleRoomListFilter(const {}, RoomListFilter.unread);
      selected = toggleRoomListFilter(selected, RoomListFilter.people);
      expect(selected, {RoomListFilter.unread, RoomListFilter.people});
      selected = toggleRoomListFilter(selected, RoomListFilter.rooms);
      expect(selected, {RoomListFilter.unread, RoomListFilter.rooms});
      selected = toggleRoomListFilter(selected, RoomListFilter.invites);
      expect(selected, {RoomListFilter.invites});
      selected = toggleRoomListFilter(selected, RoomListFilter.favourites);
      expect(selected, {RoomListFilter.favourites});
      selected = toggleRoomListFilter(selected, RoomListFilter.lowPriority);
      expect(selected, {RoomListFilter.lowPriority});
      selected = toggleRoomListFilter(selected, RoomListFilter.lowPriority);
      expect(selected, isEmpty);
    });

    test('a selected Space restricts the list and search applies', () {
      expect(
        _ids(
          filterRoomList(
            rooms,
            const {},
            const RoomListContext(spaceRooms: {'group', 'dm', 'space'}),
          ),
        ),
        ['dm', 'group'],
      );
      expect(
        _ids(
          filterRoomList(rooms, const {}, const RoomListContext(query: 'GRO')),
        ),
        ['group'],
      );
    });

    test('empty states use Element X copy', () {
      expect(roomListEmptyState(const {}), isNull);
      expect(
        roomListEmptyState({RoomListFilter.unread})!.title,
        'Congrats! You don’t have any unread messages!',
      );
      expect(
        roomListEmptyState({RoomListFilter.people})!.title,
        'You don’t have any DMs yet',
      );
      expect(
        roomListEmptyState({RoomListFilter.favourites})!.title,
        'You don’t have favourite chats yet',
      );
      expect(
        roomListEmptyState({
          RoomListFilter.unread,
          RoomListFilter.people,
        })!.title,
        'You don’t have chats for this selection',
      );
      expect(
        roomListEmptyState(const {}, spaceSelected: true)!.title,
        'No chats in this Space yet',
      );
    });

    test('query matches people in group rooms, not just room names', () {
      final rooms = [
        ChatRoom(
          id: '!g:x',
          name: 'Project',
          preview: '',
          lastActivity: null,
          heroes: const [ChatAvatar(name: 'Mia Chen')],
        ),
        _room('!d:x', name: 'Alex', direct: true),
        _room('!other:x', name: 'Other', sender: 'Bob'),
      ];
      List<String> run(String query) =>
          _ids(filterRoomList(rooms, const {}, RoomListContext(query: query)));
      expect(run('mia'), ['!g:x']); // member name in a group
      expect(run('alex'), ['!d:x']); // DM name
      expect(run('bob'), ['!other:x']); // last sender
      expect(run('project'), ['!g:x']); // room name still works
      expect(run('zzz'), isEmpty);
    });

    test('matrix.to links encode IDs and add a via server', () {
      expect(
        matrixToRoomLink('!abc:example.org', viaServer: 'example.org'),
        'https://matrix.to/#/!abc%3Aexample.org?via=example.org',
      );
      expect(
        matrixToRoomLink('#room:example.org', viaServer: 'example.org'),
        'https://matrix.to/#/%23room%3Aexample.org',
      );
    });
  });

  group('inbox', () {
    late HomeFakeBackend backend;
    late List<String> clipboard;
    late List<String?> haptics;

    setUp(() {
      backend = HomeFakeBackend()
        ..roomList = [
          _room(
            '!team:x.org',
            name: 'Team',
            unread: 3,
            highlights: 1,
            preview: 'hello',
            sender: 'Mia',
          ),
          _room('!quiet:x.org', name: 'Quiet', low: true),
          _room(
            '!muted:x.org',
            name: 'Muted room',
            unread: 1,
            mode: RoomNotificationMode.mute,
          ),
          _room('!alex:x.org', name: 'Alex', direct: true),
          _room('!space:x.org', name: 'Hidden space', space: true),
        ]
        ..spaces = const [HomeSpace(id: '!space:x.org', name: 'Work')]
        ..spaceChildren = const {
          '!space:x.org': {'!team:x.org'},
        };
      clipboard = [];
      haptics = [];
    });

    Future<void> pump(
      WidgetTester tester, {
      AppearancePreferences? prefs,
    }) async {
      // Phone window: the inbox tests assert single-pane behaviour.
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String?);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final inbox = MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      );
      await tester.pumpWidget(
        prefs == null
            ? inbox
            : FeatureSettingsScope(
                preferences: prefs,
                draftStore: MessageDraftStore(),
                child: inbox,
              ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('room rows show sender previews, mention and muted state', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Mia: hello'), findsOneWidget);
      expect(find.byTooltip('Mentioned'), findsOneWidget);
      expect(find.byTooltip('Notifications muted'), findsOneWidget);
      expect(find.text('Hidden space'), findsNothing);
      await openHomeOptions(tester);
      expect(find.text('4 ROOMS'), findsOneWidget);
      // Low priority sorts last.
      expect(
        tester.getTopLeft(find.text('Quiet')).dy,
        greaterThan(tester.getTopLeft(find.text('Alex')).dy),
      );
    });

    testWidgets('room rows do not repeat senders in activity previews', (
      tester,
    ) async {
      backend.roomList = [
        _room(
          '!activity:x.org',
          name: 'Group',
          preview: 'Chris sent a photo',
          sender: 'Chris',
          previewIncludesSender: true,
        ),
      ];
      await pump(tester);
      expect(find.text('Chris sent a photo'), findsOneWidget);
      expect(find.text('Chris: Chris sent a photo'), findsNothing);
    });

    testWidgets('row style and message preview follow the home settings', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = AppearancePreferences();
      addTearDown(prefs.dispose);
      await pump(tester, prefs: prefs);
      // Defaults: cards with a two-line preview.
      expect(find.text('Mia: hello'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Mia: hello')).maxLines, 2);
      expect(find.byType(Divider), findsNothing);

      await prefs.setHomePreview(HomePreview.small);
      await prefs.setHomeRowStyle(HomeRowStyle.list);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('Mia: hello')).maxLines, 1);
      // Flat rows are separated by lines.
      expect(find.byType(Divider), findsWidgets);

      await prefs.setHomePreview(HomePreview.none);
      await prefs.setHomeRowStyle(HomeRowStyle.compact);
      await tester.pumpAndSettle();
      expect(find.text('Mia: hello'), findsNothing);
      // Names and unread/mention badges stay.
      expect(find.text('Team'), findsOneWidget);
      expect(find.byTooltip('Mentioned'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('copying an unread code marks its chat read without opening', (
      tester,
    ) async {
      const sms = 'Your verification code is 671152. Don’t share it.';
      backend.roomList = [
        _room(
          '!google:x.org',
          name: 'Google',
          direct: true,
          unread: 1,
          preview: sms,
          code: '671152',
        ),
        // Read, and an invitation: no button.
        _room('!bank:x.org', name: 'Bank', preview: sms, code: '671152'),
        _room('!inv:x.org', name: 'Invitation', invited: true, code: '671152'),
      ];
      await pump(tester);
      final copy = find.text('Copy ‘671152’');
      expect(copy, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('room-!google:x.org')),
          matching: copy,
        ),
        findsOneWidget,
      );
      // Under the preview, inside the row.
      expect(
        tester.getTopLeft(copy).dy,
        greaterThan(tester.getBottomLeft(find.text(sms).first).dy),
      );

      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(clipboard, ['671152']);
      expect(find.text('Code copied'), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      // The chat is marked read, and only that chat, without being opened.
      expect(find.byType(RoomScreen), findsNothing);
      expect(backend.activeRoomId, isNull);
      expect(backend.calls, ['read:!google:x.org']);
      expect(backend.lastPublicReceipt, isTrue);
      expect(backend.lastRoomUnread, isNull);
      // Read now, so the button goes and the row stays.
      expect(copy, findsNothing);
      expect(find.text('Google'), findsOneWidget);
      expect(
        backend.roomList.singleWhere((r) => r.id == '!google:x.org').unread,
        0,
      );
    });

    testWidgets('copying a code clears a manual unread mark as well', (
      tester,
    ) async {
      backend.roomList = [
        _room(
          '!bank:x.org',
          name: 'Bank',
          direct: true,
          manual: true,
          preview: 'Use 4821 to sign in.',
          code: '4821',
        ),
      ];
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('copy-code-!bank:x.org')));
      await tester.pumpAndSettle();
      expect(clipboard, ['4821']);
      expect(backend.lastRoomUnread, isFalse);
      expect(backend.calls, ['read:!bank:x.org']);
      expect(
        backend.roomList.single.manuallyUnread,
        isFalse,
        reason: 'the manual unread mark is cleared',
      );
      expect(find.byKey(const ValueKey('copy-code-!bank:x.org')), findsNothing);
    });

    testWidgets('copying a code respects the private receipt preference', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = AppearancePreferences();
      addTearDown(prefs.dispose);
      await prefs.setSendReadReceipts(false);
      backend.roomList = [
        _room('!google:x.org', name: 'Google', unread: 1, code: '671152'),
      ];
      await pump(tester, prefs: prefs);
      await tester.tap(find.byKey(const ValueKey('copy-code-!google:x.org')));
      await tester.pumpAndSettle();
      expect(clipboard, ['671152']);
      expect(backend.calls, ['read:!google:x.org']);
      expect(backend.lastPublicReceipt, isFalse);
    });

    testWidgets('a code that could not be copied leaves its chat unread', (
      tester,
    ) async {
      backend.roomList = [
        _room('!google:x.org', name: 'Google', unread: 1, code: '671152'),
      ];
      await pump(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'clipboard');
          }
          return null;
        },
      );
      final button = find.byKey(const ValueKey('copy-code-!google:x.org'));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t copy the code.'), findsOneWidget);
      expect(find.text('Code copied'), findsNothing);
      expect(backend.calls, isEmpty);
      expect(button, findsOneWidget);
      expect(backend.roomList.single.unread, 1);
    });

    testWidgets('a failed mark as read still copies and keeps the button', (
      tester,
    ) async {
      backend
        ..markAsReadError = StateError('offline')
        ..roomList = [
          _room('!google:x.org', name: 'Google', unread: 1, code: '671152'),
        ];
      await pump(tester);
      final button = find.byKey(const ValueKey('copy-code-!google:x.org'));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(clipboard, ['671152']);
      expect(find.text('Code copied'), findsOneWidget);
      expect(backend.calls, ['read:!google:x.org']);
      expect(tester.takeException(), isNull);
      // Still unread, so the code can be copied again.
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(clipboard, ['671152', '671152']);
    });

    testWidgets('the copy button fits every row style on a narrow phone', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = AppearancePreferences();
      addTearDown(prefs.dispose);
      backend.roomList = [
        _room(
          '!codes:x.org',
          name: 'A sender with a very long name that has to be cut short',
          unread: 120,
          highlights: 1,
          preview: 'Your code is ABCD-1234-EFGH. Do not share it with anyone.',
          sender: 'Mia',
          code: 'ABCD-1234-EFGH',
        ),
      ];
      await pump(tester, prefs: prefs);
      await tester.binding.setSurfaceSize(const Size(320, 700));
      for (final style in HomeRowStyle.values) {
        for (final preview in HomePreview.values) {
          await prefs.setHomeRowStyle(style);
          await prefs.setHomePreview(preview);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('copy-code-!codes:x.org')),
            findsOneWidget,
            reason: '$style $preview',
          );
          expect(tester.takeException(), isNull, reason: '$style $preview');
        }
      }
    });

    testWidgets('Space switcher filters to Space children', (tester) async {
      await pump(tester);
      await openHomeOptions(tester);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(find.text('Team'), findsOneWidget);
      expect(find.text('Alex'), findsNothing);
      await tester.tap(find.text('All chats'));
      await tester.pumpAndSettle();
      expect(find.text('Alex'), findsOneWidget);
    });

    testWidgets('Space can be left from its options', (tester) async {
      await pump(tester);
      await openHomeOptions(tester);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Work'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave Space'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Leave Space'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('leaveSpace:!space:x.org'));
      expect(find.text('Work'), findsNothing);
      expect(find.text('Alex'), findsOneWidget);
    });

    testWidgets('long-press menu tags, mutes, copies and marks read', (
      tester,
    ) async {
      await pump(tester);
      Future<void> menu(String room, String action) async {
        await tester.longPress(find.text(room));
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
      }

      await menu('Team', 'Mark as read');
      expect(backend.calls, contains('read:!team:x.org'));
      expect(backend.lastPublicReceipt, isTrue);
      expect(find.byTooltip('Mentioned'), findsNothing);

      await menu('Alex', 'Mark as low priority');
      expect(backend.calls, contains('low:!alex:x.org:true'));

      await menu('Alex', 'Add favourite');
      expect(backend.calls, contains('favourite:!alex:x.org:true'));

      await menu('Muted room', 'Unmute notifications');
      expect(backend.calls, contains('mute:!muted:x.org:false'));
      await menu('Team', 'Mute notifications');
      expect(backend.calls, contains('mute:!team:x.org:true'));

      await menu('Team', 'Copy room link');
      expect(clipboard.single, startsWith('https://matrix.to/#/!team'));
      expect(find.text('Room link copied'), findsOneWidget);
    });

    testWidgets('mark as read respects the private receipt preference', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = AppearancePreferences();
      addTearDown(prefs.dispose);
      await prefs.setSendReadReceipts(false);
      await pump(tester, prefs: prefs);
      await tester.longPress(find.text('Team'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as read'));
      await tester.pumpAndSettle();
      expect(backend.lastPublicReceipt, isFalse);
    });

    testWidgets('filters show Element X empty states and can be cleared', (
      tester,
    ) async {
      await pump(tester);
      await openHomeOptions(tester);
      // The chip row scrolls horizontally on a phone-width screen.
      await tester.ensureVisible(find.text('Favourites'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favourites'));
      await tester.pumpAndSettle();
      expect(find.text('You don’t have favourite chats yet'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Clear filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Team'), findsOneWidget);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('Team'), findsNothing);
    });

    testWidgets(
      'search pops in from the top bar and Explore rooms stays in options',
      (tester) async {
        await pump(tester);
        final search = find.byKey(const ValueKey('home.conversation_search'));
        expect(find.text('Team'), findsOneWidget);
        expect(find.text('Alex'), findsOneWidget);
        expect(search, findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.byTooltip('Search conversations'), findsOneWidget);
        for (final hidden in [
          'Explore rooms',
          'Favourites',
          'Work',
          '4 ROOMS',
          'Messages',
        ]) {
          expect(find.text(hidden), findsNothing, reason: hidden);
        }
        expect(find.byTooltip('Explore public rooms'), findsNothing);

        await tester.tap(find.byTooltip('Search conversations'));
        await tester.pumpAndSettle();
        expect(search, findsOneWidget);
        expect(find.text('Search people, rooms and messages'), findsOneWidget);
        expect(FocusScope.of(tester.element(search)).hasFocus, isTrue);
        expect(
          tester.getTopLeft(search).dy,
          lessThan(tester.getTopLeft(find.text('Team')).dy),
        );

        // Search works without opening the options panel.
        await tester.enterText(search, 'ale');
        await tester.pump();
        expect(find.text('Alex'), findsOneWidget);
        expect(find.text('Team'), findsNothing);

        // Closing search also removes its now-invisible room-list filter.
        await tester.tap(find.byTooltip('Hide conversation search'));
        await tester.pumpAndSettle();
        expect(search, findsNothing);
        expect(find.text('Team'), findsOneWidget);
        await tester.tap(find.byTooltip('Search conversations'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        await tester.tap(find.byTooltip('Hide conversation search'));
        await tester.pumpAndSettle();

        await openHomeOptions(tester);
        expect(search, findsNothing);
        expect(find.text('Explore rooms'), findsOneWidget);
        expect(find.text('Favourites'), findsOneWidget);
        expect(find.text('Work'), findsOneWidget);
        expect(find.text('4 ROOMS'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Favourites')).dy,
          lessThan(tester.getTopLeft(find.text('Team')).dy),
        );

        await tester.tap(find.byTooltip('Hide options'));
        await tester.pumpAndSettle();
        expect(find.text('Explore rooms'), findsNothing);
        expect(find.text('Favourites'), findsNothing);
        expect(search, findsNothing);
        expect(find.byTooltip('Show options'), findsOneWidget);
      },
    );

    testWidgets('system back closes conversation search before app exit', (
      tester,
    ) async {
      await pump(tester);
      final search = find.byKey(const ValueKey('home.conversation_search'));
      await tester.tap(find.byTooltip('Search conversations'));
      await tester.pumpAndSettle();
      await tester.enterText(search, 'ale');
      await tester.pump();
      expect(find.text('Team'), findsNothing);
      expect(find.text('Alex'), findsOneWidget);

      final searchHandled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(searchHandled, isTrue);
      expect(search, findsNothing);
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(find.text('Team'), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);

      // With search dismissed, Back retains its normal app-exit behaviour.
      final exitHandled = await tester.binding.handlePopRoute();
      expect(exitHandled, isFalse);
    });

    testWidgets(
      'home search lists message matches inline without a second screen',
      (tester) async {
        // FakeBackend.searchMessages returns "Found it in a room" in
        // !r:example.org; make that room visible so the hit is in scope.
        backend.roomList = [
          ...backend.roomList,
          _room('!r:example.org', name: 'General'),
        ];
        await pump(tester);
        await tester.tap(find.byTooltip('Search conversations'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Search messages'), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('home.conversation_search')),
          'zzz',
        );
        await tester.pump();
        // While the search is pending, show the searching animation instead of a
        // premature empty state.
        expect(
          find.byKey(const ValueKey('home.message_search_spinner')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('home.message_search_shimmer')),
          findsOneWidget,
        );
        expect(find.text('Searching…'), findsOneWidget);
        expect(find.text('No matches yet'), findsNothing);

        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.text('Found it in a room'), findsOneWidget);
        expect(find.text('MESSAGE MATCHES'), findsOneWidget);
        expect(find.text('See all message results'), findsNothing);
        expect(
          find.byKey(const ValueKey('home.message_search_spinner')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('home.message_search_shimmer')),
          findsNothing,
        );
        // No room name matches "zzz": the room list is empty, only messages.
        expect(find.text('Team'), findsNothing);
        expect(find.text('Alex'), findsNothing);
      },
    );

    testWidgets('a collapsed menu says what narrows the list and can clear', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Search conversations'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('home.conversation_search')),
        'ale',
      );
      await openHomeOptions(tester);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hide options'));
      await tester.pumpAndSettle();
      expect(find.text('Showing “ale” · People'), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('Team'), findsNothing);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Showing'), findsNothing);
      expect(find.text('Team'), findsOneWidget);
      // The still-open search field is cleared too, not just the query.
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('home.conversation_search')),
            )
            .controller!
            .text,
        isEmpty,
      );
    });

    testWidgets('Show all home options keeps everything on screen', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = AppearancePreferences();
      addTearDown(prefs.dispose);
      await prefs.setExpandedHome(true);
      await pump(tester, prefs: prefs);
      expect(find.byTooltip('Show options'), findsNothing);
      expect(find.text('Messages'), findsOneWidget);
      expect(find.text('Search people, rooms and messages'), findsNothing);
      expect(find.text('Explore rooms'), findsOneWidget);
      expect(find.text('Favourites'), findsOneWidget);
      expect(find.text('4 ROOMS'), findsOneWidget);

      // Search remains an independent pop-in even in the expanded layout.
      await tester.tap(find.byTooltip('Search conversations'));
      await tester.pumpAndSettle();
      expect(find.text('Search people, rooms and messages'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide conversation search'));
      await tester.pumpAndSettle();

      // Turning it off live folds the options back into the menu.
      await prefs.setExpandedHome(false);
      await tester.pumpAndSettle();
      expect(find.text('Favourites'), findsNothing);
      expect(find.byTooltip('Show options'), findsOneWidget);
    });

    testWidgets('menu, filters and Spaces give haptic feedback', (
      tester,
    ) async {
      addTearDown(() => Haptics.enabled = true);
      await pump(tester);
      await openHomeOptions(tester);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(haptics, hasLength(3));

      Haptics.enabled = false;
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      expect(haptics, hasLength(3));
    });

    testWidgets('a joined Space can be left from its browser', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SpaceBrowserScreen(
                    backend: backend,
                    spaceId: '!space:x.org',
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Leave Space'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Leave Space'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('leaveSpace:!space:x.org'));
      expect(find.byType(SpaceBrowserScreen), findsNothing);
    });

    testWidgets('invite avatars can be hidden and invites accepted inline', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = AppearancePreferences();
      addTearDown(prefs.dispose);
      await prefs.setHideInviteAvatars(true);
      backend.roomList = [
        ...backend.roomList,
        _room('!inv:x.org', name: 'Invitation', invited: true),
      ];
      await pump(tester, prefs: prefs);
      final row = find.ancestor(
        of: find.text('Invitation'),
        matching: find.byKey(const ValueKey('room-!inv:x.org')),
      );
      expect(
        find.descendant(of: row, matching: find.byType(InitialAvatar)),
        findsOneWidget,
      );
      expect(find.text('Invited you to join'), findsOneWidget);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(backend.activeRoomId, '!inv:x.org');
    });
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/appearance_settings_screen.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/gallery_bubble.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/main.dart';
import 'package:parallax/media_viewer.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/message_image.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/features/reactions/message_action_features.dart';
import 'package:parallax/features/reactions/emoji_picker_sheet.dart';
import 'package:parallax/features/reactions/quick_reaction_settings.dart';
import 'package:parallax/rich_message_composer.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/space_browser_screen.dart';
import 'package:parallax/thread_screen.dart';
import 'package:parallax/timeline/message_bubble.dart';
import 'package:parallax/user_directory_screen.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

import 'widget_test.dart' show FakeBackend, FakeBackgroundStore;
import 'home_options.dart';

Offset copySpanCenter(WidgetTester tester, String span) {
  for (final element in find.byType(RichText).evaluate()) {
    final rich = element.widget as RichText;
    final plain = rich.text.toPlainText();
    final start = plain.indexOf(span);
    if (start < 0) continue;
    var tappable = false;
    rich.text.visitChildren((child) {
      if (child is TextSpan &&
          child.text == span &&
          child.recognizer is TapGestureRecognizer) {
        tappable = true;
      }
      return !tappable;
    });
    if (!tappable) continue;
    final paragraph = element.renderObject! as RenderParagraph;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + span.length),
    );
    expect(boxes, isNotEmpty);
    return paragraph.localToGlobal(boxes.first.toRect().center);
  }
  fail('No tappable span for $span');
}

const roomId = '!r:example.org';

class Drafts extends MessageDraftStore {
  final values = <String, String>{};
  final writes = <String>[];
  Completer<String>? readGate;
  bool failRead = false;

  String key(String account, String room) => '$account/$room';

  @override
  Future<String> read(String accountKey, String roomId) async {
    if (failRead) throw StateError('locked');
    return readGate?.future ?? values[key(accountKey, roomId)] ?? '';
  }

  @override
  Future<void> write(String accountKey, String roomId, String text) async {
    writes.add(text);
    values[key(accountKey, roomId)] = text;
  }

  @override
  Future<void> clearAccount(String accountKey) async {
    values.removeWhere((key, _) => key.startsWith('$accountKey/'));
  }
}

class FeaturesBackend extends FakeBackend
    implements MessagingFeatures, MessageActionFeatures {
  String account = 'account-a';
  String? busyRoom;
  void Function(String)? onQueue;
  @override
  bool isRoomSending(String roomId) => busyRoom == roomId || sending;
  SessionStatus status = SessionStatus.ready;
  Completer<void>? queueGate;
  List<PendingSend> outbox = [];
  String? queuedText;
  String? queuedReply;
  String? queuedEdit;
  String? queuedFont;
  MediaSelection? queuedMedia;
  String? retried;
  String? discarded;
  String? cancelled;
  String? directUser;
  String? favouriteFailure;
  String? receiptEvent;
  final favourites = <String>{};

  @override
  SessionStatus get connection => status;
  @override
  String get accountKey => account;
  @override
  List<PendingSend> get pendingSends => outbox;
  @override
  Future<void> queueMessage(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
    String? threadRootId,
    String? font,
  }) async {
    queuedText = text;
    queuedReply = replyToId;
    queuedEdit = editEventId;
    queuedFont = font;
    onQueue?.call(text);
    await queueGate?.future;
  }

  @override
  Future<void> queueMedia(
    String roomId,
    MediaSelection media, {
    String? caption,
    String? replyToId,
    String? threadRootId,
  }) async {
    queuedMedia = media;
    queuedText = caption;
    queuedReply = replyToId;
    await queueGate?.future;
  }

  @override
  Future<void> retryPending(String id) async => retried = id;
  @override
  Future<void> discardPending(String id) async => discarded = id;
  @override
  void cancelPending(String id) => cancelled = id;
  @override
  bool isFavourite(String roomId) {
    if (favouriteFailure == roomId) throw StateError('broken room');
    return favourites.contains(roomId);
  }

  @override
  Future<void> setFavourite(String roomId, bool favourite) async {
    favourite ? favourites.add(roomId) : favourites.remove(roomId);
    notifyListeners();
  }

  @override
  Future<void> createDirectChat(String userId) async {
    directUser = userId;
    activeId = roomId;
    notifyListeners();
  }

  @override
  List<SpaceSummary> get spaces => [];
  @override
  Future<List<DirectoryUser>> searchUsers(String query) async => [];
  @override
  Future<SpacePage> loadSpace(String spaceId, {String? nextBatch}) async =>
      const SpacePage([]);
  @override
  Future<ThreadPage> loadThread(
    String roomId,
    String rootEventId, {
    String? nextBatch,
  }) async => const ThreadPage([]);
  @override
  Future<List<MessageReader>> messageReaders(
    String roomId,
    String eventId,
  ) async {
    receiptEvent = eventId;
    return [];
  }

  @override
  MessageActionPermissions permissions(String roomId) =>
      const MessageActionPermissions(
        canReact: true,
        canPin: true,
        canRedactOthers: true,
        canSendMessages: true,
      );

  @override
  List<String> pinnedEventIds(String roomId) => const [];

  @override
  Future<void> setPinned(
    String roomId,
    String eventId, {
    required bool pinned,
  }) async {}

  @override
  Future<ChatEntry?> loadEvent(String roomId, String eventId) async => null;

  @override
  Future<List<ReactionSender>> reactionSenders(
    String roomId,
    String eventId,
  ) async => [];

  @override
  Future<String> forwardEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async => r'$forwarded';

  @override
  Future<void> reportContent(
    String roomId,
    String eventId, {
    required String reason,
  }) async {}

  @override
  Future<void> ignoreUser(String userId) async {}

  @override
  Future<void> removeEvent(
    String roomId,
    String eventId, {
    String? reason,
  }) async {}

  @override
  Future<ProviderDiscovery> discoverProvider(String input) async =>
      throw UnimplementedError();
  @override
  Future<void> loginWithBrowser(
    ProviderDiscovery discovery, {
    required bool oidc,
  }) async => throw UnimplementedError();
}

Widget room(
  FeaturesBackend backend,
  Drafts drafts, {
  AppearancePreferences? preferences,
  String id = roomId,
}) => FeatureSettingsScope(
  preferences: preferences ?? AppearancePreferences(),
  draftStore: drafts,
  child: MaterialApp(
    home: RoomScreen(
      backend: backend,
      palette: paletteFor(VisualTheme.parallax),
      roomId: id,
      draftStore: drafts,
      backgroundStore: FakeBackgroundStore(),
    ),
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmojiRecents.instance = EmojiRecents();
    QuickReactionSettings.instance = QuickReactionSettings();
  });

  testWidgets('scoped draft loads, debounces and flushes on route disposal', (
    tester,
  ) async {
    final backend = FeaturesBackend();
    final drafts = Drafts()..values['account-a/$roomId'] = 'Saved draft';
    await tester.pumpWidget(room(backend, drafts));
    await tester.pumpAndSettle();
    expect(find.byType(RichMessageComposer), findsOneWidget);
    expect(find.text('Saved draft'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Changed');
    await tester.pump(const Duration(milliseconds: 500));
    expect(drafts.values['account-a/$roomId'], 'Changed');
    await tester.enterText(find.byType(TextField).last, 'Flushed');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(drafts.values['account-a/$roomId'], 'Flushed');
  });

  testWidgets('room and account replacements load only their own drafts', (
    tester,
  ) async {
    final backend = FeaturesBackend();
    final drafts = Drafts()
      ..values['account-a/$roomId'] = 'Room one'
      ..values['account-a/!other:s'] = 'Room two'
      ..values['account-b/!other:s'] = 'Account B';
    await tester.pumpWidget(room(backend, drafts));
    await tester.pumpAndSettle();
    expect(find.text('Room one'), findsOneWidget);
    await tester.pumpWidget(room(backend, drafts, id: '!other:s'));
    await tester.pumpAndSettle();
    expect(find.text('Room two'), findsOneWidget);
    expect(find.text('Room one'), findsNothing);
    backend.account = 'account-b';
    backend.notifyListeners();
    await tester.pumpWidget(room(backend, drafts, id: '!other:s'));
    await tester.pumpAndSettle();
    expect(find.text('Account B'), findsOneWidget);
    expect(find.text('Room two'), findsNothing);
  });

  testWidgets(
    'send joins pending draft hydration and clears after closed route',
    (tester) async {
      final backend = FeaturesBackend();
      final drafts = Drafts()..readGate = Completer<String>();
      await tester.pumpWidget(room(backend, drafts));
      await tester.pump();
      await tester.enterText(
        find.byType(TextField).last,
        'Accepted while loading',
      );
      final send = tester
          .widget<RichMessageComposer>(find.byType(RichMessageComposer))
          .onSend('Accepted while loading', null);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(backend.queuedText, isNull);
      drafts.readGate!.complete('Earlier persisted draft');
      await send;
      expect(backend.queuedText, 'Accepted while loading');
      expect(drafts.values['account-a/$roomId'], '');
    },
  );

  testWidgets('late draft read never overwrites new typing', (tester) async {
    final drafts = Drafts()..readGate = Completer<String>();
    await tester.pumpWidget(room(FeaturesBackend(), drafts));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'New typing');
    drafts.readGate!.complete('Old storage');
    await tester.pumpAndSettle();
    expect(find.text('New typing'), findsOneWidget);
    expect(find.text('Old storage'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('failed draft read cannot overwrite unread secure storage', (
    tester,
  ) async {
    final drafts = Drafts()..failRead = true;
    await tester.pumpWidget(room(FeaturesBackend(), drafts));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Do not overwrite');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(drafts.writes, isEmpty);
  });

  testWidgets('queue acceptance clears the draft even after route close', (
    tester,
  ) async {
    final backend = FeaturesBackend()..queueGate = Completer<void>();
    final drafts = Drafts();
    await tester.pumpWidget(room(backend, drafts));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Queue this');
    final composer = tester.widget<RichMessageComposer>(
      find.byType(RichMessageComposer),
    );
    final send = composer.onSend('Queue this', null);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    backend.queueGate!.complete();
    await send;
    expect(drafts.values['account-a/$roomId'], '');
    expect(backend.queuedText, 'Queue this');
    expect(backend.lastMessage, isNull);
  });

  testWidgets(
    'right swipe replies immediately without dismissing the message',
    (tester) async {
      final backend = FeaturesBackend()
        ..entries = [
          ChatEntry(
            id: r'$swipe-reply-target',
            sender: '@alice:s',
            senderName: 'Alice',
            body: 'Swipe reply target',
            time: DateTime(2026),
            mine: false,
          ),
        ];
      await tester.pumpWidget(room(backend, Drafts()));
      await tester.pumpAndSettle();

      await tester.drag(find.text('Swipe reply target'), const Offset(400, 0));
      await tester.pumpAndSettle();

      expect(
        find.text('Replying to Alice: Swipe reply target'),
        findsOneWidget,
      );
      expect(find.text('Swipe reply target'), findsOneWidget);
      expect(find.text('Forward'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byType(TextField).last)
            .focusNode
            ?.hasFocus,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('left swipe replies to your own message without dismissing it', (
    tester,
  ) async {
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: r'$own-swipe-reply-target',
          sender: '@me:s',
          senderName: 'Me',
          body: 'Own swipe reply target',
          time: DateTime(2026),
          mine: true,
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts()));
    await tester.pumpAndSettle();

    await tester.drag(
      find.text('Own swipe reply target'),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text('Replying to Me: Own swipe reply target'), findsOneWidget);
    expect(find.text('Own swipe reply target'), findsOneWidget);
    // The gallery action lives in the composer's + menu, not above the field.
    expect(find.text('Send a photo gallery'), findsNothing);
    final replyBar = tester.getRect(
      find.byKey(const ValueKey('composer-context-bar')),
    );
    final field = tester.getRect(find.byType(TextField).last);
    expect(field.top, closeTo(replyBar.bottom, 0.01));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('gallery swipe replies to the specific photo', (tester) async {
    final backend = FeaturesBackend();
    String? replied;
    final entries = [
      for (final id in [r'$gallery-one', r'$gallery-two'])
        ChatEntry(
          id: id,
          sender: '@alice:s',
          body: '',
          time: DateTime(2026),
          mine: false,
          isImage: true,
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GalleryBubble(
            entries: entries,
            backend: backend,
            roomId: roomId,
            palette: paletteFor(VisualTheme.parallax),
            onHeart: (_) {},
            onAction: (_) {},
            onReaction: (_, _) {},
            onReply: (entry) => replied = entry.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byWidgetPredicate(
        (widget) =>
            widget is Dismissible &&
            widget.key == const ValueKey('swipe-photo-\$gallery-two'),
      ),
      const Offset(240, 0),
    );
    await tester.pumpAndSettle();
    expect(replied, r'$gallery-two');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('bubble bottom padding accepts long press and double tap', (
    tester,
  ) async {
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: r'$padded-gesture-target',
          sender: '@alice:s',
          body: 'Padded gesture target',
          time: DateTime(2026),
          mine: false,
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts()));
    await tester.pumpAndSettle();
    final bubble = tester.getRect(find.byType(MessageBubble));
    final point = Offset(bubble.center.dx, bubble.bottom - 3);

    await tester.longPressAt(point);
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    Navigator.pop(tester.element(find.text('Reply')));
    await tester.pumpAndSettle();

    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(backend.lastReaction, '❤️');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'queued send captures reply and preserves a newer composer context',
    (tester) async {
      final backend = FeaturesBackend()
        ..queueGate = Completer<void>()
        ..entries = [
          ChatEntry(
            id: 'original',
            sender: '@friend:s',
            body: 'Original',
            time: DateTime(2026),
            mine: false,
          ),
        ];
      final drafts = Drafts();
      await tester.pumpWidget(room(backend, drafts));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Original'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byType(TextField).last)
            .focusNode
            ?.hasFocus,
        isTrue,
      );
      await tester.enterText(find.byType(TextField).last, 'Reply body');
      final send = tester
          .widget<RichMessageComposer>(find.byType(RichMessageComposer))
          .onSend('Reply body', null);
      await tester.pump();
      await tester.tap(find.byTooltip('Cancel reply or edit'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'New message');
      backend.queueGate!.complete();
      await send;
      await tester.pump();
      expect(backend.queuedReply, 'original');
      expect(find.text('New message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('edits never replace the normal draft', (tester) async {
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: 'mine',
          sender: '@me:s',
          body: 'Old text',
          time: DateTime(2026),
          mine: true,
        ),
      ];
    final drafts = Drafts()..values['account-a/$roomId'] = 'Normal draft';
    await tester.pumpWidget(room(backend, drafts));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Old text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit message'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Edited text');
    await tester.pump(const Duration(seconds: 1));
    expect(drafts.values['account-a/$roomId'], 'Normal draft');
    await tester.tap(find.byTooltip('Cancel reply or edit'));
    await tester.pump();
    expect(find.text('Normal draft'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('session replacement rejects late draft and send completion', (
    tester,
  ) async {
    final backend = FeaturesBackend()..queueGate = Completer<void>();
    final drafts = Drafts();
    await tester.pumpWidget(room(backend, drafts));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Account A');
    final send = tester
        .widget<RichMessageComposer>(find.byType(RichMessageComposer))
        .onSend('Account A', null);
    await tester.pump();
    backend.account = 'account-b';
    backend.notifyListeners();
    backend.queueGate!.complete();
    await send;
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(drafts.values['account-b/$roomId'], isNull);
    expect(drafts.writes, isNot(contains('')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending controls forward the exact transaction ID', (
    tester,
  ) async {
    final backend = FeaturesBackend()
      ..outbox = [
        PendingSend(
          id: 'tx-stable',
          roomId: roomId,
          body: 'Failed body',
          state: DeliveryState.failed,
          createdAt: DateTime(2026),
          error: 'Offline',
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(backend.retried, 'tx-stable');
    await tester.tap(find.text('Discard'));
    await tester.pump();
    expect(backend.discarded, 'tx-stable');
    backend.outbox = [
      PendingSend(
        id: 'tx-upload',
        roomId: roomId,
        body: '',
        fileName: 'clip.mp4',
        state: DeliveryState.sending,
        createdAt: DateTime(2026),
        progress: .25,
      ),
    ];
    backend.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    expect(backend.cancelled, 'tx-upload');
  });

  testWidgets(
    'successful rich send clears UI and stored draft, not network retry',
    (tester) async {
      final backend = FeaturesBackend();
      final drafts = Drafts();
      await tester.pumpWidget(room(backend, drafts));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Accepted text');
      await tester.pump();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(backend.queuedText, 'Accepted text');
      expect(
        tester
            .widget<RichMessageComposer>(find.byType(RichMessageComposer))
            .controller
            .text,
        '',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(drafts.values['account-a/$roomId'], '');
      await tester.pumpWidget(room(backend, drafts));
      await tester.pumpAndSettle();
      expect(find.text('Accepted text'), findsNothing);
    },
  );

  testWidgets(
    'queued media captures caption and reply without legacy sending',
    (tester) async {
      final backend = FeaturesBackend()
        ..entries = [
          ChatEntry(
            id: 'reply-target',
            sender: '@a:s',
            body: 'Reply here',
            time: DateTime(2026),
            mine: false,
          ),
        ];
      await tester.pumpWidget(room(backend, Drafts()));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Reply here'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Photo caption');
      final selection = MediaSelection(
        bytes: Uint8List.fromList([1, 2, 3]),
        name: 'photo.jpg',
        mimeType: 'image/jpeg',
      );
      tester
          .widget<TextField>(find.byType(TextField).last)
          .contentInsertionConfiguration!
          .onContentInserted(
            KeyboardInsertedContent(
              mimeType: selection.mimeType,
              uri: 'content://keyboard/image',
              data: selection.bytes,
            ),
          );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(backend.queuedMedia!.bytes, selection.bytes);
      expect(backend.queuedReply, 'reply-target');
      expect(backend.queuedText, 'Photo caption');
      expect(backend.lastMessage, isNull);
      expect(find.textContaining('Replying to'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'background flush and edit cancellation preserve ordinary draft',
    (tester) async {
      final drafts = Drafts();
      await tester.pumpWidget(room(FeaturesBackend(), drafts));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Background draft');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(drafts.values['account-a/$roomId'], 'Background draft');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'favourites stay behind invites and a failed favourite lookup hides no room',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = FeaturesBackend()
        ..roomList = [
          const ChatRoom(
            id: '!first:s',
            name: 'First',
            preview: '',
            lastActivity: null,
          ),
          const ChatRoom(
            id: '!broken:s',
            name: 'Broken projection',
            preview: '',
            lastActivity: null,
          ),
          const ChatRoom(
            id: '!fav:s',
            name: 'Favourite',
            preview: '',
            lastActivity: null,
          ),
          const ChatRoom(
            id: '!invite:s',
            name: 'Invitation',
            preview: '',
            lastActivity: null,
            invited: true,
          ),
        ]
        ..favouriteFailure = '!broken:s';
      backend.favourites.add('!fav:s');
      await tester.pumpWidget(
        MaterialApp(
          home: InboxScreen(
            backend: backend,
            palette: paletteFor(VisualTheme.parallax),
            style: VisualTheme.parallax,
            onThemeChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Invitation')).dy,
        lessThan(tester.getTopLeft(find.text('Favourite')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Favourite')).dy,
        lessThan(tester.getTopLeft(find.text('First')).dy),
      );
      expect(find.text('Broken projection'), findsOneWidget);
      await tester.longPress(find.text('First'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add favourite'));
      await tester.pumpAndSettle();
      expect(backend.favourites, contains('!first:s'));
    },
  );

  testWidgets('failed send rooms remain reachable in unread filter', (
    tester,
  ) async {
    final backend = FeaturesBackend()
      ..roomList = [
        const ChatRoom(
          id: roomId,
          name: 'Failed room',
          preview: '',
          lastActivity: null,
        ),
        const ChatRoom(
          id: '!quiet:s',
          name: 'Quiet room',
          preview: '',
          lastActivity: null,
        ),
      ]
      ..outbox = [
        PendingSend(
          id: 'same-tx',
          roomId: roomId,
          body: 'Unsent',
          state: DeliveryState.failed,
          createdAt: DateTime(2026),
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await openHomeOptions(tester);
    await tester.tap(find.text('Unread'));
    await tester.pump();
    expect(find.text('Failed room'), findsOneWidget);
    expect(find.text('Quiet room'), findsNothing);
    expect(find.byTooltip('Message not sent'), findsOneWidget);
  });

  testWidgets(
    'directory selection creates a DM and Spaces returns a room route',
    (tester) async {
      // Phone window: the flow asserts a pushed room route.
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = FeaturesBackend();
      await tester.pumpWidget(
        FeatureSettingsScope(
          preferences: AppearancePreferences(),
          draftStore: Drafts(),
          child: MaterialApp(
            home: InboxScreen(
              backend: backend,
              palette: paletteFor(VisualTheme.parallax),
              style: VisualTheme.parallax,
              onThemeChanged: (_) {},
            ),
          ),
        ),
      );
      await openHomeOptions(tester);
      await tester.tap(find.text('Find people'));
      await tester.pumpAndSettle();
      expect(find.byType(UserDirectoryScreen), findsOneWidget);
      Navigator.pop(
        tester.element(find.byType(UserDirectoryScreen)),
        '@selected:example.org',
      );
      await tester.pumpAndSettle();
      expect(backend.directUser, '@selected:example.org');
      expect(tester.widget<RoomScreen>(find.byType(RoomScreen)).roomId, roomId);
      await tester.tap(find.byTooltip('Back to rooms'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spaces'));
      await tester.pumpAndSettle();
      expect(find.byType(SpaceBrowserScreen), findsOneWidget);
      Navigator.pop(
        tester.element(find.byType(SpaceBrowserScreen)),
        '!space-room:s',
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<RoomScreen>(find.byType(RoomScreen)).roomId,
        '!space-room:s',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('message actions stay compact until More expands them', (
    tester,
  ) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
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
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: r'$compact-actions-event',
          sender: '@a:s',
          body: 'Compact actions',
          time: DateTime(2026),
          mine: false,
          content: const {'msgtype': 'm.text', 'body': 'Compact actions'},
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Compact actions'));
    await tester.pumpAndSettle();

    expect(find.text('Reply'), findsOneWidget);
    expect(find.byTooltip('React ❤️'), findsOneWidget);
    expect(find.text('Forward'), findsOneWidget);
    expect(find.text('Copy text'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);
    for (final hidden in [
      'Edit message',
      'Open thread',
      'Read receipts',
      'Copy link to message',
      'View source',
    ]) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
    final replyY = tester.getTopLeft(find.text('Reply')).dy;
    final reactionsY = tester.getTopLeft(find.byTooltip('React ❤️')).dy;
    final forwardY = tester.getTopLeft(find.text('Forward')).dy;
    final copyY = tester.getTopLeft(find.text('Copy text')).dy;
    final moreY = tester.getTopLeft(find.text('More')).dy;
    expect(reactionsY, lessThan(replyY));
    expect(replyY, lessThan(forwardY));
    expect(forwardY, lessThan(copyY));
    expect(copyY, lessThan(moreY));

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('More'), findsNothing);
    expect(find.text('Open thread'), findsOneWidget);
    expect(find.text('Read receipts'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Less'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Less'));
    await tester.pumpAndSettle();
    expect(find.text('More'), findsOneWidget);
    expect(find.text('Open thread'), findsNothing);
    expect(find.text('Read receipts'), findsNothing);

    await tester.tap(find.text('Copy text'));
    await tester.pumpAndSettle();
    expect(clipboard, ['Compact actions']);
  });

  testWidgets('a code copy action stays above More and copies the code', (
    tester,
  ) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
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
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: r'$code-event',
          sender: '@a:s',
          body: 'Your login code is 123456',
          time: DateTime(2026),
          mine: false,
          content: const {
            'msgtype': 'm.text',
            'body': 'Your login code is 123456',
          },
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Your login code is 123456'));
    await tester.pumpAndSettle();
    expect(find.text('Copy code'), findsNothing);
    expect(find.text('Copy text'), findsOneWidget);
    expect(find.text('Copy link to message'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await tester.tapAt(copySpanCenter(tester, '123456'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.text('Copy')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('Call')),
      findsNothing,
    );
    await tester.tap(find.descendant(of: dialog, matching: find.text('Copy')));
    await tester.pumpAndSettle();
    expect(clipboard, ['123456']);
  });

  testWidgets('own local messages show Forward in compact actions', (
    tester,
  ) async {
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: 'local-own-message',
          sender: '@me:s',
          body: 'Forward my message',
          time: DateTime(2026),
          mine: true,
          content: const {'msgtype': 'm.text', 'body': 'Forward my message'},
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Forward my message'));
    await tester.pumpAndSettle();
    expect(find.text('Forward'), findsOneWidget);
    await tester.tap(find.text('Forward'));
    await tester.pumpAndSettle();
    expect(find.text('Forward message'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'own editable messages keep Edit message and Copy text above More on a phone',
    (tester) async {
      tester.view
        ..physicalSize = const Size(360, 640)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FeaturesBackend()
        ..entries = [
          ChatEntry(
            id: r'$own-editable',
            sender: '@me:s',
            body: 'Editable text',
            time: DateTime(2026),
            mine: true,
            content: const {'msgtype': 'm.text', 'body': 'Editable text'},
          ),
          ChatEntry(
            id: r'$own-image',
            sender: '@me:s',
            body: 'photo.jpg',
            isImage: true,
            kind: EntryKind.image,
            time: DateTime(2026, 1, 1, 0, 1),
            mine: true,
            content: const {
              'msgtype': 'm.image',
              'body': 'photo.jpg',
              'url': 'mxc://s/pic',
            },
          ),
        ];
      await tester.pumpWidget(room(backend, Drafts()));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Editable text'));
      await tester.pumpAndSettle();

      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Forward'), findsOneWidget);
      expect(find.text('Edit message'), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
      expect(find.text('Delete message'), findsNothing);

      final forwardY = tester.getTopLeft(find.text('Forward')).dy;
      final editY = tester.getTopLeft(find.text('Edit message')).dy;
      final copyY = tester.getTopLeft(find.text('Copy text')).dy;
      final moreY = tester.getTopLeft(find.text('More')).dy;
      expect(forwardY, lessThan(editY));
      expect(editY, lessThan(copyY));
      expect(copyY, lessThan(moreY));

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('View source'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Edit message').hitTestable(), findsOneWidget);
      expect(find.text('Delete message'), findsOneWidget);

      Navigator.pop(tester.element(find.text('Edit message')));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MessageImage));
      await tester.pumpAndSettle();
      expect(find.text('Forward'), findsOneWidget);
      expect(find.text('Edit message'), findsNothing);
      expect(find.text('More'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'recent mode: + picker reaction leads a persisted six-emoji recent row',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        EmojiRecents.storageKey: '["❤️","👍","😂","🎉","😮","🙏"]',
        QuickReactionSettings.modeKey: 'recent',
      });
      EmojiRecents.instance = EmojiRecents();
      final backend = FeaturesBackend()
        ..entries = [
          ChatEntry(
            id: r'$recent-reactions-event',
            sender: '@a:s',
            body: 'Recent reactions',
            time: DateTime(2026),
            mine: false,
            content: const {'msgtype': 'm.text', 'body': 'Recent reactions'},
          ),
        ];
      await tester.pumpWidget(room(backend, Drafts()));
      await tester.pumpAndSettle();

      Future<void> openActions() async {
        await tester.longPress(find.text('Recent reactions'));
        await tester.pumpAndSettle();
      }

      void expectRowOrder(List<String> emojis) {
        for (var i = 0; i < emojis.length; i++) {
          expect(
            find.byTooltip('React ${emojis[i]}'),
            findsOneWidget,
            reason: emojis[i],
          );
          if (i > 0) {
            expect(
              tester.getTopLeft(find.byTooltip('React ${emojis[i - 1]}')).dx,
              lessThan(
                tester.getTopLeft(find.byTooltip('React ${emojis[i]}')).dx,
              ),
            );
          }
        }
      }

      await openActions();
      expectRowOrder(const ['❤️', '👍', '😂', '🎉', '😮', '🙏']);
      expect(find.byTooltip('React 😀'), findsNothing);

      await tester.tap(find.byTooltip('More reactions'));
      await tester.pumpAndSettle();
      final grinning = find.text('😀');
      expect(grinning, findsWidgets);
      await tester.tap(grinning.first);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );

      // Force a disk read rather than relying on the previous store's cache.
      EmojiRecents.instance = EmojiRecents();
      await openActions();
      expectRowOrder(const ['😀', '❤️', '👍', '😂', '🎉', '😮']);
      expect(find.byTooltip('React 🙏'), findsNothing);

      // A quick-row selection is also a use and moves to the front next time.
      await tester.tap(find.byTooltip('React 👍'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      EmojiRecents.instance = EmojiRecents();
      await openActions();
      expectRowOrder(const ['👍', '😀', '❤️', '😂', '🎉', '😮']);
    },
  );

  testWidgets('default most-used mode orders the quick row by reaction count', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      EmojiRecents.usageKey: '{"😂": 3, "❤️": 2, "👍": 1}',
    });
    EmojiRecents.instance = EmojiRecents();
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: r'$most-used-event',
          sender: '@a:s',
          body: 'Most used',
          time: DateTime(2026),
          mine: false,
          content: const {'msgtype': 'm.text', 'body': 'Most used'},
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts()));
    await tester.pumpAndSettle();

    Future<void> openActions() async {
      await tester.longPress(find.text('Most used'));
      await tester.pumpAndSettle();
    }

    void expectRowOrder(List<String> emojis) {
      for (var i = 0; i < emojis.length; i++) {
        expect(
          find.byTooltip('React ${emojis[i]}'),
          findsOneWidget,
          reason: emojis[i],
        );
        if (i > 0) {
          expect(
            tester.getTopLeft(find.byTooltip('React ${emojis[i - 1]}')).dx,
            lessThan(
              tester.getTopLeft(find.byTooltip('React ${emojis[i]}')).dx,
            ),
          );
        }
      }
    }

    // Most used first (distinct counts), topped up with defaults.
    await openActions();
    expectRowOrder(const ['😂', '❤️', '👍', '😮', '😢', '🎉']);

    // A quick-row reaction counts towards the tally.
    await tester.tap(find.byTooltip('React 👍'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    final usage = await EmojiRecents.instance.loadUsage();
    expect(usage['👍'], 2);
    expect(usage['😂'], 3);
  });

  testWidgets('manual mode shows exactly the chosen quick reactions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      QuickReactionSettings.modeKey: 'manual',
      QuickReactionSettings.manualKey: '["🚀", "🎉", "❤️"]',
    });
    EmojiRecents.instance = EmojiRecents();
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: r'$manual-event',
          sender: '@a:s',
          body: 'Manual row',
          time: DateTime(2026),
          mine: false,
          content: const {'msgtype': 'm.text', 'body': 'Manual row'},
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Manual row'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('React 🚀'), findsOneWidget);
    expect(find.byTooltip('React 🎉'), findsOneWidget);
    expect(find.byTooltip('React ❤️'), findsOneWidget);
    // The manual list is used as-is: no default top-up.
    expect(find.byTooltip('React 👍'), findsNothing);
    expect(
      tester.getTopLeft(find.byTooltip('React 🚀')).dx,
      lessThan(tester.getTopLeft(find.byTooltip('React 🎉')).dx),
    );
  });

  testWidgets('thread and receipt actions keep the selected event identity', (
    tester,
  ) async {
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: 'selected-event',
          sender: '@a:s',
          body: 'Thread root',
          time: DateTime(2026),
          mine: false,
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Thread root'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Open thread'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Open thread'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ThreadScreen>(find.byType(ThreadScreen)).root.id,
      'selected-event',
    );
    Navigator.pop(tester.element(find.byType(ThreadScreen)));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Thread root'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Read receipts'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Read receipts'));
    await tester.pumpAndSettle();
    expect(backend.receiptEvent, 'selected-event');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'preview preference prevents thumbnail fetch and image tap opens original',
    (tester) async {
      final preferences = AppearancePreferences();
      await preferences.setAutoLoadMedia(false);
      final backend = FeaturesBackend()
        ..currentUserId = '@me:s'
        ..entries = [
          ChatEntry(
            id: 'image-event',
            sender: '@a:s',
            body: 'photo.jpg',
            time: DateTime(2026),
            mine: false,
            isImage: true,
          ),
        ];
      await tester.pumpWidget(
        room(backend, Drafts(), preferences: preferences),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MessageImage), findsOneWidget);
      expect(backend.imageLoads, 0);
      await tester.tap(find.text('Tap to open image'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MediaViewer>(find.byType(MediaViewer)).eventId,
        'image-event',
      );
      Navigator.pop(tester.element(find.byType(MediaViewer)));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Tap to open image'));
      await tester.pumpAndSettle();
      expect(find.text('Reply'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'shared appearance preferences affect app text scale and settings route',
    (tester) async {
      final preferences = AppearancePreferences();
      await preferences.setTextScale(1.3);
      final backend = FeaturesBackend();
      await tester.pumpWidget(
        ParallaxApp(
          backend: backend,
          preferences: preferences,
          draftStore: Drafts(),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(InboxScreen)),
        ).scale(20),
        closeTo(20 * preferences.textScale, 0.001),
      );
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      // The settings list is built lazily; scroll the tile into existence.
      final appearance = find.byKey(const ValueKey('settings.appearance'));
      await tester.scrollUntilVisible(
        appearance,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(appearance);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppearanceSettingsScreen>(
              find.byType(AppearanceSettingsScreen),
            )
            .preferences,
        same(preferences),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('compact preference changes the actual message layout', (
    tester,
  ) async {
    final preferences = AppearancePreferences();
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: 'compact-event',
          sender: '@a:s',
          body: 'Compact message',
          time: DateTime(2026),
          mine: false,
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts(), preferences: preferences));
    await tester.pumpAndSettle();
    final normalHeight = tester
        .getSize(find.byKey(const ValueKey('compact-event')))
        .height;
    await preferences.setCompact(true);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('compact-event'))).height,
      lessThan(normalHeight),
    );
  });

  testWidgets('rejected queue acknowledgement keeps the rich draft for retry', (
    tester,
  ) async {
    final backend = FeaturesBackend()..queueGate = Completer<void>();
    final drafts = Drafts();
    await tester.pumpWidget(room(backend, drafts));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Keep queued draft');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    backend.queueGate!.completeError(StateError('storage unavailable'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<RichMessageComposer>(find.byType(RichMessageComposer))
          .controller
          .text,
      'Keep queued draft',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(drafts.values['account-a/$roomId'], 'Keep queued draft');
  });

  testWidgets('queued edit preserves the normal draft and original edit ID', (
    tester,
  ) async {
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: 'edit-id',
          sender: '@me:s',
          body: 'Edit original',
          time: DateTime(2026),
          mine: true,
        ),
      ];
    final drafts = Drafts()..values['account-a/$roomId'] = 'Keep normal draft';
    await tester.pumpWidget(room(backend, drafts));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Edit original'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit message'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'New edit body');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(backend.queuedEdit, 'edit-id');
    expect(backend.queuedText, 'New edit body');
    expect(
      tester
          .widget<RichMessageComposer>(find.byType(RichMessageComposer))
          .controller
          .text,
      'Keep normal draft',
    );
    expect(drafts.values['account-a/$roomId'], 'Keep normal draft');
  });

  for (final logout in [true, false]) {
    testWidgets(
      '${logout ? 'hard logout' : 'account replacement'} removes all decrypted routes',
      (tester) async {
        final backend = FeaturesBackend()
          ..roomList = [
            const ChatRoom(
              id: roomId,
              name: 'Private room',
              preview: '',
              lastActivity: null,
            ),
          ];
        await tester.pumpWidget(
          ParallaxApp(
            backend: backend,
            preferences: AppearancePreferences(),
            draftStore: Drafts(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Private room'));
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(RoomScreen));
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Decrypted attachment')),
          ),
        );
        await tester.pumpAndSettle();
        if (logout) {
          backend.status = SessionStatus.signedOut;
        } else {
          backend.account = 'account-b';
        }
        backend.notifyListeners();
        await tester.pumpAndSettle();
        expect(
          find.text('Decrypted attachment', skipOffstage: false),
          findsNothing,
        );
        expect(find.byType(RoomScreen, skipOffstage: false), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'multiple messages queue in one room while earlier ones are pending',
    (tester) async {
      final backend = FeaturesBackend();
      final queued = <String>[];
      backend.onQueue = (text) => queued.add(text);
      final drafts = Drafts();
      await tester.pumpWidget(room(backend, drafts));
      await tester.pumpAndSettle();

      // First message accepted into the outbox.
      await tester.enterText(find.byType(TextField).last, 'First');
      await tester.pump();
      final send = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Send message',
        ),
      );
      send.onPressed!();
      await tester.pumpAndSettle();
      expect(queued, ['First']);

      // Second message: the composer accepts it while the first is still pending.
      await tester.enterText(find.byType(TextField).last, 'Second');
      await tester.pump();
      send.onPressed!();
      await tester.pumpAndSettle();
      expect(queued, ['First', 'Second']);

      // Third message in the same room.
      await tester.enterText(find.byType(TextField).last, 'Third');
      await tester.pump();
      send.onPressed!();
      await tester.pumpAndSettle();
      expect(queued, ['First', 'Second', 'Third']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('a send in one room does not block the composer in another', (
    tester,
  ) async {
    final backend = FeaturesBackend();
    final drafts = Drafts();
    await tester.pumpWidget(room(backend, drafts));
    await tester.pumpAndSettle();

    // Simulate a direct send in a DIFFERENT room.
    backend.busyRoom = '!other:example.org';
    backend.notifyListeners();
    await tester.pump();

    // The composer in THIS room must still accept a message.
    await tester.enterText(find.byType(TextField).last, 'Not blocked');
    await tester.pump();
    final send = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Send message',
      ),
    );
    send.onPressed!();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(backend.queuedText, 'Not blocked');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the composer’s font goes out with messages and edits', (
    tester,
  ) async {
    final preferences = AppearancePreferences();
    final backend = FeaturesBackend()
      ..entries = [
        ChatEntry(
          id: 'edit-id',
          sender: '@me:s',
          body: 'Edit original',
          time: DateTime(2026),
          mine: true,
        ),
      ];
    await tester.pumpWidget(room(backend, Drafts(), preferences: preferences));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Message font'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('message-font-pacifico')));
    await tester.pumpAndSettle();
    expect(preferences.messageFont, 'pacifico');
    expect(
      tester.widget<TextField>(find.byType(TextField).last).style?.fontFamily,
      'Pacifico',
    );

    await tester.enterText(find.byType(TextField).last, 'In Pacifico');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(backend.queuedText, 'In Pacifico');
    expect(backend.queuedFont, 'pacifico');

    // Edits take the font chosen now.
    await tester.longPress(find.text('Edit original'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit message'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Edited');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(backend.queuedEdit, 'edit-id');
    expect(backend.queuedFont, 'pacifico');

    // Back to the default font: no font is sent.
    await tester.tap(find.byTooltip('Message font'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('message-font-default')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Plain again');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(backend.queuedText, 'Plain again');
    expect(backend.queuedFont, isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

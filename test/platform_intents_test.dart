import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/platform/matrix_link_opener.dart';
import 'package:parallax/features/platform/platform_intents.dart';
import 'package:parallax/features/platform/platform_intents_host.dart';
import 'package:parallax/features/platform/share_screen.dart';
import 'package:parallax/features/platform/unified_push.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/push_notifications.dart';

import 'platform_fakes.dart';

Map<String, Object?> _file(
  String name, {
  String path = '/data/user/0/app/cache/shared_intents/1/',
  Object? size = 10,
  Object? mime = 'image/png',
}) => {'path': '$path$name', 'name': name, 'mimeType': mime, 'size': size};

void main() {
  final palette = paletteFor(VisualTheme.parallax);

  group('parsePlatformIntent', () {
    test('accepts a share with text and cached files', () {
      final intent =
          parsePlatformIntent({
                'kind': 'share',
                'text': '  Look at this  ',
                'files': [
                  _file('a.png'),
                  _file('b.pdf', mime: 'application/pdf'),
                ],
                'skipped': 1,
                'tooLarge': 2,
              })
              as ShareIntent;
      expect(intent.text, 'Look at this');
      expect(intent.files.map((f) => f.name), ['a.png', 'b.pdf']);
      expect(intent.files.last.mimeType, 'application/pdf');
      expect(intent.skipped, 1);
      expect(intent.tooLarge, 2);
    });

    test('falls back to the subject when there is no text', () {
      final intent =
          parsePlatformIntent({'kind': 'share', 'subject': 'Title'})
              as ShareIntent;
      expect(intent.text, 'Title');
    });

    test('refuses files outside the share cache or with bad sizes', () {
      final intent =
          parsePlatformIntent({
                'kind': 'share',
                'files': [
                  _file('ok.png'),
                  _file('db', path: '/data/user/0/app/databases/'),
                  _file('x', path: '/data/cache/shared_intents/../../'),
                  _file('rel.png', path: 'cache/shared_intents/1/'),
                  _file('big.png', size: maxSharedFileBytes + 1),
                  _file('zero.png', size: 0),
                  _file('str.png', size: '10'),
                  'not a map',
                ],
              })
              as ShareIntent;
      expect(intent.files.map((f) => f.name), ['ok.png']);
      expect(intent.skipped, 7);
    });

    test('keeps at most ten files', () {
      final intent =
          parsePlatformIntent({
                'kind': 'share',
                'files': [for (var i = 0; i < 13; i++) _file('$i.png')],
              })
              as ShareIntent;
      expect(intent.files, hasLength(maxSharedFiles));
      expect(intent.skipped, 3);
    });

    test('sanitises names, MIME types and over-long text', () {
      final intent =
          parsePlatformIntent({
                'kind': 'share',
                'text': 'x' * (maxSharedTextLength + 50),
                'files': [
                  {
                    ..._file('a.png', mime: 'IMAGE/PNG; q=1'),
                    'name': 'a/../evil\u0000name.png',
                  },
                  _file('b.bin', mime: 'not a mime'),
                ],
              })
              as ShareIntent;
      expect(intent.text, hasLength(maxSharedTextLength));
      expect(intent.files.first.name, 'evilname.png');
      expect(intent.files.first.mimeType, 'image/png');
      expect(intent.files.last.mimeType, 'application/octet-stream');
      expect(sanitiseSharedName('..'), 'shared-file');
      expect(sanitiseSharedName(null), 'shared-file');
    });

    test('accepts Matrix VIEW links only', () {
      final link =
          parsePlatformIntent({
                'kind': 'link',
                'uri': 'https://matrix.to/#/#room:example.org',
              })
              as LinkIntent;
      expect(link.uri.host, 'matrix.to');
      expect(
        parsePlatformIntent({'kind': 'link', 'uri': 'matrix:u/a:b.org'}),
        isA<LinkIntent>(),
      );
      expect(
        parsePlatformIntent({'kind': 'link', 'uri': 'https://evil.example/'}),
        isNull,
      );
      expect(
        parsePlatformIntent({'kind': 'link', 'uri': 'javascript:alert(1)'}),
        isNull,
      );
    });

    test('rejects malformed payloads', () {
      expect(parsePlatformIntent(null), isNull);
      expect(parsePlatformIntent('share'), isNull);
      expect(parsePlatformIntent({'kind': 'other'}), isNull);
      expect(parsePlatformIntent({'kind': 'share'}), isNull);
      expect(parsePlatformIntent({'kind': 'link', 'uri': 7}), isNull);
    });
  });

  group('sendSharedContent', () {
    Future<Uint8List> read(SharedFile file) async =>
        Uint8List.fromList([1, 2, 3]);

    test('a single file carries the text as its caption', () async {
      final backend = PlatformBackend();
      final result = await sendSharedContent(
        backend,
        '!room:example.org',
        ShareIntent(text: 'Caption', files: [sharedFile('a.jpg')]),
        isCurrent: () => true,
        read: read,
      );
      expect(result.sent, 1);
      expect(result.textSent, isTrue);
      final (roomId, media, caption) = backend.queuedMedia.single;
      expect(roomId, '!room:example.org');
      expect(media.name, 'a.jpg');
      expect(media.mimeType, 'image/jpeg');
      expect(caption, 'Caption');
      expect(backend.queuedText, isEmpty);
    });

    test('several files are followed by the text message', () async {
      final backend = PlatformBackend();
      final result = await sendSharedContent(
        backend,
        '!room:example.org',
        ShareIntent(
          text: 'Holiday',
          files: [sharedFile('a.jpg'), sharedFile('b.jpg')],
        ),
        isCurrent: () => true,
        read: read,
      );
      expect(result.complete, isTrue);
      expect(backend.queuedMedia.map((m) => m.$3), [null, null]);
      expect(backend.queuedText.single.$2, 'Holiday');
    });

    test('a failed item is counted without dropping the rest', () async {
      final backend = PlatformBackend()..failMediaAfter = 1;
      final result = await sendSharedContent(
        backend,
        '!room:example.org',
        ShareIntent(files: [sharedFile('a.jpg'), sharedFile('b.jpg')]),
        isCurrent: () => true,
        read: read,
      );
      expect(result.sent, 1);
      expect(result.failed, 1);
    });

    test('an account change stops sending', () async {
      final backend = PlatformBackend();
      var current = true;
      await expectLater(
        sendSharedContent(
          backend,
          '!room:example.org',
          ShareIntent(
            text: 'Hi',
            files: [sharedFile('a.jpg'), sharedFile('b.jpg')],
          ),
          isCurrent: () => current,
          read: (file) async {
            current = false;
            return Uint8List.fromList([1]);
          },
        ),
        throwsA(isA<ShareSessionChanged>()),
      );
      expect(backend.queuedMedia, isEmpty);
      expect(backend.queuedText, isEmpty);
    });

    test('text-only shares use the outbox', () async {
      final backend = PlatformBackend();
      await sendSharedContent(
        backend,
        '!room:example.org',
        const ShareIntent(text: 'https://example.org/article'),
        isCurrent: () => true,
      );
      expect(backend.queuedText.single.$2, 'https://example.org/article');
    });
  });

  group('ShareTargetScreen', () {
    testWidgets('lists joined rooms by recent activity and sends on tap', (
      tester,
    ) async {
      final backend = PlatformBackend()
        ..roomList = [
          room('!old:example.org', 'Old room', minutesAgo: 90),
          room('!new:example.org', 'New room'),
          room('!inv:example.org', 'Invite', invited: true),
        ];
      String? popped;
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    popped = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                        builder: (_) => ShareTargetScreen(
                          backend: backend,
                          palette: palette,
                          share: ShareIntent(
                            text: 'Hello',
                            files: [sharedFile('a.jpg'), sharedFile('b.jpg')],
                            tooLarge: 1,
                          ),
                          read: (_) async => Uint8List.fromList([1, 2]),
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('2 photos'), findsOneWidget);
      expect(find.textContaining('20 MB or smaller'), findsOneWidget);
      expect(find.text('Invite'), findsNothing);
      final newTop = tester.getTopLeft(find.text('New room')).dy;
      final oldTop = tester.getTopLeft(find.text('Old room')).dy;
      expect(newTop, lessThan(oldTop));

      await tester.enterText(find.byType(TextField), 'old');
      await tester.pump();
      expect(find.text('New room'), findsNothing);
      await tester.tap(find.text('Old room'));
      await tester.pumpAndSettle();
      expect(popped, '!old:example.org');
      expect(backend.queuedMedia, hasLength(2));
      expect(backend.queuedText.single, ('!old:example.org', 'Hello'));
    });
  });

  group('PlatformIntentsHost', () {
    late PlatformBackend backend;
    late FakeIntentSource source;
    late GlobalKey<NavigatorState> navigatorKey;
    late List<String> opened;

    setUp(() {
      backend = PlatformBackend()
        ..roomList = [room('!room:example.org', 'Team room')];
      source = FakeIntentSource();
      navigatorKey = GlobalKey<NavigatorState>();
      opened = [];
      openRoomRoute = (context, backend, palette, roomId) => opened.add(roomId);
    });

    Widget app({PushNotifications? notifications}) => MaterialApp(
      navigatorKey: navigatorKey,
      theme: themeFor(VisualTheme.parallax),
      builder: (context, child) => FeatureSettingsScope(
        preferences: AppearancePreferences(),
        draftStore: MessageDraftStore(),
        notifications: notifications,
        child: PlatformIntentsHost(
          app: AppHookContext(
            backend: backend,
            palette: palette,
            navigatorKey: navigatorKey,
          ),
          source: source,
          readSharedFile: (_) async => Uint8List.fromList([7]),
          child: child!,
        ),
      ),
      home: const Scaffold(body: Text('Inbox')),
    );

    testWidgets('a matrix.to VIEW intent opens the joined room', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      source.controller.add(
        LinkIntent(Uri.parse('https://matrix.to/#/!room:example.org')),
      );
      await tester.pumpAndSettle();
      expect(opened, ['!room:example.org']);
    });

    testWidgets('a share is sent to the picked room and its cache cleared', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      final file = sharedFile('photo.jpg');
      source.controller.add(ShareIntent(text: 'Look', files: [file]));
      await tester.pumpAndSettle();
      expect(find.byType(ShareTargetScreen), findsOneWidget);
      await tester.tap(find.text('Team room'));
      await tester.pumpAndSettle();
      expect(find.byType(ShareTargetScreen), findsNothing);
      expect(backend.queuedMedia.single.$3, 'Look');
      expect(source.discarded, [file.path]);
      expect(opened, ['!room:example.org']);
    });

    testWidgets('cancelling a share discards the copies and opens nothing', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      final file = sharedFile('doc.pdf', mime: 'application/pdf');
      source.controller.add(ShareIntent(files: [file]));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.queuedMedia, isEmpty);
      expect(source.discarded, [file.path]);
      expect(opened, isEmpty);
    });

    testWidgets('intents are handled one at a time, in order', (tester) async {
      await tester.pumpWidget(app());
      final file = sharedFile('a.jpg');
      source.controller
        ..add(ShareIntent(files: [file]))
        ..add(LinkIntent(Uri.parse('matrix:roomid/room:example.org')));
      await tester.pumpAndSettle();
      expect(find.byType(ShareTargetScreen), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(opened, ['!room:example.org']);
    });

    testWidgets('unmounting discards queued shares', (tester) async {
      await tester.pumpWidget(app());
      final first = sharedFile('1.jpg');
      final second = sharedFile('2.jpg');
      source.controller
        ..add(ShareIntent(files: [first]))
        ..add(ShareIntent(files: [second]));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(source.discarded, containsAll([first.path, second.path]));
    });

    testWidgets('a share with nothing readable explains why', (tester) async {
      await tester.pumpWidget(app());
      source.controller.add(const ShareIntent(tooLarge: 2));
      await tester.pumpAndSettle();
      expect(find.byType(ShareTargetScreen), findsNothing);
      expect(
        find.text('Files must be 20 MB or smaller to share.'),
        findsOneWidget,
      );
    });

    testWidgets('notification "Mark as read" marks the verified room read', (
      tester,
    ) async {
      final alerts = _Alerts();
      final api = _Api();
      final store = _Store();
      final push = PushNotifications(
        unifiedPushDriver: UnifiedPushDriver(api: api, alerts: alerts),
        store: store,
        configuration: const PushConfiguration(),
      );
      final registered = <PushRegistration>[];
      await tester.runAsync(() async {
        await push.configure(
          PushConfiguration.unifiedPush(
            gatewayUrl: Uri.parse(
              'https://gw.example.org/_matrix/push/v1/notify',
            ),
          ),
        );
        await push.setSession(
          PushSession(
            userId: '@me:example.org',
            deviceId: 'DEVICE',
            registerPusher: (r) async => registered.add(r),
            removePusher: (_) async {},
            onNavigate: (_) async {},
          ),
        );
        await push.enable(consent: true);
      });
      expect(push.active, isTrue);
      await tester.pumpWidget(app(notifications: push));
      expect(push.markReadHandler, isNotNull);
      alerts.onMarkRead!({
        'registration_id': registered.single.registrationId,
        'room_id': '!room:example.org',
        'event_id': r'$latest',
      });
      await tester.runAsync(push.settle);
      await tester.pumpAndSettle();
      expect(backend.markedRead.single, (
        '!room:example.org',
        r'$latest',
        true,
      ));
      expect(find.text('Marked as read.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      expect(push.markReadHandler, isNull);
      await tester.runAsync(push.shutdown);
    });
  });
}

class _Store implements PushStateStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? value) async => this.value = value;
}

class _Api implements UnifiedPushApi {
  void Function(String, String)? onNewEndpoint;
  @override
  Future<void> initialize({
    required void Function(String endpoint, String instance) onNewEndpoint,
    required void Function(String reason, String instance) onRegistrationFailed,
    required void Function(String instance) onUnregistered,
    required void Function(Uint8List content, String instance) onMessage,
  }) async {
    this.onNewEndpoint = onNewEndpoint;
  }

  @override
  Future<List<String>> distributors() async => ['io.heckel.ntfy'];
  @override
  Future<String?> savedDistributor() async => null;
  @override
  Future<void> saveDistributor(String distributor) async {}
  @override
  Future<void> register(String instance) async => scheduleMicrotask(
    () => onNewEndpoint!('https://ntfy.example.org/upX?up=1', instance),
  );
  @override
  Future<void> unregister(String instance) async {}
}

class _Alerts implements PushAlertSurface {
  void Function(Map<String, dynamic>)? onMarkRead;
  @override
  Future<void> initialize({
    required void Function(Map<String, dynamic>) onOpen,
    required void Function(Map<String, dynamic>) onMarkRead,
  }) async {
    this.onMarkRead = onMarkRead;
  }

  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show(PushEnvelope envelope) async {}
  @override
  Future<void> cancelAll() async {}
}

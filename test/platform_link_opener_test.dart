import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/platform/matrix_link_opener.dart';
import 'package:parallax/features/platform/platform_features.dart';

import 'platform_fakes.dart';

void main() {
  final palette = paletteFor(VisualTheme.parallax);
  late PlatformBackend backend;
  late List<String> opened;
  late BuildContext appContext;

  setUp(() {
    backend = PlatformBackend();
    opened = [];
    openRoomRoute = (context, backend, palette, roomId) => opened.add(roomId);
  });

  Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: themeFor(VisualTheme.parallax),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            appContext = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );

  Future<bool?> open(WidgetTester tester, String link) async {
    bool? result;
    openMatrixLink(
      appContext,
      backend,
      palette,
      Uri.parse(link),
    ).then((value) => result = value);
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('non-Matrix links are left to the caller', (tester) async {
    await pumpApp(tester);
    expect(await open(tester, 'https://example.org/page'), isFalse);
    expect(await open(tester, 'https://matrix.to/#/not-an-id'), isFalse);
    expect(opened, isEmpty);
  });

  testWidgets('a joined room ID opens straight away', (tester) async {
    backend.roomList = [room('!joined:example.org', 'Joined')];
    await pumpApp(tester);
    expect(
      await open(tester, 'https://matrix.to/#/!joined:example.org'),
      isTrue,
    );
    expect(opened, ['!joined:example.org']);
    expect(find.byType(RoomLinkSheet), findsNothing);
  });

  testWidgets('an alias of a joined room resolves and opens', (tester) async {
    backend.aliases['#lounge:example.org'] = '!lounge:example.org';
    backend.joinedIds.add('!lounge:example.org');
    await pumpApp(tester);
    expect(await open(tester, 'matrix:r/lounge:example.org'), isTrue);
    expect(opened, ['!lounge:example.org']);
    expect(backend.joins, isEmpty);
  });

  testWidgets('an unjoined room shows a preview and joins via servers', (
    tester,
  ) async {
    backend.aliases['#lounge:example.org'] = '!lounge:example.org';
    backend.preview = const RoomLinkPreview(
      roomId: '!lounge:example.org',
      name: 'Parallax Lounge',
      topic: 'Talk about everything',
      alias: '#lounge:example.org',
      members: 12,
    );
    await pumpApp(tester);
    final result = open(
      tester,
      'https://matrix.to/#/%23lounge%3Aexample.org?via=a.org',
    );
    await result;
    expect(find.text('Parallax Lounge'), findsOneWidget);
    expect(find.text('12 members'), findsOneWidget);
    expect(find.text('Talk about everything'), findsOneWidget);
    await tester.tap(find.text('Join room'));
    await tester.pumpAndSettle();
    expect(backend.joins.single.$1, '!lounge:example.org');
    expect(backend.joins.single.$2, ['a.org', 'directory.org']);
    expect(opened, ['!lounge:example.org']);
    expect(find.byType(RoomLinkSheet), findsNothing);
  });

  testWidgets('a refused join keeps the sheet open with the reason', (
    tester,
  ) async {
    backend.joinError = matrix.MatrixException.fromJson({
      'errcode': 'M_FORBIDDEN',
      'error': 'You are not invited',
    });
    await pumpApp(tester);
    await open(tester, 'matrix:roomid/private:example.org?via=example.org');
    await tester.tap(find.text('Join room'));
    await tester.pumpAndSettle();
    expect(find.textContaining('It may need an invitation'), findsOneWidget);
    expect(opened, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(RoomLinkSheet), findsNothing);
  });

  testWidgets('an unknown alias explains the failure and can retry', (
    tester,
  ) async {
    await pumpApp(tester);
    await open(tester, 'https://matrix.to/#/#missing:example.org');
    expect(find.textContaining('Couldn’t find #missing:example.org'), findsOne);
    backend.aliases['#missing:example.org'] = '!found:example.org';
    backend.joinedIds.add('!found:example.org');
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(opened, ['!found:example.org']);
  });

  testWidgets('an invited room offers to accept the invitation', (
    tester,
  ) async {
    backend.invitedIds.add('!invite:example.org');
    backend.roomList = [room('!invite:example.org', 'Invite', invited: true)];
    await pumpApp(tester);
    await open(tester, 'https://matrix.to/#/!invite:example.org');
    await tester.tap(find.text('Accept invitation'));
    await tester.pumpAndSettle();
    expect(backend.accepted, ['!invite:example.org']);
    expect(opened, ['!invite:example.org']);
  });

  testWidgets('an account change closes the join sheet without opening', (
    tester,
  ) async {
    await pumpApp(tester);
    await open(tester, 'matrix:roomid/abc:example.org');
    expect(find.byType(RoomLinkSheet), findsOneWidget);
    backend.replaceAccount('account-b');
    await tester.pumpAndSettle();
    expect(find.byType(RoomLinkSheet), findsNothing);
    expect(opened, isEmpty);
    expect(backend.joins, isEmpty);
  });

  testWidgets('a user link opens or starts a direct chat', (tester) async {
    await pumpApp(tester);
    expect(await open(tester, 'matrix:u/alice:example.org'), isNull);
    expect(find.text('Alice Example'), findsOneWidget);
    expect(find.text('@alice:example.org'), findsOneWidget);
    await tester.tap(find.text('Message'));
    await tester.pumpAndSettle();
    expect(backend.directChats, ['@alice:example.org']);
    expect(opened, ['!dm:example.org']);
  });

  testWidgets('a link to your own account does not start a chat', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(await open(tester, 'https://matrix.to/#/@me:example.org'), isTrue);
    expect(find.byType(UserLinkSheet), findsNothing);
    expect(find.text('That link is to your own account.'), findsOneWidget);
  });

  testWidgets('legacy backends join room IDs through the core dialog', (
    tester,
  ) async {
    final legacy = _LegacyBackend()..roomList = [];
    await pumpApp(tester);
    bool? result;
    openMatrixLink(
      appContext,
      legacy,
      palette,
      Uri.parse('https://matrix.to/#/#alias:example.org'),
    ).then((value) => result = value);
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.textContaining('can’t be opened'), findsOneWidget);
    expect(platformFeaturesOf(legacy), isNull);
  });
}

class _LegacyBackend extends PlatformBackendBase {}

/// A backend without the platform surface.
class PlatformBackendBase extends ChatBackend {
  List<ChatRoom> roomList = [];
  @override
  List<ChatRoom> get rooms => roomList;
  @override
  String? get userId => '@me:example.org';
  @override
  SessionStatus get connection => SessionStatus.ready;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

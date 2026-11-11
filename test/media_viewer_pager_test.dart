import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/media_actions.dart';
import 'package:parallax/features/media/media_viewer_pager.dart';
import 'package:parallax/media_player_owner.dart';
import 'package:parallax/media_viewer.dart' show MediaViewer;

import 'media_test_support.dart';

DownloadedAttachment attachment(String mime, [String name = 'photo.png']) =>
    DownloadedAttachment(
      name: name,
      mimeType: mime,
      bytes: Uint8List.fromList([1, 2, 3]),
    );

void main() {
  group('mediaViewerItems', () {
    final entries = [
      mediaEntry('t', EntryKind.text),
      mediaEntry('i1', EntryKind.image),
      mediaEntry('v', EntryKind.video),
      mediaEntry('f', EntryKind.file),
      mediaEntry('i2', EntryKind.image, redacted: true),
      mediaEntry('i3', EntryKind.image),
    ];

    test('images and videos page together, oldest first', () {
      final items = mediaViewerItems(
        FakeMediaBackend(),
        roomId,
        'v',
        entries: entries,
      );
      expect([for (final item in items) item.eventId], ['i1', 'v', 'i3']);
    });

    test('files and unknown events open on their own', () {
      final backend = FakeMediaBackend();
      final file = mediaViewerItems(backend, roomId, 'f', entries: entries);
      expect(file.single.eventId, 'f');
      expect(file.single.entry?.kind, EntryKind.file);
      final unknown = mediaViewerItems(
        backend,
        roomId,
        'zzz',
        entries: entries,
      );
      expect(unknown.single.entry, isNull);
    });

    test('without entries the active room timeline is used', () {
      final backend = FakeMediaBackend()..timeline = entries;
      final items = mediaViewerItems(backend, roomId, 'i1');
      expect(items, hasLength(3));
    });

    test('a minimal backend without a timeline still opens one item', () {
      final items = mediaViewerItems(PlainBackend(), roomId, 'x');
      expect(items.single.eventId, 'x');
    });

    test('PDF files are documents, image files are previewable', () {
      final pdf = MediaViewerItem(
        eventId: 'p',
        loader: () async => attachment('application/pdf'),
        entry: mediaEntry(
          'p',
          EntryKind.file,
          content: {
            'info': {'mimetype': 'application/pdf'},
          },
        ),
      );
      final png = MediaViewerItem(
        eventId: 'q',
        loader: () async => attachment('image/png'),
        entry: mediaEntry(
          'q',
          EntryKind.file,
          content: {
            'info': {'mimetype': 'image/png'},
          },
        ),
      );
      expect(pdf.isDocument, isTrue);
      expect(png.isDocument, isFalse);
    });
  });

  Future<List<ui.Image>> images(WidgetTester tester, int count) async => [
    for (var i = 0; i < count; i++) (await tester.runAsync(makeImage))!,
  ];

  testWidgets('swipes between images and shows position and file info', (
    tester,
  ) async {
    final decoded = await images(tester, 3);
    var next = 0;
    final backend = FakeMediaBackend()
      ..original = (id) => attachment('image/png', '$id.png');
    final entries = [
      mediaEntry(
        'a',
        EntryKind.image,
        body: 'first.png',
        content: {
          'info': {'mimetype': 'image/png', 'size': 2048, 'w': 8, 'h': 6},
        },
      ),
      mediaEntry('b', EntryKind.image, body: 'second.png'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewerPager(
          backend: backend,
          roomId: roomId,
          items: mediaViewerItems(backend, roomId, 'a', entries: entries),
          imageDecoder: (_) async => decoded[next++],
        ),
      ),
    );
    await settle(tester);
    expect(find.text('first.png'), findsOneWidget);
    expect(find.text('Alice · 1 of 2'), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);

    await tester.tap(find.byTooltip('File info'));
    await tester.pumpAndSettle();
    expect(find.text('File info'), findsWidgets);
    expect(find.text('Uploaded by'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('image/png'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget);
    expect(find.text('8 × 6'), findsOneWidget);
    Navigator.of(tester.element(find.text('Uploaded by'))).pop();
    await tester.pumpAndSettle();

    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('second.png'), findsOneWidget);
    expect(find.text('Alice · 2 of 2'), findsOneWidget);
    expect(backend.loads, ['a', 'b']);
    expect(decoded.first.debugDisposed, isTrue, reason: 'off-screen page');
    expect(find.byTooltip('Delete'), findsNothing, reason: 'not my message');
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleting my media confirms, redacts and drops the page', (
    tester,
  ) async {
    final decoded = await images(tester, 3);
    var next = 0;
    final backend = FakeMediaBackend()
      ..original = (id) => attachment('image/png', '$id.png');
    final entries = [
      mediaEntry(
        'a',
        EntryKind.image,
        body: 'mine.png',
        mine: true,
        sender: me,
      ),
      mediaEntry('b', EntryKind.image, body: 'theirs.png'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewerPager(
          backend: backend,
          roomId: roomId,
          items: mediaViewerItems(backend, roomId, 'a', entries: entries),
          imageDecoder: (_) async => decoded[next++],
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete file?'), findsOneWidget);
    expect(
      find.text(
        'This file will be removed from the room and members won’t have '
        'access to it.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(backend.deleted, ['a']);
    expect(find.text('theirs.png'), findsOneWidget);
    expect(find.textContaining('of 2'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('documents show a file card instead of a player', (tester) async {
    final backend = FakeMediaBackend();
    final pdf = mediaEntry(
      'p',
      EntryKind.file,
      body: 'Lease.pdf',
      content: {
        'info': {'mimetype': 'application/pdf', 'size': 4096},
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewerPager(
          backend: backend,
          roomId: roomId,
          items: mediaViewerItems(backend, roomId, 'p', entries: [pdf]),
        ),
      ),
    );
    await settle(tester);
    expect(find.byType(MediaViewer), findsNothing);
    expect(find.text('PDF · 4 KB'), findsOneWidget);
    expect(find.textContaining('can’t be previewed'), findsOneWidget);
    expect(backend.loads, isEmpty);
  });

  testWidgets('closing joins every page: players dispose before files go', (
    tester,
  ) async {
    final log = <String>[];
    final backend = FakeMediaBackend()
      ..original = (id) => attachment('video/mp4', '$id.mp4');
    final entries = [
      mediaEntry('v1', EntryKind.video, body: 'one.mp4'),
      mediaEntry('v2', EntryKind.video, body: 'two.mp4'),
    ];
    final route = MaterialPageRoute<void>(
      builder: (_) => MediaViewerPager(
        backend: backend,
        roomId: roomId,
        items: mediaViewerItems(backend, roomId, 'v1', entries: entries),
        fileFactory: (_) async => FakeTempFile(log),
        playerFactory: (_, _) => FakePlayer(log),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(route),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('native video'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('two.mp4'), findsOneWidget);
    await tester.tap(find.byTooltip('Close media'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(log.where((event) => event == 'dispose'), hasLength(2));
    expect(log.where((event) => event == 'delete'), hasLength(2));
    expect(log.indexOf('dispose'), lessThan(log.indexOf('delete')));
    expect(log.lastIndexOf('dispose'), lessThan(log.lastIndexOf('delete')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('logout ends the pager and disables actions', (tester) async {
    final decoded = await images(tester, 1);
    final backend = FakeMediaBackend()
      ..original = (id) => attachment('image/png');
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewerPager(
          backend: backend,
          roomId: roomId,
          items: mediaViewerItems(
            backend,
            roomId,
            'a',
            entries: [mediaEntry('a', EntryKind.image)],
          ),
          imageDecoder: (_) async => decoded.single,
        ),
      ),
    );
    await settle(tester);
    backend.signOut();
    await settle(tester);
    expect(find.text('This media session has ended.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.share_outlined),
          )
          .onPressed,
      isNull,
    );
    expect(decoded.single.debugDisposed, isTrue);
  });

  testWidgets('share hands over a private copy and deletes it afterwards', (
    tester,
  ) async {
    final base = Directory('${Directory.current.path}/build');
    await tester.runAsync(() => base.create(recursive: true));
    final root = (await tester.runAsync(
      () => base.createTemp('media-share-test-'),
    ))!;
    String? sharedPath;
    List<int>? sharedBytes;
    String? sharedMime;
    final originalRoot = debugShareTemporaryRoot;
    final originalPresenter = debugMediaSharePresenter;
    debugShareTemporaryRoot = () async => root;
    debugMediaSharePresenter = (path, mime, name) async {
      sharedPath = path;
      sharedMime = mime;
      sharedBytes = await File(path).readAsBytes();
    };
    addTearDown(() {
      debugShareTemporaryRoot = originalRoot;
      debugMediaSharePresenter = originalPresenter;
    });
    await tester.pumpWidget(host(const Text('ctx')));
    final context = tester.element(find.text('ctx'));
    await tester.runAsync(
      () => shareMedia(
        context,
        backend: FakeMediaBackend(),
        loader: () async => DownloadedAttachment(
          name: '../../secret plans.pdf',
          mimeType: 'application/pdf',
          bytes: Uint8List.fromList([9, 8, 7]),
        ),
      ),
    );
    expect(sharedBytes, [9, 8, 7]);
    expect(sharedMime, 'application/pdf');
    expect(sharedPath, isNot(contains('../')));
    expect(sharedPath, startsWith(root.path));
    final remaining = (await tester.runAsync(() => root.list().toList()))!;
    expect(remaining, isEmpty, reason: 'decrypted copy cleaned up');
    await tester.runAsync(() => root.delete(recursive: true));
  });

  test('MediaPlayerOwner keeps animated sources for GIF/WebP only', () async {
    Future<MediaPlayerOwner> load(String mime) async {
      final owner = MediaPlayerOwner(
        loader: () async => attachment(mime),
        imageDecoder: (_) => makeImage(),
      );
      await owner.load();
      return owner;
    }

    final gif = await load('image/gif');
    expect(gif.animatedSource, isNotNull);
    await gif.close();
    expect(gif.animatedSource, isNull);
    final png = await load('image/png');
    expect(png.animatedSource, isNull);
    await png.close();
  });

  test('MediaPlayerOwner forwards playback speed to the player', () async {
    final log = <String>[];
    final owner = MediaPlayerOwner(
      loader: () async => attachment('audio/ogg', 'a.ogg'),
      fileFactory: (_) async => FakeTempFile(log),
      playerFactory: (_, _) => FakePlayer(log),
    );
    await owner.load();
    await owner.setSpeed(1.5);
    await owner.close();
    expect(log, ['initialize', 'speed 1.5', 'dispose', 'delete']);
  });
}

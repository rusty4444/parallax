import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/media_features.dart';
import 'package:parallax/features/media/media_gallery_screen.dart';
import 'package:parallax/features/media/media_viewer_pager.dart';

import 'media_test_support.dart';

Widget gallery(FakeMediaBackend backend) => MaterialApp(
  home: MediaGalleryScreen(
    backend: backend,
    features: backend,
    roomId: roomId,
    palette: palette,
  ),
);

void main() {
  final november = DateTime.utc(2026, 11, 10, 9);
  final october = DateTime.utc(2026, 10, 2, 9);

  testWidgets('media grid and files list split one paginated history', (
    tester,
  ) async {
    final backend = FakeMediaBackend()
      ..pages.add(
        MediaHistoryPage([
          mediaEntry('img', EntryKind.image, body: 'beach.jpg', time: november),
          mediaEntry(
            'vid',
            EntryKind.video,
            body: 'surf.mp4',
            time: november,
            content: {
              'info': {'duration': 12000},
            },
          ),
          mediaEntry(
            'doc',
            EntryKind.file,
            body: 'Itinerary.pdf',
            time: october,
            content: {
              'info': {'mimetype': 'application/pdf', 'size': 1048576},
            },
          ),
          mediaEntry(
            'voice',
            EntryKind.voice,
            body: 'Voice message',
            time: october,
            content: {
              'org.matrix.msc3245.voice': <String, Object?>{},
              'info': {'duration': 7000},
            },
          ),
        ]),
      );
    await tester.pumpWidget(gallery(backend));
    await settle(tester);
    expect(find.text('Media and files'), findsOneWidget);
    expect(backend.historyRequests, [null]);
    expect(find.text('NOVEMBER 2026'), findsOneWidget);
    expect(find.bySemanticsLabel('Image: beach.jpg'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Video: surf.mp4')), findsOneWidget);
    expect(find.text('0:12'), findsOneWidget);
    expect(find.text('No more media to show'), findsOneWidget);

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('OCTOBER 2026'), findsOneWidget);
    expect(find.text('Itinerary.pdf'), findsOneWidget);
    expect(find.text('1 MB · PDF'), findsOneWidget);
    expect(find.text('Voice message · 0:07'), findsOneWidget);
    expect(find.text('No more files to show'), findsOneWidget);
  });

  testWidgets('empty rooms show Element X empty states', (tester) async {
    final backend = FakeMediaBackend();
    await tester.pumpWidget(gallery(backend));
    await settle(tester);
    expect(find.text('No media uploaded yet'), findsOneWidget);
    expect(
      find.text('Images and videos uploaded to this room will be shown here.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('No files uploaded yet'), findsOneWidget);
  });

  testWidgets('sparse history paginates a bounded number of pages', (
    tester,
  ) async {
    final backend = FakeMediaBackend();
    for (var i = 0; i < 10; i++) {
      backend.pages.add(MediaHistoryPage(const [], nextBatch: 'token-$i'));
    }
    await tester.pumpWidget(gallery(backend));
    await settle(tester);
    // The first load plus three automatic follow-ups, then "Load more".
    expect(backend.historyRequests, [null, 'token-0', 'token-1', 'token-2']);
    expect(find.text('Load more'), findsOneWidget);
    await tester.tap(find.text('Load more'));
    await settle(tester);
    expect(backend.historyRequests.length, greaterThan(4));
    expect(backend.historyRequests[4], 'token-3');
  });

  testWidgets('history errors are retryable', (tester) async {
    final backend = FakeMediaBackend()
      ..historyError = StateError('offline')
      ..pages.add(
        MediaHistoryPage([mediaEntry('img', EntryKind.image, body: 'a.png')]),
      );
    await tester.pumpWidget(gallery(backend));
    await settle(tester);
    expect(
      find.text('Check your internet connection and try again.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await settle(tester);
    expect(find.bySemanticsLabel('Image: a.png'), findsOneWidget);
  });

  testWidgets('tapping media opens the swipeable viewer with history loaders', (
    tester,
  ) async {
    final backend = FakeMediaBackend()
      // Unsupported type: the viewer fails fast without native plugins.
      ..original = ((_) => DownloadedAttachment(
        name: 'x',
        mimeType: 'application/x-test',
        bytes: Uint8List(1),
      ))
      ..pages.add(
        MediaHistoryPage([
          mediaEntry('new', EntryKind.image, body: 'new.png', time: november),
          mediaEntry('old', EntryKind.image, body: 'old.png', time: october),
        ]),
      );
    await tester.pumpWidget(gallery(backend));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Image: new.png'));
    await tester.pumpAndSettle();
    final pager = tester.widget<MediaViewerPager>(
      find.byType(MediaViewerPager),
    );
    // The viewer pages oldest → newest and opens on the tapped item.
    expect([for (final item in pager.items) item.eventId], ['old', 'new']);
    expect(pager.initialIndex, 1);
    expect(find.text('new.png'), findsOneWidget);
    expect(backend.loads, ['new']);
    await tester.tap(find.byTooltip('Close media'));
    await tester.pumpAndSettle();
  });

  testWidgets('own files can be deleted from the long-press menu', (
    tester,
  ) async {
    final backend = FakeMediaBackend()
      ..pages.add(
        MediaHistoryPage([
          mediaEntry(
            'doc',
            EntryKind.file,
            body: 'notes.txt',
            mine: true,
            sender: me,
          ),
        ]),
      );
    await tester.pumpWidget(gallery(backend));
    await settle(tester);
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More options for notes.txt'));
    await tester.pumpAndSettle();
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('File info'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(backend.deleted, ['doc']);
    expect(find.text('notes.txt'), findsNothing);
  });

  test('history projection keeps visible media events only', () {
    final room = matrix.Room(id: roomId, client: _Client());
    matrix.Event event(
      String id,
      Map<String, Object?> content, {
      String type = matrix.EventTypes.Message,
      String sender = '@alice:example.org',
    }) => matrix.Event(
      content: content,
      type: type,
      eventId: id,
      senderId: sender,
      originServerTs: november,
      room: room,
    );
    final image = projectMediaEvent(
      event('img', {
        'msgtype': 'm.image',
        'body': 'a.png',
        'url': 'mxc://example.org/a',
      }, sender: me),
      me,
    )!;
    expect(image.kind, EntryKind.image);
    expect(image.mine, isTrue);
    expect(image.content['url'], 'mxc://example.org/a');
    final voice = projectMediaEvent(
      event('v', {
        'msgtype': 'm.audio',
        'body': 'Voice message',
        'url': 'mxc://example.org/v',
        'org.matrix.msc3245.voice': <String, Object?>{},
      }),
      me,
    )!;
    expect(voice.kind, EntryKind.voice);
    expect(
      projectMediaEvent(event('t', {'msgtype': 'm.text', 'body': 'hi'}), me),
      isNull,
    );
    expect(
      projectMediaEvent(
        event('edit', {
          'msgtype': 'm.image',
          'body': 'b.png',
          'url': 'mxc://example.org/b',
          'm.relates_to': {'rel_type': 'm.replace', 'event_id': 'img'},
        }),
        me,
      ),
      isNull,
      reason: 'edits are not separate gallery items',
    );
    expect(
      projectMediaEvent(
        event('no-url', {'msgtype': 'm.file', 'body': 'x'}),
        me,
      ),
      isNull,
    );
    expect(
      projectMediaEvent(
        event('enc', {
          'algorithm': 'm.megolm.v1.aes-sha2',
        }, type: matrix.EventTypes.Encrypted),
        me,
      ),
      isNull,
    );
    expect(mediaFeaturesOf(PlainBackend()), isNull);
  });
}

class _Client extends Fake implements matrix.Client {}

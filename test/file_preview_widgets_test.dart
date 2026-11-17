import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/file_preview/document_loader.dart';
import 'package:parallax/features/file_preview/document_model.dart';
import 'package:parallax/features/file_preview/document_page.dart';
import 'package:parallax/features/file_preview/document_parser.dart';
import 'package:parallax/features/file_preview/document_view.dart';
import 'package:parallax/features/file_preview/inline_document_preview.dart';
import 'package:parallax/features/media/media_bubbles.dart';
import 'package:parallax/features/media/media_hooks.dart';
import 'package:parallax/features/media/media_viewer_pager.dart';
import 'package:parallax/features/rich_timeline/message_actions.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/timeline/message_bubble.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_preview_support.dart';
import 'media_test_support.dart';

Uint8List fixture(String name) =>
    File('test/fixtures/file_preview/$name').readAsBytesSync();

DownloadedAttachment file(String name, List<int> bytes, [String? mime]) =>
    DownloadedAttachment(
      name: name,
      mimeType: mime ?? 'application/octet-stream',
      bytes: Uint8List.fromList(bytes),
    );

ChatEntry fileEntry(
  String id,
  String name, {
  int? size,
  String? mime,
  bool mine = false,
}) => mediaEntry(
  id,
  EntryKind.file,
  body: name,
  mine: mine,
  content: {
    'info': {'mimetype': ?mime, 'size': ?size},
  },
);

/// The auto-load rule reads the room list.
class _RoomsBackend extends FakeMediaBackend {
  @override
  List<ChatRoom> get rooms => const [];
}

void main() {
  setUp(() {
    // Fake async cannot wait for a real isolate.
    debugDocumentParser = (request) async => parseDocument(request);
  });
  tearDown(() => debugDocumentParser = parseDocumentInBackground);

  Widget bubbleBody(FakeMediaBackend backend, ChatEntry entry) => host(
    Builder(
      builder: (context) =>
          mediaEntryBody(context, hookFor(backend, entry)) ??
          const Text('none'),
    ),
  );

  group('in the timeline', () {
    testWidgets('a CSV shows its first cells under the file card', (
      tester,
    ) async {
      final backend = FakeMediaBackend()
        ..original = (_) => file(
          'people.csv',
          utf8.encode('Name,Team,Start\nQuinn,Ops,2024\nSam,IT,2019\n'),
        );
      await tester.pumpWidget(
        bubbleBody(backend, fileEntry(r'$csv', 'people.csv', size: 60)),
      );
      // The box is there, at its final size, before the file arrives.
      final box = find.byKey(const ValueKey('document.inline'));
      expect(tester.getSize(box).height, InlineDocumentPreview.height);
      expect(find.text('Quinn'), findsNothing);
      await settle(tester);
      expect(tester.getSize(box).height, InlineDocumentPreview.height);
      for (final cell in ['Name', 'Team', 'Start', 'Quinn', 'Ops', 'Sam']) {
        expect(find.text(cell), findsOneWidget, reason: cell);
      }
      expect(find.text('people.csv'), findsOneWidget);
      expect(backend.loads, [r'$csv']);
    });

    testWidgets('Markdown, text and Word show their first lines', (
      tester,
    ) async {
      final backend = FakeMediaBackend()
        ..original = (id) => switch (id) {
          r'$md' => file(
            'README.md',
            utf8.encode(
              '# Parallax\n\nA *vivid* '
              'messenger.\n\n- fast\n- private\n',
            ),
          ),
          r'$txt' => file('notes.txt', utf8.encode('first line\nsecond line')),
          _ => file('report.docx', fixture('report.docx')),
        };
      await tester.pumpWidget(
        bubbleBody(backend, fileEntry(r'$md', 'README.md')),
      );
      await settle(tester);
      expect(
        find.textContaining('Parallax\nA vivid messenger.\n• fast\n• private'),
        findsOneWidget,
      );
      await tester.pumpWidget(
        bubbleBody(backend, fileEntry(r'$txt', 'notes.txt')),
      );
      await settle(tester);
      expect(find.text('first line\nsecond line'), findsOneWidget);
      await tester.pumpWidget(
        bubbleBody(backend, fileEntry(r'$docx', 'report.docx')),
      );
      await settle(tester);
      expect(
        find.textContaining('Quarterly report\nSummary\nRevenue grew 12%'),
        findsOneWidget,
      );
    });

    testWidgets('a bubble built again reuses the preview', (tester) async {
      final backend = FakeMediaBackend()
        ..original = (_) => file('a.txt', utf8.encode('hello there'));
      final entry = fileEntry(r'$a', 'a.txt');
      await tester.pumpWidget(bubbleBody(backend, entry));
      await settle(tester);
      expect(find.text('hello there'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(bubbleBody(backend, entry));
      // Shown at once, with no second download.
      expect(find.text('hello there'), findsOneWidget);
      expect(backend.loads, [r'$a']);
    });

    testWidgets('nothing is fetched for files it cannot or should not read', (
      tester,
    ) async {
      final backend = FakeMediaBackend()
        ..original = (_) => file('x', utf8.encode('data'));
      for (final entry in [
        // Not formats with a preview.
        fileEntry(r'$doc', 'Lease.doc', mime: 'application/msword'),
        fileEntry(r'$zip', 'photos.zip'),
        // Larger than the inline limit.
        fileEntry(
          r'$big',
          'big.csv',
          size: DocumentPreviews.inlineMaxBytes + 1,
        ),
        // Still sending: no event on the server yet.
        fileEntry('mx_local_echo', 'draft.md'),
      ]) {
        await tester.pumpWidget(bubbleBody(backend, entry));
        await settle(tester);
        expect(
          find.byKey(const ValueKey('document.inline')),
          findsNothing,
          reason: entry.body,
        );
      }
      expect(backend.loads, isEmpty);
    });

    testWidgets('previews follow the "media previews" setting', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = AppearancePreferences();
      addTearDown(preferences.dispose);
      await tester.runAsync(
        () => preferences.setMediaPreviewMode(MediaPreviewMode.never),
      );
      final backend = _RoomsBackend()
        ..original = (_) => file('a.txt', utf8.encode('secret'));
      await tester.pumpWidget(
        FeatureSettingsScope(
          preferences: preferences,
          draftStore: MessageDraftStore(),
          child: bubbleBody(backend, fileEntry(r'$a', 'a.txt')),
        ),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('document.inline')), findsNothing);
      expect(backend.loads, isEmpty);
      // The card still opens the viewer.
      expect(find.text('a.txt'), findsOneWidget);
    });

    testWidgets('a file that fails to load or parse leaves just the card', (
      tester,
    ) async {
      var failures = 0;
      final backend = FakeMediaBackend()
        ..original = (id) {
          if (id == r'$gone') {
            failures++;
            throw StateError('Attachment unavailable');
          }
          return file('broken.docx', utf8.encode('this is not a zip file'));
        };
      await tester.pumpWidget(
        bubbleBody(backend, fileEntry(r'$gone', 'gone.md')),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('document.inline')), findsNothing);
      expect(find.text('gone.md'), findsOneWidget);
      // Not asked for again each time the bubble is rebuilt.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        bubbleBody(backend, fileEntry(r'$gone', 'gone.md')),
      );
      await settle(tester);
      expect(failures, 1);

      await tester.pumpWidget(
        bubbleBody(backend, fileEntry(r'$broken', 'broken.docx')),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('document.inline')), findsNothing);
      expect(find.text('broken.docx'), findsOneWidget);
    });

    testWidgets('previews are dropped when the account signs out', (
      tester,
    ) async {
      final backend = FakeMediaBackend()
        ..original = (_) => file('a.txt', utf8.encode('private text'));
      await tester.pumpWidget(bubbleBody(backend, fileEntry(r'$a', 'a.txt')));
      await settle(tester);
      final previews = DocumentPreviews.of(backend);
      expect(previews.hasInline(roomId, r'$a'), isTrue);
      backend.signOut();
      // Signing out replaces the signed-in screens; a bubble built in that
      // moment must not show the old account's file.
      await tester.pumpWidget(bubbleBody(backend, fileEntry(r'$a', 'a.txt')));
      await settle(tester);
      expect(find.text('private text'), findsNothing);
      expect(previews.hasInline(roomId, r'$a'), isFalse);
    });

    testWidgets('fits a 320 dp phone inside a message bubble', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = FakeMediaBackend()
        ..original = (_) => file(
          'wide.csv',
          utf8.encode(
            '${List.filled(20, 'a very long column title').join(',')}\n',
          ),
        );
      for (final mine in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MessageBubble(
                entry: fileEntry(
                  r'$wide',
                  'A rather long file name for a narrow phone.csv',
                  mine: mine,
                ),
                backend: backend,
                roomId: roomId,
                palette: palette,
                group: false,
                onHeart: () {},
                onAction: () {},
                onReaction: (_) {},
              ),
            ),
          ),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);
        final box = tester.getRect(
          find.byKey(const ValueKey('document.inline')),
        );
        expect(box.right, lessThanOrEqualTo(320));
        expect(box.left, greaterThanOrEqualTo(0));
      }
    });

    testWidgets('tapping the preview opens the viewer', (tester) async {
      final backend = FakeMediaBackend()
        ..original = (_) => file('a.md', utf8.encode('# Title\n\nBody text'));
      final entry = fileEntry(r'$a', 'a.md');
      backend.timeline = [entry];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FileMessageBody(
                ctx: hookFor(backend, entry, entries: [entry]),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('document.inline')));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewerPager), findsOneWidget);
      expect(find.byKey(const ValueKey('document.rich')), findsOneWidget);
      expect(find.text('Body text'), findsOneWidget);
    });
  });

  group('in the viewer', () {
    Future<void> open(
      WidgetTester tester,
      FakeMediaBackend backend,
      ChatEntry entry,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewerPager(
            backend: backend,
            roomId: roomId,
            items: mediaViewerItems(
              backend,
              roomId,
              entry.id,
              entries: [entry],
            ),
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('an Excel workbook is a grid with a tab per sheet', (
      tester,
    ) async {
      final backend = FakeMediaBackend()
        ..original = (_) => file('budget.xlsx', fixture('budget.xlsx'));
      await open(tester, backend, fileEntry(r'$x', 'budget.xlsx'));
      expect(find.text('budget.xlsx'), findsOneWidget);
      expect(find.text('5 rows · 8 columns'), findsOneWidget);
      // Column letters and the spreadsheet's own row numbers.
      for (final label in ['A', 'B', 'H', '1', '4', '7']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('Laptop'), findsOneWidget);
      expect(find.text('5 Nov 2026'), findsOneWidget);
      expect(find.text('TRUE'), findsOneWidget);
      expect(find.text('Secret'), findsNothing);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Notes'));
      await tester.pump();
      expect(find.text('Remember the café order'), findsOneWidget);
      expect(find.text('Laptop'), findsNothing);
      expect(find.text('2 rows · 1 column'), findsOneWidget);
    });

    testWidgets('tapping a cell shows all of its text, with Copy', (
      tester,
    ) async {
      final long = 'A long comment ${'that keeps going ' * 12}to the end';
      final backend = FakeMediaBackend()
        ..original = (_) =>
            file('a.csv', utf8.encode('id,comment\n7,"$long"\n'));
      await open(tester, backend, fileEntry(r'$c', 'a.csv'));
      await tester.tap(find.text(long));
      await tester.pumpAndSettle();
      expect(find.text('Cell B2'), findsOneWidget);
      expect(find.widgetWithText(SelectableText, long), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('a Word document keeps its headings, lists and table', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = FakeMediaBackend()
        ..original = (_) => file('report.docx', fixture('report.docx'));
      await open(tester, backend, fileEntry(r'$d', 'report.docx'));
      expect(find.byKey(const ValueKey('document.rich')), findsOneWidget);
      expect(find.text('Quarterly report'), findsOneWidget);
      expect(find.text('Hire two engineers'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.text('Review with finance'), findsOneWidget);
      expect(find.text('Region'), findsOneWidget);
      expect(find.text('West'), findsOneWidget);
      final heading = tester.widget<Text>(
        find.descendant(
          of: find.widgetWithText(DocumentSpans, 'Quarterly report'),
          matching: find.byType(Text),
        ),
      );
      expect(heading.textSpan!.style!.fontWeight, FontWeight.w800);
    });

    testWidgets('a PowerPoint file lists its slides', (tester) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = FakeMediaBackend()
        ..original = (_) => file('roadmap.pptx', fixture('roadmap.pptx'));
      await open(tester, backend, fileEntry(r'$p', 'roadmap.pptx'));
      expect(find.text('Slide 1'), findsOneWidget);
      expect(find.text('Slide 3'), findsOneWidget);
      expect(find.text('Parallax roadmap'), findsOneWidget);
      expect(find.text('Word and Excel first'), findsOneWidget);
    });

    testWidgets('Markdown links open like message links', (tester) async {
      final opened = <Uri>[];
      final previous = richTimelineLaunchUrl;
      richTimelineLaunchUrl = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => richTimelineLaunchUrl = previous);
      final backend = FakeMediaBackend()
        ..original = (_) => file(
          'a.md',
          utf8.encode(
            '[docs](https://example.org/docs)\n\n'
            '[bad](javascript:alert(1))\n',
          ),
        );
      await open(tester, backend, fileEntry(r'$m', 'a.md'));
      // Tap the words themselves (the paragraph is as wide as the page).
      await tester.tapAt(
        tester.getTopLeft(find.text('docs')) + const Offset(8, 8),
      );
      await tester.pump();
      await tester.tapAt(
        tester.getTopLeft(find.text('bad')) + const Offset(8, 8),
      );
      await tester.pump();
      expect(opened, [Uri.parse('https://example.org/docs')]);
    });

    testWidgets('long text is cut with a note, and can be selected', (
      tester,
    ) async {
      final backend = FakeMediaBackend()
        ..original = (_) =>
            file('big.log', utf8.encode('line of log output\n' * 200000));
      await open(tester, backend, fileEntry(r'$l', 'big.log'));
      expect(find.byKey(const ValueKey('document.text')), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget);
      final position = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(const ValueKey('document.text')),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      // The list is built lazily, so its end is an estimate until reached.
      for (var i = 0; i < 20; i++) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
      }
      expect(
        find.textContaining('shows the start of the file'),
        findsOneWidget,
      );
    });

    testWidgets('files it cannot read keep the file card', (tester) async {
      final backend = FakeMediaBackend()
        ..original = (_) => file('broken.xlsx', utf8.encode('not a workbook'));
      await open(tester, backend, fileEntry(r'$b', 'broken.xlsx', size: 14));
      expect(find.textContaining('can’t be previewed'), findsOneWidget);
      expect(find.text('XLSX · 14 B'), findsOneWidget);

      // Never downloaded just to find out.
      backend.loads.clear();
      await open(
        tester,
        backend,
        fileEntry(r'$doc', 'Lease.doc', mime: 'application/msword'),
      );
      expect(find.textContaining('can’t be previewed'), findsOneWidget);
      expect(backend.loads, isEmpty);
    });

    testWidgets('a failed download offers Retry', (tester) async {
      var attempts = 0;
      final backend = FakeMediaBackend()
        ..original = (_) {
          // The loader asks the open timeline, then the room's history.
          if (attempts++ < 2) throw StateError('offline');
          return file('a.txt', utf8.encode('now it loads'));
        };
      await open(tester, backend, fileEntry(r'$r', 'a.txt'));
      expect(find.text('Couldn’t load this file.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text('now it loads'), findsOneWidget);
    });

    testWidgets('signing out while a file loads shows nothing from it', (
      tester,
    ) async {
      final backend = FakeMediaBackend()
        ..original = (_) => file('a.txt', utf8.encode('private text'));
      final entry = fileEntry(r'$s', 'a.txt');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentPage(
              backend: backend,
              roomId: roomId,
              eventId: entry.id,
              loader: () async {
                backend.signOut();
                return file('a.txt', utf8.encode('private text'));
              },
              info: mediaViewerItems(
                backend,
                roomId,
                entry.id,
                entries: [entry],
              ).single.info!,
              fallback: const Text('card'),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('private text'), findsNothing);
      expect(
        DocumentPreviews.of(backend).inlineOrNull(roomId, entry.id),
        isNull,
      );
    });
  });

  test('a ZIP built by the test helper round-trips', () {
    // Guards the fixtures used above against a broken helper.
    final preview = parseDocument(
      DocumentRequest(
        bytes: buildZip({
          'word/document.xml':
              '<w:document><w:body><w:p><w:r><w:t>ok</w:t></w:r></w:p></w:body></w:document>',
        }),
        format: documentFormatFor('a.docx', null)!,
        name: 'a.docx',
      ),
    );
    expect(preview, isNotNull);
  });
}

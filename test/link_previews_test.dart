import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/link_previews/link_preview_cache.dart';
import 'package:parallax/features/link_previews/link_preview_card.dart';
import 'package:parallax/features/link_previews/link_preview_hooks.dart';
import 'package:parallax/features/link_previews/link_previews.dart';
import 'package:parallax/features/rich_timeline/message_actions.dart';
import 'package:parallax/hooks/registry.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/settings_pages.dart';
import 'package:parallax/timeline/bubble_column.dart';
import 'package:parallax/timeline/message_bubble.dart';
import 'package:shared_preferences/shared_preferences.dart';

final palette = paletteFor(VisualTheme.parallax);
const roomId = '!room:example.org';
final url = Uri.parse('https://example.com/article');
final articleA = Uri.parse('https://example.com/a');
final preview = LinkPreview(
  url: url,
  title: 'A very interesting article',
  description: 'Something worth reading.',
  image: Uri(scheme: 'mxc', host: 'example.org', path: '/abc'),
);

class PreviewBackend extends ChatBackend implements LinkPreviewSource {
  final replies = <String, LinkPreview?>{};
  final calls = <String>[];
  final avatars = <Uri, Uint8List>{};
  var fail = false;
  String namespace = '';

  @override
  String get linkPreviewNamespace => namespace;

  @override
  Future<LinkPreview?> fetchLinkPreview(Uri url, {int? timestamp}) async {
    calls.add(url.toString());
    if (fail) throw StateError('server unavailable');
    return replies[url.toString()];
  }

  @override
  String? get userId => '@me:example.org';

  @override
  Future<Uint8List?> loadAvatar(Uri url) async => avatars[url];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatEntry entry(String body, {EntryKind kind = EntryKind.text}) => ChatEntry(
  id: '\$event',
  sender: '@alice:example.org',
  body: body,
  time: DateTime(2026, 1, 1),
  mine: false,
  kind: kind,
);

ChatRoom room({bool encrypted = false}) => ChatRoom(
  id: roomId,
  name: 'Room',
  preview: '',
  lastActivity: null,
  encrypted: encrypted,
);

Future<AppearancePreferences> preferences({
  bool previews = true,
  bool encrypted = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final result = AppearancePreferences(prefs: prefs);
  addTearDown(result.dispose);
  await result.setLinkPreviews(previews);
  await result.setLinkPreviewsInEncryptedRooms(encrypted);
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('firstPreviewableLink', () {
    test('finds the first web link and trims punctuation', () {
      expect(firstPreviewableLink('see https://example.com/a.'), articleA);
      expect(firstPreviewableLink('no links here'), isNull);
      expect(firstPreviewableLink(''), isNull);
      expect(
        firstPreviewableLink('mail me@example.com or https://example.com/a'),
        articleA,
      );
      expect(
        firstPreviewableLink('https://one.example/a https://two.example/b'),
        Uri.parse('https://one.example/a'),
      );
      expect(
        firstPreviewableLink('(https://example.com/a)'),
        Uri.parse('https://example.com/a'),
      );
    });

    test('ignores Matrix permalinks and non-web schemes', () {
      expect(
        firstPreviewableLink('https://matrix.to/#/!room:example.org'),
        isNull,
      );
      expect(firstPreviewableLink('ftp://example.com/file'), isNull);
      expect(firstPreviewableLink('www.example.com/page'), isNotNull);
    });

    test('refuses absurdly long URLs', () {
      final long = 'https://example.com/${'a' * 3000}';
      expect(firstPreviewableLink(long), isNull);
    });
  });

  group('LinkPreview', () {
    test('reads what it saved, tolerating junk', () {
      final roundTrip = LinkPreview.fromJson(preview.toJson())!;
      expect(roundTrip.title, preview.title);
      expect(roundTrip.image, preview.image);
      expect(roundTrip.host, 'example.com');
      expect(LinkPreview.fromJson('nonsense'), isNull);
      expect(LinkPreview.fromJson({'title': 'no url'}), isNull);
      final sparse = LinkPreview.fromJson({
        'url': 'https://www.example.com/a',
        'title': 42,
        'image': 'https://not-mxc.example/a.png',
      })!;
      expect(sparse.title, isNull);
      expect(sparse.image, isNull);
      expect(sparse.host, 'example.com');
      expect(sparse.isEmpty, isTrue);
      expect(preview.isEmpty, isFalse);
    });
  });

  group('LinkPreviewCache', () {
    late PreviewBackend backend;
    late Directory directory;

    setUp(() async {
      backend = PreviewBackend()..replies[url.toString()] = preview;
      directory = await Directory.systemTemp.createTemp('link_previews');
    });
    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    LinkPreviewCache newCache({
      DateTime Function()? now,
      int maxEntries = 300,
    }) => LinkPreviewCache(
      backend,
      directory: directory,
      now: now,
      maxEntries: maxEntries,
    );

    test('fetches once, then answers from memory', () async {
      final cache = newCache();
      expect((await cache.preview(url))!.title, preview.title);
      expect(await cache.preview(url), isNotNull);
      expect(backend.calls, [url.toString()]);
    });

    test('shares one request between bubbles asking together', () async {
      final cache = newCache();
      final results = await Future.wait([
        cache.preview(url),
        cache.preview(url),
        cache.preview(url),
      ]);
      expect(results.every((r) => r?.title == preview.title), isTrue);
      expect(backend.calls, hasLength(1));
    });

    test('failures are remembered briefly, then retried', () async {
      var now = DateTime(2026);
      final cache = newCache(now: () => now);
      backend.fail = true;
      expect(await cache.preview(url), isNull);
      expect(await cache.preview(url), isNull);
      expect(backend.calls, hasLength(1));
      now = now.add(const Duration(minutes: 11));
      backend.fail = false;
      expect((await cache.preview(url))!.title, preview.title);
      expect(backend.calls, hasLength(2));
    });

    test('saves per account and survives a restart', () async {
      backend.namespace = 'account-a';
      final first = newCache();
      await first.preview(url);
      await first.flush();
      final file = File('${directory.path}/link_previews/account-a.json');
      expect(await file.exists(), isTrue);

      final second = newCache();
      expect((await second.preview(url))!.title, preview.title);
      // No new fetch: it came from disk.
      expect(backend.calls, hasLength(1));
    });

    test('an accountless cache never touches disk', () async {
      final cache = newCache();
      await cache.preview(url);
      await cache.flush();
      expect(
        await Directory('${directory.path}/link_previews').exists(),
        isFalse,
      );
    });

    test('keeps only the newest entries on disk', () async {
      backend.namespace = 'account-a';
      final cache = newCache(maxEntries: 2);
      for (var i = 0; i < 4; i++) {
        final link = Uri.parse('https://example.com/$i');
        backend.replies[link.toString()] = LinkPreview(
          url: link,
          title: 'Page $i',
        );
        await cache.preview(link);
      }
      await cache.flush();
      final text = await File(
        '${directory.path}/link_previews/account-a.json',
      ).readAsString();
      expect(text.contains('Page 0'), isFalse);
      expect(text.contains('Page 3'), isTrue);
    });

    test('clear and deleteAccount remove saved previews', () async {
      backend.namespace = 'account-a';
      final cache = newCache();
      await cache.preview(url);
      await cache.flush();
      await LinkPreviewCache.deleteAccount('account-a', root: directory);
      expect(
        await File('${directory.path}/link_previews/account-a.json').exists(),
        isFalse,
      );
      await cache.preview(url);
      await cache.clear();
      expect(await cache.preview(url), isNotNull);
      expect(backend.calls, hasLength(2));
    });
  });

  group('linkPreviewEntryFooter', () {
    Future<Widget?> footer(
      WidgetTester tester, {
      required ChatEntry forEntry,
      ChatRoom? inRoom,
      bool previews = true,
      bool encryptedPreviews = false,
      ChatBackend? backend,
    }) async {
      Widget? result;
      final prefs = await preferences(
        previews: previews,
        encrypted: encryptedPreviews,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: FeatureSettingsScope(
            preferences: prefs,
            draftStore: MessageDraftStore(),
            child: Builder(
              builder: (context) {
                result = linkPreviewEntryFooter(
                  context,
                  EntryHookContext(
                    backend: backend ?? PreviewBackend(),
                    roomId: roomId,
                    palette: palette,
                    entry: forEntry,
                    room: inRoom,
                  ),
                );
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return result;
    }

    testWidgets('a text message with a link gets a card', (tester) async {
      final widget = await footer(
        tester,
        forEntry: entry('look at https://example.com/article'),
        inRoom: room(),
      );
      expect(widget, isA<LinkPreviewCard>());
    });

    testWidgets('registered as an entry footer', (tester) async {
      final prefs = await preferences();
      late List<Widget> footers;
      await tester.pumpWidget(
        MaterialApp(
          home: FeatureSettingsScope(
            preferences: prefs,
            draftStore: MessageDraftStore(),
            child: Builder(
              builder: (context) {
                footers = entryFootersFor(
                  context,
                  EntryHookContext(
                    backend: PreviewBackend(),
                    roomId: roomId,
                    palette: palette,
                    entry: entry('https://example.com/article'),
                    room: room(),
                  ),
                );
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(footers.whereType<LinkPreviewCard>(), hasLength(1));
    });

    testWidgets('nothing without a link, or for media and redactions', (
      tester,
    ) async {
      expect(
        await footer(tester, forEntry: entry('hello'), inRoom: room()),
        isNull,
      );
      expect(
        await footer(
          tester,
          forEntry: entry('https://example.com/a', kind: EntryKind.image),
          inRoom: room(),
        ),
        isNull,
      );
      expect(
        await footer(
          tester,
          forEntry: entry('https://example.com/a', kind: EntryKind.redacted),
          inRoom: room(),
        ),
        isNull,
      );
    });

    testWidgets('off when the setting is off', (tester) async {
      expect(
        await footer(
          tester,
          forEntry: entry('https://example.com/a'),
          inRoom: room(),
          previews: false,
        ),
        isNull,
      );
    });

    testWidgets('encrypted rooms need the opt-in', (tester) async {
      final linked = entry('https://example.com/a');
      expect(
        await footer(tester, forEntry: linked, inRoom: room(encrypted: true)),
        isNull,
      );
      // A room we know nothing about is treated as encrypted.
      expect(await footer(tester, forEntry: linked), isNull);
      expect(
        await footer(
          tester,
          forEntry: linked,
          inRoom: room(encrypted: true),
          encryptedPreviews: true,
        ),
        isA<LinkPreviewCard>(),
      );
    });

    testWidgets('backends without preview support show nothing', (
      tester,
    ) async {
      expect(
        await footer(
          tester,
          forEntry: entry('https://example.com/a'),
          inRoom: room(),
          backend: _PlainBackend(),
        ),
        isNull,
      );
    });
  });

  group('LinkPreviewCard', () {
    Future<void> pump(
      WidgetTester tester,
      PreviewBackend backend, {
      Uri? uri,
    }) async {
      final prefs = await preferences();
      await tester.pumpWidget(
        MaterialApp(
          home: FeatureSettingsScope(
            preferences: prefs,
            draftStore: MessageDraftStore(),
            child: Center(
              child: LinkPreviewCard(
                uri: uri ?? url,
                source: backend,
                backend: backend,
                palette: palette,
                mine: false,
                cache: LinkPreviewCache(backend),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows the page title, site and description', (tester) async {
      final backend = PreviewBackend()..replies[url.toString()] = preview;
      await pump(tester, backend);
      expect(find.text('A very interesting article'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.text('Something worth reading.'), findsOneWidget);
      expect(backend.calls, hasLength(1));
      // Rebuilding doesn't fetch again.
      await pump(tester, backend);
      expect(backend.calls, hasLength(1));
    });

    testWidgets('nothing to show means no card', (tester) async {
      final backend = PreviewBackend();
      await pump(tester, backend);
      expect(find.byType(InkWell), findsNothing);
      backend.fail = true;
      await pump(tester, backend);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('tapping opens the link', (tester) async {
      final backend = PreviewBackend()..replies[url.toString()] = preview;
      final opened = <Uri>[];
      final previous = richTimelineLaunchUrl;
      richTimelineLaunchUrl = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => richTimelineLaunchUrl = previous);
      await pump(tester, backend);
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(opened, [url]);
    });

    testWidgets('inside a message bubble, under the text', (tester) async {
      final backend = PreviewBackend()..replies[url.toString()] = preview;
      final prefs = await preferences();
      await tester.pumpWidget(
        MaterialApp(
          home: FeatureSettingsScope(
            preferences: prefs,
            draftStore: MessageDraftStore(),
            child: SingleChildScrollView(
              child: MessageBubble(
                entry: entry('have you seen https://example.com/article ?'),
                backend: backend,
                roomId: roomId,
                palette: palette,
                group: false,
                room: room(),
                onHeart: () {},
                onAction: () {},
                onReaction: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('A very interesting article'), findsOneWidget);
      expect(find.byType(LinkPreviewCard), findsOneWidget);
      // Below the message text, above the timestamp row.
      final bubble = tester.getTopLeft(find.byType(MessageBubble)).dy;
      final card = tester.getRect(find.byType(LinkPreviewCard));
      final timestamp = tester.getTopLeft(find.byType(BubbleEnd)).dy;
      expect(card.top, greaterThan(bubble));
      expect(card.bottom, lessThanOrEqualTo(timestamp));
      expect(
        find.text(
          'have you seen https://example.com/article ?',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('Settings → Media has both link preview switches', (
    tester,
  ) async {
    final prefs = await preferences();
    await tester.pumpWidget(
      MaterialApp(
        home: FeatureSettingsScope(
          preferences: prefs,
          draftStore: MessageDraftStore(),
          child: MediaSettingsPage(
            backend: PreviewBackend(),
            palette: palette,
            preferences: prefs,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final previews = find.byKey(const ValueKey('media.link_previews'));
    final encrypted = find.byKey(
      const ValueKey('media.link_previews_encrypted'),
    );
    await tester.scrollUntilVisible(
      previews,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(encrypted);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(previews).value, isTrue);
    expect(tester.widget<SwitchListTile>(encrypted).value, isFalse);

    await tester.tap(encrypted);
    await tester.pumpAndSettle();
    expect(prefs.linkPreviewsInEncryptedRooms, isTrue);

    // Turning previews off disables the encrypted opt-in too.
    await tester.ensureVisible(previews);
    await tester.pumpAndSettle();
    await tester.tap(previews);
    await tester.pumpAndSettle();
    expect(prefs.linkPreviews, isFalse);
    expect(tester.widget<SwitchListTile>(encrypted).onChanged, isNull);
  });
}

class _PlainBackend extends ChatBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

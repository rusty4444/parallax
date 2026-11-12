// Visual QA for the rich timeline. Skipped unless PARALLAX_SCREENSHOT_DIR is
// set:  PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/rich_timeline_visual_test.dart
// Not a golden test: nothing is asserted on pixels.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/rich_timeline/rich_timeline_features.dart';
import 'package:parallax/timeline/timeline_view.dart';

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
const _me = '@sam:example.org';

class _Backend extends ChatBackend implements RichTimelineFeatures {
  @override
  String? get userId => _me;
  @override
  bool get canLoadOlder => true;
  @override
  bool get loadingHistory => false;
  @override
  Future<Uint8List?> loadAvatar(Uri url) async => null;
  @override
  Map<String, List<ReceiptReader>> latestReceipts(
    String roomId, {
    Set<String>? eventIds,
  }) => {
    r'$6': const [
      ReceiptReader(userId: '@mia:example.org', name: 'Mia'),
      ReceiptReader(userId: '@alex:example.org', name: 'Alex'),
    ],
  };
  @override
  MemberProfile? member(String roomId, String userId) => switch (userId) {
    '@mia:example.org' => const MemberProfile(
      userId: '@mia:example.org',
      displayName: 'Mia',
    ),
    _ => null,
  };
  @override
  List<MemberProfile> searchMembers(
    String roomId,
    String query, {
    int limit = 8,
  }) => const [];
  @override
  bool canMentionRoom(String roomId) => true;
  @override
  List<String> viaServers(String roomId) => const [];
  @override
  PreviousState? cachedPreviousState(String roomId, String eventId) =>
      const PreviousState(null);
  @override
  Future<PreviousState?> previousState(String roomId, String eventId) async =>
      const PreviousState(null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatEntry _entry(
  String id,
  String sender,
  String body, {
  required DateTime time,
  String? formatted,
  EntryKind kind = EntryKind.text,
  String type = 'm.room.message',
  Map<String, Object?> content = const {},
  String? name,
  bool highlight = false,
  bool edited = false,
}) => ChatEntry(
  id: id,
  sender: sender,
  body: body,
  time: time,
  mine: sender == _me,
  formattedBody: formatted,
  kind: kind,
  eventType: type,
  content: content,
  stateKey: kind == EntryKind.state ? sender : null,
  senderName: name,
  highlight: highlight,
  edited: edited,
);

void main() {
  final skip = _dir == null;
  setUpAll(() async {
    if (_dir == null) return;
    Directory(_dir!).createSync(recursive: true);
    final grotesk = FontLoader('SpaceGrotesk')
      ..addFont(
        File(
          'assets/fonts/SpaceGrotesk.ttf',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await grotesk.load();
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root != null) {
      final icons = File(
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (icons.existsSync()) {
        final loader = FontLoader('MaterialIcons')
          ..addFont(icons.readAsBytes().then((b) => ByteData.sublistView(b)));
        await loader.load();
      }
    }
  });

  for (final style in [VisualTheme.parallax, VisualTheme.parallaxDay]) {
    testWidgets('rich timeline ${style.name}', skip: skip, (tester) async {
      final p = paletteFor(style);
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final entries = [
        _entry(
          r'$s1',
          '@mia:example.org',
          'Mia joined',
          time: yesterday,
          kind: EntryKind.state,
          type: 'm.room.member',
          content: const {'membership': 'join'},
          name: 'Mia',
        ),
        _entry(
          r'$s2',
          '@alex:example.org',
          'Alex joined',
          time: yesterday,
          kind: EntryKind.state,
          type: 'm.room.member',
          content: const {'membership': 'join'},
          name: 'Alex',
        ),
        _entry(
          r'$1',
          '@alex:example.org',
          'Who is around this weekend?',
          time: now.subtract(const Duration(minutes: 30)),
          name: 'Alex',
        ),
        _entry(
          r'$2',
          '@alex:example.org',
          'Plan',
          time: now.subtract(const Duration(minutes: 29)),
          name: 'Alex',
          formatted:
              '<p><strong>Plan</strong> for <em>Saturday</em>:</p>'
              '<ul><li>Pier at 6</li><li>Dinner after</li></ul>'
              '<pre><code>meet --at pier --time 18:00 --bring camera</code></pre>',
          edited: true,
        ),
        _entry(
          r'$3',
          '@mia:example.org',
          'hey',
          time: now.subtract(const Duration(minutes: 10)),
          name: 'Mia',
          highlight: true,
          formatted:
              '<a href="https://matrix.to/#/@sam:example.org">Sam</a> can you '
              'bring the <a href="https://example.org/camera">camera</a>?'
              '<blockquote>Sunset is 7:42</blockquote>',
        ),
        _entry(
          r'$4',
          '@mia:example.org',
          'stretches',
          time: now.subtract(const Duration(minutes: 9)),
          name: 'Mia',
          kind: EntryKind.emote,
        ),
        _entry(
          r'$5',
          '@alex:example.org',
          '🔒',
          time: now.subtract(const Duration(minutes: 5)),
          name: 'Alex',
          kind: EntryKind.undecryptable,
        ),
        _entry(r'$6', _me, 'Absolutely — see https://parallax.chat', time: now),
      ];
      final key = GlobalKey();
      tester.view.physicalSize = const Size(1080, 2280);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(style),
            home: Scaffold(
              body: GlowBackdrop(
                palette: p,
                child: SafeArea(
                  child: TimelineView(
                    backend: _Backend(),
                    roomId: '!a:example.org',
                    palette: p,
                    entries: entries,
                    compact: false,
                    onHeart: (_) {},
                    onAction: (_) {},
                    onReaction: (_, _) {},
                    onLoadOlder: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$_dir/rich_timeline_${style.name}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    });
  }
}

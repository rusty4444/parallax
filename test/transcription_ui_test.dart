import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/transcription/transcription.dart';
import 'package:parallax/features/transcription/transcription_hooks.dart';
import 'package:parallax/features/transcription/transcripts.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeBackend, FakeBackgroundStore;

const _me = '@me:example.org';
const _voiceId = r'$voice';

class _AudioBackend extends FakeBackend {
  final loads = <String>[];

  @override
  Future<DownloadedAttachment> loadAttachment(
    String roomId,
    String eventId,
  ) async {
    loads.add(eventId);
    return DownloadedAttachment(
      name: 'voice.ogg',
      mimeType: 'audio/ogg',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
  }
}

class _Engine implements TranscriptionEngine {
  _Engine({this.available = true});
  final bool available;
  final requests = <DownloadedAttachment>[];
  Completer<String>? pending;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String> transcribe(DownloadedAttachment audio) {
    requests.add(audio);
    return (pending = Completer<String>()).future;
  }
}

class _Store implements TranscriptStore {
  final saved = <String, String>{};
  @override
  Future<String?> read(String accountKey, String eventId) async =>
      saved['$accountKey|$eventId'];
  @override
  Future<void> write(String accountKey, String eventId, String text) async {
    saved['$accountKey|$eventId'] = text;
  }
}

ChatEntry _voice({EntryKind kind = EntryKind.voice}) => ChatEntry(
  id: _voiceId,
  sender: '@friend:example.org',
  senderName: 'Friend',
  body: 'Voice message',
  time: DateTime(2026, 1, 1, 10),
  mine: false,
  kind: kind,
  msgtype: 'm.audio',
  isAttachment: true,
  content: {
    'msgtype': 'm.audio',
    'body': 'Voice message',
    if (kind == EntryKind.voice) 'org.matrix.msc3245.voice': {},
    'info': {'mimetype': 'audio/ogg', 'duration': 4000},
  },
);

void main() {
  late _Engine engine;
  late _Store store;
  final original = Transcripts.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    engine = _Engine();
    store = _Store();
    Transcripts.instance = Transcripts(engine: engine, store: store);
  });

  tearDown(() => Transcripts.instance = original);

  Future<_AudioBackend> pumpRoom(
    WidgetTester tester, {
    EntryKind kind = EntryKind.voice,
  }) async {
    final backend = _AudioBackend()
      ..currentUserId = _me
      ..entries = [_voice(kind: kind)];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return backend;
  }

  /// Taps inside a bubble wait out the double-tap window.
  Future<void> tapIn(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final kind in [EntryKind.voice, EntryKind.audio]) {
    testWidgets('${kind.name}: Transcribe adds the transcript to the bubble '
        'and saves it', (tester) async {
      final backend = await pumpRoom(tester, kind: kind);
      final button = find.byTooltip('Transcribe');
      expect(button, findsOneWidget);

      await tapIn(tester, button);
      expect(backend.loads, [_voiceId]);
      expect(engine.requests, hasLength(1));
      expect(find.text('Transcribing…'), findsOneWidget);
      expect(find.byTooltip('Transcribe'), findsNothing);

      engine.pending!.complete('  See you at ten tomorrow.  ');
      await tester.pumpAndSettle();
      final transcript = find.text('See you at ten tomorrow.');
      expect(transcript, findsOneWidget);
      expect(find.text('Transcribing…'), findsNothing);
      expect(find.byTooltip('Transcribe'), findsNothing);
      // Inside the message's own bubble, below its player.
      final bubble = tester.getRect(
        find
            .ancestor(of: transcript, matching: find.byType(DecoratedBox))
            .first,
      );
      expect(bubble.contains(tester.getCenter(transcript)), isTrue);
      expect(
        tester.getTopLeft(transcript).dy,
        greaterThan(tester.getBottomLeft(find.byTooltip('Play')).dy),
      );
      expect(store.saved, {'$_me|$_voiceId': 'See you at ten tomorrow.'});
    });
  }

  testWidgets('a saved transcript shows when the chat opens again', (
    tester,
  ) async {
    store.saved['$_me|$_voiceId'] = 'Saved earlier.';
    await pumpRoom(tester);
    expect(find.text('Saved earlier.'), findsOneWidget);
    expect(find.byTooltip('Transcribe'), findsNothing);
    expect(engine.requests, isEmpty);
  });

  testWidgets('a failure says why and leaves the button to try again', (
    tester,
  ) async {
    await pumpRoom(tester);
    await tapIn(tester, find.byTooltip('Transcribe'));
    engine.pending!.completeError(
      const TranscriptionUnavailable('No speech was recognised.'),
    );
    await tester.pumpAndSettle();
    expect(find.text('No speech was recognised.'), findsOneWidget);
    expect(find.byTooltip('Transcribe'), findsOneWidget);
    expect(store.saved, isEmpty);

    await tapIn(tester, find.byTooltip('Transcribe'));
    engine.pending!.complete('Second time lucky.');
    await tester.pumpAndSettle();
    expect(find.text('Second time lucky.'), findsOneWidget);
    expect(find.text('No speech was recognised.'), findsNothing);
  });

  testWidgets('no button where this device cannot transcribe', (tester) async {
    Transcripts.instance = Transcripts(
      engine: _Engine(available: false),
      store: store,
    );
    await pumpRoom(tester);
    expect(find.byTooltip('Transcribe'), findsNothing);
    expect(find.byTooltip('Play'), findsOneWidget);
  });

  testWidgets('long-press Transcribe uses the same in-bubble transcript', (
    tester,
  ) async {
    final backend = await pumpRoom(tester);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final ctx = EntryHookContext(
      backend: backend,
      roomId: '!r:example.org',
      palette: paletteFor(VisualTheme.parallax),
      entry: _voice(),
    );
    final actions = transcriptionMessageActions(context, ctx);
    expect(actions.map((a) => a.label), ['Transcribe']);
    unawaited(Future<void>.sync(() => actions.single.onSelected(context)));
    await tester.pump();
    expect(engine.requests, hasLength(1));
    engine.pending!.complete('From the menu.');
    await tester.pumpAndSettle();
    expect(
      Transcripts.instance.stateFor(backend, _voiceId).text,
      'From the menu.',
    );
    // Once transcribed, the action goes away.
    expect(transcriptionMessageActions(context, ctx), isEmpty);
  });
}

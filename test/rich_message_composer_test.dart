import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/rich_message_composer.dart';
import 'package:parallax/voice_recorder.dart';

MediaSelection attachment(String name, {int size = 3}) => MediaSelection(
  bytes: Uint8List(size),
  name: name,
  mimeType: 'application/pdf',
);

class FakeVoiceRecorder implements VoiceRecorder {
  int permissions = 0;
  int starts = 0;
  int stops = 0;
  int discards = 0;
  int disposals = 0;
  int plays = 0;
  bool permission = true;
  Completer<bool>? permissionGate;
  Completer<void>? startGate;
  Completer<MediaSelection>? stopGate;
  Completer<void>? discardGate;
  Completer<void>? playGate;
  Object? startError;
  Object? stopError;
  final changes = StreamController<bool>.broadcast();

  @override
  Stream<bool> get playbackChanges => changes.stream;
  @override
  Future<bool> requestPermission() async {
    permissions++;
    return permissionGate == null ? permission : permissionGate!.future;
  }

  @override
  Future<void> start() async {
    starts++;
    await startGate?.future;
    if (startError != null) throw startError!;
  }

  @override
  Future<MediaSelection> stop() async {
    stops++;
    if (stopError != null) throw stopError!;
    return stopGate == null
        ? MediaSelection(
            bytes: Uint8List.fromList([1, 2, 3]),
            name: 'voice.m4a',
            mimeType: 'audio/mp4',
            durationMs: 2100,
          )
        : stopGate!.future;
  }

  @override
  Future<void> discard() async {
    discards++;
    await discardGate?.future;
    changes.add(false);
  }

  @override
  Future<void> playPreview(MediaSelection media) async {
    plays++;
    await playGate?.future;
    changes.add(true);
  }

  @override
  Future<void> stopPreview() async {
    changes.add(false);
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await stopPreview();
    await changes.close();
  }
}

Future<void> mount(
  WidgetTester tester, {
  required TextEditingController controller,
  required Future<void> Function(String, MediaSelection?) onSend,
  MediaPicker? pickGallery,
  MediaPicker? pickCamera,
  MediaPicker? pickVideo,
  MediaPicker? pickFile,
  VoiceRecorder? recorder,
  ValueChanged<String>? onChanged,
  VoidCallback? onCancel,
  bool sending = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: RichMessageComposer(
          controller: controller,
          sending: sending,
          onSend: onSend,
          onChanged: onChanged,
          onCancel: onCancel,
          pickGallery: pickGallery,
          pickCamera: pickCamera,
          pickVideo: pickVideo,
          pickFile: pickFile,
          recorder: recorder,
        ),
      ),
    ),
  ),
);

Future<void> choose(
  WidgetTester tester,
  String source, {
  bool replace = false,
}) async {
  await tester.tap(
    find.byTooltip(replace ? 'Replace attachment' : 'Attach media'),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(source));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void insert(WidgetTester tester, {String mime = 'image/gif', Uint8List? data}) {
  tester
      .widget<TextField>(find.byType(TextField))
      .contentInsertionConfiguration!
      .onContentInserted(
        KeyboardInsertedContent(
          mimeType: mime,
          uri: 'content://keyboard/item',
          data: data,
        ),
      );
}

IconButton button(WidgetTester tester, String tooltip) =>
    tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == tooltip,
      ),
    );

Future<void> flushCleanup(WidgetTester tester) async {
  // StreamSubscription.cancel may complete in the root zone, outside fake async.
  await tester.runAsync(() async {
    await Future<void>.value();
  });
  await tester.pump();
}

void main() {
  testWidgets('Record video attaches the recorded clip', (tester) async {
    final clip = MediaSelection(
      bytes: Uint8List.fromList(List.filled(64, 1)),
      name: 'clip.mp4',
      mimeType: 'video/mp4',
      durationMs: 3000,
    );
    MediaSelection? sent;
    await mount(
      tester,
      controller: TextEditingController(),
      onSend: (_, media) async => sent = media,
      pickVideo: () async => clip,
    );
    await choose(tester, 'Record video');
    expect(find.text('clip.mp4'), findsWidgets);
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(sent, same(clip));
  });

  testWidgets('message box sits above the composer buttons at full width', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(412, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final haptics = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
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
    final controller = TextEditingController(text: 'hi');
    var sent = 0;
    await mount(
      tester,
      controller: controller,
      onSend: (_, _) async {
        sent++;
      },
      onCancel: () {},
    );
    final field = tester.getRect(find.byType(TextField));
    for (final tip in [
      'Attach media',
      'Text formatting',
      'Emoji',
      'Record voice message',
      'Cancel',
    ]) {
      expect(
        tester.getRect(find.byTooltip(tip)).top,
        greaterThanOrEqualTo(field.bottom),
        reason: tip,
      );
    }
    // Only Send shares the message box's row.
    expect(field.width, greaterThan(412 * 0.75));
    expect(
      tester.getCenter(find.byTooltip('Send message')).dy,
      closeTo(field.center.dy, field.height / 2),
    );
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(sent, 1);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
  });

  testWidgets('rapid send taps own one request synchronously', (tester) async {
    final controller = TextEditingController(text: 'hello');
    final gate = Completer<void>();
    var calls = 0;
    await mount(
      tester,
      controller: controller,
      onSend: (text, media) {
        calls++;
        expect(text, 'hello');
        return gate.future;
      },
    );
    final send = button(tester, 'Send message');
    send.onPressed!();
    send.onPressed!();
    expect(calls, 1);
    gate.complete();
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
  });

  testWidgets('failed send retains caption and attachment for retry', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'caption');
    var calls = 0;
    await mount(
      tester,
      controller: controller,
      pickFile: () async => attachment('notes.pdf'),
      onSend: (text, media) async {
        expect(text, 'caption');
        expect(media!.name, 'notes.pdf');
        if (calls++ == 0) throw StateError('offline');
      },
    );
    await choose(tester, 'File');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(controller.text, 'caption');
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.textContaining('Could not send'), findsOneWidget);
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(controller.text, isEmpty);
    expect(find.text('notes.pdf'), findsNothing);
  });

  testWidgets('successful old send never clears newer text or media', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'old caption');
    final gate = Completer<void>();
    var picks = 0;
    await mount(
      tester,
      controller: controller,
      pickFile: () async => attachment(picks++ == 0 ? 'old.pdf' : 'new.pdf'),
      onSend: (_, _) => gate.future,
    );
    await choose(tester, 'File');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'new caption');
    await choose(tester, 'File', replace: true);
    gate.complete();
    await tester.pumpAndSettle();
    expect(controller.text, 'new caption');
    expect(find.text('new.pdf'), findsOneWidget);
  });

  testWidgets('editing back to same text is still a newer draft', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'same');
    final gate = Completer<void>();
    await mount(tester, controller: controller, onSend: (_, _) => gate.future);
    await tester.tap(find.byTooltip('Send message'));
    controller.text = 'different';
    controller.text = 'same';
    gate.complete();
    await tester.pumpAndSettle();
    expect(controller.text, 'same');
  });

  testWidgets(
    'picker is single-flight and keyboard replacement beats stale result',
    (tester) async {
      final controller = TextEditingController();
      final gate = Completer<MediaSelection?>();
      var calls = 0;
      await mount(
        tester,
        controller: controller,
        onSend: (_, _) async {},
        pickFile: () {
          calls++;
          return gate.future;
        },
      );
      await choose(tester, 'File');
      expect(calls, 1);
      insert(tester, data: Uint8List.fromList([1, 2, 3]));
      await tester.pump();
      gate.complete(attachment('stale.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('stale.pdf'), findsNothing);
      expect(find.text('keyboard.gif'), findsOneWidget);
    },
  );

  testWidgets('dismissed picker does not replace existing attachment', (
    tester,
  ) async {
    var picks = 0;
    await mount(
      tester,
      controller: TextEditingController(),
      onSend: (_, _) async {},
      pickGallery: () async => picks++ == 0 ? attachment('photo.jpg') : null,
    );
    await choose(tester, 'Photo or video');
    await choose(tester, 'Photo or video', replace: true);
    expect(find.text('photo.jpg'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pumpAndSettle();
    expect(find.text('photo.jpg'), findsNothing);
  });

  testWidgets(
    'camera stages a captionable attachment and picker errors are visible',
    (tester) async {
      final controller = TextEditingController();
      await mount(
        tester,
        controller: controller,
        onSend: (_, _) async {},
        pickCamera: () async => attachment('camera.jpg'),
        pickFile: () async => throw StateError('permission denied'),
      );
      await choose(tester, 'Take photo');
      expect(find.text('camera.jpg'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
        'Add a caption…',
      );
      await choose(tester, 'File', replace: true);
      expect(find.textContaining('Could not open'), findsOneWidget);
      expect(find.text('camera.jpg'), findsOneWidget);
    },
  );

  testWidgets(
    'keyboard accepts image bytes and rejects empty, unsupported, oversized content',
    (tester) async {
      MediaSelection? sent;
      await mount(
        tester,
        controller: TextEditingController(),
        onSend: (_, media) async {
          sent = media;
        },
      );
      final config = tester
          .widget<TextField>(find.byType(TextField))
          .contentInsertionConfiguration!;
      expect(config.allowedMimeTypes, contains('image/*'));
      insert(tester);
      await tester.pump();
      expect(find.textContaining('did not provide'), findsOneWidget);
      insert(tester, mime: 'text/html', data: Uint8List(1));
      await tester.pump();
      expect(find.textContaining('Only images'), findsOneWidget);
      insert(tester, data: Uint8List(RichMessageComposer.maxMediaBytes + 1));
      await tester.pump();
      expect(find.textContaining('20 MB'), findsOneWidget);
      insert(tester, mime: 'image/webp', data: Uint8List.fromList([1, 2, 3]));
      await tester.pumpAndSettle();
      expect(find.text('keyboard.webp'), findsOneWidget);
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(sent!.mimeType, 'image/webp');
      expect(sent!.bytes, [1, 2, 3]);
    },
  );

  testWidgets('selection bounds include exactly 20 MB and reject empty files', (
    tester,
  ) async {
    var picks = 0;
    await mount(
      tester,
      controller: TextEditingController(),
      onSend: (_, _) async {},
      pickFile: () async => attachment(
        'bounded.pdf',
        size: picks++ == 0 ? 0 : RichMessageComposer.maxMediaBytes,
      ),
    );
    await choose(tester, 'File');
    expect(find.textContaining('empty'), findsOneWidget);
    await choose(tester, 'File');
    expect(find.text('bounded.pdf'), findsOneWidget);
  });

  testWidgets('emoji replaces selected range and notifies draft owner', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'hi replace there');
    final changes = <String>[];
    await mount(
      tester,
      controller: controller,
      onChanged: changes.add,
      onSend: (_, _) async {},
    );
    controller.selection = const TextSelection(baseOffset: 3, extentOffset: 10);
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('emoji-👍')));
    await tester.pumpAndSettle();
    expect(controller.text, 'hi 👍 there');
    expect(controller.selection.baseOffset, 5);
    expect(changes.last, 'hi 👍 there');
  });

  testWidgets('voice asks permission only on tap and handles denial', (
    tester,
  ) async {
    final recorder = FakeVoiceRecorder()..permission = false;
    await mount(
      tester,
      controller: TextEditingController(),
      recorder: recorder,
      onSend: (_, _) async {},
    );
    expect(recorder.permissions, 0);
    await tester.tap(find.byTooltip('Record voice message'));
    await tester.pumpAndSettle();
    expect(recorder.permissions, 1);
    expect(recorder.starts, 0);
    expect(find.textContaining('Microphone permission'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await flushCleanup(tester);
    expect(recorder.disposals, 1);
  });

  testWidgets(
    'record start and stop are single-flight; preview, failed send, discard work',
    (tester) async {
      final recorder = FakeVoiceRecorder()..startGate = Completer<void>();
      final controller = TextEditingController();
      await mount(
        tester,
        controller: controller,
        recorder: recorder,
        onSend: (_, _) async => throw StateError('offline'),
      );
      final mic = button(tester, 'Record voice message');
      mic.onPressed!();
      mic.onPressed!();
      await tester.pump();
      expect(recorder.starts, 1);
      recorder.startGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('0:02'), findsOneWidget);
      recorder.stopGate = Completer<MediaSelection>();
      final stop = button(tester, 'Stop recording');
      stop.onPressed!();
      stop.onPressed!();
      await tester.pump();
      expect(recorder.stops, 1);
      recorder.stopGate!.complete(
        MediaSelection(
          bytes: Uint8List(3),
          name: 'voice.m4a',
          mimeType: 'audio/mp4',
          durationMs: 2000,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play voice preview'));
      await tester.pumpAndSettle();
      expect(recorder.plays, 1);
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(find.text('voice.m4a'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove attachment'));
      await tester.pumpAndSettle();
      expect(recorder.discards, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'background joins in-flight start before discard and rejects late recording',
    (tester) async {
      final recorder = FakeVoiceRecorder()..startGate = Completer<void>();
      await mount(
        tester,
        controller: TextEditingController(),
        recorder: recorder,
        onSend: (_, _) async {},
      );
      await tester.tap(find.byTooltip('Record voice message'));
      await tester.pump();
      expect(recorder.starts, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(recorder.discards, 0);
      recorder.startGate!.complete();
      await tester.pumpAndSettle();
      expect(recorder.discards, 1);
      expect(find.byTooltip('Stop recording'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'dispose joins late stop then cleans recorder without publishing media',
    (tester) async {
      final recorder = FakeVoiceRecorder();
      await mount(
        tester,
        controller: TextEditingController(),
        recorder: recorder,
        onSend: (_, _) async {},
      );
      await tester.tap(find.byTooltip('Record voice message'));
      await tester.pump();
      recorder.stopGate = Completer<MediaSelection>();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await flushCleanup(tester);
      expect(recorder.disposals, 0);
      recorder.stopGate!.complete(attachment('late.m4a'));
      await tester.pumpAndSettle();
      await flushCleanup(tester);
      expect(recorder.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dispose while requesting permission never starts recorder', (
    tester,
  ) async {
    final recorder = FakeVoiceRecorder()..permissionGate = Completer<bool>();
    await mount(
      tester,
      controller: TextEditingController(),
      recorder: recorder,
      onSend: (_, _) async {},
    );
    await tester.tap(find.byTooltip('Record voice message'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    recorder.permissionGate!.complete(true);
    await tester.pumpAndSettle();
    expect(recorder.starts, 0);
    await flushCleanup(tester);
    expect(recorder.disposals, 1);
  });

  testWidgets('source modal and choice callbacks reject rapid duplicate taps', (
    tester,
  ) async {
    var picks = 0;
    final gate = Completer<MediaSelection?>();
    await mount(
      tester,
      controller: TextEditingController(),
      onSend: (_, _) async {},
      pickFile: () {
        picks++;
        return gate.future;
      },
    );
    final attach = button(tester, 'Attach media').onPressed!;
    attach();
    attach();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Photo or video'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('File'), matching: find.byType(ListTile)),
    );
    tile.onTap!();
    tile.onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(picks, 1);
    expect(button(tester, 'Attach media').onPressed, isNull);
    gate.complete(attachment('one.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('one.pdf'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale picker error cannot replace a newer keyboard selection', (
    tester,
  ) async {
    final gate = Completer<MediaSelection?>();
    await mount(
      tester,
      controller: TextEditingController(),
      onSend: (_, _) async {},
      pickFile: () => gate.future,
    );
    await choose(tester, 'File');
    insert(tester, data: Uint8List(3));
    await tester.pump();
    gate.completeError(StateError('obsolete permission failure'));
    await tester.pumpAndSettle();
    expect(find.textContaining('obsolete permission failure'), findsNothing);
    expect(find.text('keyboard.gif'), findsOneWidget);
  });

  testWidgets('removing a preview invalidates a pending replacement picker', (
    tester,
  ) async {
    var picks = 0;
    final gate = Completer<MediaSelection?>();
    await mount(
      tester,
      controller: TextEditingController(),
      onSend: (_, _) async {},
      pickFile: () =>
          picks++ == 0 ? Future.value(attachment('old.pdf')) : gate.future,
    );
    await choose(tester, 'File');
    await choose(tester, 'File', replace: true);
    await tester.tap(find.byTooltip('Remove attachment'));
    gate.complete(attachment('late.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('late.pdf'), findsNothing);
    expect(find.text('old.pdf'), findsNothing);
  });

  testWidgets('late picker completion after close cannot publish', (
    tester,
  ) async {
    final gate = Completer<MediaSelection?>();
    await mount(
      tester,
      controller: TextEditingController(),
      onSend: (_, _) async {},
      pickFile: () => gate.future,
    );
    await choose(tester, 'File');
    await tester.pumpWidget(const SizedBox());
    gate.complete(attachment('late.pdf'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('external sending disables send without freezing draft input', (
    tester,
  ) async {
    var sends = 0;
    final controller = TextEditingController(text: 'draft');
    await mount(
      tester,
      controller: controller,
      sending: true,
      onSend: (_, _) async {
        sends++;
      },
    );
    expect(button(tester, 'Send message').onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'new draft');
    expect(controller.text, 'new draft');
    expect(sends, 0);
  });

  testWidgets('late success preserves replaced caller-owned controller', (
    tester,
  ) async {
    final old = TextEditingController(text: 'sent');
    final next = TextEditingController(text: 'replacement draft');
    final gate = Completer<void>();
    Future<void> send(String _, MediaSelection? _) => gate.future;
    await mount(tester, controller: old, onSend: send);
    await tester.tap(find.byTooltip('Send message'));
    await mount(tester, controller: next, onSend: send);
    gate.complete();
    await tester.pumpAndSettle();
    expect(next.text, 'replacement draft');
    expect(old.text, 'sent');
    // The widget never disposes a controller owned by its caller.
    old.text = 'still usable';
  });

  testWidgets(
    'cancel before queued permission work prevents a microphone prompt',
    (tester) async {
      final recorder = FakeVoiceRecorder();
      var cancelled = 0;
      await mount(
        tester,
        controller: TextEditingController(),
        recorder: recorder,
        onCancel: () {
          cancelled++;
        },
        onSend: (_, _) async {},
      );
      button(tester, 'Record voice message').onPressed!();
      button(tester, 'Cancel').onPressed!();
      await tester.pumpAndSettle();
      expect(cancelled, 1);
      expect(recorder.permissions, 0);
      expect(recorder.starts, 0);
      expect(recorder.discards, 1);
      await tester.pumpWidget(const SizedBox());
      await flushCleanup(tester);
    },
  );

  testWidgets(
    'rapid discard is single-flight and retry waits for joined cleanup',
    (tester) async {
      final recorder = FakeVoiceRecorder()..discardGate = Completer<void>();
      await mount(
        tester,
        controller: TextEditingController(),
        recorder: recorder,
        onSend: (_, _) async {},
      );
      await tester.tap(find.byTooltip('Record voice message'));
      await tester.pump();
      final discard = button(tester, 'Discard recording').onPressed!;
      discard();
      discard();
      await tester.pump();
      expect(recorder.discards, 1);
      expect(find.byTooltip('Record voice message'), findsNothing);
      recorder.discardGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Record voice message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await flushCleanup(tester);
    },
  );

  testWidgets(
    'recording start and stop errors are visible and cleaned before retry',
    (tester) async {
      final recorder = FakeVoiceRecorder()
        ..startError = StateError('unavailable');
      await mount(
        tester,
        controller: TextEditingController(),
        recorder: recorder,
        onSend: (_, _) async {},
      );
      await tester.tap(find.byTooltip('Record voice message'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not record voice'), findsOneWidget);
      expect(recorder.discards, 1);
      recorder.startError = null;
      recorder.stopError = StateError('no audio');
      await tester.tap(find.byTooltip('Record voice message'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not finish voice recording'),
        findsOneWidget,
      );
      expect(recorder.discards, 2);
      expect(find.byTooltip('Record voice message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await flushCleanup(tester);
    },
  );

  testWidgets(
    'background joins a pending preview before discarding voice bytes',
    (tester) async {
      final recorder = FakeVoiceRecorder()..playGate = Completer<void>();
      await mount(
        tester,
        controller: TextEditingController(),
        recorder: recorder,
        onSend: (_, _) async {},
      );
      await tester.tap(find.byTooltip('Record voice message'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play voice preview'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(find.text('voice.m4a'), findsNothing);
      expect(recorder.discards, 0);
      recorder.playGate!.complete();
      await tester.pumpAndSettle();
      expect(recorder.discards, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await flushCleanup(tester);
    },
  );

  testWidgets('disposal releases the recorder without joining a text send', (
    tester,
  ) async {
    final recorder = FakeVoiceRecorder();
    final controller = TextEditingController(text: 'keep this draft');
    final gate = Completer<void>();
    await mount(
      tester,
      controller: controller,
      recorder: recorder,
      onSend: (_, _) => gate.future,
    );
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpWidget(const SizedBox());
    await flushCleanup(tester);
    expect(recorder.disposals, 1);
    gate.complete();
    await tester.pump();
    await flushCleanup(tester);
    expect(recorder.disposals, 1);
    expect(controller.text, 'keep this draft');
  });

  for (final failSend in [false, true]) {
    testWidgets(
      'disposal stops voice preview before pending send ${failSend ? 'fails' : 'succeeds'}',
      (tester) async {
        final recorder = FakeVoiceRecorder();
        final controller = TextEditingController(text: 'keep this caption');
        final sendGate = Completer<void>();
        final playbackEvents = <bool>[];
        final subscription = recorder.playbackChanges.listen(
          playbackEvents.add,
        );
        final draftChanges = <String>[];
        MediaSelection? sent;
        List<int>? deliveredBytes;
        await mount(
          tester,
          controller: controller,
          recorder: recorder,
          onChanged: draftChanges.add,
          onSend: (_, media) async {
            sent = media;
            await sendGate.future;
            // A late sender can still use its bytes after all native/file
            // cleanup. No recorder-owned path is part of the send contract.
            deliveredBytes = media!.bytes.toList();
          },
        );
        await tester.tap(find.byTooltip('Record voice message'));
        await tester.pump();
        await tester.tap(find.byTooltip('Stop recording'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Play voice preview'));
        await tester.pumpAndSettle();
        expect(playbackEvents.last, isTrue);
        await tester.tap(find.byTooltip('Send message'));
        await tester.pump();
        expect(sent!.bytes, [1, 2, 3]);
        await tester.pumpWidget(const SizedBox());
        await flushCleanup(tester);

        // Do not settle the network gate to make teardown appear successful.
        expect(sendGate.isCompleted, isFalse);
        expect(playbackEvents.last, isFalse);
        expect(recorder.disposals, 1);
        final discardsBeforeSend = recorder.discards;
        if (failSend) {
          sendGate.completeError(StateError('late offline failure'));
        } else {
          sendGate.complete();
        }
        await tester.pump();
        await flushCleanup(tester);
        expect(recorder.disposals, 1);
        expect(recorder.discards, discardsBeforeSend);
        expect(playbackEvents.last, isFalse);
        expect(controller.text, 'keep this caption');
        expect(draftChanges, isEmpty);
        expect(deliveredBytes, failSend ? isNull : [1, 2, 3]);
        expect(find.textContaining('Could not send'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.runAsync(subscription.cancel);
        controller.dispose();
      },
    );
  }

  for (final failStart in [false, true]) {
    testWidgets(
      'disposal joins microphone acquisition before ${failStart ? 'late failure' : 'late success'} cleanup',
      (tester) async {
        final recorder = FakeVoiceRecorder()..startGate = Completer<void>();
        await mount(
          tester,
          controller: TextEditingController(),
          recorder: recorder,
          onSend: (_, _) async {},
        );
        final mic = button(tester, 'Record voice message').onPressed!;
        mic();
        await tester.pump();
        expect(recorder.starts, 1);
        await tester.pumpWidget(const SizedBox());
        // A retained callback is also invalidated synchronously by dispose.
        mic();
        await flushCleanup(tester);
        expect(recorder.discards, 0);
        expect(recorder.disposals, 0);
        if (failStart) {
          recorder.startGate!.completeError(StateError('late native failure'));
        } else {
          recorder.startGate!.complete();
        }
        await tester.pump();
        await flushCleanup(tester);
        expect(recorder.starts, 1);
        expect(recorder.discards, failStart ? 1 : 0);
        expect(recorder.disposals, 1);
        expect(find.byTooltip('Stop recording'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('voice cleanup joins pending preview but not pending send', (
    tester,
  ) async {
    final recorder = FakeVoiceRecorder()..playGate = Completer<void>();
    final sendGate = Completer<void>();
    final playbackEvents = <bool>[];
    final subscription = recorder.playbackChanges.listen(playbackEvents.add);
    await mount(
      tester,
      controller: TextEditingController(),
      recorder: recorder,
      onSend: (_, _) => sendGate.future,
    );
    await tester.tap(find.byTooltip('Record voice message'));
    await tester.pump();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play voice preview'));
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpWidget(const SizedBox());
    await flushCleanup(tester);
    expect(recorder.disposals, 0);
    recorder.playGate!.complete();
    await tester.pump();
    await flushCleanup(tester);
    expect(sendGate.isCompleted, isFalse);
    expect(playbackEvents, [true, false]);
    expect(recorder.disposals, 1);
    sendGate.complete();
    await tester.pump();
    await flushCleanup(tester);
    expect(recorder.disposals, 1);
    expect(tester.takeException(), isNull);
    await tester.runAsync(subscription.cancel);
  });

  testWidgets('narrow Android composer and voice preview have no overflow', (
    tester,
  ) async {
    tester.view.reset();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    final recorder = FakeVoiceRecorder();
    await mount(
      tester,
      controller: TextEditingController(),
      recorder: recorder,
      onCancel: () {},
      onSend: (_, _) async {},
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Record voice message'));
    await tester.pump();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await flushCleanup(tester);
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/messaging_features.dart';
import 'package:matrixpress/voice_recorder.dart';
import 'package:record/record.dart';

class RecordingPlatform extends RecordPlatform {
  final events = <String>[];
  final started = Completer<void>();
  Completer<void>? startGate;
  Completer<void>? stopGate;
  Completer<void>? stopped;
  Completer<void>? disposalGate;
  Completer<void>? disposing;
  String? path;
  bool failStart = false;
  bool failStop = false;
  bool failDispose = false;
  int size = 4;

  @override
  Future<void> create(String recorderId) async {
    events.add('create');
  }

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    events.add('permission');
    return true;
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();
  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    events.add('start');
    this.path = path;
    await File(path).writeAsBytes(Uint8List(size));
    started.complete();
    await startGate?.future;
    if (failStart) throw StateError('microphone disconnected');
  }

  @override
  Future<String?> stop(String recorderId) async {
    events.add('stop');
    stopped?.complete();
    await stopGate?.future;
    if (failStop) throw StateError('device lost');
    return path;
  }

  @override
  Future<void> cancel(String recorderId) async {
    // NativeVoiceRecorder must not use record 2.1.0's non-joining cancel API.
    throw StateError('cancel is not a join barrier');
  }

  @override
  Future<void> dispose(String recorderId) async {
    events.add('dispose');
    disposing?.complete();
    await disposalGate?.future;
    if (failDispose) throw StateError('recorder release failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Exercise the real AudioPlayer Dart lifecycle against controlled native calls.
/// Filesystem assertions remain real; no sleeps or native plugins are required.
class PreviewPlatform {
  static const methods = MethodChannel('xyz.luan/audioplayers');
  static const global = MethodChannel('xyz.luan/audioplayers.global');
  static const globalEvents = MethodChannel(
    'xyz.luan/audioplayers.global/events',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final eventChannels = <MethodChannel>[];
  final events = <String>[];
  final sourceEntered = Completer<void>();
  final disposalEntered = Completer<void>();
  Completer<void>? sourceGate;
  Completer<void>? disposalGate;
  bool failSource = false;
  bool failDispose = false;
  String? path;

  void install() {
    messenger.setMockMethodCallHandler(global, (_) async => null);
    messenger.setMockMethodCallHandler(globalEvents, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      events.add(call.method);
      final args = call.arguments as Map;
      final playerId = args['playerId'] as String;
      switch (call.method) {
        case 'create':
          final channel = MethodChannel(
            'xyz.luan/audioplayers/events/$playerId',
          );
          eventChannels.add(channel);
          messenger.setMockMethodCallHandler(channel, (_) async => null);
        case 'setSourceUrl':
          path = args['url'] as String;
          expect(args['isLocal'], isTrue);
          expect(await File(path!).exists(), isTrue);
          sourceEntered.complete();
          await messenger.handlePlatformMessage(
            'xyz.luan/audioplayers/events/$playerId',
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'audio.onPrepared',
              'value': true,
            }),
            (_) {},
          );
          await sourceGate?.future;
          if (failSource) throw PlatformException(code: 'source failed');
        case 'dispose':
          // The source must survive until the native release actually joins.
          expect(await File(path!).exists(), isTrue);
          disposalEntered.complete();
          await disposalGate?.future;
          expect(await File(path!).exists(), isTrue);
          if (failDispose) throw PlatformException(code: 'release failed');
        case 'getCurrentPosition' || 'getDuration':
          return 0;
        case 'setVolume' ||
            'setBalance' ||
            'setPlaybackRate' ||
            'resume' ||
            'stop' ||
            'release':
          break;
        default:
          throw StateError('Unexpected preview call: ${call.method}');
      }
      return null;
    });
  }

  void uninstall() {
    for (final channel in [methods, global, globalEvents, ...eventChannels]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bounded stream accepts the exact limit and rejects actual overflow',
    () async {
      final bytes = await readComposerMedia(
        Stream.value(Uint8List(maxComposerMediaBytes)),
        length: 1,
      );
      expect(bytes.length, maxComposerMediaBytes);
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      final result = readComposerMedia(stream.stream, length: 1);
      stream.add(Uint8List(maxComposerMediaBytes));
      stream.add([1]);
      await expectLater(result, throwsFormatException);
      expect(cancelled, isTrue);
      await stream.close();
    },
  );

  test(
    'advertised oversized files never subscribe and empty streams fail',
    () async {
      var listened = false;
      final stream = StreamController<List<int>>(
        onListen: () {
          listened = true;
        },
      );
      await expectLater(
        readComposerMedia(stream.stream, length: maxComposerMediaBytes + 1),
        throwsFormatException,
      );
      expect(listened, isFalse);
      // No listener was created; do not await this single-subscription close.
      unawaited(stream.close());
      await expectLater(
        readComposerMedia(const Stream.empty()),
        throwsFormatException,
      );
    },
  );

  group('native recorder resource ownership', () {
    late RecordPlatform original;
    late RecordingPlatform platform;
    late PreviewPlatform preview;
    late Directory root;
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() async {
      original = RecordPlatform.instance;
      platform = RecordingPlatform();
      RecordPlatform.instance = platform;
      preview = PreviewPlatform()..install();
      final base = Directory(
        Platform.environment['TMPDIR'] ?? '${Directory.current.path}/build',
      );
      await base.create(recursive: true);
      root = await base.createTemp('voice-recorder-test-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getTemporaryDirectory') return root.path;
            throw StateError(
              'Unexpected path provider operation: ${call.method}',
            );
          });
    });
    tearDown(() async {
      RecordPlatform.instance = original;
      preview.uninstall();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'construction is lazy and stop returns bytes before deleting capture directory',
      () async {
        final recorder = NativeVoiceRecorder();
        expect(platform.events, isEmpty);
        expect(await recorder.requestPermission(), isTrue);
        await recorder.start();
        expect(await File(platform.path!).exists(), isTrue);
        final media = await recorder.stop();
        expect(media.bytes, [0, 0, 0, 0]);
        expect(media.mimeType, 'audio/mp4');
        expect(media.durationMs, isNonNegative);
        expect(await root.list().toList(), isEmpty);
        await recorder.dispose();
        expect(platform.events, [
          'create',
          'permission',
          'start',
          'stop',
          'dispose',
        ]);
      },
    );

    test(
      'dispose joins a pending start and a pending native stop before deleting files',
      () async {
        platform.startGate = Completer<void>();
        platform.stopGate = Completer<void>();
        platform.stopped = Completer<void>();
        platform.disposalGate = Completer<void>();
        platform.disposing = Completer<void>();
        final recorder = NativeVoiceRecorder();
        await recorder.requestPermission();
        final starting = recorder.start();
        await platform.started.future;
        final closing = recorder.dispose();
        expect(identical(closing, recorder.dispose()), isTrue);
        await expectLater(recorder.start(), throwsStateError);
        expect(await File(platform.path!).exists(), isTrue);
        expect(platform.events, ['create', 'permission', 'start']);
        platform.startGate!.complete();
        await starting;
        await platform.stopped!.future;
        expect(await File(platform.path!).exists(), isTrue);
        expect(platform.events.last, 'stop');
        platform.stopGate!.complete();
        await platform.disposing!.future;
        expect(await File(platform.path!).exists(), isTrue);
        platform.disposalGate!.complete();
        await closing;
        expect(await root.list().toList(), isEmpty);
        expect(platform.events.last, 'dispose');
      },
    );

    test(
      'discard joins in-flight stop, then cleans exactly one capture directory',
      () async {
        platform.stopGate = Completer<void>();
        platform.stopped = Completer<void>();
        final recorder = NativeVoiceRecorder();
        await recorder.start();
        final stopping = recorder.stop();
        await platform.stopped!.future;
        final discarding = recorder.discard();
        expect(await File(platform.path!).exists(), isTrue);
        platform.stopGate!.complete();
        expect((await stopping).bytes.length, 4);
        await discarding;
        expect(await root.list().toList(), isEmpty);
        expect(platform.events.where((event) => event == 'stop').length, 1);
        await recorder.dispose();
      },
    );

    test(
      'failed start cleans partial file and leaves a usable owner',
      () async {
        platform.failStart = true;
        final recorder = NativeVoiceRecorder();
        await expectLater(recorder.start(), throwsStateError);
        expect(await root.list().toList(), isEmpty);
        expect(platform.events, ['create', 'start', 'stop']);
        await recorder.dispose();
      },
    );

    test(
      'failed stop disposes possibly-writing native recorder before deletion',
      () async {
        platform.failStop = true;
        final recorder = NativeVoiceRecorder();
        await recorder.start();
        await expectLater(recorder.stop(), throwsStateError);
        expect(platform.events, ['create', 'start', 'stop', 'stop', 'dispose']);
        expect(await root.list().toList(), isEmpty);
        await recorder.dispose();
        expect(platform.events.where((event) => event == 'dispose').length, 1);
      },
    );

    test(
      'preview disposal joins native release before deleting its source; bytes survive',
      () async {
        final recorder = NativeVoiceRecorder();
        await recorder.start();
        final media = await recorder.stop();
        final playbackEvents = <bool>[];
        final subscription = recorder.playbackChanges.listen(
          playbackEvents.add,
        );
        final playing = recorder.playbackChanges.firstWhere((value) => value);
        await recorder.playPreview(media);
        await playing;
        preview.disposalGate = Completer<void>();
        final closing = recorder.dispose();
        expect(identical(closing, recorder.dispose()), isTrue);
        await preview.disposalEntered.future;
        expect(await File(preview.path!).exists(), isTrue);
        expect(platform.events.where((event) => event == 'dispose').length, 1);
        preview.disposalGate!.complete();
        await closing;
        expect(playbackEvents.last, isFalse);
        expect(await root.list().toList(), isEmpty);
        expect(media.bytes, [0, 0, 0, 0]);
        await recorder.dispose();
        expect(preview.events.where((event) => event == 'dispose').length, 1);
        expect(platform.events.where((event) => event == 'dispose').length, 1);
        await subscription.cancel();
      },
    );

    for (final failSource in [false, true]) {
      test(
        'dispose joins a pending preview ${failSource ? 'error' : 'success'} before native release',
        () async {
          final recorder = NativeVoiceRecorder();
          preview.sourceGate = Completer<void>();
          preview.failSource = failSource;
          final media = MediaSelection(
            bytes: Uint8List.fromList([1, 2, 3]),
            name: 'voice.m4a',
            mimeType: 'audio/mp4',
          );
          final playing = recorder.playPreview(media);
          // Attach the late failure handler before releasing its gate.
          final played = expectLater(
            playing,
            failSource ? throwsA(isA<PlatformException>()) : completes,
          );
          await preview.sourceEntered.future;
          final closing = recorder.dispose();
          await expectLater(recorder.playPreview(media), throwsStateError);
          expect(preview.events, isNot(contains('dispose')));
          expect(await File(preview.path!).exists(), isTrue);
          preview.sourceGate!.complete();
          await played;
          await closing;
          expect(await root.list().toList(), isEmpty);
          expect(preview.events.where((event) => event == 'dispose').length, 1);
          await recorder.dispose();
          expect(preview.events.where((event) => event == 'dispose').length, 1);
        },
      );
    }

    test(
      'failed player disposal retains the source but still releases the microphone handle',
      () async {
        final recorder = NativeVoiceRecorder();
        await recorder.start();
        final media = await recorder.stop();
        await recorder.playPreview(media);
        preview.failDispose = true;
        final closing = recorder.dispose();
        await expectLater(closing, throwsA(isA<PlatformException>()));
        expect(await File(preview.path!).exists(), isTrue);
        expect(platform.events.where((event) => event == 'dispose').length, 1);
        expect(identical(closing, recorder.dispose()), isTrue);
        expect(preview.events.where((event) => event == 'dispose').length, 1);
      },
    );

    test(
      'failed recorder disposal retains a possibly live capture source',
      () async {
        final recorder = NativeVoiceRecorder();
        await recorder.start();
        platform.failDispose = true;
        await expectLater(recorder.dispose(), throwsStateError);
        expect(await File(platform.path!).exists(), isTrue);
        expect(platform.events, ['create', 'start', 'stop', 'dispose']);
      },
    );

    test(
      'empty output is rejected and capture directory is still cleaned',
      () async {
        platform.size = 0;
        final recorder = NativeVoiceRecorder();
        await recorder.start();
        await expectLater(recorder.stop(), throwsFormatException);
        expect(await root.list().toList(), isEmpty);
        await recorder.dispose();
      },
    );
  });
}

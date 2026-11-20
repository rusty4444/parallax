import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/message_outbox.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/secure_store.dart';
import 'package:parallax/send_cancellation.dart';

class _Store implements SecureValueStore {
  final values = <String, String>{};
  final writes = <String>[];
  Future<void> Function()? beforeRead;
  Future<void> Function()? beforeWrite;
  Future<void> Function()? beforeDelete;
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  int reads = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    await beforeRead?.call();
    if (failRead) throw StateError('read unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await beforeWrite?.call();
    if (failWrite) throw StateError('write unavailable');
    values[key] = value;
    writes.add(value);
  }

  @override
  Future<void> delete(String key) async {
    await beforeDelete?.call();
    if (failDelete) throw StateError('delete unavailable');
    values.remove(key);
  }
}

class _Attempt {
  _Attempt(this.record, this.cancellation, this.progress);
  final OutboxRecord record;
  final SendCancellation cancellation;
  final void Function(double) progress;
  final result = Completer<void>();
  void succeed() {
    if (!result.isCompleted) result.complete();
  }

  void fail([Object error = const SendCancelled()]) {
    if (!result.isCompleted) result.completeError(error);
  }
}

class _Transport {
  final attempts = <_Attempt>[];
  final changes = StreamController<void>.broadcast(sync: true);
  Future<void> send(
    OutboxRecord record,
    SendCancellation cancellation,
    void Function(double) progress,
  ) {
    final attempt = _Attempt(record, cancellation, progress);
    attempts.add(attempt);
    changes.add(null);
    return attempt.result.future;
  }

  Future<_Attempt> at(int index) async {
    if (attempts.length <= index) {
      await changes.stream.firstWhere((_) => attempts.length > index);
    }
    return attempts[index];
  }
}

class _HoldTimer implements Timer {
  _HoldTimer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

class _HoldTimers {
  final created = <_HoldTimer>[];
  Timer create(Duration duration, void Function() callback) {
    final timer = _HoldTimer(duration, callback);
    created.add(timer);
    return timer;
  }

  void fireAll() {
    for (final timer in List.of(created)) {
      timer.fire();
    }
  }
}

/// The snapshot format as it was written before sizes were computed
/// arithmetically and media was spliced in: plain `jsonEncode`.
String _referenceSnapshot(String accountKey, Iterable<OutboxRecord> records) =>
    jsonEncode({
      'version': 1,
      'accountKey': accountKey,
      'records': [
        for (final record in records)
          {
            'id': record.id,
            'accountKey': record.accountKey,
            'roomId': record.roomId,
            'body': record.body,
            'createdAt': record.createdAt.toUtc().toIso8601String(),
            'state': record.state.name,
            if (record.caption != null) 'caption': record.caption,
            if (record.replyToId != null) 'replyToId': record.replyToId,
            if (record.editEventId != null) 'editEventId': record.editEventId,
            if (record.threadRootId != null)
              'threadRootId': record.threadRootId,
            if (record.font != null) 'font': record.font,
            if (record.error != null) 'error': record.error,
            if (record.progress != null) 'progress': record.progress,
            if (record.media case final media?)
              'media': {
                'bytes': base64.encode(media.bytes),
                'name': media.name,
                'mimeType': media.mimeType,
                if (media.durationMs != null) 'durationMs': media.durationMs,
              },
          },
      ],
    });

void main() {
  late _Store store;
  late _Transport transport;
  late String? account;
  late List<MessageOutbox> boxes;
  late StreamController<void> changes;
  late int emissions;
  late _HoldTimers timers;
  final now = DateTime.utc(2026, 11, 12, 9);

  MessageOutbox makeBox({
    int storedByteLimit = MessageOutbox.maxStoredBytes,
    DateTime Function()? clock,
    OutboxBackgroundRunner? background,
  }) {
    final box = MessageOutbox(
      storage: store,
      storedByteLimit: storedByteLimit,
      currentAccount: () => account,
      holdTimer: timers.create,
      clock: clock ?? () => now,
      background: background ?? <T>(work) => Isolate.run(work),
      transmit: transport.send,
      onChanged: () {
        emissions++;
        changes.add(null);
      },
    );
    boxes.add(box);
    return box;
  }

  Future<void> stateIs(
    MessageOutbox box,
    String id,
    DeliveryState state,
  ) async {
    bool matches() => box.records.any((r) => r.id == id && r.state == state);
    if (!matches()) await changes.stream.firstWhere((_) => matches());
  }

  Future<void> retired(MessageOutbox box, String id) async {
    bool matches() => box.records.every((r) => r.id != id);
    if (!matches()) await changes.stream.firstWhere((_) => matches());
  }

  setUp(() {
    store = _Store();
    transport = _Transport();
    account = 'alice';
    boxes = [];
    changes = StreamController<void>.broadcast(sync: true);
    emissions = 0;
    timers = _HoldTimers();
  });

  tearDown(() async {
    final closing = boxes.map((box) => box.dispose()).toList();
    for (final attempt in transport.attempts) {
      attempt.fail();
    }
    await Future.wait(closing);
    await changes.close();
    await transport.changes.close();
  });

  test(
    'durable acceptance precedes network; later failure is a record',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      store.beforeWrite = () {
        if (!entered.isCompleted) entered.complete();
        return release.future;
      };
      final box = makeBox();
      var accepted = false;
      final acceptance = box.enqueueText('alice', '!room', 'hello').then((id) {
        accepted = true;
        return id;
      });
      await entered.future;
      expect(accepted, isFalse);
      expect(transport.attempts, isEmpty);
      expect(box.records, isEmpty);
      release.complete();
      final id = await acceptance;
      expect(store.writes.first, contains(id));
      expect(id, matches(RegExp(r'^mx_[A-Za-z0-9_-]{43}$')));
      final attempt = await transport.at(0);
      expect(store.writes.first, contains('queued'));
      attempt.fail(StateError('offline'));
      await stateIs(box, id, DeliveryState.failed);
      expect(box.records.single.error, contains('offline'));
      expect(store.values.values.single, contains('offline'));
    },
  );

  test(
    'initial write failure rejects without transmitting or publishing',
    () async {
      store.failWrite = true;
      final box = makeBox();
      await expectLater(
        box.enqueueText('alice', '!r', 'hello'),
        throwsStateError,
      );
      expect(box.records, isEmpty);
      expect(transport.attempts, isEmpty);
      expect(store.values, isEmpty);
    },
  );

  test('read failure is not an empty snapshot and can be retried', () async {
    final first = makeBox();
    final id = await first.enqueueText('alice', '!r', 'preserve');
    final attempt = await transport.at(0);
    attempt.fail(StateError('offline'));
    await stateIs(first, id, DeliveryState.failed);
    await first.closeAccount();
    final snapshot = Map<String, String>.from(store.values);
    store.failRead = true;
    final second = makeBox();
    await expectLater(second.restore('alice'), throwsStateError);
    await expectLater(
      second.enqueueText('alice', '!r', 'new'),
      throwsStateError,
    );
    expect(store.values, snapshot);
    store.failRead = false;
    await second.restore('alice');
    expect(second.records.single.id, id);
    expect(transport.attempts, hasLength(1));
  });

  test(
    'enqueue without explicit restore preserves the unread snapshot',
    () async {
      final first = makeBox();
      final old = await first.enqueueText('alice', '!r', 'old');
      (await transport.at(0)).fail();
      await stateIs(first, old, DeliveryState.failed);
      await first.closeAccount();
      final second = makeBox();
      final next = await second.enqueueText('alice', '!r', 'next');
      expect(second.records.map((r) => r.id), containsAll([old, next]));
      expect(store.values.values.single, contains(old));
      await transport.at(1);
    },
  );

  test(
    'restart never replays; retry preserves identity and relation fields',
    () async {
      final first = makeBox();
      final id = await first.enqueueText(
        'alice',
        '!r',
        'edited',
        replyToId: r'$reply',
        editEventId: r'$edit',
        threadRootId: r'$root',
      );
      final attempt = await transport.at(0);
      final closing = first.closeAccount();
      expect(attempt.cancellation.isCancelled, isTrue);
      attempt.succeed();
      await closing;
      final second = makeBox();
      await second.restore('alice');
      expect(transport.attempts, hasLength(1));
      expect(second.records.single.state, DeliveryState.failed);
      expect(second.records.single.id, id);
      expect(second.records.single.error, isNotEmpty);
      await second.retry(id);
      final retried = await transport.at(1);
      expect(retried.record.id, id);
      expect(retried.record.replyToId, r'$reply');
      expect(retried.record.editEventId, r'$edit');
      expect(retried.record.threadRootId, r'$root');
      retried.succeed();
      await retired(second, id);
      final third = makeBox();
      await third.restore('alice');
      expect(third.records, isEmpty);
      expect(transport.attempts, hasLength(2));
    },
  );

  test(
    'more than 100 successive successes never consume pending quota',
    () async {
      final box = makeBox();
      final ids = <String>{};
      for (var index = 0; index < MessageOutbox.maxRecords + 5; index++) {
        final id = await box.enqueueText('alice', '!r', 'message $index');
        expect(ids.add(id), isTrue);
        (await transport.at(index)).succeed();
        await retired(box, id);
        expect(box.records, isEmpty);
        expect(store.values, isEmpty);
        await box.retry(id);
        expect(transport.attempts, hasLength(index + 1));
      }
      final next = makeBox();
      await next.restore('alice');
      expect(next.records, isEmpty);
    },
  );

  test('media payload is retired only after durable acknowledgement', () async {
    final box = makeBox();
    final id = await box.enqueueMedia(
      'alice',
      '!r',
      MediaSelection(
        bytes: Uint8List.fromList([1, 2, 3]),
        name: 'private.ogg',
        mimeType: 'audio/ogg',
      ),
      caption: 'private caption',
    );
    final attempt = await transport.at(0);
    final entered = Completer<void>();
    final release = Completer<void>();
    store.beforeDelete = () {
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };
    attempt.succeed();
    await entered.future;
    expect(box.records.single.media!.bytes, [1, 2, 3]);
    expect(box.records.single.state, DeliveryState.sending);
    expect(store.values.values.single, contains('AQID'));
    release.complete();
    await retired(box, id);
    expect(store.values, isEmpty);
    final next = makeBox();
    await next.restore('alice');
    expect(next.records, isEmpty);
  });

  test(
    'failed acknowledgement persists ambiguity and retries the same txid',
    () async {
      final box = makeBox();
      final id = await box.enqueueText('alice', '!r', 'private body');
      final attempt = await transport.at(0);
      store.failDelete = true;
      attempt.succeed();
      await stateIs(box, id, DeliveryState.failed);
      expect(box.records.single.error, contains('delete unavailable'));
      expect(store.values.values.single, contains(id));
      await box.closeAccount();
      store.failDelete = false;
      final next = makeBox();
      await next.restore('alice');
      expect(next.records.single.id, id);
      expect(next.records.single.state, DeliveryState.failed);
      expect(transport.attempts, hasLength(1));
      await next.retry(id);
      final retry = await transport.at(1);
      expect(retry.record.id, id);
      expect(retry.record.body, 'private body');
      retry.succeed();
      await retired(next, id);
      expect(store.values, isEmpty);
    },
  );

  test(
    'acknowledgement and failure-write outage retains an idempotent retry',
    () async {
      final box = makeBox();
      final keeper = await box.enqueueText('alice', '!r', 'keep pending');
      (await transport.at(0)).fail();
      await stateIs(box, keeper, DeliveryState.failed);
      final id = await box.enqueueMedia(
        'alice',
        '!r',
        MediaSelection(
          bytes: Uint8List.fromList([1, 2, 3]),
          name: 'private.bin',
          mimeType: 'application/octet-stream',
        ),
        caption: 'private caption',
      );
      final attempt = await transport.at(1);
      final snapshot = Map<String, String>.from(store.values);
      store.failWrite = true;
      attempt.succeed();
      await stateIs(box, id, DeliveryState.failed);
      expect(box.records.last.error, contains('persistence failed'));
      expect(store.values, snapshot);
      await box.closeAccount();
      final next = makeBox();
      await next.restore('alice');
      expect(next.records.last.id, id);
      expect(next.records.last.state, DeliveryState.failed);
      expect(next.records.last.media!.bytes, [1, 2, 3]);
      expect(transport.attempts, hasLength(2));
      store.failWrite = false;
      await next.retry(id);
      final retry = await transport.at(2);
      expect(retry.record.id, id);
      retry.succeed();
      await retired(next, id);
      expect(next.records.single.id, keeper);
      expect(store.values.values.single, isNot(contains('AQID')));
      expect(store.values.values.single, isNot(contains('private')));
      final restored = makeBox();
      await restored.restore('alice');
      expect(restored.records.single.id, keeper);
    },
  );

  for (final onlySent in [false, true]) {
    test(
      'legacy sent payloads are retired on restore (onlySent=$onlySent)',
      () async {
        final seed = makeBox();
        final id = await seed.enqueueMedia(
          'alice',
          '!r',
          MediaSelection(
            bytes: Uint8List.fromList([1, 2, 3]),
            name: 'private.bin',
            mimeType: 'application/octet-stream',
          ),
        );
        (await transport.at(0)).fail();
        await stateIs(seed, id, DeliveryState.failed);
        await seed.closeAccount();
        final key = store.values.keys.single;
        final snapshot = jsonDecode(store.values[key]!) as Map<String, dynamic>;
        snapshot['records'][0]['state'] = 'sent';
        final pendingId =
            'mx_${base64Url.encode(Uint8List(32)).replaceAll('=', '')}';
        if (!onlySent) {
          (snapshot['records'] as List).add(
            {
              ...snapshot['records'][0] as Map<String, dynamic>,
              'id': pendingId,
              'body': 'keep pending',
              'state': 'failed',
            }..remove('media'),
          );
        }
        store.values[key] = jsonEncode(snapshot);
        final box = makeBox();
        await box.restore('alice');
        expect(box.records, onlySent ? isEmpty : hasLength(1));
        if (onlySent) {
          expect(store.values, isEmpty);
        } else {
          expect(box.records.single.id, pendingId);
          expect(store.values.values.single, isNot(contains('AQID')));
          expect(store.values.values.single, isNot(contains('private.bin')));
        }
        await box.retry(id);
        expect(transport.attempts, hasLength(1));
      },
    );
  }

  test('media metadata and immutable bytes survive restart', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final first = makeBox();
    final id = await first.enqueueMedia(
      'alice',
      '!r',
      MediaSelection(
        bytes: bytes,
        name: 'voice.ogg',
        mimeType: 'audio/ogg',
        durationMs: 123,
      ),
      caption: 'caption',
      replyToId: r'$reply',
      threadRootId: r'$thread',
    );
    bytes[0] = 9;
    final attempt = await transport.at(0);
    expect(attempt.record.media!.bytes, [1, 2, 3]);
    expect(
      () => first.records.single.media!.bytes[0] = 8,
      throwsUnsupportedError,
    );
    attempt.fail();
    await stateIs(first, id, DeliveryState.failed);
    await first.closeAccount();
    final second = makeBox();
    await second.restore('alice');
    final restored = second.records.single;
    expect(restored.body, 'caption');
    expect(restored.caption, 'caption');
    expect(restored.media!.bytes, [1, 2, 3]);
    expect(restored.media!.name, 'voice.ogg');
    expect(restored.media!.mimeType, 'audio/ogg');
    expect(restored.media!.durationMs, 123);
    expect(restored.replyToId, r'$reply');
    expect(restored.threadRootId, r'$thread');
  });

  for (final lateError in [false, true]) {
    test(
      'cancel joins and ignores late ${lateError ? 'error' : 'success'} and progress',
      () async {
        final box = makeBox();
        final id = await box.enqueueText('alice', '!r', 'hello');
        final attempt = await transport.at(0);
        var finished = false;
        final cancelled = box.cancel(id).then((_) => finished = true);
        expect(attempt.cancellation.isCancelled, isTrue);
        attempt.progress(0.9);
        expect(box.records.single.progress, isNot(0.9));
        expect(finished, isFalse);
        if (lateError) {
          attempt.fail(StateError('late failure'));
        } else {
          attempt.succeed();
        }
        await cancelled;
        expect(box.records.single.state, DeliveryState.failed);
        expect(box.records.single.error, contains('cancel'));
        final third = makeBox();
        await third.restore('alice');
        expect(third.records.single.state, DeliveryState.failed);
        expect(third.records.single.id, id);
      },
    );

    test(
      'discard joins and cannot resurrect on late ${lateError ? 'error' : 'success'}',
      () async {
        final box = makeBox();
        final id = await box.enqueueText('alice', '!r', 'hello');
        final attempt = await transport.at(0);
        final discarded = box.discard(id);
        expect(attempt.cancellation.isCancelled, isTrue);
        attempt.progress(0.5);
        if (lateError) {
          attempt.fail(StateError('late failure'));
        } else {
          attempt.succeed();
        }
        await discarded;
        expect(box.records, isEmpty);
        final third = makeBox();
        await third.restore('alice');
        expect(third.records, isEmpty);
      },
    );
  }

  for (final discard in [false, true]) {
    test(
      '${discard ? 'discard' : 'cancel'} suppresses a retry still awaiting persistence',
      () async {
        final box = makeBox();
        final id = await box.enqueueText('alice', '!r', 'hello');
        (await transport.at(0)).fail();
        await stateIs(box, id, DeliveryState.failed);
        final entered = Completer<void>();
        final release = Completer<void>();
        store.beforeWrite = () {
          if (!entered.isCompleted) entered.complete();
          return release.future;
        };
        final retrying = box.retry(id);
        await entered.future;
        final stopping = discard ? box.discard(id) : box.cancel(id);
        release.complete();
        await retrying;
        await stopping;
        expect(transport.attempts, hasLength(1));
        expect(box.records, discard ? isEmpty : hasLength(1));
        if (!discard) expect(box.records.single.state, DeliveryState.failed);
      },
    );
  }

  test('overlapping stop intents fence a retry queued between them', () async {
    final box = makeBox();
    final id = await box.enqueueText('alice', '!r', 'hello');
    (await transport.at(0)).fail();
    await stateIs(box, id, DeliveryState.failed);
    final entered = Completer<void>();
    final release = Completer<void>();
    store.beforeWrite = () {
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };
    final writes = store.writes.length;
    final retrying = box.retry(id);
    await entered.future;
    final cancelled = box.cancel(id);
    final retriedAgain = box.retry(id);
    final discarded = box.discard(id);
    release.complete();
    await Future.wait([retrying, cancelled, retriedAgain, discarded]);
    expect(transport.attempts, hasLength(1));
    expect(box.records, isEmpty);
    expect(
      store.writes.skip(writes).any((raw) => raw.contains('sending')),
      isFalse,
    );
    final next = makeBox();
    await next.restore('alice');
    expect(next.records, isEmpty);
  });

  test(
    'dispose is synchronous, idempotent and permanently rejects new work',
    () async {
      final box = makeBox();
      final id = await box.enqueueText('alice', '!r', 'hello');
      final attempt = await transport.at(0);
      final closing = box.dispose();
      final secondClose = box.dispose();
      expect(attempt.cancellation.isCancelled, isTrue);
      expect(box.records, isEmpty);
      final count = emissions;
      final writes = store.writes.length;
      attempt.progress(0.9);
      attempt.fail(StateError('late failure'));
      await Future.wait([closing, secondClose]);
      expect(emissions, count);
      expect(store.writes, hasLength(writes));
      await expectLater(box.restore('alice'), throwsStateError);
      await expectLater(
        box.enqueueText('alice', '!r', 'new'),
        throwsStateError,
      );
      final next = makeBox();
      await next.restore('alice');
      expect(next.records.single.id, id);
      expect(next.records.single.state, DeliveryState.failed);
    },
  );

  test('concurrent retries have one transport owner', () async {
    final box = makeBox();
    final id = await box.enqueueText('alice', '!r', 'hello');
    (await transport.at(0)).fail();
    await stateIs(box, id, DeliveryState.failed);
    await Future.wait([box.retry(id), box.retry(id), box.retry(id)]);
    final attempt = await transport.at(1);
    expect(transport.attempts, hasLength(2));
    expect(attempt.record.id, id);
    attempt.succeed();
    await retired(box, id);
  });

  test(
    'account switch synchronously invalidates callbacks and preserves old account',
    () async {
      final box = makeBox();
      final oldId = await box.enqueueText('alice', '!r', 'old');
      final attempt = await transport.at(0);
      account = 'bob';
      final closing = box.closeAccount();
      final before = emissions;
      final writes = store.writes.length;
      attempt.progress(0.5);
      attempt.succeed();
      await closing;
      expect(emissions, before);
      expect(store.writes, hasLength(writes));
      expect(box.records, isEmpty);
      final bob = await box.enqueueText('bob', '!b', 'new');
      expect(box.records.single.id, bob);
      (await transport.at(1)).fail();
      await stateIs(box, bob, DeliveryState.failed);
      account = 'alice';
      await box.restore('alice');
      expect(box.records.single.id, oldId);
      expect(box.records.single.state, DeliveryState.failed);
      expect(transport.attempts, hasLength(2));
    },
  );

  test(
    'replacement instance cancels and joins the old owner before reading',
    () async {
      final first = makeBox();
      final id = await first.enqueueText('alice', '!r', 'old');
      final attempt = await transport.at(0);
      final second = makeBox();
      var restored = false;
      final restore = second.restore('alice').then((_) => restored = true);
      await attempt.cancellation.whenCancelled;
      expect(restored, isFalse);
      final before = emissions;
      attempt.progress(0.7);
      attempt.fail(StateError('late'));
      await restore;
      expect(first.records, isEmpty);
      expect(second.records.single.id, id);
      expect(second.records.single.error, isNot(contains('late')));
      expect(emissions, before + 1);
    },
  );

  test(
    'shared durable ordering survives a held write from a retired instance',
    () async {
      final first = makeBox();
      await first.restore('alice');
      final entered = Completer<void>();
      final release = Completer<void>();
      store.beforeWrite = () {
        if (!entered.isCompleted) entered.complete();
        return release.future;
      };
      final pending = first.enqueueText('alice', '!r', 'held');
      final assertion = expectLater(pending, throwsA(isA<SendCancelled>()));
      await entered.future;
      final closing = first.closeAccount();
      final second = makeBox();
      final newer = second.enqueueText('alice', '!r', 'newer');
      release.complete();
      await assertion;
      await closing;
      final nextId = await newer;
      await transport.at(0);
      expect(second.records.map((r) => r.body), containsAll(['held', 'newer']));
      expect(store.values.values.single, contains(nextId));
      expect(transport.attempts, hasLength(1));
    },
  );

  test(
    'restore finishing after switch cannot emit or overwrite either account',
    () async {
      final first = makeBox();
      final id = await first.enqueueText('alice', '!r', 'old');
      (await transport.at(0)).fail();
      await stateIs(first, id, DeliveryState.failed);
      await first.closeAccount();
      final entered = Completer<void>();
      final release = Completer<void>();
      store.beforeRead = () {
        if (!entered.isCompleted) entered.complete();
        return release.future;
      };
      final second = makeBox();
      final restoring = second.restore('alice');
      final assertion = expectLater(restoring, throwsA(isA<SendCancelled>()));
      await entered.future;
      account = 'bob';
      final closing = second.closeAccount();
      final before = emissions;
      final snapshot = Map<String, String>.from(store.values);
      release.complete();
      await assertion;
      await closing;
      expect(second.records, isEmpty);
      expect(emissions, before);
      expect(store.values, snapshot);
    },
  );

  test('wrong account is rejected without reading or writing', () async {
    final box = makeBox();
    await expectLater(box.restore('bob'), throwsA(isA<SendCancelled>()));
    await expectLater(
      box.enqueueText('bob', '!r', 'x'),
      throwsA(isA<SendCancelled>()),
    );
    expect(store.reads, 0);
    expect(store.values, isEmpty);
  });

  test('malformed snapshot fails closed and is never overwritten', () async {
    final first = makeBox();
    final id = await first.enqueueText('alice', '!r', 'x');
    (await transport.at(0)).fail();
    await stateIs(first, id, DeliveryState.failed);
    await first.closeAccount();
    final key = store.values.keys.single;
    for (final corrupt in [
      'not json',
      '{"version":99,"records":[]}',
      '{"version":1,"accountKey":"alice","records":[{}]}',
    ]) {
      store.values[key] = corrupt;
      final box = makeBox();
      await expectLater(box.restore('alice'), throwsFormatException);
      await expectLater(
        box.enqueueText('alice', '!r', 'replacement'),
        throwsFormatException,
      );
      expect(store.values[key], corrupt);
      await box.closeAccount();
    }
  });

  test(
    'duplicate identities, wrong account and invalid base64 fail closed',
    () async {
      final first = makeBox();
      final id = await first.enqueueMedia(
        'alice',
        '!r',
        MediaSelection(
          bytes: Uint8List.fromList([1]),
          name: 'x',
          mimeType: 'image/png',
        ),
      );
      (await transport.at(0)).fail();
      await stateIs(first, id, DeliveryState.failed);
      await first.closeAccount();
      final key = store.values.keys.single;
      final original = store.values[key]!;
      final duplicate = jsonDecode(original) as Map<String, dynamic>;
      (duplicate['records'] as List).add((duplicate['records'] as List).first);
      final wrongAccount = jsonDecode(original) as Map<String, dynamic>;
      wrongAccount['accountKey'] = 'bob';
      final invalidMedia = jsonDecode(original) as Map<String, dynamic>;
      invalidMedia['records'][0]['media']['bytes'] = '%%%';
      for (final corrupt in [duplicate, wrongAccount, invalidMedia]) {
        final value = jsonEncode(corrupt);
        store.values[key] = value;
        final box = makeBox();
        await expectLater(box.restore('alice'), throwsFormatException);
        expect(store.values[key], value);
        await box.closeAccount();
      }
    },
  );

  test('rejects payloads over 20 MiB without persistence or network', () async {
    final box = makeBox();
    await expectLater(
      box.enqueueMedia(
        'alice',
        '!r',
        MediaSelection(
          bytes: Uint8List(20 * 1024 * 1024 + 1),
          name: 'x',
          mimeType: 'application/octet-stream',
        ),
      ),
      throwsArgumentError,
    );
    expect(store.values, isEmpty);
    expect(transport.attempts, isEmpty);
  });

  test(
    'failure to persist sending never transmits and preserves acceptance',
    () async {
      final box = makeBox();
      store.beforeWrite = () async {
        if (store.writes.isNotEmpty) store.failWrite = true;
      };
      final id = await box.enqueueText('alice', '!r', 'accepted');
      await stateIs(box, id, DeliveryState.failed);
      expect(transport.attempts, isEmpty);
      expect(box.records.single.error, contains('persistence failed'));
      expect(store.values.values.single, contains('queued'));
      store.beforeWrite = null;
      store.failWrite = false;
      await box.closeAccount();
      final next = makeBox();
      await next.restore('alice');
      expect(next.records.single.id, id);
      expect(next.records.single.state, DeliveryState.failed);
    },
  );

  test(
    'restore projects interrupted sends without requiring a write',
    () async {
      final box = makeBox();
      final id = await box.enqueueText('alice', '!r', 'accepted');
      final attempt = await transport.at(0);
      final closing = box.closeAccount();
      attempt.fail();
      await closing;
      final snapshot = Map<String, String>.from(store.values);
      store.failWrite = true;
      final next = makeBox();
      await next.restore('alice');
      expect(next.records.single.id, id);
      expect(next.records.single.state, DeliveryState.failed);
      expect(store.values, snapshot);
      store.failWrite = false;
      await next.restore('alice');
      expect(next.records.single.id, id);
      expect(next.records.single.state, DeliveryState.failed);
      expect(transport.attempts, hasLength(1));
    },
  );

  test('delete failure retains the durable record for restart', () async {
    final box = makeBox();
    final id = await box.enqueueText('alice', '!r', 'accepted');
    final attempt = await transport.at(0);
    store.failDelete = true;
    final discard = box.discard(id);
    final assertion = expectLater(discard, throwsStateError);
    attempt.succeed();
    await assertion;
    expect(box.records.single.id, id);
    store.failDelete = false;
    final next = makeBox();
    await next.restore('alice');
    expect(next.records.single.id, id);
    expect(next.records.single.state, DeliveryState.failed);
    await next.discard(id);
    expect(store.values, isEmpty);
  });

  test(
    'admission reserves bounded lifecycle metadata before accepting',
    () async {
      const limit = 40 * 1024;
      final box = makeBox(storedByteLimit: limit);
      // The queued payload would fit physically, but lacks lifecycle headroom.
      await expectLater(
        box.enqueueText('alice', '!r', 'x' * 9000),
        throwsStateError,
      );
      expect(store.values, isEmpty);
      expect(transport.attempts, isEmpty);
      final id = await box.enqueueText('alice', '!r', 'x' * 7000);
      final attempt = await transport.at(0);
      attempt.progress(0.12345678901234568);
      attempt.fail(StateError('\u0000' * 8000));
      await stateIs(box, id, DeliveryState.failed);
      expect(box.records.single.error!.length, lessThanOrEqualTo(4096));
      expect(box.records.single.error, isNot(contains('persistence failed')));
      for (final raw in store.writes) {
        expect(utf8.encode(raw).length, lessThanOrEqualTo(limit));
      }
      final snapshot = Map<String, String>.from(store.values);
      await expectLater(
        box.enqueueText('alice', '!r', 'overflow' * 1000),
        throwsStateError,
      );
      expect(store.values, snapshot);
      expect(transport.attempts, hasLength(1));
      final next = makeBox(storedByteLimit: limit);
      await next.restore('alice');
      expect(next.records.single.id, id);
      expect(next.records.single.state, DeliveryState.failed);
    },
  );

  for (final state in [DeliveryState.queued, DeliveryState.sending]) {
    test(
      'near-limit legacy ${state.name} snapshot restores and discards without expansion',
      () async {
        const limit = 4096;
        final seed = makeBox();
        final id = await seed.enqueueText('alice', '!r', 'seed');
        (await transport.at(0)).fail();
        await stateIs(seed, id, DeliveryState.failed);
        await seed.closeAccount();
        final key = store.values.keys.single;
        final snapshot = jsonDecode(store.values[key]!) as Map<String, dynamic>;
        final template = Map<String, dynamic>.from(
          snapshot['records'][0] as Map,
        );
        template.remove('error');
        template['state'] = state.name;
        final otherIds = List.generate(
          9,
          (index) =>
              'mx_${base64Url.encode(Uint8List(32)..[0] = index).replaceAll('=', '')}',
        );
        snapshot['records'] = [
          template,
          for (final otherId in otherIds) {...template, 'id': otherId},
        ];
        template['body'] =
            'x' * (4 + limit - utf8.encode(jsonEncode(snapshot)).length);
        final raw = jsonEncode(snapshot);
        expect(utf8.encode(raw), hasLength(limit));
        store.values[key] = raw;
        final writes = store.writes.length;
        store.failWrite = true;
        final box = makeBox(storedByteLimit: limit);
        await box.restore('alice');
        expect(box.records, hasLength(10));
        expect(
          box.records.every((r) => r.state == DeliveryState.failed),
          isTrue,
        );
        expect(
          box.records.every((r) => r.error!.contains('interrupted')),
          isTrue,
        );
        expect(store.writes, hasLength(writes));
        expect(store.values[key], raw);
        store.failWrite = false;
        // Removing one short record does not make space for the other nine
        // synthesized recovery errors; optional diagnostics must be omitted.
        await box.discard(otherIds.first);
        expect(box.records, hasLength(9));
        expect(box.records.first.id, id);
        expect(store.values[key], isNot(contains('interrupted')));
        expect(
          utf8.encode(store.values[key]!).length,
          lessThanOrEqualTo(limit),
        );
        final next = makeBox(storedByteLimit: limit);
        await next.restore('alice');
        expect(next.records, hasLength(9));
        expect(next.records.first.id, id);
        for (final record in next.records) {
          await next.discard(record.id);
        }
        expect(store.values, isEmpty);
        expect(transport.attempts, hasLength(1));
      },
    );
  }

  test('cancel cannot resurrect a durably acknowledged payload', () async {
    final box = makeBox();
    final id = await box.enqueueText('alice', '!r', 'private body');
    final attempt = await transport.at(0);
    final entered = Completer<void>();
    final release = Completer<void>();
    store.beforeDelete = () {
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };
    attempt.succeed();
    await entered.future;
    final cancelling = box.cancel(id);
    release.complete();
    await cancelling;
    expect(box.records, isEmpty);
    expect(store.values, isEmpty);
    final next = makeBox();
    await next.restore('alice');
    expect(next.records, isEmpty);
  });

  test('discard joins a terminal write already in progress', () async {
    final box = makeBox();
    final id = await box.enqueueText('alice', '!r', 'accepted');
    final attempt = await transport.at(0);
    final entered = Completer<void>();
    final release = Completer<void>();
    store.beforeDelete = () {
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };
    attempt.succeed();
    await entered.future;
    final discard = box.discard(id);
    expect(attempt.cancellation.isCancelled, isTrue);
    release.complete();
    await discard;
    expect(box.records, isEmpty);
    final next = makeBox();
    await next.restore('alice');
    expect(next.records, isEmpty);
  });

  test('repeated restore leaves an active owner alone', () async {
    final box = makeBox();
    final id = await box.enqueueText('alice', '!r', 'accepted');
    final attempt = await transport.at(0);
    final reads = store.reads;
    await Future.wait([box.restore('alice'), box.restore('alice')]);
    expect(store.reads, reads);
    expect(attempt.cancellation.isCancelled, isFalse);
    expect(box.records.single.state, DeliveryState.sending);
    attempt.succeed();
    await retired(box, id);
  });

  test(
    'switching accounts does not block the new account on an old transport',
    () async {
      final box = makeBox();
      final old = await box.enqueueText('alice', '!r', 'old');
      final first = await transport.at(0);
      account = 'bob';
      final next = await box.enqueueText('bob', '!b', 'next');
      expect(first.cancellation.isCancelled, isTrue);
      final second = await transport.at(1);
      expect(box.records.single.id, next);
      final count = emissions;
      final writes = store.writes.length;
      first.progress(0.5);
      first.fail(StateError('old failure'));
      // Joining both owners provides a deterministic stale-callback fence.
      final closing = box.closeAccount();
      second.fail();
      await closing;
      expect(emissions, count);
      expect(store.writes, hasLength(writes));
      account = 'alice';
      await box.restore('alice');
      expect(box.records.single.id, old);
      expect(box.records.single.state, DeliveryState.failed);
    },
  );

  test(
    '100-record bound rejects acceptance without replacing old data',
    () async {
      final first = makeBox();
      final id = await first.enqueueText('alice', '!r', 'seed');
      (await transport.at(0)).fail();
      await stateIs(first, id, DeliveryState.failed);
      await first.closeAccount();
      final key = store.values.keys.single;
      final snapshot = jsonDecode(store.values[key]!) as Map<String, dynamic>;
      final template =
          (snapshot['records'] as List).single as Map<String, dynamic>;
      snapshot['records'] = List.generate(
        100,
        (i) => {
          ...template,
          'id':
              'mx_${base64Url.encode(Uint8List(32)..[0] = i).replaceAll('=', '')}',
        },
      );
      final encoded = jsonEncode(snapshot);
      store.values[key] = encoded;
      final next = makeBox();
      await next.restore('alice');
      expect(next.records, hasLength(100));
      await expectLater(
        next.enqueueText('alice', '!r', 'overflow'),
        throwsStateError,
      );
      expect(store.values[key], encoded);
      expect(transport.attempts, hasLength(1));
    },
  );

  test(
    '20 MiB is accepted; 64 MiB aggregate bound rejects without data loss',
    () async {
      final box = makeBox();
      final media = MediaSelection(
        bytes: Uint8List(MessageOutbox.maxPayloadBytes),
        name: 'large.bin',
        mimeType: 'application/octet-stream',
      );
      final first = await box.enqueueMedia('alice', '!r', media);
      (await transport.at(0)).fail();
      await stateIs(box, first, DeliveryState.failed);
      final second = await box.enqueueMedia('alice', '!r', media);
      (await transport.at(1)).fail();
      await stateIs(box, second, DeliveryState.failed);
      final snapshot = Map<String, String>.from(store.values);
      await expectLater(
        box.enqueueMedia('alice', '!r', media),
        throwsStateError,
      );
      expect(store.values, snapshot);
      expect(box.records, hasLength(2));
      expect(transport.attempts, hasLength(2));
      final next = makeBox();
      await next.restore('alice');
      expect(next.records.map((r) => r.id), [first, second]);
      expect(
        next.records.first.media!.bytes.length,
        MessageOutbox.maxPayloadBytes,
      );
    },
  );

  test(
    'finite progress is clamped, stale progress ignored and result is durable',
    () async {
      final box = makeBox();
      final id = await box.enqueueText('alice', '!r', 'x');
      final attempt = await transport.at(0);
      attempt.progress(0.3);
      expect(box.records.single.progress, 0.3);
      attempt.progress(double.nan);
      expect(box.records.single.progress, 0.3);
      attempt.progress(2);
      expect(box.records.single.progress, 1);
      attempt.succeed();
      await retired(box, id);
      final count = emissions;
      attempt.progress(0.1);
      expect(emissions, count);
      expect(box.records, isEmpty);
      expect(store.values, isEmpty);
    },
  );

  group('snapshot codec', () {
    test('sizes are exact without encoding media', () {
      OutboxRecord record(
        int index, {
        String body = 'plain',
        MediaSelection? media,
        String? error,
        double? progress,
        bool relations = false,
      }) => OutboxRecord(
        id: 'mx_${base64Url.encode(Uint8List(32)..[0] = index).replaceAll('=', '')}',
        accountKey: 'älice',
        roomId: '!r:example',
        body: body,
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5, index, index * 3),
        state: DeliveryState.values[index % DeliveryState.values.length],
        media: media,
        caption: relations ? 'Caption “quoted” 🎉' : null,
        replyToId: relations ? r'$reply' : null,
        editEventId: relations ? r'$edit' : null,
        threadRootId: relations ? r'$root' : null,
        font: relations && media == null ? 'pacifico' : null,
        error: error,
        progress: progress,
      );
      final records = [
        record(0),
        record(
          1,
          body:
              'quote " backslash \\ / newline \n tab \t nul \u0000 é 中 🎉 '
              'lone \uD800 and \uDC00 end',
          error: 'Bad state: 💥 \u0007',
          progress: 0.12345678901234568,
          relations: true,
        ),
        // Every base64 padding case, with and without a duration.
        for (var length = 1; length <= 6; length++)
          record(
            length + 1,
            media: MediaSelection(
              bytes: Uint8List(length)..fillRange(0, length, 0xFB),
              name: 'ñame $length "x".bin',
              mimeType: 'application/octet-stream',
              durationMs: length.isEven ? length * 100 : null,
            ),
            relations: length == 3,
            progress: length == 4 ? 1 : null,
          ),
      ];
      int reference(Iterable<OutboxRecord> subset) =>
          utf8.encode(_referenceSnapshot('älice', subset)).length;
      expect(MessageOutbox.encodedSnapshotBytes('älice', []), reference([]));
      for (final one in records) {
        expect(
          MessageOutbox.encodedSnapshotBytes('älice', [one]),
          reference([one]),
          reason: one.body,
        );
      }
      expect(
        MessageOutbox.encodedSnapshotBytes('älice', records),
        reference(records),
      );
    });

    test(
      'large media is coded off the UI isolate in the same format',
      () async {
        var workers = 0;
        Future<T> counting<T>(T Function() work) {
          workers++;
          return Isolate.run(work);
        }

        final box = makeBox(background: counting);
        final text = await box.enqueueText('alice', '!r', 'small');
        (await transport.at(0)).fail();
        await stateIs(box, text, DeliveryState.failed);
        final tiny = await box.enqueueMedia(
          'alice',
          '!r',
          MediaSelection(
            bytes: Uint8List.fromList([1, 2, 3]),
            name: 'tiny.ogg',
            mimeType: 'audio/ogg',
          ),
        );
        (await transport.at(1)).fail();
        await stateIs(box, tiny, DeliveryState.failed);
        expect(workers, 0, reason: 'small snapshots stay inline');

        final bytes = Uint8List.fromList(
          List.generate(200 * 1024 + 1, (index) => index * 7 % 256),
        );
        final id = await box.enqueueMedia(
          'alice',
          '!r',
          MediaSelection(
            bytes: bytes,
            name: 'café.jpg',
            mimeType: 'image/jpeg',
            durationMs: 5,
          ),
          caption: 'Look 🎉',
          replyToId: r'$reply',
          threadRootId: r'$root',
        );
        expect(workers, greaterThan(0));
        final attempt = await transport.at(2);
        attempt.progress(0.5);
        attempt.fail(StateError('offline'));
        await stateIs(box, id, DeliveryState.failed);
        expect(
          store.values.values.single,
          _referenceSnapshot('alice', box.records),
        );
        await box.closeAccount();

        final encodes = workers;
        final next = makeBox(background: counting);
        await next.restore('alice');
        expect(workers, encodes + 1, reason: 'one background decode');
        expect(next.records.map((r) => r.id), [text, tiny, id]);
        final restored = next.records.last;
        expect(restored.state, DeliveryState.failed);
        expect(restored.error, contains('offline'));
        expect(restored.media!.bytes, bytes);
        expect(restored.media!.name, 'café.jpg');
        expect(restored.media!.mimeType, 'image/jpeg');
        expect(restored.media!.durationMs, 5);
        expect(restored.caption, 'Look 🎉');
        expect(restored.replyToId, r'$reply');
        expect(restored.threadRootId, r'$root');
        expect(() => restored.media!.bytes[0] = 1, throwsUnsupportedError);
      },
    );

    test('a slow background encode keeps durable writes in order', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      Future<T> holding<T>(T Function() work) async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        return work();
      }

      final first = makeBox(background: holding);
      await first.restore('alice');
      final pending = first.enqueueMedia(
        'alice',
        '!r',
        MediaSelection(
          bytes: Uint8List(100 * 1024),
          name: 'big.bin',
          mimeType: 'application/octet-stream',
        ),
      );
      final assertion = expectLater(pending, throwsA(isA<SendCancelled>()));
      await entered.future;
      final closing = first.closeAccount();
      final second = makeBox(background: holding);
      final newer = second.enqueueText('alice', '!r', 'newer');
      await pumpEventQueue();
      expect(store.writes, isEmpty, reason: 'newer write waits its turn');
      release.complete();
      await assertion;
      await closing;
      final nextId = await newer;
      await transport.at(0);
      expect(store.writes.first, contains('big.bin'));
      expect(store.writes.first, isNot(contains(nextId)));
      expect(
        second.records.map((r) => r.body),
        containsAll(['big.bin', 'newer']),
      );
      expect(store.values.values.single, contains(nextId));
      expect(store.values.values.single, contains('big.bin'));
      expect(transport.attempts, hasLength(1));
    });
  });

  test(
    'upload progress notifies in visible steps; the value stays exact',
    () async {
      var clock = now;
      final box = makeBox(clock: () => clock);
      final id = await box.enqueueText('alice', '!r', 'x');
      final attempt = await transport.at(0);
      var seen = emissions;
      int published() {
        final count = emissions - seen;
        seen = emissions;
        return count;
      }

      attempt.progress(0);
      expect(published(), 1, reason: 'a start is always shown');
      attempt.progress(0.004);
      attempt.progress(0.009);
      expect(published(), 0);
      expect(box.records.single.progress, 0.009);
      attempt.progress(0.0101);
      expect(published(), 1, reason: 'a 1% step is shown');
      attempt.progress(0.015);
      expect(published(), 0);
      expect(box.records.single.progress, 0.015);
      clock = clock.add(const Duration(milliseconds: 100));
      attempt.progress(0.016);
      expect(published(), 1, reason: '100 ms later any change is shown');
      attempt.progress(0.016);
      expect(published(), 0);
      attempt.progress(1);
      expect(published(), 1, reason: 'completion is always shown');
      expect(box.records.single.progress, 1);
      attempt.succeed();
      await retired(box, id);
      expect(published(), greaterThan(0), reason: 'state changes are shown');
    },
  );

  test('a 20 MB upload notifies about once per percent', () async {
    final box = makeBox();
    await box.enqueueText('alice', '!r', 'x');
    final attempt = await transport.at(0);
    final before = emissions;
    // queued_media_sender reports every 64 KiB, scaled into 0..0.9.
    const chunks = 20 * 1024 * 1024 ~/ (64 * 1024);
    for (var chunk = 1; chunk <= chunks; chunk++) {
      attempt.progress(chunk / chunks * 0.9);
    }
    expect(emissions - before, inInclusiveRange(80, 91));
    expect(box.records.single.progress, 0.9);
  });

  group('undo send hold', () {
    test('a held send waits for its deadline, then transmits', () async {
      final box = makeBox();
      final id = await box.enqueueText(
        'alice',
        '!r',
        'held',
        hold: const Duration(seconds: 5),
      );
      expect(box.records.single.state, DeliveryState.queued);
      expect(box.heldUntil(id), now.add(const Duration(seconds: 5)));
      expect(timers.created.single.duration, const Duration(seconds: 5));
      expect(store.values.values.single, contains('queued'));
      await pumpEventQueue();
      expect(transport.attempts, isEmpty);
      timers.fireAll();
      final attempt = await transport.at(0);
      expect(attempt.record.id, id);
      expect(box.heldUntil(id), isNull);
      attempt.succeed();
      await retired(box, id);
    });

    test('undo withdraws a held send durably and returns it', () async {
      final box = makeBox();
      final id = await box.enqueueText(
        'alice',
        '!r',
        'take it back',
        replyToId: r'$reply',
        hold: const Duration(seconds: 10),
      );
      final undone = await box.undo(id);
      expect(undone!.body, 'take it back');
      expect(undone.replyToId, r'$reply');
      expect(box.records, isEmpty);
      expect(store.values, isEmpty);
      expect(timers.created.single.isActive, isFalse);
      timers.fireAll();
      await pumpEventQueue();
      expect(transport.attempts, isEmpty);
      expect(await box.undo(id), isNull);
    });

    test('undo is too late once transmission started', () async {
      final box = makeBox();
      final id = await box.enqueueText(
        'alice',
        '!r',
        'too late',
        hold: const Duration(seconds: 5),
      );
      timers.fireAll();
      final attempt = await transport.at(0);
      expect(await box.undo(id), isNull);
      expect(attempt.cancellation.isCancelled, isFalse);
      expect(box.records.single.id, id);
      attempt.succeed();
      await retired(box, id);
    });

    test('media holds keep the caption for the composer', () async {
      final box = makeBox();
      final id = await box.enqueueMedia(
        'alice',
        '!r',
        MediaSelection(
          bytes: Uint8List.fromList([1, 2, 3]),
          name: 'photo.png',
          mimeType: 'image/png',
        ),
        caption: 'Look',
        hold: const Duration(seconds: 5),
      );
      final undone = await box.undo(id);
      expect(undone!.caption, 'Look');
      expect(undone.media!.name, 'photo.png');
      expect(transport.attempts, isEmpty);
    });

    test(
      'cancel during a hold fails the record and the timer never sends',
      () async {
        final box = makeBox();
        final id = await box.enqueueText(
          'alice',
          '!r',
          'cancelled',
          hold: const Duration(seconds: 5),
        );
        await box.cancel(id);
        await stateIs(box, id, DeliveryState.failed);
        expect(box.heldUntil(id), isNull);
        timers.fireAll();
        await pumpEventQueue();
        expect(transport.attempts, isEmpty);
      },
    );

    test('retry and releaseHeld skip the grace period', () async {
      final box = makeBox();
      final first = await box.enqueueText(
        'alice',
        '!r',
        'one',
        hold: const Duration(seconds: 20),
      );
      final second = await box.enqueueText(
        'alice',
        '!r',
        'two',
        hold: const Duration(seconds: 20),
      );
      final third = await box.enqueueText(
        'alice',
        '!r',
        'three',
        hold: const Duration(seconds: 20),
      );
      await box.retry(first);
      expect((await transport.at(0)).record.id, first);
      expect(box.heldUntil(first), isNull);
      box.releaseHeld();
      final ids = {
        (await transport.at(1)).record.id,
        (await transport.at(2)).record.id,
      };
      expect(ids, {second, third});
      expect(timers.created.where((timer) => timer.isActive), isEmpty);
      for (final attempt in transport.attempts) {
        attempt.succeed();
      }
      await retired(box, third);
    });

    test('closing retires holds; restore reports them interrupted', () async {
      final first = makeBox();
      final id = await first.enqueueText(
        'alice',
        '!r',
        'held at close',
        hold: const Duration(seconds: 5),
      );
      await first.closeAccount();
      expect(timers.created.single.isActive, isFalse);
      final second = makeBox();
      await second.restore('alice');
      expect(second.records.single.id, id);
      expect(second.records.single.state, DeliveryState.failed);
      expect(second.heldUntil(id), isNull);
      timers.fireAll();
      await pumpEventQueue();
      expect(transport.attempts, isEmpty);
    });

    test('a failed undo write never transmits silently', () async {
      final box = makeBox();
      final id = await box.enqueueText(
        'alice',
        '!r',
        'stuck',
        hold: const Duration(seconds: 5),
      );
      store.failDelete = true;
      await expectLater(box.undo(id), throwsStateError);
      expect(box.records.single.state, DeliveryState.failed);
      timers.fireAll();
      await pumpEventQueue();
      expect(transport.attempts, isEmpty);
      store.failDelete = false;
      await box.discard(id);
      expect(box.records, isEmpty);
    });

    test('holds are bounded', () async {
      final box = makeBox();
      await expectLater(
        box.enqueueText(
          'alice',
          '!r',
          'x',
          hold: MessageOutbox.maxHold + const Duration(seconds: 1),
        ),
        throwsArgumentError,
      );
      expect(store.values, isEmpty);
    });
  });

  group('message fonts', () {
    test('a font survives a restart and goes out again on retry', () async {
      final first = makeBox();
      final id = await first.enqueueText(
        'alice',
        '!r',
        'fancy',
        replyToId: r'$reply',
        font: 'pacifico',
      );
      final attempt = await transport.at(0);
      expect(attempt.record.font, 'pacifico');
      expect(store.values.values.single, contains('"font":"pacifico"'));
      attempt.fail(StateError('offline'));
      await stateIs(first, id, DeliveryState.failed);
      await first.closeAccount();

      final second = makeBox();
      await second.restore('alice');
      expect(second.records.single.font, 'pacifico');
      await second.retry(id);
      final retried = await transport.at(1);
      expect(retried.record.id, id);
      expect(retried.record.font, 'pacifico');
      expect(retried.record.replyToId, r'$reply');
    });

    test('the default font stores no font key', () async {
      final box = makeBox();
      final id = await box.enqueueText('alice', '!r', 'plain');
      expect((await transport.at(0)).record.font, isNull);
      expect(store.values.values.single, contains(id));
      expect(store.values.values.single, isNot(contains('"font"')));
    });

    test('a well-formed font this version does not know is kept', () async {
      final first = makeBox();
      final id = await first.enqueueText(
        'alice',
        '!r',
        'future',
        font: 'future-font_2',
      );
      (await transport.at(0)).fail();
      await stateIs(first, id, DeliveryState.failed);
      await first.closeAccount();
      final second = makeBox();
      await second.restore('alice');
      expect(second.records.single.font, 'future-font_2');
    });

    test('a malformed font is refused on enqueue', () async {
      final box = makeBox();
      for (final font in ['', 'Pacifico', 'comic sans', 'x' * 33, 'ü']) {
        await expectLater(
          box.enqueueText('alice', '!r', 'x', font: font),
          throwsArgumentError,
          reason: font,
        );
      }
      expect(store.values, isEmpty);
      expect(transport.attempts, isEmpty);
    });

    test('a malformed stored font fails closed on restore', () async {
      final first = makeBox();
      final id = await first.enqueueText('alice', '!r', 'x', font: 'lobster');
      (await transport.at(0)).fail();
      await stateIs(first, id, DeliveryState.failed);
      await first.closeAccount();
      final key = store.values.keys.single;
      final original = store.values[key]!;
      for (final font in <Object>['NOT A FONT', 'a' * 33, 42, 'x' * 70000]) {
        final corrupt = jsonDecode(original) as Map<String, dynamic>;
        corrupt['records'][0]['font'] = font;
        final value = jsonEncode(corrupt);
        store.values[key] = value;
        final box = makeBox();
        await expectLater(
          box.restore('alice'),
          throwsFormatException,
          reason: font is String ? '${font.length} characters' : '$font',
        );
        expect(store.values[key], value);
        await box.closeAccount();
      }
      store.values[key] = original;
      final restored = makeBox();
      await restored.restore('alice');
      expect(restored.records.single.font, 'lobster');
    });

    test('media never carries a font', () async {
      final first = makeBox();
      final id = await first.enqueueMedia(
        'alice',
        '!r',
        MediaSelection(
          bytes: Uint8List.fromList([1]),
          name: 'x.png',
          mimeType: 'image/png',
        ),
      );
      (await transport.at(0)).fail();
      await stateIs(first, id, DeliveryState.failed);
      await first.closeAccount();
      final key = store.values.keys.single;
      final corrupt = jsonDecode(store.values[key]!) as Map<String, dynamic>;
      corrupt['records'][0]['font'] = 'pacifico';
      store.values[key] = jsonEncode(corrupt);
      final box = makeBox();
      await expectLater(box.restore('alice'), throwsFormatException);
    });
  });
}

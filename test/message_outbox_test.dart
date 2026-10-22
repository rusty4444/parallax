import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/message_outbox.dart';
import 'package:matrixpress/messaging_features.dart';
import 'package:matrixpress/secure_store.dart';
import 'package:matrixpress/send_cancellation.dart';

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

void main() {
  late _Store store;
  late _Transport transport;
  late String? account;
  late List<MessageOutbox> boxes;
  late StreamController<void> changes;
  late int emissions;

  MessageOutbox makeBox({int storedByteLimit = MessageOutbox.maxStoredBytes}) {
    final box = MessageOutbox(
      storage: store,
      storedByteLimit: storedByteLimit,
      currentAccount: () => account,
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
}

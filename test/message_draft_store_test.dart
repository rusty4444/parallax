import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/message_draft_store.dart';
import 'package:matrixpress/secure_store.dart';

void main() {
  late _MemorySecureStore storage;
  late MessageDraftStore store;

  setUp(() {
    storage = _MemorySecureStore();
    store = MessageDraftStore(storage: storage);
  });

  test('missing drafts are null and text is preserved exactly', () async {
    expect(await store.read('alice', '!room:server'), isNull);
    const text = '  unfinished 🦋\nsecond line  ';
    await store.write('alice', '!room:server', text);
    expect(await store.read('alice', '!room:server'), text);
  });

  test('accounts and rooms use separate unambiguous scoped keys', () async {
    await store.write('alice', '!one:server', 'first');
    await store.write('alice', '!two:server', 'second');
    await store.write('bob', '!one:server', 'third');
    await store.write('a/b', 'c', 'fourth');
    await store.write('a', 'b/c', 'fifth');
    expect(await store.read('alice', '!one:server'), 'first');
    expect(await store.read('alice', '!two:server'), 'second');
    expect(await store.read('bob', '!one:server'), 'third');
    expect(await store.read('a/b', 'c'), 'fourth');
    expect(await store.read('a', 'b/c'), 'fifth');
    final draftKeys = storage.values.entries
        .where(
          (entry) => [
            'first',
            'second',
            'third',
            'fourth',
            'fifth',
          ].contains(entry.value),
        )
        .map((entry) => entry.key)
        .toSet();
    expect(draftKeys, hasLength(5));
    expect(draftKeys.any((key) => key.contains('alice')), isFalse);
    expect(draftKeys.any((key) => key.contains('!one:server')), isFalse);
  });

  test(
    'recreated instances read durable drafts without a memory cache',
    () async {
      await store.write('alice', '!one:server', 'saved');
      final recreated = MessageDraftStore(storage: storage);
      expect(await recreated.read('alice', '!one:server'), 'saved');
      await recreated.write('alice', '!one:server', 'changed');
      expect(await store.read('alice', '!one:server'), 'changed');
    },
  );

  test('writing before reading preserves unread rooms and accounts', () async {
    await store.write('alice', '!one:server', 'unread room');
    await store.write('bob', '!one:server', 'unread account');
    final recreated = MessageDraftStore(storage: storage);
    await recreated.write('alice', '!two:server', 'new room');
    expect(await recreated.read('alice', '!one:server'), 'unread room');
    expect(await recreated.read('bob', '!one:server'), 'unread account');
    expect(await recreated.read('alice', '!two:server'), 'new room');
  });

  test('empty text removes only its draft; whitespace is a draft', () async {
    await store.write('alice', '!one:server', 'remove me');
    await store.write('alice', '!two:server', 'keep me');
    await store.write('alice', '!one:server', '');
    expect(await store.read('alice', '!one:server'), isNull);
    expect(storage.values.values, isNot(contains('remove me')));
    expect(await store.read('alice', '!two:server'), 'keep me');
    await store.write('alice', '!one:server', '  ');
    expect(await store.read('alice', '!one:server'), '  ');
  });

  test(
    'clearAccount survives recreation and never clears other data',
    () async {
      storage.values['unrelated-secret'] = 'keep this';
      await store.write('alice', '!one:server', 'one');
      await store.write('alice', '!two:server', 'two');
      await store.write('bob', '!one:server', 'other account');
      final recreated = MessageDraftStore(storage: storage);
      await recreated.clearAccount('alice');
      await recreated.clearAccount('alice');
      expect(await store.read('alice', '!one:server'), isNull);
      expect(await store.read('alice', '!two:server'), isNull);
      expect(await store.read('bob', '!one:server'), 'other account');
      expect(storage.values['unrelated-secret'], 'keep this');
      expect(storage.values.values, isNot(contains('one')));
      expect(storage.values.values, isNot(contains('two')));
    },
  );

  test('deferred writes are ordered across recreated instances', () async {
    await store.write('alice', '!one:server', 'initial');
    final entered = Completer<void>();
    final release = Completer<void>();
    storage.beforeWrite = (key, value) async {
      if (value == 'older') {
        entered.complete();
        await release.future;
      }
    };
    final older = store.write('alice', '!one:server', 'older');
    await entered.future;
    final recreated = MessageDraftStore(storage: _StoreView(storage));
    final newer = recreated.write('alice', '!one:server', 'newer');
    final read = recreated.read('alice', '!one:server');
    await _flushQueue();
    expect(storage.writes.where((entry) => entry.$2 == 'newer'), isEmpty);
    release.complete();
    await Future.wait([older, newer]);
    expect(await read, 'newer');
    expect(await store.read('alice', '!one:server'), 'newer');
  });

  test('deferred index reads cannot lose a concurrent room', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var firstRead = true;
    storage.beforeRead = (key) async {
      if (firstRead) {
        firstRead = false;
        entered.complete();
        await release.future;
      }
    };
    final first = store.write('alice', '!one:server', 'one');
    await entered.future;
    final recreated = MessageDraftStore(storage: storage);
    final second = recreated.write('alice', '!two:server', 'two');
    release.complete();
    await Future.wait([first, second]);
    expect(await recreated.read('alice', '!one:server'), 'one');
    expect(await recreated.read('alice', '!two:server'), 'two');
    await recreated.clearAccount('alice');
    expect(storage.values, isEmpty);
  });

  test('clear waits for older writes and later writes survive clear', () async {
    await store.write('alice', '!one:server', 'initial');
    final entered = Completer<void>();
    final release = Completer<void>();
    storage.beforeWrite = (key, value) async {
      if (value == 'old owner') {
        entered.complete();
        await release.future;
      }
    };
    final older = store.write('alice', '!one:server', 'old owner');
    await entered.future;
    final recreated = MessageDraftStore(storage: storage);
    final clear = recreated.clearAccount('alice');
    final later = recreated.write('alice', '!two:server', 'after clear');
    release.complete();
    await Future.wait([older, clear, later]);
    expect(await recreated.read('alice', '!one:server'), isNull);
    expect(await recreated.read('alice', '!two:server'), 'after clear');
  });

  test('blocked operations do not block another account', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    storage.beforeWrite = (key, value) async {
      if (value == 'blocked') {
        entered.complete();
        await release.future;
      }
    };
    final blocked = store.write('alice', '!one:server', 'blocked');
    await entered.future;
    try {
      await MessageDraftStore(
        storage: storage,
      ).write('bob', '!one:server', 'free');
      expect(await store.read('bob', '!one:server'), 'free');
    } finally {
      release.complete();
      await blocked;
    }
  });

  test('draft read failures propagate instead of becoming missing', () async {
    await store.write('alice', '!one:server', 'saved');
    final failure = StateError('secure storage locked');
    storage.beforeRead = (_) async => throw failure;
    await expectLater(
      store.read('alice', '!one:server'),
      throwsA(same(failure)),
    );
    storage.beforeRead = null;
    expect(await store.read('alice', '!one:server'), 'saved');
  });

  test('failed index read never overwrites unread drafts', () async {
    await store.write('alice', '!one:server', 'saved');
    final before = Map.of(storage.values);
    final failure = StateError('cannot read index');
    storage.beforeRead = (_) async => throw failure;
    await expectLater(
      MessageDraftStore(storage: storage).write('alice', '!two:server', 'new'),
      throwsA(same(failure)),
    );
    expect(storage.values, before);
    storage.beforeRead = null;
    expect(await store.read('alice', '!one:server'), 'saved');
  });

  test('failed index writes do not create unindexed drafts', () async {
    final failure = StateError('index write failed');
    storage.beforeWrite = (_, _) async => throw failure;
    await expectLater(
      store.write('alice', '!one:server', 'new'),
      throwsA(same(failure)),
    );
    expect(storage.values, isEmpty);
    storage.beforeWrite = null;
    await store.write('alice', '!one:server', 'retry');
    expect(await store.read('alice', '!one:server'), 'retry');
  });

  test(
    'draft write failures preserve the old draft and queue recovers',
    () async {
      await store.write('alice', '!one:server', 'saved');
      final failure = StateError('draft write failed');
      storage.beforeWrite = (key, value) async {
        if (value == 'failed') throw failure;
      };
      await expectLater(
        store.write('alice', '!one:server', 'failed'),
        throwsA(same(failure)),
      );
      expect(
        await MessageDraftStore(storage: storage).read('alice', '!one:server'),
        'saved',
      );
      await store.write('alice', '!one:server', 'retry');
      expect(await store.read('alice', '!one:server'), 'retry');
    },
  );

  test('failed first draft write remains discoverable for cleanup', () async {
    final failure = StateError('draft write failed');
    storage.beforeWrite = (key, value) async {
      if (value == 'failed') throw failure;
    };
    await expectLater(
      store.write('alice', '!one:server', 'failed'),
      throwsA(same(failure)),
    );
    expect(await store.read('alice', '!one:server'), isNull);
    await MessageDraftStore(storage: storage).clearAccount('alice');
    expect(storage.values, isEmpty);
  });

  test('clear read failures propagate without deleting anything', () async {
    await store.write('alice', '!one:server', 'saved');
    final before = Map.of(storage.values);
    final failure = StateError('locked');
    storage.beforeRead = (_) async => throw failure;
    await expectLater(store.clearAccount('alice'), throwsA(same(failure)));
    expect(storage.values, before);
  });

  test(
    'clear delete failures retain the index for an idempotent retry',
    () async {
      await store.write('alice', '!one:server', 'one');
      await store.write('alice', '!two:server', 'two');
      final secondKey = storage.values.entries
          .singleWhere((entry) => entry.value == 'two')
          .key;
      final failure = StateError('delete failed');
      storage.beforeDelete = (key) async {
        if (key == secondKey) throw failure;
      };
      await expectLater(store.clearAccount('alice'), throwsA(same(failure)));
      expect(await store.read('alice', '!two:server'), 'two');
      storage.beforeDelete = null;
      await MessageDraftStore(storage: storage).clearAccount('alice');
      expect(storage.values, isEmpty);
    },
  );

  test('corrupt index is not treated as an empty account', () async {
    await store.write('alice', '!one:server', 'saved');
    final indexKey = storage.values.entries
        .singleWhere((entry) => entry.value != 'saved')
        .key;
    for (final corrupt in ['not json', '{}', '[42]', '["../other-secret"]']) {
      storage.values[indexKey] = corrupt;
      final before = Map.of(storage.values);
      await expectLater(
        store.write('alice', '!two:server', 'new'),
        throwsFormatException,
      );
      await expectLater(store.clearAccount('alice'), throwsFormatException);
      expect(storage.values, before);
      expect(await store.read('alice', '!one:server'), 'saved');
    }
  });

  test('empty scope identifiers are rejected asynchronously', () async {
    await expectLater(store.read('', '!room'), throwsArgumentError);
    await expectLater(store.read('alice', ''), throwsArgumentError);
    await expectLater(store.write('', '!room', 'text'), throwsArgumentError);
    await expectLater(store.write('alice', '', 'text'), throwsArgumentError);
    await expectLater(store.clearAccount(''), throwsArgumentError);
    expect(storage.values, isEmpty);
  });
}

Future<void> _flushQueue() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.value();
  }
}

class _MemorySecureStore implements SecureValueStore {
  final values = <String, String>{};
  final writes = <(String, String)>[];
  Future<void> Function(String key)? beforeRead;
  Future<void> Function(String key, String value)? beforeWrite;
  Future<void> Function(String key)? beforeDelete;

  @override
  Future<String?> read(String key) async {
    await beforeRead?.call(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add((key, value));
    await beforeWrite?.call(key, value);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    await beforeDelete?.call(key);
    values.remove(key);
  }
}

// Separate adapters to one backing store must still share operation ordering.
class _StoreView implements SecureValueStore {
  _StoreView(this.delegate);
  final SecureValueStore delegate;
  @override
  Future<String?> read(String key) => delegate.read(key);
  @override
  Future<void> write(String key, String value) => delegate.write(key, value);
  @override
  Future<void> delete(String key) => delegate.delete(key);
}

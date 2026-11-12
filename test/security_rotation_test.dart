import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/security/recovery_key_rotation.dart';

const _master = 'm.cross_signing.master';
const _self = 'm.cross_signing.self_signing';
const _user = 'm.cross_signing.user_signing';
const _backup = 'm.megolm_backup.v1';
const _required = {_master, _self, _user, _backup};

/// In-memory SSSS: type -> keyId -> plaintext, plus an operation log.
class _Storage implements SecretStorageWriter {
  _Storage() {
    for (final type in [..._required, 'org.example.extra']) {
      secrets[type] = {'old': 'secret-$type'};
    }
    secrets['unrelated'] = {'other-key': 'x'};
  }

  String? defaultKey = 'old';
  final secrets = <String, Map<String, String>>{};
  final log = <String>[];
  String? failStage;
  String? corruptReadBack;
  String? failRetire;
  bool changeDefaultBeforeCommit = false;

  @override
  String? get defaultKeyId => defaultKey;

  @override
  Map<String, Set<String>> encryptedSecrets() => {
    for (final entry in secrets.entries) entry.key: entry.value.keys.toSet(),
  };

  @override
  Future<String> readWithOldKey(String type) async {
    log.add('read-old $type');
    return secrets[type]!['old']!;
  }

  @override
  Future<String> createNewKey() async {
    log.add('create');
    return 'new';
  }

  @override
  Future<void> stage(String type, String secret) async {
    log.add('stage $type');
    if (type == failStage) throw StateError('write failed');
    secrets[type]!['new'] = secret;
  }

  @override
  Future<String> readWithNewKey(String type) async {
    log.add('read-new $type');
    if (changeDefaultBeforeCommit) defaultKey = 'elsewhere';
    final value = secrets[type]!['new']!;
    return type == corruptReadBack ? '$value-corrupt' : value;
  }

  @override
  Future<void> commitDefault() async {
    log.add('commit');
    defaultKey = 'new';
  }

  @override
  Future<void> retireOldCopies(String type, String secret) async {
    log.add('retire $type');
    if (type == failRetire) throw StateError('strip failed');
    secrets[type]!.removeWhere((key, _) => key != 'new');
  }
}

void main() {
  test('copies, verifies, commits, then retires in that order', () async {
    final storage = _Storage();
    final outcome = await rotateSecretStorageKey(
      storage,
      requiredTypes: _required,
      isCurrent: () => true,
    );
    expect(outcome, RotationOutcome.completed);
    expect(storage.defaultKey, 'new');
    final commit = storage.log.indexOf('commit');
    expect(
      storage.log.indexOf('create'),
      greaterThan(storage.log.lastIndexOf('read-old org.example.extra')),
    );
    for (final type in [..._required, 'org.example.extra']) {
      expect(storage.log.indexOf('stage $type'), lessThan(commit));
      expect(storage.log.indexOf('read-new $type'), lessThan(commit));
      expect(storage.log.indexOf('retire $type'), greaterThan(commit));
      expect(storage.secrets[type], {'new': 'secret-$type'});
    }
    // Secrets under other keys are left alone.
    expect(storage.log.where((e) => e.contains('unrelated')), isEmpty);
  });

  test('a failed copy keeps the old key as the default', () async {
    final storage = _Storage()..failStage = _backup;
    await expectLater(
      rotateSecretStorageKey(
        storage,
        requiredTypes: _required,
        isCurrent: () => true,
      ),
      throwsStateError,
    );
    expect(storage.defaultKey, 'old');
    expect(storage.log, isNot(contains('commit')));
    for (final type in _required) {
      expect(storage.secrets[type]!['old'], 'secret-$type');
    }
  });

  test('a mismatched read-back aborts before commit', () async {
    final storage = _Storage()..corruptReadBack = _self;
    await expectLater(
      rotateSecretStorageKey(
        storage,
        requiredTypes: _required,
        isCurrent: () => true,
      ),
      throwsA(isA<RotationAborted>()),
    );
    expect(storage.defaultKey, 'old');
    expect(storage.log, isNot(contains('commit')));
  });

  test('a concurrent default change aborts before commit', () async {
    final storage = _Storage()..changeDefaultBeforeCommit = true;
    await expectLater(
      rotateSecretStorageKey(
        storage,
        requiredTypes: _required,
        isCurrent: () => true,
      ),
      throwsA(isA<RotationAborted>()),
    );
    expect(storage.log, isNot(contains('commit')));
  });

  test('an incomplete identity is refused before any write', () async {
    final storage = _Storage()..secrets.remove(_user);
    await expectLater(
      rotateSecretStorageKey(
        storage,
        requiredTypes: _required,
        isCurrent: () => true,
      ),
      throwsA(isA<RotationAborted>()),
    );
    expect(storage.log, isEmpty);
  });

  test('session loss stops before writing', () async {
    final storage = _Storage();
    var reads = 0;
    await expectLater(
      rotateSecretStorageKey(
        storage,
        requiredTypes: _required,
        isCurrent: () => ++reads < 2,
      ),
      throwsA(isA<RotationAborted>()),
    );
    expect(storage.log, isNot(contains('create')));
    expect(storage.defaultKey, 'old');
  });

  test('retirement failure is reported, not thrown', () async {
    final storage = _Storage()..failRetire = _master;
    final outcome = await rotateSecretStorageKey(
      storage,
      requiredTypes: _required,
      isCurrent: () => true,
    );
    expect(outcome, RotationOutcome.oldCopiesRemain);
    expect(storage.defaultKey, 'new');
    expect(storage.secrets[_backup], {'new': 'secret-$_backup'});
  });
}

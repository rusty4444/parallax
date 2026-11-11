import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'secure_store.dart';

/// Account- and room-scoped drafts in encrypted platform storage.
///
/// The default [PlatformSecureValueStore] encrypts data at rest. Injected stores
/// must provide the same protection in production. Draft text never goes into
/// SharedPreferences or a plaintext file. Identifiers are hashed in storage keys.
///
/// All operations for an account share invocation ordering across instances in
/// this isolate, including adapters to the same backing storage. This is not a
/// cross-isolate or cross-process transaction lock.
class MessageDraftStore {
  MessageDraftStore({SecureValueStore? storage})
    : _storage = storage ?? const PlatformSecureValueStore();

  final SecureValueStore _storage;
  static const _prefix = 'parallax.message_drafts.v1';
  static final _accountTails = <String, Future<void>>{};
  static final _validRoomToken = RegExp(r'^[a-f0-9]{64}$');

  /// Null means no draft; storage read failures are propagated unchanged.
  Future<String?> read(String accountKey, String roomId) =>
      _ordered(accountKey, (scope) async {
        _requireRoom(roomId);
        return _storage.read(_draftKey(scope, _digest(roomId)));
      });

  /// Persists exact text. An empty string removes only this room's draft.
  ///
  /// The encrypted per-account index is read before modification and written
  /// before a new draft, so interrupted writes never create unindexed secrets.
  /// Draft bodies have individual keys; no unread draft map is overwritten.
  Future<void> write(String accountKey, String roomId, String text) =>
      _ordered(accountKey, (scope) async {
        _requireRoom(roomId);
        final roomToken = _digest(roomId);
        final rooms = await _readIndex(scope);
        final key = _draftKey(scope, roomToken);
        if (text.isEmpty) {
          await _storage.delete(key);
          if (rooms.remove(roomToken)) await _writeIndex(scope, rooms);
          return;
        }
        if (rooms.add(roomToken)) await _writeIndex(scope, rooms);
        await _storage.write(key, text);
      });

  /// Removes only this account's drafts, including those not read this session.
  ///
  /// Keep the index until every deletion succeeds, making a failed or interrupted
  /// cleanup retryable. Older writes finish first; later writes run after clear.
  Future<void> clearAccount(String accountKey) =>
      _ordered(accountKey, (scope) async {
        final rooms = await _readIndex(scope);
        for (final roomToken in rooms) {
          await _storage.delete(_draftKey(scope, roomToken));
        }
        await _storage.delete(_indexKey(scope));
      });

  Future<Set<String>> _readIndex(String scope) async {
    final value = await _storage.read(_indexKey(scope));
    if (value == null) return <String>{};
    final decoded = jsonDecode(value);
    if (decoded is! List ||
        decoded.any(
          (token) => token is! String || !_validRoomToken.hasMatch(token),
        )) {
      // Corruption or an unavailable store is not an empty account. In
      // particular, do not overwrite the index and orphan existing drafts.
      throw const FormatException('Invalid message draft index');
    }
    return decoded.cast<String>().toSet();
  }

  Future<void> _writeIndex(String scope, Set<String> rooms) {
    if (rooms.isEmpty) return _storage.delete(_indexKey(scope));
    return _storage.write(_indexKey(scope), jsonEncode(rooms.toList()));
  }

  Future<T> _ordered<T>(
    String accountKey,
    Future<T> Function(String scope) operation,
  ) {
    if (accountKey.isEmpty) {
      return Future<T>.error(
        ArgumentError.value(accountKey, 'accountKey', 'Must not be empty'),
      );
    }
    final scope = '$_prefix.${_digest(accountKey)}';
    final previous = _accountTails[scope] ?? Future<void>.value();
    final result = previous.then((_) => operation(scope));
    // Only the queue's tail recovers. The caller still receives the original
    // error, and a failed operation cannot poison subsequent operations.
    final tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    _accountTails[scope] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_accountTails[scope], tail)) {
          _accountTails.remove(scope);
        }
      }),
    );
    return result;
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String _indexKey(String scope) => '$scope.index';
  static String _draftKey(String scope, String roomToken) =>
      '$scope.room.$roomToken';

  static void _requireRoom(String roomId) {
    if (roomId.isEmpty) {
      throw ArgumentError.value(roomId, 'roomId', 'Must not be empty');
    }
  }
}

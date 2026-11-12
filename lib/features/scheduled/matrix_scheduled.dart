import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../hooks/registry.dart' show transformOutgoingText;
import '../../hooks/hook_types.dart';
import '../../room_events.dart';
import '../rich_timeline/message_composition.dart';
import 'delayed_events.dart';
import 'scheduled_features.dart';
import 'scheduled_store.dart';

/// [ScheduledFeatures] over the live backend.
///
/// Sends go through [DelayedRoomEventSender] (the backend's guarded path);
/// listing and management use read access to the SDK client. Every await is
/// followed by an ownership check, and operations for one account are
/// serialised so a refresh cannot overwrite a concurrent schedule/cancel.
class MatrixScheduledMessages extends ChangeNotifier
    implements ScheduledFeatures {
  MatrixScheduledMessages(
    this._backend,
    this._access,
    this._sender, {
    ScheduledMessageStore? store,
    DateTime Function()? clock,
  }) : _store = store ?? ScheduledMessageStore(),
       _clock = clock ?? DateTime.now;

  static const capabilityLifetime = Duration(minutes: 10);

  /// Shortest delay accepted, so the picker's choice is still in the future
  /// by the time the request arrives.
  static const minimumDelay = Duration(seconds: 30);

  final ChatBackend _backend;
  final MatrixSdkAccess _access;
  final DelayedRoomEventSender _sender;
  final ScheduledMessageStore _store;
  final DateTime Function() _clock;

  _Owner? _owner;
  Map<String, ScheduledMessage> _items = const {};
  final _unsaved = <String, ScheduledRecord>{};
  ScheduledLoadState _state = ScheduledLoadState.idle;
  bool _localUnavailable = false;
  bool _loadScheduled = false;
  Future<void>? _refreshing;
  Future<void> _tail = Future<void>.value();
  DelayedEventsCapability? _capability;
  DateTime? _capabilityAt;

  @override
  Listenable get scheduledUpdates => this;

  @override
  ScheduledLoadState get scheduledState {
    _current();
    return _state;
  }

  @override
  bool get localRecordsUnavailable {
    _current();
    return _localUnavailable;
  }

  static String? _accountKeyFor(matrix.Client client) {
    final homeserver = client.homeserver;
    final user = client.userID;
    if (homeserver == null || user == null) return null;
    return jsonEncode([homeserver.toString(), user]);
  }

  /// The current owner; resets cached state (without notifying) when the
  /// signed-in session or account changed.
  _Owner? _current() {
    final client = _access.sdkClient;
    final account = client == null || !_access.isSessionCurrent(client)
        ? null
        : _accountKeyFor(client);
    final owner = _owner;
    if (client == null || account == null) {
      if (owner != null) _reset(null);
      return null;
    }
    if (owner != null &&
        identical(owner.client, client) &&
        owner.account == account) {
      return owner;
    }
    _reset(_Owner(client, account));
    return _owner;
  }

  void _reset(_Owner? owner) {
    _owner = owner;
    _items = const {};
    _unsaved.clear();
    _state = ScheduledLoadState.idle;
    _localUnavailable = false;
    _loadScheduled = false;
    _refreshing = null;
    _capability = null;
    _capabilityAt = null;
  }

  bool _live(_Owner owner) =>
      identical(_owner, owner) &&
      _access.isSessionCurrent(owner.client) &&
      _accountKeyFor(owner.client) == owner.account;

  void _require(_Owner owner) {
    if (!_live(owner)) throw StateError('The session changed');
  }

  _Owner _requireCurrent() {
    final owner = _current();
    if (owner == null) throw StateError('No signed-in session');
    return owner;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  List<ScheduledMessage> scheduledIn(String roomId) {
    _current();
    return [
      for (final item in _items.values)
        if (item.roomId == roomId) item,
    ]..sort((a, b) => a.sendAt.compareTo(b.sendAt));
  }

  @override
  void ensureScheduledLoaded() {
    final owner = _current();
    if (owner == null || _state != ScheduledLoadState.idle || _loadScheduled) {
      return;
    }
    _loadScheduled = true;
    Future<void>.microtask(() {
      if (!identical(_owner, owner)) return;
      _loadScheduled = false;
      if (_state == ScheduledLoadState.idle) unawaited(refreshScheduled());
    });
  }

  @override
  Future<void> refreshScheduled() {
    final owner = _current();
    if (owner == null) return Future<void>.value();
    final running = _refreshing;
    if (running != null) return running;
    late final Future<void> refresh;
    refresh = _serial(() => _refresh(owner)).whenComplete(() {
      if (identical(_refreshing, refresh)) _refreshing = null;
    });
    _refreshing = refresh;
    return refresh;
  }

  Future<void> _refresh(_Owner owner) async {
    if (!_live(owner)) return;
    if (_state == ScheduledLoadState.idle) {
      _state = ScheduledLoadState.loading;
      notifyListeners();
    }
    Map<String, ScheduledRecord>? stored;
    try {
      stored = await _store.read(owner.account);
    } catch (_) {
      stored = null;
    }
    if (!_live(owner)) return;
    final listedAt = _clock().toUtc();
    ServerDelayedEvents? server;
    try {
      server = await fetchScheduledDelayedEvents(owner.client);
    } catch (_) {
      server = null;
    }
    if (!_live(owner)) return;
    final local = {...?stored, ..._unsaved};
    final result = reconcileScheduled(
      local: local,
      server: server,
      listedAt: listedAt,
    );
    if (result.stale.isNotEmpty) {
      _unsaved.removeWhere((id, _) => result.stale.contains(id));
      if (stored != null) {
        try {
          await _store.remove(owner.account, result.stale);
        } catch (_) {
          // Retried on the next refresh; the server list is authoritative.
        }
        if (!_live(owner)) return;
      }
    }
    _items = result.items;
    _localUnavailable = stored == null;
    _state = server == null
        ? ScheduledLoadState.failed
        : ScheduledLoadState.ready;
    notifyListeners();
  }

  @override
  Future<DelayedEventsCapability> delayedEventsCapability({
    bool refresh = false,
  }) async {
    final owner = _requireCurrent();
    return _capabilityFor(owner, refresh: refresh);
  }

  Future<DelayedEventsCapability> _capabilityFor(
    _Owner owner, {
    bool refresh = false,
  }) async {
    final cached = _capability;
    final at = _capabilityAt;
    if (!refresh &&
        cached != null &&
        at != null &&
        _clock().difference(at) < capabilityLifetime) {
      return cached;
    }
    final probed = await probeDelayedEvents(owner.client);
    _require(owner);
    _capability = probed;
    _capabilityAt = _clock();
    return probed;
  }

  Future<Duration> _checkedDelay(_Owner owner, DateTime sendAt) async {
    final capability = await _capabilityFor(owner);
    if (!capability.supported) {
      throw const DelayedEventException(DelayedEventFailure.unsupported);
    }
    final delay = sendAt.difference(_clock());
    if (delay < minimumDelay) {
      throw const ScheduleInputError('Choose a time in the future.');
    }
    final max = capability.maxDelay;
    if (max != null && delay > max) {
      throw DelayedEventException(
        DelayedEventFailure.delayTooLarge,
        maxDelay: max,
      );
    }
    if (delay > maxScheduleDelay) {
      throw const ScheduleInputError('Choose a time within the next year.');
    }
    return delay;
  }

  Future<String> _send(
    _Owner owner,
    String roomId,
    String type,
    Map<String, Object?> content,
    Duration delay,
  ) async {
    try {
      return await _sender.sendRoomEventDelayed(roomId, type, content, delay);
    } on DelayedEventException catch (error) {
      // Limits may have changed: read them again next time.
      if (error.kind == DelayedEventFailure.delayTooLarge ||
          error.kind == DelayedEventFailure.unsupported) {
        _capability = null;
      }
      rethrow;
    }
  }

  @override
  Future<ScheduledMessage> scheduleDraft(
    String roomId,
    ComposerDraft draft,
    DateTime sendAt,
  ) async {
    final owner = _requireCurrent();
    if (draft.editing) {
      throw const ScheduleInputError('Edits can’t be scheduled.');
    }
    final text = draft.text.trim();
    if (text.isEmpty) throw const ScheduleInputError('Write a message first.');
    return _serial(() async {
      _require(owner);
      final delay = await _checkedDelay(owner, sendAt);
      final content = await _compose(owner, roomId, draft, text);
      _require(owner);
      final encrypted = owner.client.getRoomById(roomId)?.encrypted ?? false;
      final delayId = await _send(
        owner,
        roomId,
        matrix.EventTypes.Message,
        content,
        delay,
      );
      // Scheduled on the server from here on: never report failure.
      return _remember(
        owner,
        ScheduledRecord(
          delayId: delayId,
          roomId: roomId,
          type: matrix.EventTypes.Message,
          content: content,
          sendAt: _clock().add(delay).toUtc(),
          createdAt: _clock().toUtc(),
          encrypted: encrypted,
        ),
      );
    });
  }

  /// Builds `m.room.message` content exactly like a normal send: markdown,
  /// `/me` and mentions (composeTextMessage), then feature transforms
  /// (transformOutgoingText), plus reply/thread relations.
  Future<Map<String, Object?>> _compose(
    _Owner owner,
    String roomId,
    ComposerDraft draft,
    String text,
  ) async {
    final client = owner.client;
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw const ScheduleInputError('You’re no longer in this room.');
    }
    final replyId = draft.replyToId;
    String? replySender;
    if (replyId != null) {
      final reply = await room.getEventById(replyId);
      _require(owner);
      if (reply == null || reply.redacted) {
        throw const ScheduleInputError(
          'The message you’re replying to is no longer available.',
        );
      }
      replySender = reply.senderId;
    }
    final content = Map<String, Object?>.of(
      transformOutgoingText(
        OutgoingTextContext(backend: _backend, roomId: roomId, text: text),
        composeTextMessage(
          text,
          ownUserId: client.userID,
          replyToSender: replySender,
        ),
      ),
    );
    final threadRoot = draft.threadRootId;
    if (threadRoot != null) {
      content['m.relates_to'] = {
        'rel_type': matrix.RelationshipTypes.thread,
        'event_id': threadRoot,
        'is_falling_back': replyId == null,
        if (replyId != null) 'm.in_reply_to': {'event_id': replyId},
      };
    } else if (replyId != null) {
      content['m.relates_to'] = {
        'm.in_reply_to': {'event_id': replyId},
      };
    }
    return content;
  }

  Future<ScheduledMessage> _remember(
    _Owner owner,
    ScheduledRecord record,
  ) async {
    final message = ScheduledMessage(
      delayId: record.delayId,
      roomId: record.roomId,
      type: record.type,
      sendAt: record.sendAt,
      encrypted: record.encrypted,
      content: record.content,
    );
    if (!_live(owner)) return message;
    try {
      await _store.put(owner.account, record);
    } catch (_) {
      // Keep it listed for this session: an encrypted server-only entry
      // could not otherwise be shown or cancelled here.
      if (_live(owner)) _unsaved[record.delayId] = record;
    }
    if (!_live(owner)) return message;
    _items = {..._items, record.delayId: message};
    if (_state == ScheduledLoadState.idle) _state = ScheduledLoadState.ready;
    notifyListeners();
    return message;
  }

  Future<void> _forget(_Owner owner, String delayId) async {
    if (!_live(owner)) return;
    _unsaved.remove(delayId);
    if (_items.containsKey(delayId)) {
      _items = Map.of(_items)..remove(delayId);
      notifyListeners();
    }
    try {
      await _store.remove(owner.account, [delayId]);
    } catch (_) {
      // Reconciled on the next refresh.
    }
  }

  Future<void> _manage(
    ScheduledMessage message,
    DelayedEventCommand command,
  ) async {
    final owner = _requireCurrent();
    return _serial(() async {
      _require(owner);
      try {
        await manageScheduledEvent(owner.client, message.delayId, command);
      } on DelayedEventException catch (error) {
        if (error.kind == DelayedEventFailure.notFound) {
          await _forget(owner, message.delayId);
        }
        rethrow;
      }
      await _forget(owner, message.delayId);
    });
  }

  @override
  Future<void> sendScheduledNow(ScheduledMessage message) =>
      _manage(message, DelayedEventCommand.send);

  @override
  Future<void> cancelScheduled(ScheduledMessage message) =>
      _manage(message, DelayedEventCommand.cancel);

  /// Schedules the new copy first, so a failure never loses the message,
  /// then cancels the original. If the original was already sent, the copy
  /// is withdrawn again rather than sending twice.
  @override
  Future<ScheduledMessage> rescheduleScheduled(
    ScheduledMessage message,
    DateTime sendAt,
  ) async {
    final owner = _requireCurrent();
    final content = message.content;
    if (content == null || content.isEmpty) {
      throw const ScheduleInputError(
        'This message can’t be rescheduled from this device.',
      );
    }
    return _serial(() async {
      _require(owner);
      final delay = await _checkedDelay(owner, sendAt);
      final delayId = await _send(
        owner,
        message.roomId,
        message.type,
        content,
        delay,
      );
      final copy = await _remember(
        owner,
        ScheduledRecord(
          delayId: delayId,
          roomId: message.roomId,
          type: message.type,
          content: content,
          sendAt: _clock().add(delay).toUtc(),
          createdAt: _clock().toUtc(),
          encrypted: message.encrypted,
        ),
      );
      try {
        await manageScheduledEvent(
          owner.client,
          message.delayId,
          DelayedEventCommand.cancel,
        );
      } on DelayedEventException catch (error) {
        if (error.kind != DelayedEventFailure.notFound) {
          throw const ScheduleInputError(
            'Rescheduled, but the original is still scheduled. '
            'Cancel it from the list.',
          );
        }
        await _forget(owner, message.delayId);
        try {
          await manageScheduledEvent(
            owner.client,
            delayId,
            DelayedEventCommand.cancel,
          );
          await _forget(owner, delayId);
        } catch (_) {
          throw const ScheduleInputError(
            'The original was already sent, and the new copy is still '
            'scheduled. Cancel it from the list.',
          );
        }
        rethrow;
      } catch (_) {
        throw const ScheduleInputError(
          'Rescheduled, but the original is still scheduled. '
          'Cancel it from the list.',
        );
      }
      await _forget(owner, message.delayId);
      return copy;
    });
  }
}

class _Owner {
  _Owner(this.client, this.account);
  final matrix.Client client;
  final String account;
}

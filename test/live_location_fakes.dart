import 'dart:async';

import 'package:parallax/features/live_location/live_location_sharer.dart';
import 'package:parallax/features/live_location/live_share_store.dart';
import 'package:parallax/features/live_location/position_source.dart';
import 'package:parallax/features/polls/location_model.dart';

/// Manual clock: timers fire only when [advance] passes their deadline.
class FakeLiveClock implements LiveClock {
  FakeLiveClock(this._now);
  DateTime _now;
  final _timers = <_FakeTimer>[];

  @override
  DateTime now() => _now;

  @override
  Timer timer(Duration delay, void Function() callback) {
    final timer = _FakeTimer(
      this,
      _now.add(delay.isNegative ? Duration.zero : delay),
      callback,
    );
    _timers.add(timer);
    return timer;
  }

  int get pendingTimers => _timers.where((t) => t.isActive).length;

  /// Moves time forward, firing due timers in deadline order. Yields to the
  /// event loop between timers so async work they start can settle.
  Future<void> advance(Duration by) async {
    final target = _now.add(by);
    while (true) {
      final due =
          _timers.where((t) => t.isActive && !t.at.isAfter(target)).toList()
            ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final next = due.first;
      if (next.at.isAfter(_now)) _now = next.at;
      next.fire();
      await settle();
    }
    _now = target;
    await settle();
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.clock, this.at, this.callback);
  final FakeLiveClock clock;
  final DateTime at;
  final void Function() callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    clock._timers.remove(this);
    callback();
  }

  @override
  void cancel() {
    _active = false;
    clock._timers.remove(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakePositions implements LivePositionSource {
  FakePositions({this.access = LocationAccess.granted});
  LocationAccess access;
  LocationAccess? requestResult;
  int checks = 0;
  int requests = 0;
  int watches = 0;
  int settingsOpened = 0;
  StreamController<PositionFix>? controller;

  bool get watching => controller != null && controller!.hasListener;

  @override
  Future<LocationAccess> check() async {
    checks++;
    return access;
  }

  @override
  Future<LocationAccess> request() async {
    requests++;
    return requestResult ?? access;
  }

  @override
  Stream<PositionFix> watch() {
    watches++;
    final controller = StreamController<PositionFix>();
    controller.onCancel = () {
      if (identical(this.controller, controller)) this.controller = null;
    };
    this.controller = controller;
    return controller.stream;
  }

  void emit(GeoPoint point, DateTime at) =>
      controller?.add(PositionFix(point, receivedAt: at));

  void fail(Object error) => controller?.addError(error);

  @override
  Future<void> openAppSettings() async => settingsOpened++;

  @override
  Future<void> openLocationSettings() async => settingsOpened++;
}

class MemoryShareStore implements LiveShareStore {
  final records = <String, List<PersistedShare>>{};
  int clears = 0;

  @override
  Future<List<PersistedShare>> load(String accountKey) async =>
      List.of(records[accountKey] ?? const []);

  @override
  Future<void> save(String accountKey, List<PersistedShare> shares) async {
    if (shares.isEmpty) {
      records.remove(accountKey);
    } else {
      records[accountKey] = List.of(shares);
    }
  }

  @override
  Future<void> clear(String accountKey) async {
    clears++;
    records.remove(accountKey);
  }
}

typedef TransportCall = ({
  String kind,
  String roomId,
  Map<String, Object?> content,
});

class FakeTransport implements LiveLocationTransport {
  final calls = <TransportCall>[];
  final serverState = <String, Map<String, Object?>>{};
  Completer<String>? startGate;
  Completer<String>? beaconGate;
  Object? startError;
  Object? beaconError;
  Object? stateReadError;
  Object? stopError;
  int _next = 0;

  List<TransportCall> get beacons =>
      calls.where((c) => c.kind == 'beacon').toList();
  List<TransportCall> get stateWrites =>
      calls.where((c) => c.kind == 'start' || c.kind == 'write').toList();

  @override
  Future<String> startBeaconInfo(
    String roomId,
    Map<String, Object?> content,
  ) async {
    calls.add((kind: 'start', roomId: roomId, content: content));
    final error = startError;
    if (error != null) throw error;
    final gate = startGate;
    final id = gate != null ? await gate.future : '\$info${_next++}';
    serverState[roomId] = content;
    return id;
  }

  @override
  Future<void> writeBeaconInfo(
    String roomId,
    Map<String, Object?> content,
  ) async {
    calls.add((kind: 'write', roomId: roomId, content: content));
    final error = stopError;
    if (error != null) throw error;
    serverState[roomId] = content;
  }

  @override
  Future<String> sendBeacon(String roomId, Map<String, Object?> content) async {
    calls.add((kind: 'beacon', roomId: roomId, content: content));
    final gate = beaconGate;
    if (gate != null) {
      beaconGate = null;
      return gate.future;
    }
    final error = beaconError;
    if (error != null) throw error;
    return '\$beacon${_next++}';
  }

  @override
  Future<Map<String, Object?>?> ownBeaconInfo(String roomId) async {
    calls.add((kind: 'read', roomId: roomId, content: const {}));
    final error = stateReadError;
    if (error != null) throw error;
    return serverState[roomId];
  }
}

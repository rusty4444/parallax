// Shared fakes for the Element Call module tests.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/call/call_features.dart';
import 'package:parallax/features/call/call_memberships.dart';
import 'package:parallax/features/call/call_web_host.dart';
import 'package:parallax/features/call/call_widget_url.dart';
import 'package:parallax/features/call/widget_capabilities.dart';
import 'package:parallax/features/call/widget_driver.dart';
import 'package:parallax/platform_permissions.dart';

const testUser = '@me:example.org';
const testDevice = 'DEVICEID';
const testRoom = '!room:example.org';

class FakeCallMatrix implements CallWidgetMatrix {
  FakeCallMatrix({this.encrypted = true});

  bool encrypted;
  final calls = <String>[];
  final roomSends = <(String, Map<String, Object?>)>[];
  final stateSends = <(String, String, Map<String, Object?>)>[];
  final delayedSends = <(String, String, int)>[];
  final delayedUpdates = <(String, String)>[];
  final toDevice = <(String, Map<String, Object?>, bool)>[];
  final redactions = <String>[];
  Map<String, List<Map<String, Object?>>> state = {};
  List<Map<String, Object?>> history = [];
  Object? openIdError;
  Object? delayedError;
  bool disposed = false;
  final roomEventController =
      StreamController<Map<String, Object?>>.broadcast();
  final stateController = StreamController<Map<String, Object?>>.broadcast();
  final toDeviceController = StreamController<Map<String, Object?>>.broadcast();

  @override
  String get roomId => testRoom;

  @override
  bool get roomEncrypted => encrypted;

  @override
  Future<Map<String, Object?>> requestOpenId() async {
    calls.add('openid');
    if (openIdError != null) throw openIdError!;
    return {
      'access_token': 'openid-token',
      'expires_in': 3600,
      'matrix_server_name': 'example.org',
      'token_type': 'Bearer',
    };
  }

  @override
  Future<String> sendRoomEvent(
    String type,
    Map<String, Object?> content,
  ) async {
    roomSends.add((type, content));
    return r'$sent';
  }

  @override
  Future<String?> redactOwnEvent(String eventId) async {
    redactions.add(eventId);
    return null;
  }

  @override
  Future<String> sendStateEvent(
    String type,
    String stateKey,
    Map<String, Object?> content,
  ) async {
    stateSends.add((type, stateKey, content));
    return r'$state';
  }

  @override
  Future<String> sendDelayedStateEvent(
    String type,
    String stateKey,
    Map<String, Object?> content, {
    required int delayMs,
  }) async {
    delayedSends.add((type, stateKey, delayMs));
    if (delayedError != null) throw delayedError!;
    return 'delay-1';
  }

  @override
  Future<void> updateDelayedEvent(String delayId, String action) async {
    delayedUpdates.add((delayId, action));
  }

  @override
  Future<Map<String, List<String>>> sendToDevice(
    String type,
    Map<String, Map<String, Map<String, Object?>>> messages, {
    required bool encrypted,
  }) async {
    toDevice.add((type, messages, encrypted));
    return const {};
  }

  @override
  Future<List<Map<String, Object?>>> readState(
    String type, {
    String? stateKey,
  }) async => [
    for (final event in state[type] ?? const <Map<String, Object?>>[])
      if (stateKey == null || event['state_key'] == stateKey) event,
  ];

  @override
  Future<List<Map<String, Object?>>> readEvents(
    String type, {
    required int limit,
  }) async => [
    for (final event in history)
      if (event['type'] == type) event,
  ];

  @override
  Stream<Map<String, Object?>> get roomEvents => roomEventController.stream;

  @override
  Stream<Map<String, Object?>> get stateUpdates => stateController.stream;

  @override
  Stream<Map<String, Object?>> get toDeviceEvents => toDeviceController.stream;

  @override
  void dispose() => disposed = true;
}

Map<String, Object?> stateEvent(
  String type,
  String stateKey,
  Map<String, Object?> content, {
  String sender = '@alice:example.org',
}) => {
  'type': type,
  'state_key': stateKey,
  'sender': sender,
  'content': content,
  'event_id': '\$${type.hashCode}-$stateKey',
  'room_id': testRoom,
  'origin_server_ts': 1700000000000,
};

/// Backend that only supports calls; every other ChatBackend member throws.
class FakeCallBackend extends ChatBackend implements CallFeatures {
  FakeCallBackend({this.direct = false});

  bool direct;
  String? identity = testUser;
  SessionStatus status = SessionStatus.ready;
  RoomCallSummary summary = RoomCallSummary.none;
  bool joinAllowed = true;
  final changes = StreamController<String>.broadcast();
  final rings = StreamController<IncomingCall>.broadcast();
  final declines = <(String, String)>[];
  final prepared = <String>[];
  FakeCallMatrix matrix = FakeCallMatrix();
  Object? prepareError;
  CallServiceInfo serviceInfo = CallServiceInfo(
    baseUrl: Uri.parse(defaultElementCallUrl),
    source: CallUrlSource.defaultUrl,
  );

  @override
  String? get userId => identity;

  @override
  SessionStatus get connection => status;

  @override
  RoomCallSummary roomCall(String roomId) => summary;

  @override
  Stream<String> get callChanges => changes.stream;

  @override
  Stream<IncomingCall> get incomingCalls => rings.stream;

  @override
  bool canJoinCall(String roomId) => joinAllowed;

  @override
  Future<CallLaunch> prepareCall(
    String roomId,
    CallLaunchOptions options,
  ) async {
    prepared.add(roomId);
    if (prepareError != null) throw prepareError!;
    final intent = callIntentFor(
      direct: direct,
      hasActiveCall: summary.active,
      audioOnly: options.audioOnly,
    );
    return CallLaunch(
      url: buildElementCallUrl(
        ElementCallUrlParams(
          baseUrl: serviceInfo.baseUrl,
          widgetId: 'widget-1',
          userId: testUser,
          deviceId: testDevice,
          roomId: roomId,
          homeserver: Uri.parse('https://matrix.example.org'),
          encrypted: true,
          intent: intent,
          language: options.language,
          theme: options.theme,
        ),
      ),
      widgetId: 'widget-1',
      intent: intent,
      matrix: matrix,
      allowedCapabilities: elementCallAllowedCapabilities(
        userId: testUser,
        deviceId: testDevice,
        roomId: roomId,
      ),
    );
  }

  @override
  Future<CallServiceInfo> callServiceInfo() async => serviceInfo;

  @override
  Future<void> declineCall(String roomId, String notificationEventId) async {
    declines.add((roomId, notificationEventId));
  }

  void signOut() {
    identity = null;
    status = SessionStatus.signedOut;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakePermissions extends PlatformPermissions {
  const FakePermissions({this.microphone = true, this.camera = true});
  final bool microphone;
  final bool camera;

  @override
  Future<Map<String, bool>> request(List<String> permissions) async => {
    PlatformPermissions.microphone: microphone,
    PlatformPermissions.camera: camera,
  };
}

/// WebView stand-in: records loads and posted messages, lets tests inject
/// page events.
class FakeWebHost implements CallWebHost {
  FakeWebHost({
    required this.page,
    required this.allowCamera,
    required this.allowMicrophone,
    required this.onMessage,
    required this.onLoadError,
    required this.onPageFinished,
  });

  final Uri page;
  final bool allowCamera;
  final bool allowMicrophone;
  final void Function(String) onMessage;
  final void Function(String) onLoadError;
  final void Function() onPageFinished;
  final loads = <Uri>[];
  final posted = <String>[];
  bool disposed = false;

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.black, child: Text('webview'));

  @override
  Future<void> load(Uri url) async => loads.add(url);

  @override
  Future<void> post(String json) async => posted.add(json);

  @override
  void dispose() => disposed = true;
}

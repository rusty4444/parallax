// Backend interface for the Element Call module.
//
// Core `ChatBackend` stays unchanged: the live Matrix backend is wrapped by
// MatrixCallFeatures (via MatrixSdkAccess + RoomEventFeatures) and test fakes
// implement [CallFeatures] directly.

import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'call_memberships.dart';
import 'call_widget_url.dart';
import 'matrix_call_features.dart';
import 'widget_driver.dart';

/// An MSC4075 ring addressed to this account.
@immutable
class IncomingCall {
  const IncomingCall({
    required this.roomId,
    required this.eventId,
    required this.senderId,
    required this.senderName,
    required this.roomName,
    required this.expiresAt,
    this.audioOnly = false,
    this.senderAvatar,
  });

  final String roomId;

  /// The notification event (for declines).
  final String eventId;
  final String senderId;
  final String senderName;
  final String roomName;
  final DateTime expiresAt;
  final bool audioOnly;
  final Uri? senderAvatar;
}

/// Client preferences that shape the widget URL.
@immutable
class CallLaunchOptions {
  const CallLaunchOptions({
    this.language = 'en-AU',
    this.theme = 'dark',
    this.fontScale,
    this.audioOnly = false,
  });

  final String language;
  final String theme;
  final double? fontScale;
  final bool audioOnly;
}

/// What the call screen needs to load Element Call for one room.
class CallLaunch {
  CallLaunch({
    required this.url,
    required this.widgetId,
    required this.intent,
    required this.matrix,
    required this.allowedCapabilities,
  });

  final Uri url;
  final String widgetId;
  final CallIntent intent;
  final CallWidgetMatrix matrix;
  final Set<String> allowedCapabilities;

  /// Origin the WebView may navigate within.
  String get origin => url.origin;
}

/// Where the Element Call base URL came from (shown in settings).
enum CallUrlSource { defaultUrl, homeserver, custom }

/// Homeserver discovery relevant to calls (`.well-known/matrix/client`).
@immutable
class CallServiceInfo {
  const CallServiceInfo({
    required this.baseUrl,
    required this.source,
    this.rtcFocusHosts = const [],
    this.discoveryFailed = false,
  });

  final Uri baseUrl;
  final CallUrlSource source;

  /// Hosts of advertised `org.matrix.msc4143.rtc_foci` LiveKit services.
  final List<String> rtcFocusHosts;
  final bool discoveryFailed;
}

abstract interface class CallFeatures {
  /// The live room call from cached MatrixRTC membership state.
  RoomCallSummary roomCall(String roomId);

  /// Room IDs whose call membership may have changed (broadcast).
  Stream<String> get callChanges;

  /// Rings addressed to this account as they arrive (broadcast).
  Stream<IncomingCall> get incomingCalls;

  /// Whether this user may join or start a call here (membership + power
  /// level for call membership state).
  bool canJoinCall(String roomId);

  /// Builds the widget URL and a Matrix driver bound to [roomId].
  Future<CallLaunch> prepareCall(String roomId, CallLaunchOptions options);

  /// Resolves the Element Call URL and MatrixRTC service advertisement.
  Future<CallServiceInfo> callServiceInfo();

  /// Declines a ring (MSC4310 decline referencing the notification).
  Future<void> declineCall(String roomId, String notificationEventId);
}

final _matrixFeatures = Expando<CallFeatures>('callFeatures');

/// Resolves call support for [backend], or null when calls are unavailable.
CallFeatures? callFeaturesOf(ChatBackend backend) {
  if (backend is CallFeatures) return backend as CallFeatures;
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _matrixFeatures[backend] ??= MatrixCallFeatures(backend);
  }
  return null;
}

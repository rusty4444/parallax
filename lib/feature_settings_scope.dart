import 'package:flutter/widgets.dart';

import 'appearance_preferences.dart';
import 'chat_backend.dart';
import 'message_draft_store.dart';
import 'messaging_features.dart';
import 'push_notifications.dart';

/// App-owned preferences and draft storage, shared by every pushed route.
class FeatureSettingsScope extends InheritedNotifier<AppearancePreferences> {
  const FeatureSettingsScope({
    super.key,
    required AppearancePreferences preferences,
    required this.draftStore,
    this.notifications,
    required super.child,
  }) : super(notifier: preferences);

  final MessageDraftStore draftStore;
  final PushNotifications? notifications;

  AppearancePreferences get preferences => notifier!;

  static FeatureSettingsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeatureSettingsScope>();

  @override
  bool updateShouldNotify(FeatureSettingsScope oldWidget) =>
      draftStore != oldWidget.draftStore ||
      notifications != oldWidget.notifications ||
      super.updateShouldNotify(oldWidget);
}

/// Pins async UI work to the session that started it, including a logout/login
/// of the same account. A send may retain its owner until queue acceptance so
/// closing a route cannot resurrect an already accepted message as a draft.
class BackendSessionOwner {
  BackendSessionOwner(this.backend)
    : accountKey = keyFor(backend),
      userId = backend.userId,
      _status = backend.connection {
    backend.addListener(_check);
  }

  final ChatBackend backend;
  final String? accountKey;
  final String? userId;
  SessionStatus _status;
  bool _invalid = false;
  int _leases = 1;

  static String? keyFor(ChatBackend backend) => backend is MessagingFeatures
      ? (backend as MessagingFeatures).accountKey
      : backend.userId;

  bool get isCurrent {
    _check();
    return !_invalid && _leases > 0;
  }

  void _check() {
    if (keyFor(backend) != accountKey ||
        backend.userId != userId ||
        (backend.connection == SessionStatus.signedOut &&
            _status != SessionStatus.signedOut)) {
      _invalid = true;
    }
    _status = backend.connection;
  }

  void retain() => _leases++;

  void release() {
    if (--_leases == 0) backend.removeListener(_check);
  }
}

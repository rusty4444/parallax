import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat_backend.dart';

/// "Undo send" grace period (Off / 5 s / 10 s / 20 s, default 5 s).
///
/// App-wide and nonsensitive, so it lives in shared preferences. Defaults
/// apply until [ensureLoaded] completes; writes persist before the in-memory
/// value changes.
class UndoSendPreferences extends ChangeNotifier {
  UndoSendPreferences({SharedPreferences? preferences}) : _prefs = preferences;

  /// Shared instance read by the outbox wiring and the settings section.
  static final shared = UndoSendPreferences();

  static const secondsKey = 'parallax.undo_send.v1.seconds';
  static const choices = [0, 5, 10, 20];
  static const defaultSeconds = 5;

  SharedPreferences? _prefs;
  Future<void>? _loading;
  int _seconds = defaultSeconds;
  Future<void> _tail = Future<void>.value();

  int get seconds => _seconds;
  Duration get delay => Duration(seconds: _seconds);

  /// Loads the saved value once. Failures keep the default and allow a retry.
  Future<void> ensureLoaded() => _loading ??= _load().catchError((Object _) {
    _loading = null;
  });

  Future<void> _load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final value = prefs.get(secondsKey);
    if (value is int && choices.contains(value) && value != _seconds) {
      _seconds = value;
      notifyListeners();
    }
  }

  /// The grace period after a bounded attempt to load the saved value.
  Future<Duration> resolveDelay() async {
    try {
      await ensureLoaded().timeout(const Duration(seconds: 2));
    } catch (_) {
      // The default (5 s) applies.
    }
    return delay;
  }

  Future<void> setSeconds(int value) {
    if (!choices.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unsupported undo period');
    }
    final result = _tail.then((_) async {
      await ensureLoaded();
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      if (!await prefs.setInt(secondsKey, value)) {
        throw StateError('Could not save the undo send setting');
      }
      if (_seconds == value) return;
      _seconds = value;
      notifyListeners();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// A send withdrawn by Undo, for putting back into the composer.
@immutable
class UndoneSend {
  const UndoneSend({
    required this.text,
    this.replyToId,
    this.threadRootId,
    this.attachmentName,
  });

  /// Message text, or the caption of an attachment ('' when none).
  final String text;
  final String? replyToId;
  final String? threadRootId;

  /// Set when the withdrawn send was an attachment (which is discarded).
  final String? attachmentName;
}

/// Undo send over the backend's outbox (implemented by `MatrixBackend`).
abstract interface class UndoSendFeatures {
  /// When pending send [pendingId] is held for undo, the time it will be
  /// transmitted; null when it is not held.
  DateTime? undoDeadline(String pendingId);

  /// Withdraws a held send before transmission. Returns null when it is too
  /// late (transmission already started) or unknown.
  Future<UndoneSend?> undoSend(String pendingId);
}

UndoSendFeatures? undoSendFeaturesOf(ChatBackend backend) =>
    backend is UndoSendFeatures ? backend as UndoSendFeatures : null;

/// Calls [onBackground] when the app is hidden, paused or detached, so held
/// sends go out instead of waiting in a process the OS may freeze or kill.
/// Returns null when no Flutter binding is available (plain unit tests).
AppLifecycleListener? watchAppBackground(VoidCallback onBackground) {
  try {
    return AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) {
          onBackground();
        }
      },
    );
  } catch (_) {
    return null;
  }
}

/// Whole seconds left until [deadline], rounded up (never negative).
int secondsUntil(DateTime deadline, DateTime now) {
  final millis = deadline.difference(now).inMilliseconds;
  if (millis <= 0) return 0;
  return (millis + 999) ~/ 1000;
}

/// Rebuilds once a second with the seconds left until [deadline].
class HeldSendCountdown extends StatefulWidget {
  const HeldSendCountdown({
    super.key,
    required this.deadline,
    required this.builder,
    this.clock = DateTime.now,
  });
  final DateTime deadline;
  final Widget Function(BuildContext context, int seconds) builder;
  final DateTime Function() clock;

  @override
  State<HeldSendCountdown> createState() => _HeldSendCountdownState();
}

class _HeldSendCountdownState extends State<HeldSendCountdown> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(HeldSendCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deadline != widget.deadline) _start();
  }

  void _start() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (secondsUntil(widget.deadline, widget.clock()) == 0) {
        _ticker?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, secondsUntil(widget.deadline, widget.clock()));
}

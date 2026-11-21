import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app_theme.dart';
import 'appearance_preferences.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'hooks/registry.dart';
import 'inbox_screen.dart';
import 'login_screen.dart';
import 'matrix_backend.dart';
import 'message_draft_store.dart';
import 'push_notifications.dart';
import 'security_overlay.dart';
import 'two_pane.dart';
import 'widgets.dart';
import 'features/app_fonts/app_fonts.dart' show registerAppFontLicences;
import 'features/live_location/live_location_hooks.dart'
    show liveLocationBeforeLogout;
import 'features/message_fonts/message_fonts.dart'
    show registerMessageFontLicences;
import 'features/platform/apple_bootstrap.dart';
import 'features/platform/background_connection.dart';
import 'features/platform/desktop_content_insets.dart';
import 'features/platform/desktop_shell.dart';
import 'features/platform/windows_bootstrap.dart';
import 'haptics.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeApplePlatform();
  assert(() {
    _installDebugLog();
    return true;
  }());
  initializeWindowsPlatform();
  // Only registers a callback: the licence files load when the licence page
  // opens.
  registerMessageFontLicences();
  registerAppFontLicences();
  if (Platform.isWindows || Platform.isMacOS) {
    // Replace the native caption with the blended desktop header. On macOS
    // TitleBarStyle.hidden keeps the traffic lights; on Windows the
    // DesktopTitleBar draws the caption buttons.
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
  }
  runApp(const ParallaxApp());
  _installFrameDump();
}

final GlobalKey _frameDumpKey = GlobalKey();

/// Diagnostic: with PARALLAX_FRAME_DUMP=1, write a PNG of the rendered UI
/// shortly after startup. Win32 screen/PrintWindow capture cannot read the
/// Flutter GPU swap chain on some Windows builds, so this dumps the frame
/// from inside the engine instead.
void _installFrameDump() {
  if (!Platform.isWindows) return;
  if (Platform.environment['PARALLAX_FRAME_DUMP'] != '1') return;
  Future<void>.delayed(const Duration(seconds: 6), () async {
    try {
      final obj = _frameDumpKey.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return;
      final image = await obj.toImage(pixelRatio: 1.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      File(
        r'C:\Users\Public\Documents\parallax-framedump.png',
      ).writeAsBytesSync(data.buffer.asUint8List());
    } catch (_) {
      // Best-effort diagnostic.
    }
  });
}

/// Debug-build-only diagnostic: timestamped SDK log to a file, for
/// investigating live flows such as verification stalls. Compiled out of
/// release builds by the assert, and skipped under `flutter test`.
void _installDebugLog() {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  final file = File(
    Platform.isWindows
        ? r'C:\Users\Public\Documents\parallax-debug.log'
        : '${Directory.systemTemp.path}/parallax-debug.log',
  );
  matrix.Logs().level = matrix.Level.verbose;
  matrix.Logs().onLog = (event) {
    try {
      file.writeAsStringSync(
        '${DateTime.now().toIso8601String()} [${event.level.name}] '
        '${event.toFormattedString()}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Diagnostics must never break the app.
    }
  };
}

typedef MatrixBackendFactory =
    MatrixBackend Function({
      required Future<void> Function() beforeLogout,
      required bool Function() sendReadReceipts,
    });

class ParallaxApp extends StatefulWidget {
  const ParallaxApp({
    super.key,
    this.backend,
    this.preferences,
    this.draftStore,
    this.notifications,
    this.backendFactory,
    this.notificationsFactory,
  }) : assert(backend == null || backendFactory == null),
       assert(notifications == null || notificationsFactory == null);
  final ChatBackend? backend;
  final AppearancePreferences? preferences;
  final MessageDraftStore? draftStore;

  /// Borrowed resources are detached, never disposed by this widget.
  final PushNotifications? notifications;

  /// Factories transfer ownership to the app; useful for lifecycle tests.
  @visibleForTesting
  final MatrixBackendFactory? backendFactory;
  @visibleForTesting
  final PushNotifications Function()? notificationsFactory;

  @override
  State<ParallaxApp> createState() => _ParallaxAppState();
}

class _ParallaxAppState extends State<ParallaxApp> with WidgetsBindingObserver {
  late final AppearancePreferences _preferences;
  late final MessageDraftStore _draftStore;
  late final PushNotifications _notifications;
  late final ChatBackend _backend;
  late final bool _ownsPreferences;
  late final bool _ownsNotifications;
  late final bool _ownsBackend;
  VisualTheme _style = defaultVisualTheme;
  bool _followSystemTheme = false;
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// Chat routes above the inbox, so widening the window (tablet, unfold)
  /// can absorb them into the detail pane.
  final _roomRoutes = RoomRouteObserver();
  String? _accountKey;
  String? _userId;
  bool _authenticated = false;
  bool _rebuildScheduled = false;
  int _themeRevision = 0;
  bool _closing = false;
  bool _pushReady = false;
  bool _notificationsStarting = false;

  /// UnifiedPush could not start in this process: stay on the built-in
  /// connection until the next launch instead of retrying on every resume.
  bool _unifiedPushFailed = false;
  bool _pushBindingObserved = false;
  String? _pushSessionKey;
  PushSession? _pushSession;
  int _pushGeneration = 0;
  String? _pushError;
  String? _startupError;
  Future<void>? _starting;
  Future<void>? _pushInitializing;
  Future<void>? _backendInitializing;
  bool _backendReady = false;
  final _startupDeadlines = <Timer, Completer<void>>{};

  @override
  void initState() {
    super.initState();
    // Resource identity and ownership belong to this State, not a later widget
    // configuration. Use a new widget key to replace an app's injected owners.
    _ownsPreferences = widget.preferences == null;
    _ownsNotifications = widget.notifications == null;
    _ownsBackend = widget.backend == null;
    _preferences = widget.preferences ?? AppearancePreferences();
    _preferences.addListener(_syncHaptics);
    _syncHaptics();
    _draftStore = widget.draftStore ?? MessageDraftStore();
    _notifications =
        widget.notifications ??
        widget.notificationsFactory?.call() ??
        PushNotifications();
    _backend =
        widget.backend ??
        (widget.backendFactory != null
            ? widget.backendFactory!(
                beforeLogout: _notifications.logout,
                sendReadReceipts: () => _preferences.sendReadReceipts,
              )
            : MatrixBackend(
                beforeLogout: _beforeLogout,
                sendReadReceipts: () => _preferences.sendReadReceipts,
                sendTypingNotifications: () =>
                    _preferences.sendTypingNotifications,
              ));
    _accountKey = BackendSessionOwner.keyFor(_backend);
    _userId = _backend.userId;
    _authenticated = _backend.connection == SessionStatus.ready;
    _backend.addListener(_sessionChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_start());
      unawaited(_loadTheme());
    });
  }

  void _syncHaptics() => Haptics.enabled = _preferences.haptics;

  void _sessionChanged() {
    final account = BackendSessionOwner.keyFor(_backend);
    final user = _backend.userId;
    final signedOut = _backend.connection == SessionStatus.signedOut;
    final replaced = account != _accountKey || user != _userId;
    if (_authenticated && (signedOut || replaced)) {
      // Replacing the navigator removes *all* pushed decrypted routes, rather
      // than merely changing the home widget underneath a media/thread route.
      _navigatorKey = GlobalKey<NavigatorState>();
      // The old navigator's routes died without pops; drop their records.
      _roomRoutes.reset();
      _authenticated = false;
      _scheduleRebuild();
    }
    _accountKey = account;
    _userId = user;
    if (_backend.connection == SessionStatus.ready && !_authenticated) {
      _authenticated = true;
      // Signed-in wrappers (app lock, calls, share intents) attach now.
      _scheduleRebuild();
    }
    _bindPushSession();
  }

  void _scheduleRebuild() {
    if (!mounted || _closing || _rebuildScheduled) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _rebuildScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _rebuildScheduled = false;
        if (mounted && !_closing) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _start() => _starting ??= _startOnce().whenComplete(() {
    _starting = null;
  });

  Future<void> _startOnce() async {
    // Apply saved privacy preferences before the SDK can restore any room.
    await _loadAppearance();
    if (!mounted || _closing) return;
    // This is local revocation only, NOT Firebase/token initialization. A failed
    // push store must not trap messaging on its splash screen or permit opt-in.
    await _initializePush();
    if (!mounted || _closing) return;
    await _initialize();
    if (!mounted || _closing) return;
    _bindPushSession();
  }

  Future<void> _initializePush() async {
    if (_pushReady) return;
    try {
      // Retain a timed-out operation: timeout is not cancellation. A retry joins
      // the same local write instead of racing a late revocation against opt-in.
      _pushInitializing ??= _notifications.initialize();
      await _waitForStartup(_pushInitializing!, const Duration(seconds: 15));
      if (!mounted || _closing) return;
      _pushReady = true;
      _pushError = null;
    } catch (error) {
      if (!mounted || _closing) return;
      if (error is! TimeoutException) _pushInitializing = null;
      _pushError =
          'Push notifications are unavailable: local notification storage could '
          'not be cleared. Push stays off. Retry to enable notification settings.';
    }
    _scheduleRebuild();
  }

  Future<void> _retryPush() async {
    await _initializePush();
    if (!mounted || _closing || !_pushReady) return;
    // Explicit retry, not ordinary sync, may reattempt a failed cleanup/bind.
    _pushBindingObserved = false;
    _bindPushSession();
  }

  Future<void> _initialize() async {
    _startupError = null;
    _scheduleRebuild();
    try {
      _backendInitializing ??= _backend.initialize().whenComplete(() {
        _backendInitializing = null;
      });
      await _waitForStartup(_backendInitializing!, const Duration(seconds: 45));
      if (!mounted || _closing) return;
      _backendReady = true;
    } catch (_) {
      if (!mounted || _closing) return;
      // Injected/platform implementations may throw without changing connection.
      // Render a retry instead of leaving SessionStatus.loading spinning forever.
      _startupError =
          'Could not initialize local Matrix storage or encryption. '
          'Try again; if this continues, check device storage and permissions.';
      _scheduleRebuild();
    }
  }

  /// A deadline only releases the UI waiter, never the underlying storage/SDK
  /// work. The app retains those original futures for retry and joined teardown.
  Future<void> _waitForStartup(Future<void> work, Duration budget) {
    final completion = Completer<void>();
    late final Timer timer;
    void finish([Object? error, StackTrace? stack]) {
      timer.cancel();
      _startupDeadlines.remove(timer);
      if (completion.isCompleted) return;
      if (error == null) {
        completion.complete();
      } else {
        completion.completeError(error, stack);
      }
    }

    timer = Timer(
      budget,
      () => finish(
        TimeoutException('Startup is taking too long'),
        StackTrace.current,
      ),
    );
    _startupDeadlines[timer] = completion;
    unawaited(
      work.then<void>(
        (_) => finish(),
        onError: (Object error, StackTrace stack) {
          finish(error, stack);
        },
      ),
    );
    return completion.future;
  }

  void _bindPushSession() {
    final backend = _backend;
    if (_closing ||
        !_pushReady ||
        !_backendReady ||
        backend is! MatrixBackend) {
      return;
    }
    final key = backend.pushSessionKey;
    if (_pushBindingObserved && key == _pushSessionKey) return;
    _pushBindingObserved = true;
    _pushSessionKey = key;
    final generation = ++_pushGeneration;
    try {
      _pushSession = key == null
          ? null
          : backend.createPushSession(_navigatePush);
      // setSession invalidates synchronously, then joins the prior owner. Do not
      // queue binding itself behind an await that could leave stale taps current.
      unawaited(
        _finishPushBinding(_notifications.setSession(_pushSession), generation),
      );
    } catch (_) {
      _pushSession = null;
      unawaited(
        _finishPushBinding(
          _notifications.setSession(null).then<void>((_) {
            throw StateError('Could not bind the push session');
          }),
          generation,
        ),
      );
    }
  }

  Future<void> _finishPushBinding(Future<void> binding, int generation) async {
    try {
      await binding;
      if (!mounted || _closing || generation != _pushGeneration) return;
      _pushError = null;
      if (_pushSession == null) {
        // Signed out: nothing to stay connected for, now or after a reboot.
        unawaited(_stopBackgroundConnection());
      } else {
        unawaited(_startNotifications());
      }
    } catch (_) {
      if (!mounted || _closing || generation != _pushGeneration) return;
      _pushError =
          'Push cleanup failed. Retry before enabling push or signing '
          'out; you may need to remove this device’s pusher on your homeserver.';
    }
    _scheduleRebuild();
  }

  /// Notifications are on by default, with no opt-in: UnifiedPush when a
  /// distributor app such as ntfy is installed, otherwise the built-in
  /// connection. Retried when Parallax comes to the foreground (for example
  /// after the notification permission was granted, or ntfy was installed).
  Future<void> _startNotifications() async {
    if (_notificationsStarting) return;
    _notificationsStarting = true;
    final session = _pushSession;
    try {
      final failed = await startDefaultNotifications(
        _notifications,
        unifiedPushFailed: _unifiedPushFailed,
        isCurrent: () =>
            mounted &&
            !_closing &&
            _pushReady &&
            session != null &&
            identical(_pushSession, session),
      );
      if (failed) _unifiedPushFailed = true;
    } catch (_) {
      // Settings shows the status; the next resume tries again.
    } finally {
      _notificationsStarting = false;
    }
  }

  Future<void> _stopBackgroundConnection() async {
    try {
      await const MethodChannelBackgroundConnection().stop();
    } catch (_) {
      // Best effort; the service also stops itself when turned off.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_startNotifications());
  }

  Future<void> _navigatePush(PushNavigationRequest request) async {
    final backend = _backend;
    final generation = _pushGeneration;
    final key = _pushSessionKey;
    bool current() =>
        mounted &&
        !_closing &&
        request.isCurrent &&
        generation == _pushGeneration &&
        backend is MatrixBackend &&
        key != null &&
        backend.pushSessionKey == key &&
        backend.userId == request.userId &&
        _pushSession?.userId == request.userId &&
        _pushSession?.deviceId == request.deviceId;
    if (!current()) return;
    bool joined() =>
        backend.rooms.any((room) => room.id == request.roomId && !room.invited);
    try {
      if (!joined()) {
        await backend.refreshRooms().timeout(const Duration(seconds: 20));
        if (!current()) return;
      }
      if (!current()) return;
      if (!joined()) {
        _pushError =
            'This notification’s room is not joined or is unavailable.';
        _scheduleRebuild();
        return;
      }
      if (_navigatorKey.currentState == null) {
        await WidgetsBinding.instance.endOfFrame;
        if (!current()) return;
      }
      final navigator = _navigatorKey.currentState;
      if (!current() || navigator == null) return;
      // Complete on dispatch, NOT on pop. Push.logout joins this callback; waiting
      // for the route lifetime would deadlock sign-out from a notification route.
      // A notification is a fresh entry into a room: retain the inbox root but
      // remove any previous room/media/settings routes above it. Back therefore
      // returns to the inbox, never to an inactive room whose timeline is empty.
      // On a wide window the room is selected in the detail pane instead.
      unawaited(
        openRoomOnNavigator(
          navigator,
          backend: backend,
          palette: paletteFor(_style),
          roomId: request.roomId,
          replaceStack: true,
        ).then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            if (!current()) return;
            _pushError = 'Could not open the notification’s room. Try again.';
            _scheduleRebuild();
          },
        ),
      );
    } catch (_) {
      if (!current()) return;
      _pushError =
          'Could not resolve the notification’s room. Refresh and retry.';
      _scheduleRebuild();
    }
  }

  Future<void> _loadAppearance() async {
    try {
      await _preferences.load();
    } catch (_) {
      debugPrint('Parallax appearance preferences could not be loaded.');
    }
  }

  Future<void> _loadTheme() async {
    final revision = _themeRevision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || revision != _themeRevision) return;
      final saved = prefs.getString('visual_theme');
      if (saved == systemThemePreference) {
        setState(() {
          _followSystemTheme = true;
          _style = _systemStyle;
        });
        return;
      }
      for (final theme in VisualTheme.values) {
        if (theme.name == saved) setState(() => _style = theme);
      }
    } catch (_) {
      debugPrint('Parallax theme preference could not be loaded.');
    }
  }

  VisualTheme get _systemStyle => visualThemeForBrightness(
    WidgetsBinding.instance.platformDispatcher.platformBrightness,
  );

  @override
  void didChangePlatformBrightness() {
    if (!mounted || _closing || !_followSystemTheme) return;
    final style = _systemStyle;
    if (style != _style) setState(() => _style = style);
  }

  void _changeTheme(VisualTheme style) {
    _themeRevision++;
    setState(() {
      _followSystemTheme = false;
      _style = style;
    });
    unawaited(_saveTheme(style.name));
  }

  void _followSystem(bool follow) {
    if (!follow) return _changeTheme(_style);
    _themeRevision++;
    setState(() {
      _followSystemTheme = true;
      _style = _systemStyle;
    });
    unawaited(_saveTheme(systemThemePreference));
  }

  Future<void> _saveTheme(String value) async {
    final revision = _themeRevision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || revision != _themeRevision) return;
      await prefs.setString('visual_theme', value);
    } catch (_) {
      debugPrint('Parallax theme preference could not be saved.');
    }
  }

  /// Runs before the Matrix session ends: end live-location shares on the
  /// server while writes still work, then remove pushers. A share that can't
  /// be ended in time expires at its own timeout.
  Future<void> _beforeLogout() async {
    try {
      await liveLocationBeforeLogout(
        _backend,
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
    await _notifications.logout();
  }

  @override
  void dispose() {
    _closing = true;
    // Cancel UI deadlines synchronously. Accepted storage/SDK work is still
    // joined below; it is not cancelled or allowed to race a replacement owner.
    for (final deadline in _startupDeadlines.entries) {
      deadline.key.cancel();
      if (!deadline.value.isCompleted) deadline.value.complete();
    }
    _startupDeadlines.clear();
    ++_pushGeneration;
    WidgetsBinding.instance.removeObserver(this);
    _preferences.removeListener(_syncHaptics);
    _backend.removeListener(_sessionChanged);
    // Cancel immediately; release the SDK only after all accepted push callbacks
    // and exact pusher removals have joined. Never dispose borrowed resources.
    final cleanup = _ownsNotifications
        ? _notifications.shutdown()
        : _pushBindingObserved
        ? _notifications.setSession(null)
        : Future<void>.value();
    unawaited(_releaseOwnedResources(cleanup));
    if (_ownsPreferences) _preferences.dispose();
    super.dispose();
  }

  Future<void> _releaseOwnedResources(Future<void> cleanup) async {
    try {
      await cleanup;
    } catch (_) {
      debugPrint('Parallax push cleanup failed during teardown.');
    } finally {
      // shutdown disposes the notifier, which may enqueue a final cleanup retry.
      await _notifications.settle();
      if (_ownsBackend) {
        try {
          await _backendInitializing;
        } catch (_) {
          // Initialization failed; the backend still needs its final disposal.
        }
        _backend.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteFor(_style);
    return AnimatedBuilder(
      animation: _preferences,
      builder: (context, _) => MaterialApp(
        navigatorKey: _navigatorKey,
        navigatorObservers: [_roomRoutes],
        title: 'Parallax',
        debugShowCheckedModeBanner: false,
        theme: themeFor(_style, _preferences.appFont),
        builder: (context, child) {
          final content = _AppTextScale(
            factor: _preferences.textScale,
            child: Column(
              children: [
                if (_pushError != null)
                  SafeArea(
                    bottom: false,
                    child: MaterialBanner(
                      content: Text(_pushError!),
                      actions: [
                        TextButton(
                          onPressed: () => unawaited(_retryPush()),
                          child: const Text('Retry notifications'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final hook = AppHookContext(
                        backend: _backend,
                        palette: p,
                        navigatorKey: _navigatorKey,
                      );
                      final overlay = SecurityOverlay(
                        backend: _backend,
                        child: _authenticated
                            ? wrapSignedInApp(
                                context,
                                hook,
                                child ?? const SizedBox.shrink(),
                              )
                            : child ?? const SizedBox.shrink(),
                      );
                      return _authenticated
                          ? wrapSignedInAppLock(context, hook, overlay)
                          : overlay;
                    },
                  ),
                ),
              ],
            ),
          );
          return DesktopContentInsets(
            child: RepaintBoundary(
              key: _frameDumpKey,
              child: FeatureSettingsScope(
                preferences: _preferences,
                draftStore: _draftStore,
                notifications: _pushReady ? _notifications : null,
                child: (Platform.isWindows || Platform.isMacOS)
                    ? DesktopShell(palette: p, child: content)
                    : content,
              ),
            ),
          );
        },
        // Only the session status picks the screen. Rebuilding on every
        // backend notification (each sync, each timeline update of an open
        // room) rebuilt the whole inbox underneath the room on screen.
        home: _SessionStatusBuilder(
          backend: _backend,
          builder: (context) => switch (_startupError == null
              ? _backend.connection
              : SessionStatus.offline) {
            SessionStatus.loading => Scaffold(
              body: GlowBackdrop(
                palette: p,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      BrandMark(palette: p, size: 72),
                      const SizedBox(height: 20),
                      Text(
                        'Parallax',
                        style: TextStyle(
                          color: p.foreground,
                          fontSize: 27,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 18),
                      CircularProgressIndicator(color: p.accent),
                    ],
                  ),
                ),
              ),
            ),
            SessionStatus.signedOut => LoginScreen(
              backend: _backend,
              palette: p,
            ),
            SessionStatus.ready => InboxScreen(
              backend: _backend,
              palette: p,
              style: _style,
              onThemeChanged: _changeTheme,
              followSystemTheme: _followSystemTheme,
              onFollowSystemTheme: _followSystem,
              roomRoutes: _roomRoutes,
            ),
            SessionStatus.offline => Scaffold(
              body: GlowBackdrop(
                palette: p,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, color: p.accent, size: 48),
                        const SizedBox(height: 18),
                        Text(
                          'Couldn’t start Parallax',
                          style: TextStyle(
                            color: p.foreground,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _startupError ??
                              _backend.error ??
                              'Something went wrong.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: p.muted),
                        ),
                        const SizedBox(height: 24),
                        AccentButton(
                          palette: p,
                          label: 'Try again',
                          onPressed: () => unawaited(_start()),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          },
        ),
      ),
    );
  }
}

/// Rebuilds [builder] only when the backend's session status or startup
/// error changes, not on every notification.
class _SessionStatusBuilder extends StatefulWidget {
  const _SessionStatusBuilder({required this.backend, required this.builder});
  final ChatBackend backend;
  final WidgetBuilder builder;

  @override
  State<_SessionStatusBuilder> createState() => _SessionStatusBuilderState();
}

class _SessionStatusBuilderState extends State<_SessionStatusBuilder> {
  late SessionStatus _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _read();
    widget.backend.addListener(_changed);
  }

  @override
  void didUpdateWidget(_SessionStatusBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      oldWidget.backend.removeListener(_changed);
      widget.backend.addListener(_changed);
      _read();
    }
  }

  @override
  void dispose() {
    widget.backend.removeListener(_changed);
    super.dispose();
  }

  void _read() {
    _status = widget.backend.connection;
    _error = widget.backend.error;
  }

  void _changed() {
    if (widget.backend.connection == _status &&
        widget.backend.error == _error) {
      return;
    }
    setState(_read);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// Applies the app's text size on top of the platform's. Only this widget
/// depends on all of MediaQuery (it changes every frame while the keyboard
/// animates); [child] is built once by the caller and passes through.
class _AppTextScale extends StatelessWidget {
  const _AppTextScale({required this.factor, required this.child});
  final double factor;
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: _PreferenceTextScaler(
        MediaQuery.textScalerOf(context),
        factor,
      ),
    ),
    child: child,
  );
}

/// Preserve platform accessibility's nonlinear scaling at each font size.
class _PreferenceTextScaler extends TextScaler {
  const _PreferenceTextScaler(this.platform, this.factor);
  final TextScaler platform;
  final double factor;

  @override
  double scale(double fontSize) => platform.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(14) / 14;

  // Value equality: a new scaler is made whenever MediaQuery changes (each
  // keyboard animation frame). Without it every Text in the app saw a
  // "changed" text scale and rebuilt on each of those frames.
  @override
  bool operator ==(Object other) =>
      other is _PreferenceTextScaler &&
      other.platform == platform &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(platform, factor);
}

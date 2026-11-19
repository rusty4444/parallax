// Adaptive master-detail layout for iPad, the unfolded iPhone Fold and Mac.
//
// Compact windows (iPhone portrait and landscape, the Fold's outer screen,
// narrow Mac windows) keep the phone flow: the room list pushes full-screen
// chat routes. Wide windows show the room list beside the open chat, and
// resizing across the breakpoint (folding/unfolding, iPad Split View, Mac
// window resize) keeps the open chat on screen: it moves between the detail
// pane and a full-screen route.
//
// The room list and chat screens are unchanged; the shell only decides where
// the chat lives. Secondary screens (room info, threads, search, settings)
// still push full-screen routes on both layouts.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';

/// Windows whose shortest side is larger than this show two panes. Material's
/// expanded-window class starts at 600; staying strictly above it keeps phone
/// landscape (and the default 800x600 test surface) on the compact flow,
/// while every iPad portrait width (744+) and the unfolded Fold qualify.
bool useWideLayout(Size size) => size.shortestSide > 600;

/// Width of the room-list pane on wide windows.
const wideListPaneWidth = 380.0;

/// Route names of pushed chat routes, so transitions can find the open chat.
const roomRoutePrefix = 'room:';

/// A chat route tagged for [RoomRouteObserver].
Route<void> buildRoomRoute({
  required String roomId,
  required WidgetBuilder builder,
}) => MaterialPageRoute<void>(
  settings: RouteSettings(name: '$roomRoutePrefix$roomId'),
  builder: builder,
);

/// Which chat is open in the detail pane (wide windows only).
class AdaptiveLayoutController extends ChangeNotifier {
  String? _selectedRoomId;
  String? get selectedRoomId => _selectedRoomId;

  void select(String roomId) {
    if (_selectedRoomId == roomId) return;
    _selectedRoomId = roomId;
    notifyListeners();
  }

  void clear() {
    if (_selectedRoomId == null) return;
    _selectedRoomId = null;
    notifyListeners();
  }
}

/// Present only around the room list while the layout is wide. Screens use
/// [of] to decide between selecting a chat and pushing a route.
class AdaptiveLayoutHost extends InheritedNotifier<AdaptiveLayoutController> {
  const AdaptiveLayoutHost({
    super.key,
    required AdaptiveLayoutController controller,
    required super.child,
  }) : super(notifier: controller);

  static AdaptiveLayoutController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AdaptiveLayoutHost>()
      ?.notifier;
}

/// Tracks the route stack so fold/unfold transitions keep the open chat.
/// Notifies listeners whenever the top chat route changes.
class RoomRouteObserver extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> _stack = [];

  /// The room of the topmost chat route, or null when none is open.
  String? get topRoomId {
    for (final route in _stack.reversed) {
      final name = route.settings.name;
      if (name != null && name.startsWith(roomRoutePrefix)) {
        final id = name.substring(roomRoutePrefix.length);
        return id.isEmpty ? null : id;
      }
    }
    return null;
  }

  void _changed() => notifyListeners();

  /// The app replaces its whole navigator on sign-out/account switch; the
  /// old routes are gone without didPop/didRemove.
  void reset() {
    if (_stack.isEmpty) return;
    _stack.clear();
    _changed();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _stack.remove(oldRoute);
    if (newRoute != null) _stack.add(newRoute);
    _changed();
  }
}

/// Chooses between the compact flow and the master-detail layout, and keeps
/// the open chat on screen when the window crosses the breakpoint.
class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({
    super.key,
    required this.controller,
    required this.observer,
    required this.palette,
    required this.inbox,
    required this.roomBuilder,
  });

  final AdaptiveLayoutController controller;
  final RoomRouteObserver observer;
  final AppPalette palette;
  final Widget inbox;
  final Widget Function(String roomId) roomBuilder;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  bool? _wasWide;
  bool _transitionScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.observer.addListener(_syncRouteSelection);
  }

  @override
  void dispose() {
    widget.observer.removeListener(_syncRouteSelection);
    super.dispose();
  }

  /// A chat opened as a full-screen route while wide (notification tap,
  /// search result, link) also becomes the pane's selection, so popping the
  /// route leaves that chat in the pane.
  void _syncRouteSelection() {
    if (!mounted || _wasWide != true) return;
    final id = widget.observer.topRoomId;
    if (id != null) widget.controller.select(id);
  }

  void _scheduleTransition(bool wide) {
    if (_transitionScheduled) return;
    _transitionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _transitionScheduled = false;
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (!wide) {
        // Folded or narrowed: keep the open chat as a full-screen route.
        final id = widget.controller.selectedRoomId;
        if (id != null && widget.observer.topRoomId != id) {
          navigator.push(
            buildRoomRoute(roomId: id, builder: (_) => widget.roomBuilder(id)),
          );
        }
      } else {
        // Unfolded or widened: move the open chat into the detail pane.
        final id = widget.observer.topRoomId;
        if (id != null) {
          widget.controller.select(id);
          navigator.pop();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // MediaQuery, not LayoutBuilder: while a full-screen chat route covers
    // the shell, the overlay skips layout of this offstage subtree, so a
    // LayoutBuilder would never see the new window size. MediaQuery changes
    // rebuild dependents even offstage, which is what lets fold/unfold move
    // the open chat between the pane and a route.
    final wide = useWideLayout(MediaQuery.sizeOf(context));
    if (_wasWide != null && _wasWide != wide) _scheduleTransition(wide);
    _wasWide = wide;
    if (!wide) return widget.inbox;
    final p = widget.palette;
    return AdaptiveLayoutHost(
      controller: widget.controller,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: wideListPaneWidth, child: widget.inbox),
          VerticalDivider(width: 1, thickness: 1, color: p.stroke),
          Expanded(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) {
                final id = widget.controller.selectedRoomId;
                if (id == null) return _EmptyDetailPane(palette: p);
                return KeyedSubtree(
                  key: ValueKey('adaptive-detail-$id'),
                  child: widget.roomBuilder(id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDetailPane extends StatelessWidget {
  const _EmptyDetailPane({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return GlowBackdrop(
      palette: p,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BrandMark(palette: p, size: 72),
              const SizedBox(height: 18),
              Text(
                'Pick a chat',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your conversations open here.',
                style: TextStyle(color: p.muted, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

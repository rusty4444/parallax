import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'room_screen.dart';

/// Tablet/foldable layout: the inbox and the open chat sit side by side once
/// the window reaches Material's medium width class. The height guard keeps
/// landscape phones (short windows) on the single-pane phone layout.
const double kTwoPaneMinWidth = 600;
const double kTwoPaneMinHeight = 480;

/// Desktop drag-resize bounds: both panes stay usable at any window width.
const double kTwoPaneMinListWidth = 280;
const double kTwoPaneMinDetailWidth = 320;

/// Persisted user-chosen list pane width (desktop divider drag).
const String kTwoPaneWidthPref = 'two_pane_list_width';

double clampTwoPaneWidth(double width, double windowWidth) => width.clamp(
  kTwoPaneMinListWidth,
  windowWidth - kTwoPaneMinDetailWidth < kTwoPaneMinListWidth
      ? kTwoPaneMinListWidth
      : windowWidth - kTwoPaneMinDetailWidth,
);

bool isTwoPaneWindow(Size size) =>
    size.width >= kTwoPaneMinWidth && size.height >= kTwoPaneMinHeight;

/// The list pane's width and the gap after it. Normally 40% of the window
/// clamped to 300–420 with a hairline divider; when a physical hinge or a
/// half-opened fold splits the window vertically, the panes meet at the
/// hinge so neither pane's content sits under it.
({double listWidth, double gapWidth}) twoPaneSplit(
  double width, {
  List<DisplayFeature> features = const [],
}) {
  for (final feature in features) {
    final bounds = feature.bounds;
    final vertical = bounds.height > bounds.width;
    final separating =
        feature.type == DisplayFeatureType.hinge ||
        (feature.type == DisplayFeatureType.fold &&
            feature.state == DisplayFeatureState.postureHalfOpened);
    if (!vertical || !separating) continue;
    // Only split at the hinge when both panes stay usable.
    if (bounds.left >= 280 && bounds.right <= width - 280) {
      return (listWidth: bounds.left, gapWidth: bounds.width);
    }
  }
  return (listWidth: (width * 0.4).clamp(300.0, 420.0), gapWidth: 1);
}

/// A draggable divider between the two panes (desktop). Dragging resizes the
/// list pane; double-clicking restores the default split. On a physical hinge
/// the plain gap is used instead, so the panes stay aligned with the hardware.
class PaneDivider extends StatelessWidget {
  const PaneDivider({
    super.key,
    required this.palette,
    required this.onDrag,
    required this.onDragEnd,
    required this.onReset,
  });

  final AppPalette palette;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      key: const ValueKey('two-pane-divider'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
      onHorizontalDragEnd: (_) => onDragEnd(),
      onDoubleTap: onReset,
      child: VerticalDivider(width: 9, thickness: 1, color: palette.stroke),
    ),
  );
}

/// A chat route that carries its room id, so a widening window (unfold,
/// rotate, split-screen exit) can absorb it into the detail pane instead of
/// leaving a phone-style fullscreen chat on a tablet.
class RoomRoute extends MaterialPageRoute<void> {
  RoomRoute({
    required this.backend,
    required this.palette,
    required this.roomId,
    super.settings,
  }) : super(
         builder: (_) =>
             RoomScreen(backend: backend, palette: palette, roomId: roomId),
       );

  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
}

/// Tracks the chat routes above the inbox. Registered on the root navigator;
/// the inbox reads it when the window widens to fold open chats into the
/// detail pane.
class RoomRouteObserver extends NavigatorObserver {
  final List<RoomRoute> _rooms = [];

  /// Pushed chat routes, oldest first (the last is the topmost chat).
  List<RoomRoute> get rooms => List.unmodifiable(_rooms);

  /// The navigator was replaced (sign-out): its routes died without pops.
  void reset() => _rooms.clear();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is RoomRoute) _rooms.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _rooms.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _rooms.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute is RoomRoute ? _rooms.indexOf(oldRoute) : -1;
    if (newRoute is RoomRoute) {
      if (at >= 0) {
        _rooms[at] = newRoute;
      } else {
        _rooms.add(newRoute);
      }
    } else if (at >= 0) {
      _rooms.removeAt(at);
    }
  }
}

/// The inbox's detail-pane selection. One controller per mounted inbox,
/// registered against its backend so every room-opening flow (notification
/// taps, matrix links, Spaces, profiles) selects the detail pane on wide
/// windows instead of pushing a phone route.
class TwoPaneController extends ChangeNotifier {
  String? _selectedRoomId;
  bool _wide = false;

  String? get selectedRoomId => _selectedRoomId;

  /// Whether the inbox is currently laid out as two panes.
  bool get wide => _wide;

  set wide(bool value) {
    if (value == _wide) return;
    _wide = value;
    notifyListeners();
  }

  void select(String? roomId) {
    if (roomId == _selectedRoomId) return;
    _selectedRoomId = roomId;
    notifyListeners();
  }

  static final Map<ChatBackend, TwoPaneController> _mounted = {};

  /// The mounted inbox's controller for [backend], if any.
  static TwoPaneController? of(ChatBackend backend) => _mounted[backend];

  void register(ChatBackend backend) => _mounted[backend] = this;

  void unregister(ChatBackend backend) {
    if (identical(_mounted[backend], this)) _mounted.remove(backend);
  }
}

/// Opens a room the way the current window wants it: selected in the detail
/// pane on wide windows, a pushed [RoomRoute] on phones. On wide windows any
/// routes covering the inbox are popped first so the selection is visible
/// (a link tapped from Settings or Saved Messages must not select a pane
/// hidden behind them). [replaceStack] additionally clears everything above
/// the inbox before pushing on phones (notification taps, profile chats),
/// matching the previous pushAndRemoveUntil flows.
Future<void> openRoom(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required String roomId,
  bool replaceStack = false,
}) => openRoomOnNavigator(
  Navigator.of(context),
  backend: backend,
  palette: palette,
  roomId: roomId,
  replaceStack: replaceStack,
);

Future<void> openRoomOnNavigator(
  NavigatorState navigator, {
  required ChatBackend backend,
  required AppPalette palette,
  required String roomId,
  bool replaceStack = false,
}) {
  final controller = TwoPaneController.of(backend);
  if (controller != null && controller.wide) {
    navigator.popUntil((route) => route.isFirst);
    controller.select(roomId);
    return Future<void>.value();
  }
  final route = RoomRoute(backend: backend, palette: palette, roomId: roomId);
  if (replaceStack) {
    return navigator.pushAndRemoveUntil<void>(route, (r) => r.isFirst);
  }
  return navigator.push<void>(route);
}

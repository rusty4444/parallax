import 'package:flutter/material.dart';

import '../appearance_preferences.dart';
import '../feature_settings_scope.dart';
import 'message_lift.dart';

/// The emoji a double tap reacts with (Settings → Chats).
String quickReactionOf(BuildContext context) =>
    FeatureSettingsScope.maybeOf(context)?.preferences.quickReaction ??
    AppearancePreferences.defaultQuickReaction;

/// Double tap to react, long press (or right-click) for actions. The
/// reaction pops over the message straight away, before the server confirms
/// it, so a double tap always visibly lands. A long press lifts the message
/// off the screen while its action sheet is open ([MessageLiftTarget]).
class DoubleTapReact extends StatefulWidget {
  const DoubleTapReact({
    super.key,
    required this.onDoubleTap,
    required this.onLongPress,
    required this.child,
  });

  final VoidCallback onDoubleTap;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  State<DoubleTapReact> createState() => _DoubleTapReactState();
}

class _DoubleTapReactState extends State<DoubleTapReact>
    with SingleTickerProviderStateMixin {
  late final _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  String _emoji = AppearancePreferences.defaultQuickReaction;

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  void _doubleTap() {
    setState(() => _emoji = quickReactionOf(context));
    _pop.forward(from: 0);
    widget.onDoubleTap();
  }

  /// Long press and right-click: capture the message so the action sheet
  /// can lift it, then run the handler.
  void _actions(BuildContext liftContext) {
    final action = widget.onLongPress;
    if (action != null) liftMessage(liftContext, action);
  }

  @override
  Widget build(BuildContext context) => MessageLiftTarget(
    child: Builder(
      builder: (liftContext) => GestureDetector(
        onDoubleTap: _doubleTap,
        // The action sheet owner plays the long-press haptic.
        onLongPress: widget.onLongPress == null
            ? null
            : () => _actions(liftContext),
        // Desktop: right-click opens the same action menu as a long press.
        onSecondaryTapUp: (_) => _actions(liftContext),
        behavior: HitTestBehavior.opaque,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            // Never affects the message's size or hit testing.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _pop,
                  builder: (context, _) {
                    if (!_pop.isAnimating) return const SizedBox.shrink();
                    final t = _pop.value;
                    final scale = Curves.elasticOut.transform(
                      (t / 0.6).clamp(0.0, 1.0),
                    );
                    final opacity = t < 0.7 ? 1.0 : 1 - (t - 0.7) / 0.3;
                    return Center(
                      child: OverflowBox(
                        maxWidth: 96,
                        maxHeight: 96,
                        child: Opacity(
                          opacity: opacity.clamp(0.0, 1.0),
                          child: Transform.scale(
                            scale: 0.4 + scale * 0.8,
                            child: Text(
                              _emoji,
                              key: const ValueKey('double-tap-pop'),
                              style: const TextStyle(fontSize: 44),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../app_theme.dart';

/// The hidden macOS title bar keeps its native traffic lights over the content.
/// Reserve that strip for every Navigator route, including fullscreen dialogs,
/// instead of individually patching each settings/media screen. A wide inbox
/// deliberately removes the top padding locally: its header clears the lights
/// horizontally and the detail pane starts to their right.
class DesktopContentInsets extends StatelessWidget {
  const DesktopContentInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return child;
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(
          top: math.max(media.padding.top, kDesktopTitleBarHeight),
        ),
        viewPadding: media.viewPadding.copyWith(
          top: math.max(media.viewPadding.top, kDesktopTitleBarHeight),
        ),
      ),
      child: child,
    );
  }
}

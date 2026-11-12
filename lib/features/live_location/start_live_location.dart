import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'live_location_features.dart';
import 'live_location_format.dart';
import 'live_location_model.dart';
import 'position_source.dart';

/// Element X disclaimer shown before sharing.
const liveLocationDisclaimer =
    'Your live location history will be stored in the room and visible to '
    'members after the session ends.';

const liveLocationBackgroundNote =
    'Parallax keeps sharing while it is in the background and shows a '
    'notification until you stop or the time runs out.';

const liveLocationNoPermission =
    'You do not have permissions to share your live location in this room';

/// "Share live location": checks the room's power levels, offers 15 minutes
/// / 1 hour / 8 hours, then asks for location access (prompting only now,
/// because the user tapped) and starts sharing. Returns whether sharing
/// started.
Future<bool> startLiveLocationFlow(
  BuildContext context, {
  required LiveLocationFeatures features,
  required String roomId,
  required AppPalette palette,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (!features.canShareIn(roomId)) {
    messenger?.showSnackBar(
      const SnackBar(content: Text(liveLocationNoPermission)),
    );
    return false;
  }
  final duration = await showLiveLocationDurationSheet(context, palette);
  if (duration == null || !context.mounted) return false;
  final access = await features.positions.request();
  if (!context.mounted) return false;
  if (access != LocationAccess.granted) {
    await explainLocationAccess(context, access, features.positions);
    return false;
  }
  try {
    await features.startSharing(roomId, duration.duration);
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          'Couldn’t start sharing your live location. Check your '
          'connection and try again.',
        ),
      ),
    );
    return false;
  }
  return true;
}

/// Explains why location is unavailable, offering the relevant settings.
Future<void> explainLocationAccess(
  BuildContext context,
  LocationAccess access,
  LivePositionSource positions,
) async {
  final (message, settings) = switch (access) {
    LocationAccess.serviceDisabled => (
      'Please enable your GPS to access location-based features.',
      positions.openLocationSettings,
    ),
    LocationAccess.deniedForever => (
      'Parallax does not have permission to access your location. '
          'You can enable access in Settings.',
      positions.openAppSettings,
    ),
    LocationAccess.denied => (
      'Parallax needs access to your location to share it live. '
          'Allow location access when asked, then try again.',
      null,
    ),
    LocationAccess.unavailable || LocationAccess.granted => (
      'Parallax could not access your location. Please try again later.',
      null,
    ),
  };
  final open = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Live location'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(settings == null ? 'OK' : 'Cancel'),
        ),
        if (settings != null)
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open settings'),
          ),
      ],
    ),
  );
  if (open == true && settings != null) await settings();
}

/// Duration picker: 15 minutes, 1 hour or 8 hours (as Element offers).
Future<LiveShareDuration?> showLiveLocationDurationSheet(
  BuildContext context,
  AppPalette palette,
) => showModalBottomSheet<LiveShareDuration>(
  context: context,
  backgroundColor: palette.surface,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _DurationSheet(palette: palette),
);

class _DurationSheet extends StatefulWidget {
  const _DurationSheet({required this.palette});
  final AppPalette palette;

  @override
  State<_DurationSheet> createState() => _DurationSheetState();
}

class _DurationSheetState extends State<_DurationSheet> {
  LiveShareDuration _selected = LiveShareDuration.fifteenMinutes;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final now = DateTime.now();
    final use24 = use24HourOf(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Eyebrow('Live location', palette: p),
            const SizedBox(height: 6),
            Text(
              'Share live location',
              style: TextStyle(
                color: p.foreground,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Choose how long to share your live location.',
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
            const SizedBox(height: 8),
            for (final option in LiveShareDuration.values)
              ListTile(
                key: ValueKey('live-duration-${option.name}'),
                contentPadding: EdgeInsets.zero,
                selected: option == _selected,
                leading: Icon(
                  option == _selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: option == _selected ? p.accent : p.muted,
                ),
                title: Text(
                  option.label,
                  style: TextStyle(color: p.foreground),
                ),
                subtitle: Text(
                  'Until ${formatEndTime(now.add(option.duration), now, use24Hour: use24)}',
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
                onTap: () => setState(() => _selected = option),
              ),
            const SizedBox(height: 8),
            Text(
              liveLocationDisclaimer,
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              liveLocationBackgroundNote,
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            AccentButton(
              palette: p,
              label: 'Share live location',
              icon: Icons.share_location_rounded,
              onPressed: () => Navigator.pop(context, _selected),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'media_preferences.dart';

/// Element X media upload settings: "Optimise image upload quality" and the
/// video quality note.
class MediaSettingsSection extends StatefulWidget {
  const MediaSettingsSection({
    super.key,
    required this.palette,
    this.preferences,
  });
  final AppPalette palette;

  /// Defaults to [MediaPreferences.shared].
  final MediaPreferences? preferences;

  @override
  State<MediaSettingsSection> createState() => _MediaSettingsSectionState();
}

class _MediaSettingsSectionState extends State<MediaSettingsSection> {
  MediaPreferences get _prefs => widget.preferences ?? MediaPreferences.shared;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_changed);
    unawaited(_prefs.ensureLoaded());
  }

  @override
  void didUpdateWidget(MediaSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.preferences ?? MediaPreferences.shared;
    if (!identical(previous, _prefs)) {
      previous.removeListener(_changed);
      _prefs.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _prefs.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _setOptimise(bool value) async {
    setState(() => _saving = true);
    try {
      await _prefs.setOptimiseImages(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t save this setting.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        Eyebrow('Media', palette: p),
        const SizedBox(height: 10),
        // Material (not a decorated box) so list tiles keep their ink.
        Material(
          color: p.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: p.stroke),
          ),
          child: Column(
            children: [
              SwitchListTile(
                value: _prefs.optimiseImages,
                onChanged: _saving ? null : _setOptimise,
                secondary: Icon(
                  Icons.photo_size_select_large_rounded,
                  color: p.secondary,
                ),
                title: const Text('Optimise image upload quality'),
                subtitle: const Text(
                  'Automatically optimise images for faster uploads and '
                  'smaller file sizes.',
                ),
              ),
              Divider(height: 1, color: p.stroke),
              ListTile(
                leading: Icon(Icons.videocam_outlined, color: p.secondary),
                title: const Text('Video upload quality'),
                subtitle: const Text(
                  'Videos up to 20 MB and 1080p are sent as recorded. Larger '
                  'ones are compressed to 720p so they fit (up to about '
                  '4 minutes).',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

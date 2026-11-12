import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'location_map.dart';
import 'location_model.dart';

/// Timeline body for `m.location`: a bounded, non-interactive map preview
/// with marker, a caption and "Open in maps". Tapping the map opens
/// [LocationViewerScreen].
class LocationBody extends StatelessWidget {
  const LocationBody({
    super.key,
    required this.palette,
    required this.location,
    required this.foreground,
    required this.senderName,
    required this.sentAt,
  });
  final AppPalette palette;
  final SharedLocation location;
  final Color foreground;
  final String senderName;
  final DateTime sentAt;

  static const previewHeight = 160.0;
  static const maxWidth = 320.0;

  void _openViewer(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LocationViewerScreen(
        palette: palette,
        location: location,
        senderName: senderName,
        sentAt: sentAt,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final caption =
        location.description ??
        (location.asset == LocationAsset.pin
            ? 'Shared location'
            : '$senderName’s location');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: 'Show location on the map',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: maxWidth,
                height: previewHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    StaticLocationMap(
                      palette: palette,
                      location: location,
                      senderName: senderName,
                    ),
                    OsmAttribution(palette: palette, interactive: false),
                    Material(
                      type: MaterialType.transparency,
                      child: InkWell(onTap: () => _openViewer(context)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                location.asset == LocationAsset.pin
                    ? Icons.location_on_outlined
                    : Icons.my_location_rounded,
                size: 16,
                color: foreground,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: foreground, fontSize: 13),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: foreground,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _openInMaps(context, location, senderName),
                child: const Text('Open in maps'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _openInMaps(
  BuildContext context,
  SharedLocation location,
  String label,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final opened = await openInMaps(location.point, label: label);
  if (!opened) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('No app could open this location.')),
    );
  }
}

/// Full-screen "Location" view (Element X `ShowLocationView`).
class LocationViewerScreen extends StatelessWidget {
  const LocationViewerScreen({
    super.key,
    required this.palette,
    required this.location,
    required this.senderName,
    required this.sentAt,
  });
  final AppPalette palette;
  final SharedLocation location;
  final String senderName;
  final DateTime sentAt;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final shared = location.sharedAt ?? sentAt;
    final local = shared.toLocal();
    final when =
        '${MaterialLocalizations.of(context).formatMediumDate(local)}, '
        '${TimeOfDay.fromDateTime(local).format(context)}';
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: Text(
                      'Location',
                      style: TextStyle(
                        color: p.foreground,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FlutterMap(
                          options: MapOptions(
                            initialCenter: latLngOf(location.point),
                            initialZoom: location.zoom ?? defaultLocationZoom,
                            minZoom: 2,
                            maxZoom: 19,
                            backgroundColor: p.raised,
                            interactionOptions: const InteractionOptions(
                              flags:
                                  InteractiveFlag.all & ~InteractiveFlag.rotate,
                            ),
                          ),
                          children: [
                            osmTileLayer(p),
                            if (location.point.uncertainty != null &&
                                location.point.uncertainty! > 0)
                              CircleLayer(
                                circles: [
                                  CircleMarker(
                                    point: latLngOf(location.point),
                                    radius: location.point.uncertainty!
                                        .clamp(0, 50000)
                                        .toDouble(),
                                    useRadiusInMeter: true,
                                    color: p.accent.withValues(alpha: 0.15),
                                    borderColor: p.accent.withValues(
                                      alpha: 0.5,
                                    ),
                                    borderStrokeWidth: 1,
                                  ),
                                ],
                              ),
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: latLngOf(location.point),
                                  width: 48,
                                  height: 48,
                                  alignment: location.asset == LocationAsset.pin
                                      ? Alignment.topCenter
                                      : Alignment.center,
                                  child: LocationMarker(
                                    palette: p,
                                    asset: location.asset,
                                    senderName: senderName,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        OsmAttribution(palette: p),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Eyebrow('On the map', palette: p),
                    const SizedBox(height: 6),
                    Text(
                      location.description ?? senderName,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.foreground,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Shared $when · '
                      '${location.point.latitude.toStringAsFixed(5)}, '
                      '${location.point.longitude.toStringAsFixed(5)}',
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: AccentButton(
                        palette: p,
                        label: 'Open in maps',
                        icon: Icons.map_outlined,
                        onPressed: () =>
                            _openInMaps(context, location, senderName),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

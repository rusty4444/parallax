import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_theme.dart';
import 'location_model.dart';

/// OpenStreetMap standard tiles. The OSM tile usage policy requires a
/// descriptive User-Agent and visible attribution.
const osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const osmAttribution = '© OpenStreetMap contributors';
const mapUserAgentPackage = 'net.samrussell.parallax';
final osmCopyrightUri = Uri.https('www.openstreetmap.org', '/copyright');

/// Test seam: widget tests disable network tiles.
@visibleForTesting
bool locationMapTilesEnabled = true;

/// Test seam for opening external links; returns whether it succeeded.
typedef ExternalUrlOpener = Future<bool> Function(Uri uri);

@visibleForTesting
ExternalUrlOpener? debugLocationUrlOpener;

const _allowedSchemes = {'geo', 'https'};

/// Opens [uri] outside the app. Only `geo:` and `https:` are allowed.
Future<bool> openExternalLocationUrl(Uri uri) async {
  if (!_allowedSchemes.contains(uri.scheme.toLowerCase())) return false;
  final override = debugLocationUrlOpener;
  if (override != null) return override(uri);
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Opens [point] in a maps app, falling back to openstreetmap.org.
Future<bool> openInMaps(GeoPoint point, {String? label}) async {
  if (await openExternalLocationUrl(point.mapsAppUri(label: label))) {
    return true;
  }
  return openExternalLocationUrl(point.openStreetMapUri);
}

LatLng latLngOf(GeoPoint point) => LatLng(point.latitude, point.longitude);

/// The OSM tile layer (or a neutral placeholder in tests).
Widget osmTileLayer(AppPalette palette) => locationMapTilesEnabled
    ? TileLayer(
        urlTemplate: osmTileUrl,
        userAgentPackageName: mapUserAgentPackage,
        maxNativeZoom: 19,
      )
    : ColoredBox(color: palette.raised);

/// "© OpenStreetMap contributors", tappable to the copyright page.
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({
    super.key,
    required this.palette,
    this.alignment = Alignment.bottomRight,
    this.interactive = true,
  });
  final AppPalette palette;
  final Alignment alignment;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final label = DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          osmAttribution,
          style: TextStyle(color: palette.foreground, fontSize: 10),
        ),
      ),
    );
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: interactive
            ? Semantics(
                link: true,
                child: GestureDetector(
                  onTap: () =>
                      unawaited(openExternalLocationUrl(osmCopyrightUri)),
                  child: label,
                ),
              )
            : label,
      ),
    );
  }
}

/// Marker for a shared location: the sender's initial for their own
/// position, a pin for a dropped location.
class LocationMarker extends StatelessWidget {
  const LocationMarker({
    super.key,
    required this.palette,
    required this.asset,
    this.senderName,
  });
  final AppPalette palette;
  final LocationAsset asset;
  final String? senderName;

  @override
  Widget build(BuildContext context) {
    if (asset == LocationAsset.pin) {
      return Semantics(
        label: 'Pinned location',
        child: Icon(
          Icons.location_on_rounded,
          size: 44,
          color: palette.accent,
          shadows: const [Shadow(blurRadius: 6, color: Colors.black54)],
        ),
      );
    }
    final name = senderName?.trim() ?? '';
    return Semantics(
      label: 'Sender location',
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: palette.accent,
          border: Border.all(color: palette.bubbleText, width: 3),
          boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black45)],
        ),
        child: Text(
          name.isEmpty ? '•' : name.characters.first.toUpperCase(),
          style: TextStyle(
            color: palette.accentOn,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

/// A non-interactive map centred on [location] with its marker.
class StaticLocationMap extends StatelessWidget {
  const StaticLocationMap({
    super.key,
    required this.palette,
    required this.location,
    this.senderName,
  });
  final AppPalette palette;
  final SharedLocation location;
  final String? senderName;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: FlutterMap(
      options: MapOptions(
        initialCenter: latLngOf(location.point),
        initialZoom: location.zoom ?? defaultLocationZoom,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.none,
        ),
        backgroundColor: palette.raised,
      ),
      children: [
        osmTileLayer(palette),
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
                palette: palette,
                asset: location.asset,
                senderName: senderName,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

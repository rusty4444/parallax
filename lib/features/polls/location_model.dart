// Static location sharing model (m.location + MSC3488), Flutter-free.
import 'package:flutter/foundation.dart';

const locationMsgtype = 'm.location';
const _locationKey = 'org.matrix.msc3488.location';
const _assetKey = 'org.matrix.msc3488.asset';
const _tsKey = 'org.matrix.msc3488.ts';
const _textKey = 'org.matrix.msc1767.text';

/// Element X `MapDefaults.DEFAULT_ZOOM`.
const defaultLocationZoom = 15.0;

/// Untrusted geo URIs longer than this are rejected outright.
const _maxGeoUriLength = 256;
const _maxDescriptionLength = 500;

/// Wraps a map longitude (which can exceed ±180 after panning across the
/// antimeridian) into [-180, 180].
double normaliseLongitude(double longitude) {
  if (!longitude.isFinite) return 0;
  if (longitude >= -180 && longitude <= 180) return longitude;
  final wrapped = ((longitude + 180) % 360 + 360) % 360 - 180;
  return wrapped;
}

/// MSC3488 asset type: the sender's own position or a dropped pin.
enum LocationAsset { self, pin }

final _geoPattern = RegExp(
  r'^geo:(-?\d{1,3}(?:\.\d{1,15})?),(-?\d{1,3}(?:\.\d{1,15})?)'
  r'(?:,-?\d{1,6}(?:\.\d{1,9})?)?((?:;[A-Za-z0-9\-]+=[A-Za-z0-9\-\.%]*)*)$',
  caseSensitive: false,
);

/// A WGS84 point parsed from or formatted to an RFC 5870 `geo:` URI.
@immutable
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude, {this.uncertainty});

  final double latitude;
  final double longitude;

  /// Accuracy radius in metres (`;u=`), if known.
  final double? uncertainty;

  bool get isValid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  /// Parses `geo:lat,lon[,alt][;u=…][;crs=wgs84]`. Returns null for anything
  /// malformed, out of range, oversized or in a non-WGS84 CRS.
  static GeoPoint? tryParse(Object? raw) {
    if (raw is! String || raw.length > _maxGeoUriLength) return null;
    final match = _geoPattern.firstMatch(raw.trim());
    if (match == null) return null;
    final lat = double.tryParse(match.group(1)!);
    final lon = double.tryParse(match.group(2)!);
    if (lat == null || lon == null) return null;
    double? uncertainty;
    for (final param in (match.group(3) ?? '').split(';')) {
      if (param.isEmpty) continue;
      final parts = param.split('=');
      final key = parts.first.toLowerCase();
      final value = parts.length > 1 ? parts[1] : '';
      if (key == 'crs' && value.toLowerCase() != 'wgs84') return null;
      if (key == 'u') {
        final parsed = double.tryParse(value);
        if (parsed != null && parsed.isFinite && parsed >= 0) {
          uncertainty = parsed;
        }
      }
    }
    final point = GeoPoint(lat, lon, uncertainty: uncertainty);
    return point.isValid ? point : null;
  }

  /// `geo:` URI with six decimal places (about 0.1 m).
  String toGeoUri() {
    final buffer = StringBuffer(
      'geo:${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}',
    );
    final u = uncertainty;
    if (u != null && u.isFinite && u >= 0) {
      buffer.write(';u=${u.toStringAsFixed(u < 10 ? 1 : 0)}');
    }
    return buffer.toString();
  }

  /// Opens the device's maps app (Android `ACTION_VIEW` geo intent), with
  /// a labelled marker as Element X does.
  Uri mapsAppUri({String? label}) {
    final trimmed = label?.trim() ?? '';
    final suffix = trimmed.isEmpty ? '' : '(${Uri.encodeComponent(trimmed)})';
    return Uri.parse(
      'geo:0,0?q=${latitude.toStringAsFixed(6)},'
      '${longitude.toStringAsFixed(6)}$suffix',
    );
  }

  /// Browser fallback when no maps app handles `geo:`.
  Uri get openStreetMapUri =>
      Uri.https('www.openstreetmap.org', '/', {
        'mlat': latitude.toStringAsFixed(6),
        'mlon': longitude.toStringAsFixed(6),
      }).replace(
        fragment:
            'map=${defaultLocationZoom.toInt()}/${latitude.toStringAsFixed(5)}/${longitude.toStringAsFixed(5)}',
      );

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.uncertainty == uncertainty;

  @override
  int get hashCode => Object.hash(latitude, longitude, uncertainty);

  @override
  String toString() => toGeoUri();
}

/// A received static location (`m.location`).
@immutable
class SharedLocation {
  const SharedLocation({
    required this.point,
    this.asset = LocationAsset.self,
    this.description,
    this.zoom,
    this.sharedAt,
  });

  final GeoPoint point;
  final LocationAsset asset;
  final String? description;
  final double? zoom;
  final DateTime? sharedAt;

  /// Reads MSC3488 `org.matrix.msc3488.location.uri` first, then the legacy
  /// `geo_uri`. Returns null when neither holds a valid point.
  static SharedLocation? fromContent(Map<String, Object?> content) {
    final block = content[_locationKey];
    final blockMap = block is Map ? block : const {};
    final point =
        GeoPoint.tryParse(blockMap['uri']) ??
        GeoPoint.tryParse(content['geo_uri']);
    if (point == null) return null;
    final asset = content[_assetKey];
    final assetType = asset is Map ? asset['type'] : null;
    final description = blockMap['description'];
    final zoom = blockMap['zoom_level'];
    final ts = content[_tsKey];
    return SharedLocation(
      point: point,
      // MSC3488: a missing asset means the sender's own location.
      asset: assetType == 'm.pin' ? LocationAsset.pin : LocationAsset.self,
      description: description is String && description.trim().isNotEmpty
          ? (description.length > _maxDescriptionLength
                ? description.substring(0, _maxDescriptionLength)
                : description.trim())
          : null,
      zoom: zoom is num && zoom >= 0 && zoom <= 20 ? zoom.toDouble() : null,
      sharedAt: ts is int && ts > 0
          ? DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true)
          : null,
    );
  }
}

/// Content for a static `m.location` message, as Element X sends it (body
/// "Location was shared at geo:…", MSC3488 location/asset/ts blocks and the
/// MSC1767 text fallback).
Map<String, Object?> locationContent({
  required GeoPoint point,
  required LocationAsset asset,
  required DateTime now,
  String? description,
}) {
  final uri = point.toGeoUri();
  final body = 'Location was shared at $uri';
  final trimmed = description?.trim();
  return {
    'msgtype': locationMsgtype,
    'body': body,
    'geo_uri': uri,
    _locationKey: {
      'uri': uri,
      if (trimmed != null && trimmed.isNotEmpty) 'description': trimmed,
      'zoom_level': defaultLocationZoom.toInt(),
    },
    _assetKey: {'type': asset == LocationAsset.pin ? 'm.pin' : 'm.self'},
    _tsKey: now.millisecondsSinceEpoch,
    _textKey: body,
  };
}

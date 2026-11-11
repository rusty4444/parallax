import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'location_map.dart';
import 'location_model.dart';
import 'poll_features.dart';

/// Why the device location is unavailable.
enum LocatorFailure { serviceDisabled, denied, deniedForever, unavailable }

class LocatorException implements Exception {
  const LocatorException(this.failure);
  final LocatorFailure failure;
}

/// Device location access, injectable for tests.
abstract interface class DeviceLocator {
  /// Current position if permission is already granted and services are on.
  /// Never prompts.
  Future<GeoPoint?> currentIfPermitted();

  /// Requests permission if needed (prompting the user) and returns the
  /// current position, or throws [LocatorException].
  Future<GeoPoint> locate();

  Future<void> openAppSettings();
  Future<void> openLocationSettings();
}

class GeolocatorDeviceLocator implements DeviceLocator {
  const GeolocatorDeviceLocator();

  static const _settings = LocationSettings(
    accuracy: LocationAccuracy.high,
    timeLimit: Duration(seconds: 20),
  );

  bool _granted(LocationPermission permission) =>
      permission == LocationPermission.always ||
      permission == LocationPermission.whileInUse;

  Future<GeoPoint> _position() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: _settings,
      );
      final point = GeoPoint(
        position.latitude,
        position.longitude,
        uncertainty: position.accuracy.isFinite && position.accuracy > 0
            ? position.accuracy
            : null,
      );
      if (!point.isValid) {
        throw const LocatorException(LocatorFailure.unavailable);
      }
      return point;
    } on LocatorException {
      rethrow;
    } catch (_) {
      throw const LocatorException(LocatorFailure.unavailable);
    }
  }

  @override
  Future<GeoPoint?> currentIfPermitted() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      if (!_granted(await Geolocator.checkPermission())) return null;
      return await _position();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<GeoPoint> locate() async {
    final bool enabled;
    try {
      enabled = await Geolocator.isLocationServiceEnabled();
    } catch (_) {
      throw const LocatorException(LocatorFailure.unavailable);
    }
    if (!enabled) throw const LocatorException(LocatorFailure.serviceDisabled);
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocatorException(LocatorFailure.deniedForever);
    }
    if (!_granted(permission)) {
      throw const LocatorException(LocatorFailure.denied);
    }
    return _position();
  }

  @override
  Future<void> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();
}

/// Element X "Share location": a map with a fixed centre pin. Locating the
/// user (permission is requested only when they tap) offers "Share my
/// location"; panning switches to "Share selected location" (a pin).
class ShareLocationScreen extends StatefulWidget {
  const ShareLocationScreen({
    super.key,
    required this.palette,
    required this.roomId,
    required this.features,
    this.locator = const GeolocatorDeviceLocator(),
  });
  final AppPalette palette;
  final String roomId;
  final LocationFeatures features;
  final DeviceLocator locator;

  @override
  State<ShareLocationScreen> createState() => _ShareLocationScreenState();
}

class _ShareLocationScreenState extends State<ShareLocationScreen> {
  static const _worldCentre = LatLng(20, 0);
  final _map = MapController();
  bool _mapReady = false;
  LatLng _centre = _worldCentre;
  GeoPoint? _myLocation;
  bool _tracking = false;
  bool _locating = false;
  bool _sending = false;
  String? _error;
  int _locateGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_centreIfPermitted());
  }

  @override
  void dispose() {
    _locateGeneration++;
    _map.dispose();
    super.dispose();
  }

  Future<void> _centreIfPermitted() async {
    final generation = ++_locateGeneration;
    final point = await widget.locator.currentIfPermitted();
    if (!mounted || generation != _locateGeneration || point == null) return;
    // The user may already have panned to choose a place.
    if (_centre != _worldCentre) return;
    _applyLocation(point);
  }

  void _applyLocation(GeoPoint point) {
    setState(() {
      _myLocation = point;
      _tracking = true;
      _centre = latLngOf(point);
      _error = null;
    });
    if (_mapReady) _map.move(_centre, defaultLocationZoom);
  }

  Future<void> _locate() async {
    if (_locating || _sending) return;
    final generation = ++_locateGeneration;
    setState(() {
      _locating = true;
      _error = null;
    });
    GeoPoint? point;
    LocatorFailure? failure;
    try {
      point = await widget.locator.locate();
    } on LocatorException catch (error) {
      failure = error.failure;
    } catch (_) {
      failure = LocatorFailure.unavailable;
    }
    if (!mounted || generation != _locateGeneration) return;
    setState(() => _locating = false);
    if (point != null) {
      _applyLocation(point);
    } else {
      await _explain(failure ?? LocatorFailure.unavailable);
    }
  }

  Future<void> _explain(LocatorFailure failure) async {
    final (message, settings) = switch (failure) {
      LocatorFailure.serviceDisabled => (
        'Please enable your GPS to access location-based features.',
        widget.locator.openLocationSettings,
      ),
      LocatorFailure.deniedForever => (
        'Parallax does not have permission to access your location. '
            'You can enable access in Settings.',
        widget.locator.openAppSettings,
      ),
      LocatorFailure.denied => (
        'Parallax does not have permission to access your location. '
            'You can still drop a pin by moving the map.',
        null,
      ),
      LocatorFailure.unavailable => (
        'Parallax could not access your location. Please try again later.',
        null,
      ),
    };
    if (settings == null) {
      setState(() => _error = message);
      return;
    }
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Location sharing'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (open == true) {
      try {
        await settings();
      } catch (_) {}
    }
  }

  Future<void> _share() async {
    if (_sending) return;
    final mine = _tracking ? _myLocation : null;
    final point =
        mine ??
        GeoPoint(
          _centre.latitude.clamp(-90, 90).toDouble(),
          normaliseLongitude(_centre.longitude),
        );
    if (!point.isValid) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.features.shareLocation(
        widget.roomId,
        point,
        asset: mine == null ? LocationAsset.pin : LocationAsset.self,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error =
            'Couldn’t share this location. Check your connection and '
            'try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final shareMine = _tracking && _myLocation != null;
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
                      'Share location',
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
                          mapController: _map,
                          options: MapOptions(
                            initialCenter: _centre,
                            initialZoom: _myLocation == null
                                ? 2
                                : defaultLocationZoom,
                            minZoom: 2,
                            maxZoom: 19,
                            backgroundColor: p.raised,
                            interactionOptions: const InteractionOptions(
                              flags:
                                  InteractiveFlag.all & ~InteractiveFlag.rotate,
                            ),
                            onMapReady: () => _mapReady = true,
                            onPositionChanged: (camera, hasGesture) {
                              _centre = camera.center;
                              if (hasGesture && _tracking && mounted) {
                                setState(() => _tracking = false);
                              }
                            },
                          ),
                          children: [
                            osmTileLayer(p),
                            if (_myLocation != null && !_tracking)
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: latLngOf(_myLocation!),
                                    width: 22,
                                    height: 22,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: p.secondary,
                                        border: Border.all(
                                          color: p.bubbleText,
                                          width: 3,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                        // Fixed centre pin: the map moves underneath it.
                        IgnorePointer(
                          child: Align(
                            alignment: Alignment.center,
                            child: Transform.translate(
                              offset: const Offset(0, -22),
                              child: LocationMarker(
                                palette: p,
                                asset: shareMine
                                    ? LocationAsset.self
                                    : LocationAsset.pin,
                                senderName: 'Me',
                              ),
                            ),
                          ),
                        ),
                        OsmAttribution(
                          palette: p,
                          alignment: Alignment.bottomLeft,
                        ),
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: Material(
                            color: p.surface,
                            elevation: 3,
                            shape: CircleBorder(
                              side: BorderSide(color: p.stroke),
                            ),
                            child: IconButton(
                              tooltip: 'Move the map to my location',
                              color: _tracking ? p.accent : p.foreground,
                              onPressed: _locating || _sending ? null : _locate,
                              icon: _locating
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      _tracking
                                          ? Icons.my_location_rounded
                                          : Icons.location_searching_rounded,
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      shareMine
                          ? 'Your current location'
                          : 'Move the map to place the pin',
                      style: TextStyle(color: p.muted, fontSize: 13),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: TextStyle(color: p.foreground, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 12),
                    AccentButton(
                      palette: p,
                      label: shareMine
                          ? 'Share my location'
                          : 'Share selected location',
                      icon: shareMine
                          ? Icons.my_location_rounded
                          : Icons.location_on_outlined,
                      onPressed: _sending ? null : _share,
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

/// Opens the share screen for [roomId]; returns whether a location was sent.
Future<bool> openShareLocation(
  BuildContext context, {
  required AppPalette palette,
  required String roomId,
  required LocationFeatures features,
  DeviceLocator locator = const GeolocatorDeviceLocator(),
}) async {
  final sent = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => ShareLocationScreen(
        palette: palette,
        roomId: roomId,
        features: features,
        locator: locator,
      ),
    ),
  );
  return sent ?? false;
}

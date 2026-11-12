import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_avatar.dart';
import '../../widgets.dart';
import '../polls/location_map.dart';
import '../polls/location_model.dart';
import 'live_location_features.dart';
import 'live_location_format.dart';
import 'live_location_model.dart';

/// Destructive red for Stop (readable white text in both palettes).
const _stopRed = Color(0xFFD7263D);

/// Rebuilds [builder] when [features] change, when the soonest of
/// [deadlines] passes (a share expiring) and every 30 s (for "Updated …").
class LiveLocationTicker extends StatefulWidget {
  const LiveLocationTicker({
    super.key,
    required this.features,
    required this.builder,
  });
  final LiveLocationFeatures features;
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<LiveLocationTicker> createState() => _LiveLocationTickerState();
}

class _LiveLocationTickerState extends State<LiveLocationTicker> {
  static const _period = Duration(seconds: 30);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.features.updates.addListener(_changed);
    _schedule();
  }

  @override
  void didUpdateWidget(LiveLocationTicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.features.updates, widget.features.updates)) {
      oldWidget.features.updates.removeListener(_changed);
      widget.features.updates.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(_period, () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.features.updates.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, DateTime.now());
}

/// Rebuilds once at [at] (for example when a share expires).
class _DeadlineRebuild extends StatefulWidget {
  const _DeadlineRebuild({required this.at, required this.child});
  final DateTime? at;
  final Widget child;

  @override
  State<_DeadlineRebuild> createState() => _DeadlineRebuildState();
}

class _DeadlineRebuildState extends State<_DeadlineRebuild> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(_DeadlineRebuild oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.at != widget.at) _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    final at = widget.at;
    if (at == null) return;
    final delay = at.difference(DateTime.now());
    if (delay.isNegative) return;
    _timer = Timer(delay + const Duration(milliseconds: 50), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Ends the own share in [roomId], reporting failure in a SnackBar.
Future<void> stopLiveLocation(
  BuildContext context,
  LiveLocationFeatures features,
  String roomId,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await features.stopSharing(roomId);
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          'Couldn’t stop sharing your live location. Check your '
          'connection and try again.',
        ),
      ),
    );
  }
}

/// Avatar marker for a sharer; dimmed once the share ended.
class LiveSharerMarker extends StatelessWidget {
  const LiveSharerMarker({
    super.key,
    required this.palette,
    required this.backend,
    required this.name,
    required this.avatarUrl,
    required this.live,
    this.size = 40,
  });
  final AppPalette palette;
  final ChatBackend backend;
  final String name;
  final Uri? avatarUrl;
  final bool live;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: live ? '$name’s live location' : '$name’s last known location',
    child: Opacity(
      opacity: live ? 1 : 0.55,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: palette.surface,
          border: Border.all(
            color: live ? palette.accent : palette.muted,
            width: 3,
          ),
          boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black45)],
        ),
        alignment: Alignment.center,
        child: UserAvatar(
          name: name,
          url: avatarUrl,
          backend: backend,
          palette: palette,
          size: size - 8,
        ),
      ),
    ),
  );
}

Marker _markerFor(
  LiveShareSnapshot share, {
  required AppPalette palette,
  required ChatBackend backend,
}) => Marker(
  point: latLngOf(share.latest!.point),
  width: 44,
  height: 44,
  child: LiveSharerMarker(
    palette: palette,
    backend: backend,
    name: share.displayName,
    avatarUrl: share.avatarUrl,
    live: share.live,
  ),
);

/// Timeline body for a `beacon_info` event (Element X live location item):
/// a map preview of the sharer's latest beacon with "Live location · ends
/// 3:45 pm" (or "Live location ended"), Stop for the own live share, and a
/// tap through to [LiveLocationMapScreen].
class LiveLocationBody extends StatefulWidget {
  const LiveLocationBody({
    super.key,
    required this.features,
    required this.backend,
    required this.palette,
    required this.roomId,
    required this.info,
    required this.foreground,
  });

  final LiveLocationFeatures features;
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final BeaconInfo info;
  final Color foreground;

  static const previewHeight = 160.0;
  static const maxWidth = 320.0;

  @override
  State<LiveLocationBody> createState() => _LiveLocationBodyState();
}

class _LiveLocationBodyState extends State<LiveLocationBody> {
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    widget.features.ensureBeaconsLoaded(widget.roomId, widget.info);
  }

  @override
  void didUpdateWidget(LiveLocationBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.info.eventId != widget.info.eventId ||
        oldWidget.roomId != widget.roomId) {
      widget.features.ensureBeaconsLoaded(widget.roomId, widget.info);
    }
  }

  void _openMap(LiveShareSnapshot share) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LiveLocationMapScreen(
        features: widget.features,
        backend: widget.backend,
        palette: widget.palette,
        roomId: widget.roomId,
        focus: share.info,
      ),
    ),
  );

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    await stopLiveLocation(context, widget.features, widget.roomId);
    if (mounted) setState(() => _stopping = false);
  }

  @override
  Widget build(BuildContext context) => LiveLocationTicker(
    features: widget.features,
    builder: (context, now) {
      final share = widget.features.shareSnapshot(widget.roomId, widget.info);
      return _DeadlineRebuild(
        at: share.live ? share.info.expiresAt : null,
        child: _card(context, share, now),
      );
    },
  );

  Widget _card(BuildContext context, LiveShareSnapshot share, DateTime now) {
    final p = widget.palette;
    final latest = share.latest;
    final use24 = use24HourOf(context);
    final title = share.live
        ? 'Live location · ends '
              '${formatEndTime(share.info.expiresAt, now, use24Hour: use24)}'
        : 'Live location ended';
    final subtitle = !share.live
        ? (latest == null ? null : formatUpdatedAgo(latest.timestamp, now))
        : latest == null
        ? (share.loading ? 'Loading…' : 'Waiting for live location…')
        : formatUpdatedAgo(latest.timestamp, now);
    final canStop = share.live && share.mine;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: LiveLocationBody.maxWidth),
      child: Semantics(
        button: true,
        label: 'Show live location on the map',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: LiveLocationBody.maxWidth,
            height: LiveLocationBody.previewHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (latest != null)
                  IgnorePointer(
                    child: FlutterMap(
                      key: ValueKey('live-map-${share.info.eventId}'),
                      options: MapOptions(
                        initialCenter: latLngOf(latest.point),
                        initialZoom: defaultLocationZoom,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.none,
                        ),
                        backgroundColor: p.raised,
                      ),
                      children: [
                        osmTileLayer(p),
                        MarkerLayer(
                          markers: [
                            _markerFor(
                              share,
                              palette: p,
                              backend: widget.backend,
                            ),
                          ],
                        ),
                      ],
                    ),
                  )
                else
                  ColoredBox(
                    color: p.raised,
                    child: Align(
                      alignment: const Alignment(0, -0.35),
                      child: Icon(
                        share.live
                            ? Icons.share_location_rounded
                            : Icons.location_off_outlined,
                        size: 40,
                        color: p.muted,
                      ),
                    ),
                  ),
                if (latest != null)
                  OsmAttribution(
                    palette: p,
                    alignment: Alignment.topRight,
                    interactive: false,
                  ),
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(onTap: () => _openMap(share)),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _StatusBar(
                    palette: p,
                    live: share.live,
                    title: title,
                    subtitle: subtitle,
                    onStop: canStop && !_stopping ? _stop : null,
                    showStop: canStop,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.palette,
    required this.live,
    required this.title,
    required this.subtitle,
    required this.onStop,
    required this.showStop,
  });
  final AppPalette palette;
  final bool live;
  final String title;
  final String? subtitle;
  final VoidCallback? onStop;
  final bool showStop;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      color: p.background.withValues(alpha: 0.9),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: live ? p.surface : p.raised,
              border: Border.all(
                color: live ? p.accent.withValues(alpha: 0.6) : p.stroke,
              ),
            ),
            child: Icon(
              Icons.location_on_rounded,
              size: 18,
              color: live ? p.accent : p.muted,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
              ],
            ),
          ),
          if (showStop)
            // Element X: a compact red stop button on the own live item.
            IconButton(
              tooltip: 'Stop sharing',
              onPressed: onStop,
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                backgroundColor: _stopRed,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.stop_rounded, size: 20),
            ),
        ],
      ),
    );
  }
}

/// Compact body for a `beacon_info` that ends a share (`live: false`).
class LiveLocationEndedLine extends StatelessWidget {
  const LiveLocationEndedLine({
    super.key,
    required this.palette,
    required this.foreground,
  });
  final AppPalette palette;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.location_off_outlined, size: 16, color: foreground),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          'Live location ended',
          style: TextStyle(
            color: foreground,
            fontSize: 13,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    ],
  );
}

Future<void> _openShareInMaps(
  BuildContext context,
  LiveShareSnapshot share,
) async {
  final latest = share.latest;
  if (latest == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final opened = await openInMaps(latest.point, label: share.displayName);
  if (!opened) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('No app could open this location.')),
    );
  }
}

/// Full-screen map of every live sharer in a room (Element X "On the map"
/// live sheet): avatar markers, last update times, Open in maps, and Stop
/// for the own share. [focus] (from a timeline item) is shown and centred
/// even after it ended.
class LiveLocationMapScreen extends StatefulWidget {
  const LiveLocationMapScreen({
    super.key,
    required this.features,
    required this.backend,
    required this.palette,
    required this.roomId,
    this.focus,
  });

  final LiveLocationFeatures features;
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final BeaconInfo? focus;

  @override
  State<LiveLocationMapScreen> createState() => _LiveLocationMapScreenState();
}

class _LiveLocationMapScreenState extends State<LiveLocationMapScreen> {
  final _map = MapController();
  bool _mapReady = false;
  bool _centred = false;
  bool _stopping = false;

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  List<LiveShareSnapshot> _shares() {
    final live = widget.features.liveShares(widget.roomId);
    final focus = widget.focus;
    if (focus == null || live.any((s) => s.info.eventId == focus.eventId)) {
      return live;
    }
    final snapshot = widget.features.shareSnapshot(widget.roomId, focus);
    return [snapshot, ...live.where((s) => s.userId != focus.sender)];
  }

  LiveShareSnapshot? _initial(List<LiveShareSnapshot> shares) {
    final focus = widget.focus;
    for (final share in shares) {
      if (share.latest != null &&
          (focus == null || share.info.eventId == focus.eventId)) {
        return share;
      }
    }
    for (final share in shares) {
      if (share.latest != null) return share;
    }
    return null;
  }

  void _centreOn(LiveShareSnapshot share) {
    final latest = share.latest;
    if (latest == null || !_mapReady) return;
    _map.move(latLngOf(latest.point), defaultLocationZoom);
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    await stopLiveLocation(context, widget.features, widget.roomId);
    if (mounted) setState(() => _stopping = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: LiveLocationTicker(
            features: widget.features,
            builder: (context, now) {
              final shares = _shares();
              for (final share in shares) {
                widget.features.ensureBeaconsLoaded(widget.roomId, share.info);
              }
              final initial = _initial(shares);
              if (initial != null && _mapReady && !_centred) {
                _centred = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _centreOn(initial);
                });
              }
              final soonest = shares
                  .where((s) => s.live)
                  .map((s) => s.info.expiresAt)
                  .fold<DateTime?>(
                    null,
                    (a, b) => a == null || b.isBefore(a) ? b : a,
                  );
              return _DeadlineRebuild(
                at: soonest,
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
                            'Live location',
                            style: TextStyle(
                              color: p.foreground,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Expanded(child: _mapView(shares, initial)),
                    _sheet(context, shares, now),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _mapView(List<LiveShareSnapshot> shares, LiveShareSnapshot? initial) {
    final p = widget.palette;
    final located = shares.where((s) => s.latest != null).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: initial == null
                    ? latLngOf(const GeoPoint(20, 0))
                    : latLngOf(initial.latest!.point),
                initialZoom: initial == null ? 2 : defaultLocationZoom,
                minZoom: 2,
                maxZoom: 19,
                backgroundColor: p.raised,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
                onMapReady: () {
                  _mapReady = true;
                  if (initial != null) _centred = true;
                },
              ),
              children: [
                osmTileLayer(p),
                MarkerLayer(
                  markers: [
                    for (final share in located)
                      _markerFor(share, palette: p, backend: widget.backend),
                  ],
                ),
              ],
            ),
            OsmAttribution(palette: p),
          ],
        ),
      ),
    );
  }

  Widget _sheet(
    BuildContext context,
    List<LiveShareSnapshot> shares,
    DateTime now,
  ) {
    final p = widget.palette;
    final liveCount = shares.where((s) => s.live).length;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.4,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Eyebrow('On the map', palette: p),
            const SizedBox(height: 4),
            Text(
              liveCount == 0
                  ? 'Nobody is sharing their location'
                  : liveCount == 1
                  ? '1 person'
                  : '$liveCount people',
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final share in shares) _row(context, share, now),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, LiveShareSnapshot share, DateTime now) {
    final p = widget.palette;
    final latest = share.latest;
    final use24 = use24HourOf(context);
    final status = !share.live
        ? 'Live location ended'
        : latest == null
        ? 'Waiting for live location…'
        : '${formatUpdatedAgo(latest.timestamp, now)} · ends '
              '${formatEndTime(share.info.expiresAt, now, use24Hour: use24)}';
    return InkWell(
      key: ValueKey('live-sharer-${share.userId}'),
      borderRadius: BorderRadius.circular(14),
      onTap: latest == null ? null : () => _centreOn(share),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            UserAvatar(
              name: share.displayName,
              url: share.avatarUrl,
              backend: widget.backend,
              palette: p,
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    share.mine
                        ? '${share.displayName} (you)'
                        : share.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (share.mine && share.live)
              IconButton(
                tooltip: 'Stop sharing',
                onPressed: _stopping ? null : _stop,
                style: IconButton.styleFrom(
                  backgroundColor: _stopRed,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.stop_rounded),
              ),
            if (latest != null)
              IconButton(
                tooltip: 'Open in maps',
                onPressed: () => _openShareInMaps(context, share),
                icon: Icon(Icons.map_outlined, color: p.foreground),
              ),
          ],
        ),
      ),
    );
  }
}

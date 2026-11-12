import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import 'live_location_features.dart';
import 'live_location_format.dart';
import 'live_location_sharer.dart';
import 'live_location_view.dart';

/// Room banner (Element X `LiveLocationSharingBanner`): "You’re sharing your
/// live location" with Stop while the own share is live (from this or
/// another device), otherwise "N people are sharing live location". Tapping
/// opens [LiveLocationMapScreen].
class LiveLocationBanner extends StatefulWidget {
  const LiveLocationBanner({
    super.key,
    required this.features,
    required this.backend,
    required this.palette,
    required this.roomId,
  });

  final LiveLocationFeatures features;
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  @override
  State<LiveLocationBanner> createState() => _LiveLocationBannerState();
}

class _LiveLocationBannerState extends State<LiveLocationBanner> {
  bool _stopping = false;

  void _openMap() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LiveLocationMapScreen(
        features: widget.features,
        backend: widget.backend,
        palette: widget.palette,
        roomId: widget.roomId,
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
      final shares = widget.features.liveShares(widget.roomId);
      final device = widget.features.deviceShare(widget.roomId);
      final own = shares.where((s) => s.mine).firstOrNull;
      final others = shares.where((s) => !s.mine).toList();
      final starting = device?.status == OwnShareStatus.starting;
      if (own == null && device == null && others.isEmpty) {
        return const SizedBox.shrink();
      }
      final use24 = use24HourOf(context);
      final sharing = own != null || device != null;
      final String title;
      final String subtitle;
      if (sharing) {
        title = starting
            ? 'Starting live location…'
            : 'You’re sharing your live location';
        final expiresAt = own?.info.expiresAt ?? device!.expiresAt;
        final parts = <String>[
          if (device?.retrying ?? false)
            'Couldn’t send your location. Retrying…'
          else if (device == null)
            'Shared from another device'
          else if (!starting)
            'Ends ${formatEndTime(expiresAt, now, use24Hour: use24)}',
          if (others.isNotEmpty)
            others.length == 1
                ? '1 other person sharing'
                : '${others.length} others sharing',
        ];
        subtitle = parts.join(' · ');
      } else {
        title = peopleSharingLabel(others.length);
        subtitle = others.length <= 2
            ? others.map((s) => s.displayName).join(' and ')
            : '${others.first.displayName} and ${others.length - 1} others';
      }
      return _BannerCard(
        palette: widget.palette,
        title: title,
        subtitle: subtitle.isEmpty ? null : subtitle,
        sharing: sharing,
        busy: starting,
        onTap: _openMap,
        onStop: sharing && !_stopping ? _stop : null,
      );
    },
  );
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.sharing,
    required this.busy,
    required this.onTap,
    required this.onStop,
  });

  final AppPalette palette;
  final String title;
  final String? subtitle;
  final bool sharing;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      key: const ValueKey('live-location-banner'),
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: p.accent.withValues(alpha: 0.55)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    gradient: accentGradient(p),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: busy
                      ? Padding(
                          padding: const EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: p.accentOn,
                          ),
                        )
                      : Icon(
                          Icons.share_location_rounded,
                          color: p.accentOn,
                          size: 21,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (sharing)
                  FilledButton(
                    onPressed: onStop,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFD7263D),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Stop'),
                  )
                else
                  Icon(Icons.chevron_right_rounded, color: p.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'thumbnail_sync.dart';

/// Settings → Media → Offline thumbnails: "Sync thumbnails" with progress,
/// the space they use, and clearing them.
class ThumbnailSyncSection extends StatefulWidget {
  const ThumbnailSyncSection({
    super.key,
    required this.sync,
    required this.palette,
  });

  final ThumbnailSync sync;
  final AppPalette palette;

  @override
  State<ThumbnailSyncSection> createState() => _ThumbnailSyncSectionState();
}

class _ThumbnailSyncSectionState extends State<ThumbnailSyncSection> {
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.sync.refreshUsage());
  }

  @override
  void didUpdateWidget(ThumbnailSyncSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sync, widget.sync)) {
      unawaited(widget.sync.refreshUsage());
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear saved thumbnails?'),
        content: const Text(
          'Pictures and previews download again as you open chats, or the '
          'next time you sync thumbnails.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await widget.sync.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t clear saved thumbnails.')),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final muted = TextStyle(color: p.muted, fontSize: 12, height: 1.35);
    return ListenableBuilder(
      listenable: widget.sync,
      builder: (context, _) {
        final state = widget.sync.state;
        final usage = widget.sync.usage;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Eyebrow('Offline thumbnails', palette: p),
            const SizedBox(height: 10),
            Material(
              color: p.surface,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: p.stroke),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.download_for_offline_outlined,
                      color: p.secondary,
                    ),
                    title: const Text('Sync thumbnails'),
                    subtitle: const Text(
                      'Save chat and profile pictures and photo, sticker and '
                      'video previews from every chat on this device, so '
                      'they show straight away, even offline. Uses data; '
                      'best on Wi-Fi.',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: state.running
                        ? _progress(p, state, muted)
                        : _idle(state, muted),
                  ),
                  Divider(height: 1, color: p.stroke),
                  ListTile(
                    key: const ValueKey('thumbnails.usage'),
                    leading: Icon(
                      Icons.sd_storage_outlined,
                      color: p.secondary,
                    ),
                    title: const Text('Saved on this device'),
                    subtitle: Text(
                      usage == null
                          ? 'Checking…'
                          : usage.files == 0
                          ? 'Nothing saved yet'
                          : '${formatBytes(usage.bytes)} · '
                                '${formatCount(usage.files)} '
                                '${usage.files == 1 ? 'file' : 'files'}',
                    ),
                    trailing: TextButton(
                      key: const ValueKey('thumbnails.clear'),
                      onPressed:
                          state.running ||
                              _clearing ||
                              usage == null ||
                              usage.files == 0
                          ? null
                          : _clear,
                      child: const Text('Clear'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
              child: Text(
                'Pictures you see are saved automatically too. Previews '
                'from encrypted chats stay encrypted on the device, and '
                'everything saved is deleted when you sign out.',
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
            ),
            const SizedBox(height: 18),
          ],
        );
      },
    );
  }

  Widget _progress(AppPalette p, ThumbnailSyncState state, TextStyle muted) =>
      Column(
        key: const ValueKey('thumbnails.progress'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.fraction,
              minHeight: 6,
              color: p.accent,
              backgroundColor: p.raised,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            state.roomsTotal == 0
                ? 'Finding your chats…'
                : '${formatCount(state.roomsDone)} of '
                      '${formatCount(state.roomsTotal)} chats · '
                      '${_counts(state)}',
            style: muted,
          ),
          const SizedBox(height: 10),
          Align(
            // Same place as the start button, so it doesn't jump.
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('thumbnails.stop'),
              onPressed: widget.sync.stop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop'),
            ),
          ),
        ],
      );

  Widget _idle(ThumbnailSyncState state, TextStyle muted) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_summary(state) case final summary?) ...[
        Text(summary, key: const ValueKey('thumbnails.summary'), style: muted),
        const SizedBox(height: 10),
      ],
      FilledButton.icon(
        key: const ValueKey('thumbnails.start'),
        onPressed: _clearing ? null : () => unawaited(widget.sync.start()),
        icon: const Icon(Icons.sync_rounded),
        label: Text(
          state.finished || state.stopped ? 'Sync again' : 'Start sync',
        ),
      ),
    ],
  );

  static String _counts(ThumbnailSyncState state) => [
    '${formatCount(state.saved)} saved',
    if (state.alreadySaved > 0)
      '${formatCount(state.alreadySaved)} already saved',
    if (state.failed > 0) '${formatCount(state.failed)} failed',
  ].join(' · ');

  static String? _summary(ThumbnailSyncState state) {
    if (state.error case final error?) {
      return state.roomsDone == 0 ? error : '$error ${_counts(state)}.';
    }
    if (state.stopped) {
      return 'Stopped after ${formatCount(state.roomsDone)} of '
          '${formatCount(state.roomsTotal)} chats: ${_counts(state)}.';
    }
    if (state.finished) {
      final failed = state.failed > 0
          ? ' Failed ones are tried again next time.'
          : '';
      return 'Done: ${_counts(state)}.$failed';
    }
    return null;
  }
}

/// "1,234".
String formatCount(int value) {
  final digits = value.abs().toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return value < 0 ? '-$grouped' : grouped.toString();
}

/// "512 KB", "84 MB", "1.2 GB".
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../attachment_picker.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../../media_viewer.dart';
import '../../message_image.dart';
import 'inline_audio.dart';
import 'media_actions.dart';
import 'media_content.dart';
import 'media_features.dart';
import 'voice_waveform.dart';
import '../../media_preview_policy.dart';

bool _autoLoad(BuildContext context, EntryHookContext ctx) =>
    autoLoadMediaFor(context, ctx.backend, ctx.roomId);

void _open(BuildContext context, EntryHookContext ctx) => unawaited(
  openMediaViewer(
    context,
    backend: ctx.backend,
    roomId: ctx.roomId,
    eventId: ctx.entry.id,
    entries: ctx.entries.isEmpty ? null : ctx.entries,
  ),
);

Widget _caption(EntryHookContext ctx, String? caption) => caption == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          caption,
          style: TextStyle(color: ctx.onBubble, fontSize: 15, height: 1.35),
        ),
      );

/// Image with Element X caption rules: the body is shown under the image only
/// when the event has a separate, different `filename`.
class ImageMessageBody extends StatelessWidget {
  const ImageMessageBody({super.key, required this.ctx});
  final EntryHookContext ctx;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final info = MediaInfo.fromEntry(ctx.entry);
      final size = mediaPreviewSize(
        info,
        maxWidth: math.min(240, constraints.maxWidth),
      );
      return _image(info, size);
    },
  );

  Widget _image(MediaInfo info, Size size) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MessageImage(
          backend: ctx.backend,
          palette: ctx.palette,
          roomId: ctx.roomId,
          eventId: ctx.entry.id,
          entry: ctx.entry,
          entries: ctx.entries,
          width: size.width,
          height: size.height,
        ),
        _caption(ctx, info.caption),
      ],
    );
  }
}

/// Bounded, decrypted thumbnail/preview for one event, pinned to the session.
class MediaPreviewImage extends StatefulWidget {
  const MediaPreviewImage({
    super.key,
    required this.backend,
    required this.roomId,
    required this.eventId,
    required this.palette,
    required this.placeholderIcon,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.enabled = true,
  });
  final ChatBackend backend;
  final String roomId;
  final String eventId;
  final AppPalette palette;
  final IconData placeholderIcon;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// False shows only the placeholder (auto-load media is off).
  final bool enabled;

  @override
  State<MediaPreviewImage> createState() => _MediaPreviewImageState();
}

class _MediaPreviewImageState extends State<MediaPreviewImage> {
  late BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  Future<Uint8List?>? _preview;

  Future<Uint8List?> _load() async {
    final owner = _owner;
    final features = mediaFeaturesOf(widget.backend);
    if (features == null) return null;
    try {
      final bytes = await features.loadPreview(widget.roomId, widget.eventId);
      return mounted && owner.isCurrent && identical(owner, _owner)
          ? bytes
          : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _preview = _load();
  }

  @override
  void didUpdateWidget(MediaPreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend) {
      _owner.release();
      _owner = BackendSessionOwner(widget.backend);
    }
    if (oldWidget.backend != widget.backend ||
        oldWidget.roomId != widget.roomId ||
        oldWidget.eventId != widget.eventId ||
        oldWidget.enabled != widget.enabled) {
      _preview = widget.enabled ? _load() : null;
    }
  }

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  Widget _placeholder() => Container(
    width: widget.width,
    height: widget.height,
    color: widget.palette.raised,
    alignment: Alignment.center,
    child: Icon(widget.placeholderIcon, color: widget.palette.secondary),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _preview,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null || !_owner.isCurrent) return _placeholder();
      return Image(
        image: boundedMemoryImage(bytes, maxEdge: 768),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    },
  );
}

/// Video: thumbnail (decrypted when encrypted), play badge and duration.
/// Tapping opens the full-screen viewer, which plays the video.
class VideoMessageBody extends StatelessWidget {
  const VideoMessageBody({super.key, required this.ctx});
  final EntryHookContext ctx;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _video(
      context,
      MediaInfo.fromEntry(ctx.entry),
      math.min(240, constraints.maxWidth),
    ),
  );

  Widget _video(BuildContext context, MediaInfo info, double maxWidth) {
    final size = mediaPreviewSize(info, maxWidth: maxWidth);
    final p = ctx.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: 'Video: ${info.name}. Double tap to play.',
          child: GestureDetector(
            onTap: () => _open(context, ctx),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (info.hasThumbnail)
                      MediaPreviewImage(
                        backend: ctx.backend,
                        roomId: ctx.roomId,
                        eventId: ctx.entry.id,
                        palette: p,
                        placeholderIcon: Icons.movie_outlined,
                        width: size.width,
                        height: size.height,
                        enabled: _autoLoad(context, ctx),
                      )
                    else
                      ColoredBox(
                        color: p.raised,
                        child: Icon(
                          Icons.movie_outlined,
                          color: p.muted,
                          size: 36,
                        ),
                      ),
                    Center(
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                      ),
                    ),
                    if (info.duration != null)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: _Badge(
                          text: formatMediaDuration(info.duration!),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        _caption(ctx, info.caption),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// Shared state for inline audio/voice bodies: lazily created controller,
/// pinned to the backend session, closed (joined) on dispose.
mixin _InlineAudioOwner<T extends StatefulWidget> on State<T> {
  EntryHookContext get hookContext;
  InlineAudioController? _controller;
  late BackendSessionOwner _session = BackendSessionOwner(hookContext.backend);

  InlineAudioController _ensureController() {
    final existing = _controller;
    if (existing != null && !existing.closed) return existing;
    final ctx = hookContext;
    final load = mediaLoaderFor(ctx.backend, ctx.roomId, ctx.entry.id);
    final controller = InlineAudioController(
      loader: () async => coerceAudioAttachment(await load()),
      knownDuration: MediaInfo.fromEntry(ctx.entry).duration,
    )..addListener(_rebuild);
    _controller = controller;
    return controller;
  }

  void _rebuild() {
    if (!mounted) return;
    if (!_session.isCurrent) {
      // Never dispose a notifier from inside its own notification.
      scheduleMicrotask(() {
        if (!_session.isCurrent) _discard();
      });
    }
    setState(() {});
  }

  void _discard() {
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_rebuild);
    controller?.dispose();
  }

  void sessionCheckedToggle() {
    if (!_session.isCurrent) return;
    unawaited(_ensureController().toggle());
  }

  void resetForEntry() {
    _discard();
    _session.release();
    _session = BackendSessionOwner(hookContext.backend);
  }

  @override
  void dispose() {
    _discard();
    _session.release();
    super.dispose();
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.ctx,
    required this.controller,
    required this.onPressed,
  });
  final EntryHookContext ctx;
  final InlineAudioController? controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final status = controller?.status ?? InlineAudioStatus.idle;
    final playing = controller?.playing ?? false;
    final mine = ctx.mine;
    final background = mine ? ctx.palette.bubbleText : ctx.palette.accent;
    final foreground = mine ? ctx.palette.bubble : ctx.palette.accentOn;
    return SizedBox(
      width: 40,
      height: 40,
      child: status == InlineAudioStatus.loading
          ? Padding(
              padding: const EdgeInsets.all(9),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: background,
              ),
            )
          : IconButton.filled(
              tooltip: status == InlineAudioStatus.failed
                  ? 'Retry'
                  : playing
                  ? 'Pause'
                  : 'Play',
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: background,
                foregroundColor: foreground,
              ),
              onPressed: onPressed,
              icon: Icon(
                status == InlineAudioStatus.failed
                    ? Icons.refresh_rounded
                    : playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
    );
  }
}

/// MSC3245 voice message: waveform, play/pause, progress, time and the
/// Element X playback speed toggle (1×, 1.5×, 2×, 0.5×).
class VoiceMessageBody extends StatefulWidget {
  const VoiceMessageBody({super.key, required this.ctx});
  final EntryHookContext ctx;

  @override
  State<VoiceMessageBody> createState() => _VoiceMessageBodyState();
}

class _VoiceMessageBodyState extends State<VoiceMessageBody>
    with _InlineAudioOwner<VoiceMessageBody> {
  @override
  EntryHookContext get hookContext => widget.ctx;

  @override
  void initState() {
    super.initState();
    voicePlaybackSpeed.addListener(_speedChanged);
  }

  @override
  void didUpdateWidget(VoiceMessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ctx.entry.id != widget.ctx.entry.id ||
        oldWidget.ctx.backend != widget.ctx.backend) {
      resetForEntry();
    }
  }

  @override
  void dispose() {
    voicePlaybackSpeed.removeListener(_speedChanged);
    super.dispose();
  }

  void _speedChanged() {
    unawaited(_controller?.setSpeed(voicePlaybackSpeed.value));
    if (mounted) setState(() {});
  }

  void _toggle() {
    final controller = _ensureController();
    if (controller.speed != voicePlaybackSpeed.value) {
      unawaited(controller.setSpeed(voicePlaybackSpeed.value));
    }
    sessionCheckedToggle();
  }

  void _cycleSpeed() {
    final index = voicePlaybackSpeeds.indexOf(voicePlaybackSpeed.value);
    voicePlaybackSpeed.value =
        voicePlaybackSpeeds[(index + 1) % voicePlaybackSpeeds.length];
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final info = MediaInfo.fromEntry(ctx.entry);
    final controller = _controller;
    final started =
        controller != null && controller.status == InlineAudioStatus.ready;
    final shown =
        started && (controller.playing || controller.position > Duration.zero)
        ? controller.position
        : (controller?.duration ?? info.duration ?? Duration.zero);
    final foreground = ctx.onBubble;
    return Semantics(
      label:
          'Voice message, ${formatMediaDuration(info.duration ?? Duration.zero)}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 252),
        child: Row(
          children: [
            _PlayButton(ctx: ctx, controller: controller, onPressed: _toggle),
            const SizedBox(width: 10),
            Expanded(
              child: WaveformBars(
                samples: info.waveform,
                progress: controller?.progress ?? 0,
                playedColor: foreground,
                unplayedColor: foreground.withValues(alpha: 0.5),
                onSeek: started ? controller.seekFraction : null,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatMediaDuration(shown),
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              height: 30,
              child: TextButton(
                onPressed: _cycleSpeed,
                style: TextButton.styleFrom(
                  foregroundColor: foreground,
                  minimumSize: const Size(40, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                // Style the Text (not the button) so the theme font is kept.
                child: Text(
                  formatSpeed(voicePlaybackSpeed.value),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                  semanticsLabel:
                      'Playback speed ${formatSpeed(voicePlaybackSpeed.value)}. '
                      'Tap to change.',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline audio file player: play/pause, seek bar, position/duration, size.
class AudioMessageBody extends StatefulWidget {
  const AudioMessageBody({super.key, required this.ctx});
  final EntryHookContext ctx;

  @override
  State<AudioMessageBody> createState() => _AudioMessageBodyState();
}

class _AudioMessageBodyState extends State<AudioMessageBody>
    with _InlineAudioOwner<AudioMessageBody> {
  @override
  EntryHookContext get hookContext => widget.ctx;

  @override
  void didUpdateWidget(AudioMessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ctx.entry.id != widget.ctx.entry.id ||
        oldWidget.ctx.backend != widget.ctx.backend) {
      resetForEntry();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final info = MediaInfo.fromEntry(ctx.entry);
    final controller = _controller;
    final ready = controller?.status == InlineAudioStatus.ready;
    final duration = controller?.duration ?? info.duration ?? Duration.zero;
    final position = controller?.position ?? Duration.zero;
    final foreground = ctx.onBubble;
    final total = duration.inMilliseconds.toDouble();
    final details = [
      '${formatMediaDuration(position)} / ${formatMediaDuration(duration)}',
      if (info.size != null) formatFileSize(info.size!),
    ].join(' · ');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _PlayButton(
                ctx: ctx,
                controller: controller,
                onPressed: sessionCheckedToggle,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: SliderComponentShape.noOverlay,
                        activeTrackColor: foreground,
                        inactiveTrackColor: foreground.withValues(alpha: 0.3),
                        thumbColor: foreground,
                        disabledActiveTrackColor: foreground.withValues(
                          alpha: 0.5,
                        ),
                        disabledInactiveTrackColor: foreground.withValues(
                          alpha: 0.3,
                        ),
                        disabledThumbColor: foreground.withValues(alpha: 0.7),
                      ),
                      child: SizedBox(
                        height: 22,
                        child: Slider(
                          value: total <= 0
                              ? 0
                              : position.inMilliseconds
                                    .clamp(0, total)
                                    .toDouble(),
                          max: total <= 0 ? 1 : total,
                          onChanged: ready && total > 0
                              ? (value) => unawaited(
                                  controller!.seekFraction(value / total),
                                )
                              : null,
                          semanticFormatterCallback: (value) =>
                              formatMediaDuration(
                                Duration(milliseconds: value.round()),
                              ),
                        ),
                      ),
                    ),
                    Text(
                      details,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.8),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          _caption(ctx, info.caption),
        ],
      ),
    );
  }
}

/// Sticker image (static first frame for animated stickers), sized from its
/// declared dimensions and capped at 180 px.
class StickerMessageBody extends StatelessWidget {
  const StickerMessageBody({super.key, required this.ctx});
  final EntryHookContext ctx;

  @override
  Widget build(BuildContext context) {
    final info = MediaInfo.fromEntry(ctx.entry);
    final ratio = info.aspectRatio ?? 1;
    final width = ratio >= 1 ? 180.0 : 180.0 * ratio;
    final height = ratio >= 1 ? 180.0 / ratio : 180.0;
    return Semantics(
      label: 'Sticker: ${ctx.entry.body}',
      image: true,
      child: Tooltip(
        message: ctx.entry.body,
        child: GestureDetector(
          onTap: () => _open(context, ctx),
          child: SizedBox(
            width: width,
            height: height,
            child: MediaPreviewImage(
              backend: ctx.backend,
              roomId: ctx.roomId,
              eventId: ctx.entry.id,
              palette: ctx.palette,
              placeholderIcon: Icons.emoji_emotions_outlined,
              width: width,
              height: height,
              fit: BoxFit.contain,
              enabled: _autoLoad(context, ctx),
            ),
          ),
        ),
      ),
    );
  }
}

/// A sticker without bubble chrome, aligned like a message, with its time.
class StandaloneSticker extends StatelessWidget {
  const StandaloneSticker({super.key, required this.ctx, this.onLongPress});
  final EntryHookContext ctx;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final entry = ctx.entry;
    return Align(
      alignment: entry.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: GestureDetector(
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: entry.mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!entry.mine)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4, left: 4),
                  child: Text(
                    entry.senderLabel,
                    style: TextStyle(
                      color: ctx.palette.secondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              StickerMessageBody(ctx: ctx),
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 4, left: 4),
                child: Text(
                  TimeOfDay.fromDateTime(entry.time.toLocal()).format(context),
                  style: TextStyle(fontSize: 10, color: ctx.palette.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// File card: type icon, name, size and type; tap opens the viewer (preview,
/// save, share, info) and the download button saves directly.
class FileMessageBody extends StatelessWidget {
  const FileMessageBody({super.key, required this.ctx});
  final EntryHookContext ctx;

  @override
  Widget build(BuildContext context) {
    final info = MediaInfo.fromEntry(ctx.entry);
    final p = ctx.palette;
    final foreground = ctx.onBubble;
    final details = [
      if (info.size != null) formatFileSize(info.size!),
      fileTypeLabel(info.name, info.mimeType),
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _open(context, ctx),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: ctx.mine
                        ? p.bubbleText.withValues(alpha: 0.16)
                        : p.raised,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    fileTypeIcon(info.name, info.mimeType),
                    color: ctx.mine ? p.bubbleText : p.secondary,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        info.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        details,
                        style: TextStyle(
                          color: foreground.withValues(alpha: 0.8),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Save ${info.name}',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.download_rounded,
                    size: 20,
                    color: ctx.mine ? p.bubbleText : p.secondary,
                  ),
                  onPressed: () => unawaited(
                    saveAttachment(
                      context,
                      ctx.backend,
                      ctx.roomId,
                      ctx.entry.id,
                      loader: mediaLoaderFor(
                        ctx.backend,
                        ctx.roomId,
                        ctx.entry.id,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _caption(ctx, info.caption),
      ],
    );
  }
}

// Hook implementations for the on-device voice transcription module.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import 'transcription.dart';

/// Long-press message action: "Transcribe" on voice/audio messages.
List<MessageActionItem> transcriptionMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final entry = ctx.entry;
  if ((entry.kind != EntryKind.voice && entry.kind != EntryKind.audio) ||
      entry.redacted ||
      !entry.id.startsWith(r'$')) {
    return const [];
  }
  return [
    MessageActionItem(
      id: 'transcription.transcribe',
      icon: Icons.subtitles_outlined,
      label: 'Transcribe',
      onSelected: (context) => _openTranscript(
        context,
        backend: ctx.backend,
        palette: ctx.palette,
        roomId: ctx.roomId,
        eventId: entry.id,
      ),
    ),
  ];
}

Future<void> _openTranscript(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required String roomId,
  required String eventId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.background,
    builder: (_) => _TranscriptSheet(
      backend: backend,
      palette: palette,
      roomId: roomId,
      eventId: eventId,
    ),
  );
}

class _TranscriptSheet extends StatefulWidget {
  const _TranscriptSheet({
    required this.backend,
    required this.palette,
    required this.roomId,
    required this.eventId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final String eventId;

  @override
  State<_TranscriptSheet> createState() => _TranscriptSheetState();
}

class _TranscriptSheetState extends State<_TranscriptSheet> {
  bool _busy = true;
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final accountKey = BackendSessionOwner.keyFor(widget.backend) ?? '';
    final cached = await TranscriptCache.get(accountKey, widget.eventId);
    if (!mounted) return;
    if (cached != null) {
      setState(() {
        _text = cached;
        _busy = false;
      });
      return;
    }
    try {
      final path = await downloadAudioToFile(
        widget.backend,
        widget.roomId,
        widget.eventId,
      );
      if (!mounted) return;
      if (path == null) {
        setState(() {
          _error = 'Couldn’t load the audio.';
          _busy = false;
        });
        return;
      }
      final text = await SpeechTools.transcribe(path);
      if (!mounted) return;
      if (text.trim().isEmpty) {
        setState(() {
          _error = 'No speech was recognised.';
          _busy = false;
        });
        return;
      }
      await TranscriptCache.put(accountKey, widget.eventId, text);
      if (!mounted) return;
      setState(() {
        _text = text;
        _busy = false;
      });
    } on TranscriptionUnavailable catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Transcription failed. Try again.';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.subtitles_outlined, color: p.secondary),
              const SizedBox(width: 8),
              Text(
                'Transcript',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Transcribed on your device. Nothing was uploaded.',
            style: TextStyle(color: p.muted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (_busy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(color: p.accent),
                    const SizedBox(height: 12),
                    Text(
                      'Listening to the message…',
                      style: TextStyle(color: p.muted),
                    ),
                  ],
                ),
              ),
            )
          else if (_error != null)
            Text(_error!, style: TextStyle(color: p.accent))
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.stroke),
              ),
              child: SelectableText(
                _text ?? '',
                style: TextStyle(color: p.foreground, fontSize: 15),
              ),
            ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:image_picker/image_picker.dart';

import 'features/reactions/reaction_hooks.dart';
import 'hooks/hook_types.dart';
import 'messaging_features.dart';
import 'voice_recorder.dart';

typedef MediaPicker = Future<MediaSelection?> Function();

enum _MediaSource { gallery, camera, file }

enum _VoiceMode { idle, requesting, recording, stopping }

/// A single staged attachment with a caption, keyboard images and voice capture.
/// The controller remains caller-owned. [onSend] must throw on failure and must
/// not change the controller itself: this widget clears only successful revisions.
/// Restore caller buffers in [onAcknowledged], after that clearing has finished.
/// Injected [recorder] instances are owned/disposed by this widget and should be
/// stable for the widget's lifetime. No permission is requested before a mic tap.
class RichMessageComposer extends StatefulWidget {
  const RichMessageComposer({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSend,
    this.sendContext,
    this.onAcknowledged,
    this.onCancel,
    this.onChanged,
    this.pickGallery,
    this.pickCamera,
    this.pickFile,
    this.recorder,
    this.extraAttachments = const [],
  });

  static const maxMediaBytes = maxComposerMediaBytes;
  final TextEditingController controller;
  final bool sending;
  final Future<void> Function(String text, MediaSelection? media) onSend;

  /// Synchronous ownership/revision token. Changing it fences late success and
  /// error publication without disposing staged media or the voice recorder.
  final Object? Function()? sendContext;

  /// Called after successful, still-owned acknowledgement. The argument says
  /// whether the sent text revision was cleared (false means newer typing).
  final ValueChanged<bool>? onAcknowledged;
  final VoidCallback? onCancel;
  final ValueChanged<String>? onChanged;
  final MediaPicker? pickGallery;
  final MediaPicker? pickCamera;
  final MediaPicker? pickFile;
  final VoiceRecorder? recorder;

  /// Feature-provided attachment options (poll, location …) shown after the
  /// built-in media sources.
  final List<ComposerAttachmentAction> extraAttachments;

  @override
  State<RichMessageComposer> createState() => _RichMessageComposerState();
}

class _RichMessageComposerState extends State<RichMessageComposer>
    with WidgetsBindingObserver {
  MediaSelection? _media;
  bool _voiceMedia = false;
  String? _error;
  bool _closed = false;
  bool _background = false;
  bool _sendOwned = false;
  bool _pickOwned = false;
  bool _sourceSheetOpen = false;
  bool _emojiSheetOpen = false;
  bool _playing = false;
  bool _previewOwned = false;
  bool _discardOwned = false;
  int _pickEpoch = 0;
  int _mediaVersion = 0;
  int _textVersion = 0;
  int _voiceEpoch = 0;
  late String _lastText;
  VoiceRecorder? _recorder;
  StreamSubscription<bool>? _playbackSubscription;
  _VoiceMode _voiceMode = _VoiceMode.idle;
  Future<void> _voiceWork = Future<void>.value();
  int _recordingSeconds = 0;
  Timer? _durationTimer;

  bool get _alive => mounted && !_closed;
  bool get _voiceIdle => _voiceMode == _VoiceMode.idle;
  bool get _sending => _sendOwned || widget.sending;
  bool get _canSend =>
      !_sending &&
      !_pickOwned &&
      _voiceIdle &&
      !_background &&
      (_media != null || widget.controller.text.trim().isNotEmpty);

  @override
  void initState() {
    super.initState();
    _recorder = widget.recorder;
    _lastText = widget.controller.text;
    widget.controller.addListener(_draftChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(RichMessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_draftChanged);
      _lastText = widget.controller.text;
      _textVersion++;
      widget.controller.addListener(_draftChanged);
    }
  }

  void _draftChanged() {
    if (!_alive || _lastText == widget.controller.text) return;
    _lastText = widget.controller.text;
    _textVersion++;
    setState(() {});
    // Also notify for emoji insertion, successful clearing and external edits.
    widget.onChanged?.call(_lastText);
  }

  String _explain(Object error) =>
      error is FormatException ? error.message : error.toString();

  void _showError(String message) {
    if (_alive) setState(() => _error = message);
  }

  String? _validate(MediaSelection media) {
    if (media.bytes.isEmpty) return 'The selected attachment is empty.';
    if (media.bytes.length > RichMessageComposer.maxMediaBytes) {
      return 'Attachments must be 20 MB or smaller.';
    }
    return null;
  }

  void _assignMedia(MediaSelection? selection, {bool voice = false}) {
    _pickEpoch++; // Invalidate native results, including stale error completions.
    _mediaVersion++;
    _media = selection;
    _voiceMedia = voice;
    _error = null;
  }

  void _stage(MediaSelection selection) {
    final error = _validate(selection);
    if (error != null) {
      _showError(error);
      return;
    }
    if (!_voiceIdle || _background) {
      _showError(
        'Finish or discard the voice recording before attaching media.',
      );
      return;
    }
    if (_voiceMedia) _discardVoice();
    setState(() => _assignMedia(selection));
  }

  Future<MediaSelection?> _pickImage(ImageSource source) async {
    final image = await ImagePicker().pickImage(source: source);
    if (image == null) return null;
    return _fromFile(image);
  }

  Future<MediaSelection> _fromFile(XFile file) async => MediaSelection(
    bytes: await readComposerMedia(
      file.openRead(),
      length: await file.length(),
    ),
    name: file.name,
    mimeType: file.mimeType ?? _mimeFor(file.name),
  );

  Future<MediaSelection?> _pickFile() async {
    final file = await FilePicker.pickFile(dialogTitle: 'Attach a file');
    if (file == null) return null;
    // xFile handles Android SAF content and provider-backed cached files.
    final length = await file.length();
    if (length != null && length > RichMessageComposer.maxMediaBytes) {
      throw const FormatException('Attachments must be 20 MB or smaller.');
    }
    return _fromFile(file.xFile);
  }

  static String _mimeFor(String name) =>
      switch (name.split('.').last.toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'heif' => 'image/heif',
        'avif' => 'image/avif',
        'bmp' => 'image/bmp',
        'pdf' => 'application/pdf',
        'txt' || 'log' => 'text/plain',
        'csv' => 'text/csv',
        'json' => 'application/json',
        'zip' => 'application/zip',
        'mp4' => 'video/mp4',
        'mov' => 'video/quicktime',
        'webm' => 'video/webm',
        'mp3' => 'audio/mpeg',
        'm4a' => 'audio/mp4',
        'ogg' || 'opus' => 'audio/ogg',
        'wav' => 'audio/wav',
        _ => 'application/octet-stream',
      };

  Future<void> _showSources() async {
    if (!_alive ||
        _sourceSheetOpen ||
        _pickOwned ||
        !_voiceIdle ||
        _background) {
      return;
    }
    // Acquire before awaiting the modal. Repeated callbacks cannot open two.
    setState(() => _sourceSheetOpen = true);
    final epoch = _pickEpoch;
    var chosen = false;
    try {
      final source = await showModalBottomSheet<Object>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('Attach media'),
                subtitle: Text('One attachment · up to 20 MB'),
              ),
              for (final item in [
                (_MediaSource.gallery, Icons.photo_library_outlined, 'Gallery'),
                (_MediaSource.camera, Icons.photo_camera_outlined, 'Camera'),
                (_MediaSource.file, Icons.insert_drive_file_outlined, 'File'),
              ])
                ListTile(
                  leading: Icon(item.$2),
                  title: Text(item.$3),
                  onTap: () {
                    if (chosen) return;
                    chosen = true;
                    Navigator.pop(context, item.$1);
                  },
                ),
              for (final extra in widget.extraAttachments)
                ListTile(
                  leading: Icon(extra.icon),
                  title: Text(extra.label),
                  onTap: () {
                    if (chosen) return;
                    chosen = true;
                    Navigator.pop(context, extra);
                  },
                ),
            ],
          ),
        ),
      );
      if (!_alive || epoch != _pickEpoch || source == null) return;
      if (source is ComposerAttachmentAction) {
        _sourceSheetOpen = false;
        if (!mounted) return;
        await source.onSelected(context);
        return;
      }
      _pick(source as _MediaSource);
    } finally {
      _sourceSheetOpen = false;
      if (_alive) setState(() {});
    }
  }

  void _pick(_MediaSource source) {
    if (!_alive || _pickOwned || !_voiceIdle || _background) return;
    final epoch = ++_pickEpoch;
    setState(() {
      _pickOwned = true;
      _error = null;
    });
    final picker = switch (source) {
      _MediaSource.gallery =>
        widget.pickGallery ?? () => _pickImage(ImageSource.gallery),
      _MediaSource.camera =>
        widget.pickCamera ?? () => _pickImage(ImageSource.camera),
      _MediaSource.file => widget.pickFile ?? _pickFile,
    };
    unawaited(() async {
      try {
        final result = await picker();
        if (!_alive || epoch != _pickEpoch || result == null) return;
        _stage(result);
      } catch (error) {
        if (_alive && epoch == _pickEpoch) {
          _showError('Could not open attachment: ${_explain(error)}');
        }
      } finally {
        // No new native picker can start until this one actually finishes, even
        // when keyboard insertion/removal invalidated its publication rights.
        _pickOwned = false;
        if (_alive) setState(() {});
      }
    }());
  }

  void _insertContent(KeyboardInsertedContent content) {
    if (!_alive || _background) return;
    if (!content.mimeType.toLowerCase().startsWith('image/')) {
      _showError(
        'Only images, GIFs and image stickers can be inserted from the keyboard.',
      );
      return;
    }
    final data = content.data;
    if (data == null || data.isEmpty) {
      _showError(
        'The keyboard did not provide image bytes. Try attaching the image from Gallery.',
      );
      return;
    }
    final extension = switch (content.mimeType.toLowerCase()) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/heic' => 'heic',
      'image/heif' => 'heif',
      'image/avif' => 'avif',
      'image/bmp' => 'bmp',
      _ => 'png',
    };
    // Never follow the supplied content URI or infer/send its path as text.
    _stage(
      MediaSelection(
        bytes: data,
        name: 'keyboard.$extension',
        mimeType: content.mimeType,
      ),
    );
  }

  Future<void> _showEmoji() async {
    if (_emojiSheetOpen || !_alive || _background) return;
    setState(() => _emojiSheetOpen = true);
    var chosen = false;
    try {
      final emoji = emojiPickerAvailable
          ? await pickEmoji(context)
          : await showModalBottomSheet<String>(
              context: context,
              showDragHandle: true,
              builder: (context) => SafeArea(
                child: SizedBox(
                  height: 300,
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Emoji'),
                      ),
                      Expanded(
                        child: GridView.count(
                          crossAxisCount: 8,
                          children: [
                            for (final emoji in const [
                              '😀',
                              '😃',
                              '😁',
                              '😂',
                              '🥰',
                              '😍',
                              '😎',
                              '🥳',
                              '😊',
                              '🙂',
                              '😉',
                              '🤔',
                              '😅',
                              '😭',
                              '😮',
                              '😴',
                              '👍',
                              '👎',
                              '👏',
                              '🙌',
                              '🙏',
                              '💪',
                              '🤝',
                              '👋',
                              '❤️',
                              '🧡',
                              '💛',
                              '💚',
                              '💙',
                              '💜',
                              '🔥',
                              '✨',
                              '🎉',
                              '🎂',
                              '🎁',
                              '🌈',
                              '☀️',
                              '🌙',
                              '⭐',
                              '💯',
                              '✅',
                              '❌',
                              '❓',
                              '💡',
                              '👀',
                              '🚀',
                              '☕',
                              '🍕',
                            ])
                              TextButton(
                                key: ValueKey('emoji-$emoji'),
                                onPressed: () {
                                  if (chosen) return;
                                  chosen = true;
                                  Navigator.pop(context, emoji);
                                },
                                child: Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 26),
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
      if (!_alive || emoji == null) return;
      final controller = widget.controller;
      final text = controller.text;
      final selection = controller.selection;
      final valid =
          selection.isValid &&
          selection.start <= text.length &&
          selection.end <= text.length;
      final start = valid ? selection.start : text.length;
      final end = valid ? selection.end : text.length;
      controller.value = TextEditingValue(
        text: text.replaceRange(start, end, emoji),
        selection: TextSelection.collapsed(offset: start + emoji.length),
      );
    } finally {
      _emojiSheetOpen = false;
      if (_alive) setState(() {});
    }
  }

  void _send() {
    if (!_alive || !_canSend) return;
    final controller = widget.controller;
    final text = controller.text;
    // stop() returns durable bytes, not a recorder-owned file. The send may
    // outlive this widget without retaining the microphone or preview player.
    final media = _media;
    final textVersion = _textVersion;
    final mediaVersion = _mediaVersion;
    final sendContext = widget.sendContext;
    final contextOwner = sendContext?.call();
    final onAcknowledged = widget.onAcknowledged;
    final onSend = widget.onSend;
    bool ownsContext() =>
        _alive &&
        identical(controller, widget.controller) &&
        contextOwner == sendContext?.call();
    // Acquire the lock before calling caller-provided code.
    setState(() {
      _sendOwned = true;
      _error = null;
    });
    unawaited(() async {
      try {
        await onSend(text, media);
        if (!ownsContext()) return;
        final textCleared = textVersion == _textVersion;
        if (textCleared) controller.clear();
        if (media != null && mediaVersion == _mediaVersion) _removeAttachment();
        onAcknowledged?.call(textCleared);
      } catch (error) {
        if (ownsContext()) {
          _showError(
            'Could not send. Your draft is kept; try again. ${_explain(error)}',
          );
        }
      } finally {
        _sendOwned = false;
        if (_alive) setState(() {});
      }
    }());
  }

  VoiceRecorder _voiceRecorder() {
    final recorder = _recorder ??= NativeVoiceRecorder();
    _playbackSubscription ??= recorder.playbackChanges.listen(
      (playing) {
        if (_alive) setState(() => _playing = playing);
      },
      onError: (Object error, StackTrace stack) {
        if (_alive) {
          setState(() => _playing = false);
          _showError('Could not play voice preview: ${_explain(error)}');
        }
      },
    );
    return recorder;
  }

  bool _ownsVoice(int epoch) => _alive && !_background && epoch == _voiceEpoch;

  void _enqueueVoice(Future<void> Function() action) {
    final work = _voiceWork.then((_) => action());
    // Keep a joined, error-handled tail for dispose and subsequent cleanup.
    _voiceWork = work.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        debugPrint('Voice cleanup failed: $error');
      },
    );
  }

  void _startRecording() {
    if (!_alive ||
        !_voiceIdle ||
        _sending ||
        _pickOwned ||
        _media != null ||
        _background) {
      return;
    }
    final epoch = ++_voiceEpoch;
    _pickEpoch++;
    setState(() {
      _voiceMode = _VoiceMode.requesting;
      _error = null;
    });
    final recorder = _voiceRecorder();
    _enqueueVoice(() async {
      try {
        if (!_ownsVoice(epoch)) return;
        final allowed = await recorder.requestPermission();
        if (!_ownsVoice(epoch)) return;
        if (!allowed) {
          _showError(
            'Microphone permission is needed to record a voice message. Enable it in app settings.',
          );
          return;
        }
        await recorder.start();
        if (!_ownsVoice(epoch)) return;
        _recordingSeconds = 0;
        setState(() => _voiceMode = _VoiceMode.recording);
        _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (_ownsVoice(epoch)) setState(() => _recordingSeconds = timer.tick);
        });
      } catch (error) {
        // A partial acquisition must finish cancelling before cleanup/retry.
        try {
          await recorder.discard();
        } catch (_) {
          /* dispose retries cleanup */
        }
        if (_ownsVoice(epoch)) {
          _showError('Could not record voice: ${_explain(error)}');
        }
      } finally {
        if (_ownsVoice(epoch) && _voiceMode == _VoiceMode.requesting) {
          setState(() => _voiceMode = _VoiceMode.idle);
        }
      }
    });
  }

  void _stopRecording() {
    if (!_alive || _voiceMode != _VoiceMode.recording) return;
    final epoch = _voiceEpoch;
    _durationTimer?.cancel();
    setState(() => _voiceMode = _VoiceMode.stopping);
    final recorder = _voiceRecorder();
    _enqueueVoice(() async {
      try {
        if (!_ownsVoice(epoch)) return;
        final media = await recorder.stop();
        if (!_ownsVoice(epoch)) return;
        final error = _validate(media);
        if (error != null) throw FormatException(error);
        setState(() => _assignMedia(media, voice: true));
      } catch (error) {
        try {
          await recorder.discard();
        } catch (_) {
          /* dispose retries cleanup */
        }
        if (_ownsVoice(epoch)) {
          _showError('Could not finish voice recording: ${_explain(error)}');
        }
      } finally {
        if (_ownsVoice(epoch)) setState(() => _voiceMode = _VoiceMode.idle);
      }
    });
  }

  void _discardVoice({String? reason}) {
    if (_discardOwned) {
      if (reason != null) _showError(reason);
      return;
    }
    final epoch =
        ++_voiceEpoch; // Revoke publication before awaiting start/stop.
    _durationTimer?.cancel();
    if (_alive) {
      setState(() {
        if (_voiceMedia) _assignMedia(null);
        _playing = false;
        _voiceMode = _recorder == null ? _VoiceMode.idle : _VoiceMode.stopping;
        if (reason != null) _error = reason;
      });
    }
    final recorder = _recorder;
    if (recorder == null) return;
    _discardOwned = true;
    _enqueueVoice(() async {
      try {
        await recorder.discard();
      } catch (error) {
        if (_alive && epoch == _voiceEpoch) {
          _showError('Could not discard voice recording: ${_explain(error)}');
        }
      } finally {
        _discardOwned = false;
        if (_alive && epoch == _voiceEpoch) {
          setState(() => _voiceMode = _VoiceMode.idle);
        }
      }
    });
  }

  void _removeAttachment() {
    if (!_alive) return;
    if (_voiceMedia) {
      _discardVoice();
      return;
    }
    setState(() => _assignMedia(null));
  }

  void _togglePreview() {
    if (!_alive ||
        !_voiceMedia ||
        _media == null ||
        _previewOwned ||
        !_voiceIdle) {
      return;
    }
    final media = _media!;
    final version = _mediaVersion;
    final stop = _playing;
    setState(() => _previewOwned = true);
    final recorder = _voiceRecorder();
    _enqueueVoice(() async {
      try {
        if (!_alive || _background || version != _mediaVersion) return;
        if (stop) {
          await recorder.stopPreview();
        } else {
          await recorder.playPreview(media);
        }
      } catch (error) {
        if (_alive && version == _mediaVersion) {
          _showError('Could not play voice preview: ${_explain(error)}');
        }
      } finally {
        _previewOwned = false;
        if (_alive) setState(() {});
      }
    });
  }

  void _cancel() {
    _pickEpoch++;
    if (!_voiceIdle) {
      _discardVoice();
    }
    // Cancelling reply/edit context is not permission to discard staged media.
    // Staged attachments have a separate, explicit Remove attachment control.
    widget.onCancel?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_alive) return;
    // Permission dialogs can cause inactive; only actual backgrounding aborts.
    if (state == AppLifecycleState.resumed) {
      setState(() => _background = false);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_background) return;
      _background = true;
      if (!_voiceIdle || _voiceMedia) {
        _discardVoice(
          reason:
              'Voice recording discarded when the app moved to the background.',
        );
      } else {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _pickEpoch++;
    _voiceEpoch++;
    _durationTimer?.cancel();
    widget.controller.removeListener(_draftChanged);
    WidgetsBinding.instance.removeObserver(this);
    final voice = _voiceWork;
    final recorder = _recorder;
    final subscription = _playbackSubscription;
    // State.dispose cannot suspend. This joined owner outlives the widget until
    // accepted voice work completes, then releases native handles and files.
    // Network sends own only durable bytes and must never delay voice cleanup.
    unawaited(() async {
      try {
        await voice;
        try {
          await recorder?.dispose();
        } finally {
          await subscription?.cancel();
        }
      } catch (error) {
        debugPrint('Voice recorder disposal failed: $error');
      }
    }());
    super.dispose();
  }

  String _durationLabel(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _attachmentPreview(MediaSelection media) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          if (media.mimeType.startsWith('image/'))
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                media.bytes,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                cacheWidth: 168,
                errorBuilder: (_, _, _) => const SizedBox(
                  width: 56,
                  height: 56,
                  child: Icon(Icons.image_outlined),
                ),
              ),
            )
          else
            Icon(
              _voiceMedia
                  ? Icons.mic_rounded
                  : Icons.insert_drive_file_outlined,
              size: 32,
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(media.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(
                  _voiceMedia
                      ? 'Voice message · ${_durationLabel(media.durationMs ?? 0)}'
                      : '${(media.bytes.length / 1024).toStringAsFixed(1)} KB · ${media.mimeType}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (_voiceMedia)
            IconButton(
              tooltip: _playing ? 'Stop voice preview' : 'Play voice preview',
              onPressed: _previewOwned || !_voiceIdle ? null : _togglePreview,
              icon: Icon(
                _playing
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
              ),
            ),
          IconButton(
            tooltip: 'Replace attachment',
            onPressed: _pickOwned || !_voiceIdle ? null : _showSources,
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
          IconButton(
            tooltip: 'Remove attachment',
            onPressed: _removeAttachment,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final voiceActive = !_voiceIdle;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.only(left: 12),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(color: colors.onErrorContainer),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Dismiss error',
                      onPressed: () => setState(() => _error = null),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          if (_media != null) _attachmentPreview(_media!),
          if (voiceActive)
            Row(
              children: [
                const Icon(Icons.mic, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(switch (_voiceMode) {
                    _VoiceMode.requesting => 'Preparing microphone…',
                    _VoiceMode.recording =>
                      'Recording ${_durationLabel(_recordingSeconds * 1000)}',
                    _VoiceMode.stopping => 'Finishing voice recording…',
                    _VoiceMode.idle => '',
                  }),
                ),
                if (_voiceMode == _VoiceMode.recording)
                  IconButton(
                    tooltip: 'Stop recording',
                    onPressed: _stopRecording,
                    icon: const Icon(Icons.stop_circle),
                  ),
                IconButton(
                  tooltip: 'Discard recording',
                  onPressed: _discardVoice,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Attach media',
                onPressed:
                    _pickOwned || _sourceSheetOpen || voiceActive || _background
                    ? null
                    : _showSources,
                icon: _pickOwned
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_circle_outline),
              ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  contentInsertionConfiguration: ContentInsertionConfiguration(
                    allowedMimeTypes: const ['image/*'],
                    onContentInserted: _insertContent,
                  ),
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: _media == null
                        ? 'Write a message…'
                        : 'Add a caption…',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Emoji',
                onPressed: _emojiSheetOpen || _background ? null : _showEmoji,
                icon: const Icon(Icons.emoji_emotions_outlined),
              ),
              if (_media == null && !voiceActive)
                IconButton(
                  tooltip: 'Record voice message',
                  onPressed: _sending || _pickOwned || _background
                      ? null
                      : _startRecording,
                  icon: const Icon(Icons.mic_none_rounded),
                ),
              if (widget.onCancel != null)
                IconButton(
                  tooltip: 'Cancel',
                  onPressed: _cancel,
                  icon: const Icon(Icons.close),
                ),
              IconButton.filled(
                tooltip: 'Send message',
                onPressed: _canSend ? _send : null,
                icon: _sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

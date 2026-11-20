import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:image_picker/image_picker.dart';

import 'features/composer/formatting_toolbar.dart';
import 'features/composer/markdown_format.dart';
import 'features/composer/markdown_styling.dart';
import 'features/composer/slash_commands.dart';
import 'features/message_fonts/message_font_picker.dart';
import 'features/message_fonts/message_fonts.dart';
import 'features/reactions/reaction_hooks.dart';
import 'features/rich_timeline/mention_suggestions.dart';
import 'appearance_preferences.dart';
import 'feature_settings_scope.dart';
import 'hooks/registry.dart';
import 'messaging_features.dart';
import 'voice_recorder.dart';
import 'haptics.dart';
import 'features/media/video_prep.dart';
import 'features/media/image_editor_screen.dart';

typedef MediaPicker = Future<MediaSelection?> Function();

enum _MediaSource { gallery, camera, video, file, any }

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
    this.pickVideo,
    this.pickFile,
    this.recorder,
    this.extraAttachments = const [],
    this.mentionSource,
    this.hookContext,
    this.replyToId,
    this.editing = false,
    this.contextLabel,
    this.sendOptions,
    this.suggestionSources,
    this.focusRequest = 0,
  });

  static const maxMediaBytes = maxComposerMediaBytes;

  /// Pasted images stack up to this many before sending, like a photo pick.
  static const maxStagedImages = 10;
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

  /// Records a video with the camera (default: system camera app).
  final MediaPicker? pickVideo;
  final MediaPicker? pickFile;
  final VoiceRecorder? recorder;

  /// Feature-provided attachment options (poll, location …) shown after the
  /// built-in media sources.
  final List<ComposerAttachmentAction> extraAttachments;

  /// Room members offered after typing `@`. When null, the room shown by the
  /// timeline on the same route is used (see `bindTimelineRoute`).
  final MentionSource? mentionSource;

  /// The room this composer belongs to, for feature hooks: long-press send
  /// options ([composerSendOptionsFor]), extra autocomplete sources
  /// ([composerSuggestionSourcesFor]) and toolbar features. Null in contexts
  /// without a room hook (tests, threads that opt out).
  final RoomHookContext? hookContext;

  /// Reply target for send options that consume the draft (Send later).
  final String? replyToId;

  /// Whether the draft is an edit of an existing message.
  final bool editing;

  /// Reply or edit label attached directly to the top of the compose bubble.
  final String? contextLabel;

  /// Long-press send options. When null, [composerSendOptionsFor] supplies
  /// them for [hookContext].
  final List<ComposerSendOption>? sendOptions;

  /// Extra autocomplete sources (`:` custom emoji …). When null,
  /// [composerSuggestionSourcesFor] supplies them for [hookContext]. The
  /// built-in `/` command source is always offered at the start of a new
  /// message.
  final List<ComposerSuggestionSource>? suggestionSources;

  /// Bumped when a reply starts. The caret moves into this field after the
  /// current frame, so a closing message menu cannot steal it back.
  final int focusRequest;

  @override
  State<RichMessageComposer> createState() => _RichMessageComposerState();
}

class _RichMessageComposerState extends State<RichMessageComposer>
    with WidgetsBindingObserver {
  MediaSelection? _media;

  /// Further images pasted after [_media] (an image). Each is sent as its
  /// own message after [_media]; the typed text follows as a message.
  final List<MediaSelection> _moreMedia = [];
  bool _voiceMedia = false;
  String? _error;
  bool _closed = false;
  bool _background = false;
  bool _sendOwned = false;
  bool _pickOwned = false;

  /// A picked video is being read or compressed.
  bool _preparingVideo = false;
  bool _sourceSheetOpen = false;
  bool _emojiSheetOpen = false;
  bool _fontSheetOpen = false;
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
  ComposerTriggerQuery? _suggestionQuery;
  List<ComposerSuggestion> _suggestions = const [];

  /// `mention` or the suggestion source ID, for row keys.
  String _suggestionKind = '';

  /// Composer-owned styled mirror of the caller's controller: the TextField
  /// renders live markdown styling while the caller keeps plain text.
  late final ComposerTextController _input = ComposerTextController.fromValue(
    widget.controller.value,
  );
  final _focus = FocusNode(debugLabel: 'RichMessageComposer');
  bool _formatting = false;
  bool _linkDialogOpen = false;
  bool _sendOptionsOpen = false;
  FormattingState _formatState = const FormattingState();

  static const _maxSuggestions = 50;

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
    widget.controller.addListener(_syncFromCaller);
    widget.controller.addListener(_draftChanged);
    widget.controller.addListener(_updateSuggestions);
    _input.addListener(_syncToCaller);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(RichMessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_syncFromCaller);
      oldWidget.controller.removeListener(_draftChanged);
      oldWidget.controller.removeListener(_updateSuggestions);
      _lastText = widget.controller.text;
      _textVersion++;
      widget.controller.addListener(_syncFromCaller);
      widget.controller.addListener(_draftChanged);
      widget.controller.addListener(_updateSuggestions);
      _suggestionQuery = null;
      _suggestions = const [];
      _syncFromCaller();
    }
    if (oldWidget.editing != widget.editing) {
      // Commands do not apply to edits; build() follows didUpdateWidget.
      _suggestionQuery = null;
      _suggestions = const [];
    }
    if (widget.focusRequest != oldWidget.focusRequest) {
      _scheduleComposeFocus();
    }
  }

  /// One frame later, so a route that is still restoring focus (the message
  /// menu) cannot put the caret back on the timeline.
  void _scheduleComposeFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_alive) _focus.requestFocus();
    });
  }

  /// Caller edits (clear after send, draft restore, emoji) → the field.
  void _syncFromCaller() {
    final value = widget.controller.value;
    if (_input.value != value) _input.value = value;
  }

  /// Typing and toolbar edits → the caller's controller.
  void _syncToCaller() {
    if (_closed) return;
    final value = _input.value;
    final controller = widget.controller;
    if (controller.value != value) controller.value = value;
    if (_formatting && mounted) {
      final state = formattingStateFor(value);
      if (state != _formatState) setState(() => _formatState = state);
    }
  }

  List<ComposerSuggestionSource> _suggestionSources() {
    final ctx = widget.hookContext;
    List<ComposerSuggestionSource>? extra = widget.suggestionSources;
    if (extra == null && ctx != null) {
      try {
        extra = composerSuggestionSourcesFor(context, ctx);
      } catch (_) {
        extra = null;
      }
    }
    return [
      // Commands apply to new text messages only (not edits or captions).
      if (!widget.editing && _media == null) slashCommandSource,
      ...?extra,
    ];
  }

  /// Offers room members while an `@mention` is typed at the caret, and
  /// suggestions from other sources by trigger character (`/` commands at
  /// the start of the text, `:` custom emoji …). Inserted text stays plain;
  /// pills, `m.mentions` and commands are derived when the message is sent.
  void _updateSuggestions() {
    if (!_alive) return;
    final value = widget.controller.value;
    ComposerTriggerQuery? query;
    var suggestions = const <ComposerSuggestion>[];
    var kind = '';
    final mention = mentionQueryAt(value);
    if (mention != null) {
      query = ComposerTriggerQuery(
        '@',
        mention.start,
        mention.end,
        mention.query,
      );
      kind = 'mention';
      final source = widget.mentionSource ?? mentionSourceFor(context);
      if (source != null) {
        try {
          suggestions = [
            for (final member in source(mention.query).take(_maxSuggestions))
              ComposerSuggestion(
                id: member.id,
                label: member.label,
                subtitle: member.subtitle,
                insertText: member.insertText,
                leading: member.leading,
              ),
          ];
        } catch (_) {
          suggestions = const [];
        }
      }
    } else if (value.text.contains(RegExp(r'[^\w\s]'))) {
      for (final source in _suggestionSources()) {
        final found = triggerQueryAt(
          value,
          source.trigger,
          startOfTextOnly: source.id == slashCommandSourceId,
        );
        if (found == null || found.query.length < source.minQueryLength) {
          continue;
        }
        List<ComposerSuggestion> results;
        try {
          results = source.search(found.query);
        } catch (_) {
          results = const [];
        }
        if (results.isEmpty) continue;
        query = found;
        kind = source.id;
        suggestions = results.take(_maxSuggestions).toList();
        break;
      }
    }
    if (suggestions.isEmpty && _suggestions.isEmpty) {
      _suggestionQuery = query;
      _suggestionKind = kind;
      return;
    }
    setState(() {
      _suggestionQuery = query;
      _suggestionKind = kind;
      _suggestions = suggestions;
    });
  }

  void _pickSuggestion(ComposerSuggestion suggestion) {
    final query = _suggestionQuery;
    if (!_alive || query == null) return;
    final controller = widget.controller;
    // Re-check that the typed trigger and query are still where they were.
    final current = triggerQueryAt(
      controller.value,
      query.trigger,
      startOfTextOnly: _suggestionKind == slashCommandSourceId,
    );
    if (current == null || current.start != query.start) return;
    controller.value = applySuggestionText(
      controller.value,
      current,
      suggestion.insertText,
    );
    setState(() {
      _suggestionQuery = null;
      _suggestions = const [];
    });
    _focus.requestFocus();
  }

  Widget _suggestionList() => Card(
    margin: const EdgeInsets.only(bottom: 8),
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 216),
      child: ListView(
        key: const ValueKey('composer-suggestions'),
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          for (final suggestion in _suggestions)
            ListTile(
              key: ValueKey(
                _suggestionKind == 'mention'
                    ? 'mention-${suggestion.id}'
                    : 'suggestion-$_suggestionKind-${suggestion.id}',
              ),
              dense: true,
              leading: suggestion.leading,
              title: Text(
                suggestion.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: suggestion.subtitle == null
                  ? null
                  : Text(
                      suggestion.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              onTap: () => _pickSuggestion(suggestion),
            ),
        ],
      ),
    ),
  );

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
    _moreMedia.clear();
    _voiceMedia = voice;
    _error = null;
  }

  static bool _isImage(MediaSelection media) =>
      media.mimeType.toLowerCase().startsWith('image/');

  /// Every staged attachment, in send order.
  List<MediaSelection> get _staged => [?_media, ..._moreMedia];

  /// Stages [selection]. With [add], an image joins the images already
  /// staged instead of replacing them (pasting several images in a row).
  void _stage(MediaSelection selection, {bool add = false}) {
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
    final current = _media;
    if (add &&
        current != null &&
        !_voiceMedia &&
        _isImage(current) &&
        _isImage(selection)) {
      if (_staged.length >= RichMessageComposer.maxStagedImages) {
        _showError(
          'You can attach up to ${RichMessageComposer.maxStagedImages} '
          'images at a time.',
        );
        return;
      }
      setState(() {
        _mediaVersion++;
        _moreMedia.add(selection);
        _error = null;
      });
      return;
    }
    setState(() => _assignMedia(selection));
  }

  /// Removes one of several staged images.
  void _removeStaged(MediaSelection media) {
    if (!_alive) return;
    setState(() {
      _mediaVersion++;
      if (identical(_media, media)) {
        _media = _moreMedia.isEmpty ? null : _moreMedia.removeAt(0);
      } else {
        _moreMedia.removeWhere((m) => identical(m, media));
      }
      _error = null;
    });
  }

  Future<MediaSelection?> _pickImage(ImageSource source) async {
    if (_desktopKeyboard) {
      // Desktop has no camera capture: pick an image file instead.
      final file = await FilePicker.pickFile(
        dialogTitle: 'Attach a photo',
        type: FileType.image,
      );
      if (file == null) return null;
      return _fromFile(file.xFile);
    }
    final image = await ImagePicker().pickImage(source: source);
    if (image == null) return null;
    return _fromFile(image);
  }

  /// Gallery: photos and videos.
  Future<MediaSelection?> _pickGalleryMedia() async {
    if (_desktopKeyboard) {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Attach a photo or video',
        type: FileType.media,
      );
      if (file == null) return null;
      return _fromFile(file.xFile);
    }
    final picked = await ImagePicker().pickMedia();
    if (picked == null) return null;
    return _fromFile(picked);
  }

  Future<MediaSelection?> _recordVideo() async {
    if (_desktopKeyboard) {
      // Desktop has no camera recording: pick an existing video file.
      final file = await FilePicker.pickFile(
        dialogTitle: 'Attach a video',
        type: FileType.video,
      );
      if (file == null) return null;
      return _fromFile(file.xFile);
    }
    final video = await ImagePicker().pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 4),
    );
    if (video == null) return null;
    return _fromFile(video);
  }

  Future<MediaSelection> _fromFile(XFile file) async {
    final mimeType = file.mimeType ?? _mimeFor(file.name);
    if (isVideoMime(mimeType)) {
      // Large or high-resolution videos are compressed to fit (native).
      if (_alive) setState(() => _preparingVideo = true);
      try {
        return await prepareVideoForSending(file, mimeType: mimeType);
      } finally {
        if (_alive) setState(() => _preparingVideo = false);
      }
    }
    return MediaSelection(
      bytes: await readComposerMedia(
        file.openRead(),
        length: await file.length(),
      ),
      name: file.name,
      mimeType: mimeType,
    );
  }

  Future<MediaSelection?> _pickFile() async {
    final file = await FilePicker.pickFile(dialogTitle: 'Attach a file');
    if (file == null) return null;
    // xFile handles Android SAF content and provider-backed cached files.
    final length = await file.length();
    final video = isVideoMime(_mimeFor(file.name));
    // Videos are compressed to fit; other files must already fit.
    if (!video &&
        length != null &&
        length > RichMessageComposer.maxMediaBytes) {
      throw const FormatException('Attachments must be 20 MB or smaller.');
    }
    return _fromFile(file.xFile);
  }

  /// Windows' single attachment option: photos, videos and files through one
  /// picker, with the same size/compression rules as the separate options.
  Future<MediaSelection?> _pickAnyMedia() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Attach a photo, video or file',
    );
    if (file == null) return null;
    final length = await file.length();
    final video = isVideoMime(_mimeFor(file.name));
    if (!video &&
        length != null &&
        length > RichMessageComposer.maxMediaBytes) {
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
    // Windows: one attachment button for everything — straight to a single
    // unified picker (no camera on desktop, so no separate photo/video rows).
    if (_desktopKeyboard && widget.extraAttachments.isEmpty) {
      _pick(_MediaSource.any);
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
                subtitle: Text(
                  'One attachment · up to 20 MB · longer videos are '
                  'compressed to fit',
                ),
              ),
              for (final item in [
                if (_desktopKeyboard)
                  (
                    _MediaSource.any,
                    Icons.attach_file_rounded,
                    'Photo, video or file',
                  )
                else ...[
                  (
                    _MediaSource.gallery,
                    Icons.photo_library_outlined,
                    'Photo or video',
                  ),
                  (
                    _MediaSource.camera,
                    Icons.photo_camera_outlined,
                    'Take photo',
                  ),
                  (_MediaSource.video, Icons.videocam_outlined, 'Record video'),
                  (_MediaSource.file, Icons.insert_drive_file_outlined, 'File'),
                ],
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
      _MediaSource.gallery => widget.pickGallery ?? _pickGalleryMedia,
      _MediaSource.camera =>
        widget.pickCamera ?? () => _pickImage(ImageSource.camera),
      _MediaSource.video => widget.pickVideo ?? _recordVideo,
      _MediaSource.file => widget.pickFile ?? _pickFile,
      _MediaSource.any => widget.pickFile ?? _pickAnyMedia,
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

  /// Desktop keyboard handling: Enter sends (Shift+Enter is a newline,
  /// Enter accepts the top mention/command suggestion while one is shown),
  /// Ctrl+V (Cmd+V on macOS) pastes a clipboard image as an attachment or
  /// falls back to text. Phones keep the IME behaviour untouched.
  /// Desktop platforms, overridable in widget tests (dart:io Platform is not).
  bool get _desktopKeyboard =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  KeyEventResult _onComposeKey(FocusNode node, KeyEvent event) {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.windows &&
            defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.linux)) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored;
      }
      if (_suggestions.isNotEmpty) {
        _pickSuggestion(_suggestions.first);
        return KeyEventResult.handled;
      }
      _send();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            (defaultTargetPlatform == TargetPlatform.macOS &&
                HardwareKeyboard.instance.isMetaPressed))) {
      unawaited(_pasteClipboard());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Pastes the clipboard: an image becomes an attachment (Windows reads the
  /// native clipboard through the runner), anything else inserts plain text.
  Future<void> _pasteClipboard() async {
    if (!_alive || _background || !_voiceIdle) return;
    if (_desktopKeyboard) {
      try {
        final bytes = await const MethodChannel(
          'parallax/clipboard',
        ).invokeMethod<Uint8List>('readImage');
        if (!_alive) return;
        if (bytes != null && bytes.isNotEmpty) {
          _stage(
            MediaSelection(
              bytes: bytes,
              name: 'pasted-image.png',
              mimeType: 'image/png',
            ),
            add: true,
          );
          return;
        }
      } on MissingPluginException {
        // Fall through to text paste.
      } catch (_) {
        // Fall through to text paste.
      }
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!_alive || text == null || text.isEmpty) return;
    final value = _input.value;
    final start = value.selection.start < 0
        ? value.text.length
        : value.selection.start;
    final end = value.selection.end < 0
        ? value.text.length
        : value.selection.end;
    _input.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
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
      add: true,
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

  /// The app's preferences, which keep the message font. Without them (a
  /// bare composer) there is nowhere to keep a font, so none is offered.
  AppearancePreferences? get _preferences =>
      FeatureSettingsScope.maybeOf(context)?.preferences;

  /// Picks the font text messages are sent in. The choice is saved in the
  /// app's preferences, where the room reads it when a message is sent, so
  /// it sticks until another font is picked.
  Future<void> _showFontPicker() async {
    final preferences = _preferences;
    if (preferences == null || _fontSheetOpen || !_alive || _background) {
      return;
    }
    setState(() => _fontSheetOpen = true);
    try {
      final choice = await showMessageFontPicker(
        context,
        current: preferences.messageFont,
      );
      if (choice == null || !_alive) return;
      Haptics.selection();
      try {
        await preferences.setMessageFont(choice.id);
      } catch (_) {
        if (_alive) _showError('Couldn’t save the message font.');
      }
    } finally {
      _fontSheetOpen = false;
      if (_alive) setState(() {});
    }
  }

  /// A reason the draft cannot be sent as typed (unknown `/command` …).
  String? _draftError(String text, MediaSelection? media) =>
      media != null || widget.editing ? null : slashCommandError(text);

  void _send() {
    if (!_alive || !_canSend) return;
    final text = widget.controller.text;
    // stop() returns durable bytes, not a recorder-owned file. The send may
    // outlive this widget without retaining the microphone or preview player.
    final media = _media;
    if (media != null && _moreMedia.isNotEmpty) {
      _sendStaged(text);
      return;
    }
    final problem = _draftError(text, media);
    if (problem != null) {
      _showError(problem);
      return;
    }
    Haptics.confirm();
    final onSend = widget.onSend;
    _consumeDraft(() async {
      await onSend(text, media);
      return true;
    }, media: media);
  }

  /// Several staged images: each goes as its own message, in order, then
  /// the typed text as a message of its own (a caption on one photo of a
  /// gallery would be hidden by the grid). Images already accepted leave
  /// the composer, so a failure part-way keeps only what didn't go.
  void _sendStaged(String text) {
    final hasText = text.trim().isNotEmpty;
    final problem = hasText ? _draftError(text, null) : null;
    if (problem != null) {
      _showError(problem);
      return;
    }
    Haptics.confirm();
    final onSend = widget.onSend;
    final batch = _staged;
    _consumeDraft(() async {
      for (final item in batch) {
        if (!_alive) return false;
        // Removed from the strip while earlier images were sending.
        if (!_staged.any((m) => identical(m, item))) continue;
        await onSend('', item);
        if (_alive) _removeStaged(item);
      }
      if (hasText) await onSend(text, null);
      return true;
    });
  }

  /// Runs [action] under the send lock. When it reports the draft consumed
  /// and this composer still owns the send context, clears the sent text
  /// revision (and [media]) and acknowledges, exactly as for a normal send.
  void _consumeDraft(Future<bool> Function() action, {MediaSelection? media}) {
    final controller = widget.controller;
    final textVersion = _textVersion;
    final mediaVersion = _mediaVersion;
    final sendContext = widget.sendContext;
    final contextOwner = sendContext?.call();
    final onAcknowledged = widget.onAcknowledged;
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
        final consumed = await action();
        if (!consumed || !ownsContext()) return;
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

  List<ComposerSendOption> _sendOptionsFor(BuildContext context) {
    final explicit = widget.sendOptions;
    if (explicit != null) return explicit;
    final ctx = widget.hookContext;
    if (ctx == null) return const [];
    try {
      return composerSendOptionsFor(context, ctx);
    } catch (_) {
      return const [];
    }
  }

  /// Long-press on send: feature send options (for example "Send later").
  /// A chosen option that consumes the draft clears it like a normal send.
  Future<void> _showSendOptions() async {
    if (!_alive || !_canSend || _media != null || _sendOptionsOpen) return;
    final options = _sendOptionsFor(context);
    if (options.isEmpty) return;
    final problem = _draftError(widget.controller.text, null);
    if (problem != null) {
      _showError(problem);
      return;
    }
    Haptics.longPress();
    setState(() => _sendOptionsOpen = true);
    ComposerSendOption? chosen;
    try {
      chosen = await showModalBottomSheet<ComposerSendOption>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Send options')),
              for (final option in options)
                ListTile(
                  key: ValueKey('send-option-${option.id}'),
                  leading: Icon(option.icon),
                  title: Text(option.label),
                  onTap: () => Navigator.pop(sheetContext, option),
                ),
            ],
          ),
        ),
      );
    } finally {
      _sendOptionsOpen = false;
      if (_alive) setState(() {});
    }
    final option = chosen;
    if (option == null || !_alive || !_canSend || _media != null) return;
    final draft = ComposerDraft(
      text: widget.controller.text,
      replyToId: widget.replyToId,
      editing: widget.editing,
    );
    if (draft.text.trim().isEmpty || !mounted) return;
    _consumeDraft(() => option.onSelected(context, draft));
  }

  void _toggleFormatting() {
    if (!_alive) return;
    setState(() {
      _formatting = !_formatting;
      if (_formatting) _formatState = formattingStateFor(_input.value);
    });
    _focus.requestFocus();
  }

  void _format(FormatAction action) {
    if (!_alive) return;
    if (action == FormatAction.link) {
      unawaited(_editLink());
      return;
    }
    final next = applyFormat(_input.value, action);
    if (next != _input.value) _input.value = next;
    _focus.requestFocus();
  }

  Future<void> _editLink() async {
    if (!_alive || _linkDialogOpen) return;
    _linkDialogOpen = true;
    final before = _input.value;
    try {
      final result = await showComposerLinkDialog(
        context,
        linkTargetAt(before),
      );
      // Apply only to the draft the dialog was opened for (not one replaced
      // by a send or draft restore meanwhile).
      if (!_alive || result == null || _input.text != before.text) return;
      final base = _input.value.copyWith(
        selection: before.selection,
        composing: TextRange.empty,
      );
      _input.value = result.remove
          ? removeLink(base)
          : applyLink(base, text: result.text, url: result.url!);
    } finally {
      _linkDialogOpen = false;
      if (_alive) _focus.requestFocus();
    }
  }

  Widget _sendButton(BuildContext context) {
    final button = IconButton.filled(
      tooltip: 'Send message',
      onPressed: _canSend ? _send : null,
      icon: _sending
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.arrow_upward_rounded),
    );
    if (_media != null || _sendOptionsFor(context).isEmpty) return button;
    // The tooltip would otherwise claim the long press.
    return GestureDetector(
      key: const ValueKey('composer-send-long-press'),
      onLongPress: _canSend ? _showSendOptions : null,
      child: TooltipTheme(
        data: TooltipTheme.of(
          context,
        ).copyWith(triggerMode: TooltipTriggerMode.manual),
        child: button,
      ),
    );
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
        Haptics.confirm();
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
    Haptics.confirm();
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

  Future<void> _editAttachment() async {
    final media = _media;
    if (!_alive || media == null || !media.mimeType.startsWith('image/')) {
      return;
    }
    final edited = await showImageEditor(context, media);
    if (!_alive || edited == null || !identical(_media, media)) return;
    final error = _validate(edited);
    if (error != null) {
      _showError(error);
      return;
    }
    setState(() => _assignMedia(edited));
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
    widget.controller.removeListener(_syncFromCaller);
    widget.controller.removeListener(_draftChanged);
    widget.controller.removeListener(_updateSuggestions);
    _input
      ..removeListener(_syncToCaller)
      ..dispose();
    _focus.dispose();
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

  /// Several pasted images: a strip of thumbnails, each removable.
  Widget _stagedImagesPreview() {
    final staged = _staged;
    return Card(
      key: const ValueKey('composer-staged-images'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 64,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: staged.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final media = staged[index];
                    return Stack(
                      key: ValueKey('composer-staged-image-$index'),
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            media.bytes,
                            width: 64,
                            height: 64,
                            fit: BoxFit.cover,
                            cacheWidth: 192,
                            errorBuilder: (_, _, _) => const SizedBox(
                              width: 64,
                              height: 64,
                              child: Icon(Icons.image_outlined),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Material(
                            color: Colors.black54,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => _removeStaged(media),
                              child: Tooltip(
                                message: 'Remove image ${index + 1}',
                                child: const Padding(
                                  padding: EdgeInsets.all(3),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${staged.length} images',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            IconButton(
              tooltip: 'Remove all images',
              onPressed: _removeAttachment,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
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
          if (media.mimeType.startsWith('image/'))
            IconButton(
              tooltip: 'Edit image',
              onPressed: _editAttachment,
              icon: const Icon(Icons.edit_outlined),
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
    // Captions and voice clips are plain text: no markdown tools for them.
    final formattingAvailable = _media == null && !voiceActive;
    final formatting = _formatting && formattingAvailable;
    _input.styling = _media == null;
    final preferences = _preferences;
    // Fonts apply to text messages: not to captions or voice clips.
    final fontAvailable = preferences != null && _media == null && !voiceActive;
    final font = fontAvailable
        ? messageFontById(preferences.messageFont)
        : null;
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
          if (_preparingVideo)
            const Padding(
              key: ValueKey('composer-preparing-video'),
              padding: EdgeInsets.only(left: 12, bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Preparing video…'),
                ],
              ),
            ),
          if (_media != null && _moreMedia.isNotEmpty)
            _stagedImagesPreview()
          else if (_media != null)
            _attachmentPreview(_media!),
          if (_suggestions.isNotEmpty && _suggestionQuery != null)
            _suggestionList(),
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
          // The message box gets its own full-width row with Send beside it,
          // so the composer buttons below can never squeeze it.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Focus(
                  onKeyEvent: _onComposeKey,
                  child: _composeField(
                    context,
                    colors: colors,
                    formatting: formatting,
                    font: font,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _sendButton(context),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                if (formatting)
                  // Element X replaces "add attachment" while formatting.
                  IconButton(
                    key: const ValueKey('composer-close-formatting'),
                    tooltip: 'Close text formatting',
                    visualDensity: VisualDensity.compact,
                    onPressed: _toggleFormatting,
                    icon: const Icon(Icons.close_rounded),
                  )
                else ...[
                  IconButton(
                    tooltip: 'Attach media',
                    visualDensity: VisualDensity.compact,
                    onPressed:
                        _pickOwned ||
                            _sourceSheetOpen ||
                            voiceActive ||
                            _background
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
                  if (formattingAvailable)
                    IconButton(
                      key: const ValueKey('composer-text-formatting'),
                      tooltip: 'Text formatting',
                      visualDensity: VisualDensity.compact,
                      onPressed: _background ? null : _toggleFormatting,
                      icon: const Icon(Icons.text_format_rounded),
                    ),
                ],
                IconButton(
                  tooltip: 'Emoji',
                  visualDensity: VisualDensity.compact,
                  onPressed: _emojiSheetOpen || _background ? null : _showEmoji,
                  icon: const Icon(Icons.emoji_emotions_outlined),
                ),
                if (fontAvailable)
                  IconButton(
                    key: const ValueKey('composer-message-font'),
                    tooltip: 'Message font',
                    visualDensity: VisualDensity.compact,
                    isSelected: font != null,
                    onPressed: _fontSheetOpen || _background
                        ? null
                        : _showFontPicker,
                    icon: const Icon(Icons.font_download_outlined),
                    selectedIcon: Icon(
                      Icons.font_download_rounded,
                      color: colors.primary,
                    ),
                  ),
                if (_media == null && !voiceActive)
                  IconButton(
                    tooltip: 'Record voice message',
                    visualDensity: VisualDensity.compact,
                    onPressed: _sending || _pickOwned || _background
                        ? null
                        : _startRecording,
                    icon: const Icon(Icons.mic_none_rounded),
                  ),
                const Spacer(),
                if (widget.onCancel != null && widget.contextLabel == null)
                  IconButton(
                    tooltip: 'Cancel',
                    visualDensity: VisualDensity.compact,
                    onPressed: _cancel,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
          if (formatting)
            TextFieldTapRegion(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: FormattingToolbar(
                  state: _formatState,
                  onAction: _format,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _composeField(
    BuildContext context, {
    required ColorScheme colors,
    required bool formatting,
    MessageFont? font,
  }) {
    final contextLabel = widget.contextLabel;
    final hasContext = contextLabel != null;
    const attachedBottom = BorderRadius.vertical(bottom: Radius.circular(18));
    final field = TextField(
      controller: _input,
      focusNode: _focus,
      minLines: 1,
      maxLines: formatting ? 8 : 5,
      textCapitalization: TextCapitalization.sentences,
      keyboardType: TextInputType.multiline,
      // The chosen message font, live, so the draft looks as it will be seen.
      style: font == null ? null : TextStyle(fontFamily: font.family),
      inputFormatters: formatting ? const [_ListContinuationFormatter()] : null,
      contentInsertionConfiguration: ContentInsertionConfiguration(
        allowedMimeTypes: const ['image/*'],
        onContentInserted: _insertContent,
      ),
      onSubmitted: (_) => _send(),
      decoration: InputDecoration(
        hintText: _media == null
            ? 'Write a message…'
            : _moreMedia.isEmpty
            ? 'Add a caption…'
            : 'Add a message…',
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: hasContext
            ? OutlineInputBorder(
                borderRadius: attachedBottom,
                borderSide: BorderSide(color: colors.outline),
              )
            : null,
        enabledBorder: hasContext
            ? OutlineInputBorder(
                borderRadius: attachedBottom,
                borderSide: BorderSide(color: colors.outline),
              )
            : null,
        focusedBorder: hasContext
            ? OutlineInputBorder(
                borderRadius: attachedBottom,
                borderSide: BorderSide(color: colors.primary, width: 2),
              )
            : null,
      ),
    );
    if (!hasContext) return field;
    final fill =
        Theme.of(context).inputDecorationTheme.fillColor ?? colors.surface;
    return Column(
      key: const ValueKey('composer-context-bubble'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: _focus,
          builder: (context, child) {
            final focused = _focus.hasFocus;
            final side = BorderSide(
              color: focused ? colors.primary : colors.outline,
              width: focused ? 2 : 1,
            );
            return Container(
              key: const ValueKey('composer-context-bar'),
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(18),
                ),
                border: Border(top: side, left: side, right: side),
              ),
              child: child,
            );
          },
          child: Row(
            children: [
              Icon(
                widget.editing ? Icons.edit_outlined : Icons.reply_rounded,
                size: 18,
                color: colors.secondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  contextLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.onSurface, fontSize: 13),
                ),
              ),
              if (widget.onCancel != null)
                IconButton(
                  tooltip: 'Cancel reply or edit',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: _cancel,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
            ],
          ),
        ),
        field,
      ],
    );
  }
}

/// Continues markdown lists and quotes on Enter while the formatting
/// toolbar is shown (an empty item ends the list), like Element X's editor.
class _ListContinuationFormatter extends TextInputFormatter {
  const _ListContinuationFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => continueListOnNewline(oldValue, newValue) ?? newValue;
}

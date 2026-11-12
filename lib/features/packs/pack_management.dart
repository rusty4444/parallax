import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import '../rooms_admin/admin_ui.dart';
import 'pack_features.dart';
import 'pack_image.dart';
import 'pack_model.dart';
import 'pack_upload.dart';

/// Picks one image for a pack (injected in tests).
typedef PackImagePicker = Future<XFile?> Function();

Future<XFile?> _pickFromGallery() =>
    ImagePicker().pickImage(source: ImageSource.gallery);

String _usageLabel(Set<PackUsage> usage) => switch ((
  usage.contains(PackUsage.emoticon),
  usage.contains(PackUsage.sticker),
)) {
  (true, true) => 'Emoji and sticker',
  (true, false) => 'Emoji',
  (false, true) => 'Sticker',
  (false, false) => 'Not shown',
};

String _explainWrite(Object error) {
  if (error is FormatException) return error.message;
  if (error is ArgumentError && error.message == 'Already used') {
    return 'That shortcode is already used in this pack.';
  }
  return 'Couldn’t save the pack. Check your connection and permissions, '
      'then try again.';
}

void _snack(ScaffoldMessengerState? messenger, String message) => messenger
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message)));

/// Rebuilds when [features] report pack changes.
mixin _PackListener<T extends StatefulWidget> on State<T> {
  PacksFeatures get packFeatures;

  @override
  void initState() {
    super.initState();
    packFeatures.packUpdates.addListener(_packsChanged);
  }

  @override
  void dispose() {
    packFeatures.packUpdates.removeListener(_packsChanged);
    super.dispose();
  }

  void _packsChanged() {
    if (mounted) setState(() {});
  }
}

Widget _packAvatar(PacksFeatures features, ImagePack pack, AppPalette p) {
  final url = pack.avatarUrl ?? pack.images.values.firstOrNull?.url;
  return Container(
    width: 44,
    height: 44,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: p.raised,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: p.stroke),
    ),
    child: url == null
        ? Icon(Icons.collections_outlined, color: p.secondary)
        : PackImageView(features: features, url: url, size: 30),
  );
}

String _countLabel(ImagePack pack) {
  final n = pack.images.length;
  return n == 1 ? '1 image' : '$n images';
}

/// Room details › Emoji & stickers: the room's MSC2545 packs.
class RoomPacksScreen extends StatefulWidget {
  const RoomPacksScreen({
    super.key,
    required this.features,
    required this.roomId,
    required this.palette,
    this.pickImage,
  });
  final PacksFeatures features;
  final String roomId;
  final AppPalette palette;
  final PackImagePicker? pickImage;

  @override
  State<RoomPacksScreen> createState() => _RoomPacksScreenState();
}

class _RoomPacksScreenState extends State<RoomPacksScreen> with _PackListener {
  bool _busy = false;

  @override
  PacksFeatures get packFeatures => widget.features;

  @override
  void initState() {
    super.initState();
    widget.features.ensurePacksLoaded(widget.roomId);
  }

  Future<void> _open(PackRef ref) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PackEditorScreen(
        features: widget.features,
        packRef: ref,
        palette: widget.palette,
        pickImage: widget.pickImage,
      ),
    ),
  );

  Future<void> _create() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final name = await askPackName(context, title: 'Create pack');
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final ref = await widget.features.createRoomPack(widget.roomId, name);
      if (mounted) unawaited(_open(ref));
    } catch (error) {
      _snack(messenger, _explainWrite(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final packs = widget.features.roomPacks(widget.roomId);
    final canEdit = widget.features.canEditRoomPacks(widget.roomId);
    return AdminPage(
      palette: p,
      title: 'Emoji & stickers',
      busy: _busy,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          AdminSection(
            palette: p,
            title: 'Packs in this room',
            footer:
                'Everyone in this room can use these custom emoji and '
                'stickers. Pack images are uploaded unencrypted so every '
                'member’s app can show them.',
            children: [
              if (packs.isEmpty)
                AdminTile(
                  palette: p,
                  icon: Icons.collections_outlined,
                  title: 'No packs yet',
                  subtitle: canEdit
                      ? 'Create a pack to add custom emoji and stickers.'
                      : 'Only people allowed to change room settings can '
                            'add packs.',
                ),
              for (final state in packs)
                AdminTile(
                  key: ValueKey('room-pack-${state.ref.stateKey}'),
                  palette: p,
                  leading: _packAvatar(widget.features, state.pack, p),
                  title: state.name,
                  subtitle: [
                    _countLabel(state.pack),
                    if (widget.features.isEnabledEverywhere(state.ref))
                      'In all your rooms',
                  ].join(' · '),
                  trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
                  onTap: () => _open(state.ref),
                ),
            ],
          ),
          if (canEdit)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: AccentButton(
                palette: p,
                label: 'Create pack',
                icon: Icons.add_rounded,
                onPressed: _busy ? null : _create,
              ),
            ),
        ],
      ),
    );
  }
}

/// Settings › Emoji & stickers: the personal pack and room packs used in
/// every room.
class PackSettingsScreen extends StatefulWidget {
  const PackSettingsScreen({
    super.key,
    required this.features,
    required this.palette,
    this.pickImage,
  });
  final PacksFeatures features;
  final AppPalette palette;
  final PackImagePicker? pickImage;

  @override
  State<PackSettingsScreen> createState() => _PackSettingsScreenState();
}

class _PackSettingsScreenState extends State<PackSettingsScreen>
    with _PackListener {
  final _pending = <PackRef>{};

  @override
  PacksFeatures get packFeatures => widget.features;

  @override
  void initState() {
    super.initState();
    widget.features.ensurePacksLoaded(null);
  }

  Future<void> _disable(PackRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!_pending.add(ref)) return;
    setState(() {});
    try {
      await widget.features.setEnabledEverywhere(ref, enabled: false);
    } catch (error) {
      _snack(messenger, _explainWrite(error));
    } finally {
      _pending.remove(ref);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final personal = widget.features.personalPack();
    final global = widget.features.globalPacks();
    return AdminPage(
      palette: p,
      title: 'Emoji & stickers',
      busy: _pending.isNotEmpty,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          AdminSection(
            palette: p,
            title: 'Your pack',
            footer:
                'Your own custom emoji and stickers, available in every '
                'room. Saved to your account, so your other Matrix apps '
                'that support packs can use them too.',
            children: [
              AdminTile(
                key: const ValueKey('personal-pack-tile'),
                palette: p,
                leading: _packAvatar(widget.features, personal, p),
                title: personal.displayName ?? 'Your emoji',
                subtitle: _countLabel(personal),
                trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PackEditorScreen(
                      features: widget.features,
                      packRef: const PackRef.personal(),
                      palette: p,
                      pickImage: widget.pickImage,
                    ),
                  ),
                ),
              ),
            ],
          ),
          AdminSection(
            palette: p,
            title: 'Room packs in all rooms',
            footer:
                'Turn on “Use in all rooms” in a room’s pack to add it '
                'here.',
            children: [
              if (global.isEmpty)
                AdminTile(
                  palette: p,
                  icon: Icons.public_rounded,
                  title: 'None yet',
                  subtitle: 'Room packs you use everywhere appear here.',
                ),
              for (final state in global)
                SwitchListTile(
                  key: ValueKey('global-pack-${state.ref}'),
                  secondary: _packAvatar(widget.features, state.pack, p),
                  title: Text(
                    state.name,
                    style: TextStyle(
                      color: p.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${_countLabel(state.pack)} · ${state.roomName}',
                    style: TextStyle(color: p.muted),
                  ),
                  value: true,
                  onChanged: _pending.contains(state.ref)
                      ? null
                      : (_) => _disable(state.ref),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Edits one pack: name, avatar, images and "Use in all rooms".
class PackEditorScreen extends StatefulWidget {
  const PackEditorScreen({
    super.key,
    required this.features,
    required this.packRef,
    required this.palette,
    this.pickImage,
  });
  final PacksFeatures features;
  final PackRef packRef;
  final AppPalette palette;
  final PackImagePicker? pickImage;

  @override
  State<PackEditorScreen> createState() => _PackEditorScreenState();
}

class _PackEditorScreenState extends State<PackEditorScreen>
    with _PackListener {
  bool _busy = false;

  /// Our last write, shown until synced state moves past the state it was
  /// based on (sync can lag a write by a moment).
  ImagePack? _written;
  String? _baseline;

  @override
  PacksFeatures get packFeatures => widget.features;

  PackRef get _ref => widget.packRef;

  bool get _editable =>
      _ref.personal || widget.features.canEditRoomPacks(_ref.roomId!);

  RoomPackState? get _roomState => _ref.personal
      ? null
      : widget.features
            .roomPacks(_ref.roomId!)
            .where((state) => state.ref == _ref)
            .firstOrNull;

  ImagePack get _synced => _ref.personal
      ? widget.features.personalPack()
      : (_roomState?.pack ?? ImagePack.empty);

  static String _signature(ImagePack pack) => pack.toJson().toString();

  ImagePack get _pack {
    final synced = _synced;
    final written = _written;
    if (written == null) return synced;
    if (_signature(synced) == _baseline) return written;
    _written = null;
    _baseline = null;
    return synced;
  }

  String get _title {
    if (_ref.personal) return _pack.displayName ?? 'Your emoji';
    return _roomState?.name ?? _pack.displayName ?? 'Pack';
  }

  Future<void> _run(
    Future<ImagePack?> Function() action, {
    String? success,
  }) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      final baseline = _signature(_synced);
      final written = await action();
      if (!mounted) return;
      if (written != null) {
        _written = written;
        _baseline = baseline;
      }
      if (success != null) _snack(messenger, success);
    } catch (error) {
      _snack(messenger, _explainWrite(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<PreparedPackImage?> _pick() async {
    final file = await (widget.pickImage ?? _pickFromGallery)();
    if (file == null) return null;
    return readPackImage(file);
  }

  Future<void> _rename() async {
    final name = await askPackName(
      context,
      title: 'Pack name',
      initial: _pack.displayName ?? '',
    );
    if (name == null || !mounted) return;
    await _run(
      () => widget.features.updatePack(
        _ref,
        (current) => current.copyWith(displayName: name),
      ),
    );
  }

  Future<void> _changeAvatar() => _run(() async {
    final image = await _pick();
    if (image == null) return null;
    final url = await widget.features.uploadPackImage(
      image.bytes,
      fileName: image.fileName,
      mimeType: image.mimeType,
    );
    return widget.features.updatePack(
      _ref,
      (current) => current.copyWith(avatarUrl: url),
    );
  });

  Future<void> _addImage() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final PreparedPackImage? image;
    try {
      image = await _pick();
    } catch (error) {
      _snack(messenger, _explainWrite(error));
      return;
    }
    if (image == null || !mounted) return;
    final draft = await showPackImageDialog(
      context,
      palette: widget.palette,
      title: 'Add image',
      preview: Image.memory(
        image.bytes,
        height: 72,
        fit: BoxFit.contain,
        cacheHeight: 216,
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      ),
      initial: PackImageDraft(
        shortcode: image.suggestedShortcode,
        description: '',
        usage: const {PackUsage.emoticon, PackUsage.sticker},
      ),
      taken: _pack.images.keys.toSet(),
    );
    if (draft == null || !mounted) return;
    final picked = image;
    await _run(() async {
      final url = await widget.features.uploadPackImage(
        picked.bytes,
        fileName: picked.fileName,
        mimeType: picked.mimeType,
      );
      return widget.features.updatePack(
        _ref,
        (current) => current.withImage(
          PackImage(
            shortcode: draft.shortcode,
            url: url,
            body: draft.description.isEmpty ? null : draft.description,
            info: picked.info,
            usage: usageToJson(draft.usage, null),
          ),
        ),
      );
    }, success: 'Added :${draft.shortcode}:');
  }

  Future<void> _editImage(PackImage image) async {
    final pack = _pack;
    final result = await showPackImageDialog(
      context,
      palette: widget.palette,
      title: 'Edit :${image.shortcode}:',
      preview: PackImageView(
        features: widget.features,
        url: image.url,
        size: 72,
      ),
      initial: PackImageDraft(
        shortcode: image.shortcode,
        description: image.body ?? '',
        usage: pack.usageOf(image),
      ),
      taken: pack.images.keys.where((k) => k != image.shortcode).toSet(),
      allowDelete: true,
    );
    if (result == null || !mounted) return;
    if (result.delete) {
      final confirmed = await confirmAction(
        context,
        title: 'Delete :${image.shortcode}:?',
        message: 'It will no longer be available in this pack.',
        confirm: 'Delete',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
      await _run(
        () => widget.features.updatePack(
          _ref,
          (current) => current.withoutImage(image.shortcode),
        ),
      );
      return;
    }
    await _run(
      () => widget.features.updatePack(_ref, (current) {
        final existing = current.images[image.shortcode];
        if (existing == null) {
          throw StateError('This image was removed');
        }
        return current.withImage(
          existing.copyWith(
            shortcode: result.shortcode,
            body: result.description,
            clearBody: result.description.isEmpty,
            usage: usageToJson(result.usage, existing.usage),
          ),
          replacing: image.shortcode,
        );
      }),
    );
  }

  Future<void> _toggleEverywhere(bool enabled) => _run(() async {
    await widget.features.setEnabledEverywhere(_ref, enabled: enabled);
    return null;
  });

  Future<void> _delete() async {
    final confirmed = await confirmAction(
      context,
      title: 'Delete this pack?',
      message:
          'Its custom emoji and stickers will no longer be available to '
          'anyone in this room. Messages that already use them still show '
          'them.',
      confirm: 'Delete pack',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final navigator = Navigator.of(context);
    await _run(() async {
      await widget.features.deleteRoomPack(_ref);
      return null;
    });
    if (mounted && _roomState == null) navigator.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final pack = _pack;
    final editable = _editable;
    final idle = !_busy;
    return AdminPage(
      palette: p,
      title: _title,
      busy: _busy,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          AdminSection(
            palette: p,
            title: 'Pack',
            footer: editable
                ? null
                : 'Only people allowed to change room settings can edit '
                      'this pack.',
            children: [
              AdminTile(
                key: const ValueKey('pack-name-tile'),
                palette: p,
                leading: _packAvatar(widget.features, pack, p),
                title: pack.displayName ?? _title,
                subtitle: _countLabel(pack),
                trailing: editable
                    ? Icon(Icons.edit_outlined, color: p.muted)
                    : null,
                onTap: editable && idle ? _rename : null,
              ),
              if (editable)
                AdminTile(
                  key: const ValueKey('pack-avatar-tile'),
                  palette: p,
                  icon: Icons.image_outlined,
                  title: 'Change pack avatar',
                  onTap: idle ? _changeAvatar : null,
                ),
              if (!_ref.personal)
                SwitchListTile(
                  key: const ValueKey('pack-everywhere-switch'),
                  secondary: Icon(Icons.public_rounded, color: p.secondary),
                  title: Text(
                    'Use in all rooms',
                    style: TextStyle(
                      color: p.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    'Make this pack available to you in every room.',
                    style: TextStyle(color: p.muted),
                  ),
                  value: widget.features.isEnabledEverywhere(_ref),
                  onChanged: idle ? _toggleEverywhere : null,
                ),
            ],
          ),
          AdminSection(
            palette: p,
            title: 'Images',
            footer: editable
                ? 'Type :shortcode: in a message to use an emoji. Stickers '
                      'are sent from the attachment menu.'
                : null,
            children: [
              if (pack.images.isEmpty)
                AdminTile(
                  palette: p,
                  icon: Icons.emoji_emotions_outlined,
                  title: 'No images yet',
                  subtitle: editable
                      ? 'Add PNG, GIF, WebP or JPEG images up to 2 MB.'
                      : null,
                ),
              for (final image in pack.images.values)
                AdminTile(
                  key: ValueKey('pack-image-${image.shortcode}'),
                  palette: p,
                  leading: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: PackImageView(
                        features: widget.features,
                        url: image.url,
                        size: 36,
                        semanticLabel: ':${image.shortcode}:',
                      ),
                    ),
                  ),
                  title: ':${image.shortcode}:',
                  subtitle: [
                    _usageLabel(pack.usageOf(image)),
                    if (image.body != null) image.body!,
                  ].join(' · '),
                  trailing: editable
                      ? Icon(Icons.edit_outlined, color: p.muted)
                      : null,
                  onTap: editable && idle ? () => _editImage(image) : null,
                ),
            ],
          ),
          if (editable)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: AccentButton(
                key: const ValueKey('pack-add-image'),
                palette: p,
                label: 'Add image',
                icon: Icons.add_photo_alternate_outlined,
                onPressed: idle ? _addImage : null,
              ),
            ),
          if (editable && !_ref.personal)
            AdminSection(
              palette: p,
              children: [
                AdminTile(
                  key: const ValueKey('pack-delete-tile'),
                  palette: p,
                  icon: Icons.delete_outline_rounded,
                  title: 'Delete pack',
                  destructive: true,
                  onTap: idle ? _delete : null,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Values from the add/edit image dialog.
@immutable
class PackImageDraft {
  const PackImageDraft({
    required this.shortcode,
    required this.description,
    required this.usage,
    this.delete = false,
  });
  final String shortcode;
  final String description;
  final Set<PackUsage> usage;
  final bool delete;
}

/// Asks for a pack name; null when cancelled.
Future<String?> askPackName(
  BuildContext context, {
  required String title,
  String initial = '',
}) => showDialog<String>(
  context: context,
  builder: (_) => _PackNameDialog(title: title, initial: initial),
);

class _PackNameDialog extends StatefulWidget {
  const _PackNameDialog({required this.title, required this.initial});
  final String title;
  final String initial;

  @override
  State<_PackNameDialog> createState() => _PackNameDialogState();
}

class _PackNameDialogState extends State<_PackNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name.length > 100 ? name.substring(0, 100) : name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('pack-name-field'),
      controller: _controller,
      autofocus: true,
      maxLength: 100,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(labelText: 'Name'),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _controller.text.trim().isEmpty ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}

/// Shortcode, description and usage for a new or existing image.
Future<PackImageDraft?> showPackImageDialog(
  BuildContext context, {
  required AppPalette palette,
  required String title,
  required Widget preview,
  required PackImageDraft initial,
  required Set<String> taken,
  bool allowDelete = false,
}) => showDialog<PackImageDraft>(
  context: context,
  builder: (_) => _PackImageDialog(
    palette: palette,
    title: title,
    preview: preview,
    initial: initial,
    taken: taken,
    allowDelete: allowDelete,
  ),
);

class _PackImageDialog extends StatefulWidget {
  const _PackImageDialog({
    required this.palette,
    required this.title,
    required this.preview,
    required this.initial,
    required this.taken,
    required this.allowDelete,
  });
  final AppPalette palette;
  final String title;
  final Widget preview;
  final PackImageDraft initial;
  final Set<String> taken;
  final bool allowDelete;

  @override
  State<_PackImageDialog> createState() => _PackImageDialogState();
}

class _PackImageDialogState extends State<_PackImageDialog> {
  late final _code = TextEditingController(text: widget.initial.shortcode);
  late final _description = TextEditingController(
    text: widget.initial.description,
  );
  late Set<PackUsage> _usage = widget.initial.usage.isEmpty
      ? const {PackUsage.emoticon, PackUsage.sticker}
      : widget.initial.usage;

  @override
  void dispose() {
    _code.dispose();
    _description.dispose();
    super.dispose();
  }

  String get _shortcode => normaliseShortcode(_code.text);

  String? get _error {
    final raw = _code.text.trim();
    if (raw.isEmpty) return null;
    final code = _shortcode;
    if (!isCreatableShortcode(code) || code != raw.replaceAll(':', '')) {
      return 'Use letters, numbers, _ - + or .';
    }
    if (widget.taken.contains(code)) return 'Already used in this pack';
    return null;
  }

  bool get _valid =>
      _code.text.trim().isNotEmpty && _error == null && _usage.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: SizedBox(height: 72, child: widget.preview)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('pack-shortcode-field'),
            controller: _code,
            autofocus: true,
            maxLength: maxCreatedShortcodeLength,
            decoration: InputDecoration(
              labelText: 'Shortcode',
              prefixText: ':',
              suffixText: ':',
              errorText: _error,
            ),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const ValueKey('pack-description-field'),
            controller: _description,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
            ),
          ),
          const SizedBox(height: 4),
          Eyebrow('Use as', palette: p),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            key: const ValueKey('pack-usage'),
            segments: const [
              ButtonSegment(value: 0, label: Text('Emoji')),
              ButtonSegment(value: 1, label: Text('Sticker')),
              ButtonSegment(value: 2, label: Text('Both')),
            ],
            selected: {
              _usage.length == 2
                  ? 2
                  : _usage.contains(PackUsage.sticker)
                  ? 1
                  : 0,
            },
            onSelectionChanged: (value) => setState(
              () => _usage = switch (value.first) {
                0 => const {PackUsage.emoticon},
                1 => const {PackUsage.sticker},
                _ => const {PackUsage.emoticon, PackUsage.sticker},
              },
            ),
          ),
        ],
      ),
      actions: [
        if (widget.allowDelete)
          TextButton(
            key: const ValueKey('pack-image-delete'),
            onPressed: () => Navigator.pop(
              context,
              PackImageDraft(
                shortcode: widget.initial.shortcode,
                description: '',
                usage: _usage,
                delete: true,
              ),
            ),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFFF6B5E)),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('pack-image-save'),
          onPressed: _valid
              ? () => Navigator.pop(
                  context,
                  PackImageDraft(
                    shortcode: _shortcode,
                    description: _description.text.trim(),
                    usage: _usage,
                  ),
                )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

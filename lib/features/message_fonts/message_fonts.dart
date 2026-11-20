// Message fonts (issue #17): the sender picks a typeface in the composer and
// other Parallax users see the message in it.
//
// The choice travels in the event content under [messageFontContentKey] as a
// short, stable catalogue ID. Other clients ignore the key and show the plain
// message; a Parallax that does not know an ID shows the default font.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Event content key carrying a message's font ID (namespaced, so other
/// clients ignore it). Present only when the sender chose a non-default font.
const messageFontContentKey = 'net.samrusselltech.parallax.font';

/// The shape every font ID has: 1–32 lowercase letters, digits, `_` or `-`.
/// Durable stores validate against this, not the catalogue, so a stored
/// choice survives a catalogue change and is simply ignored when sent.
final messageFontIdPattern = RegExp(r'^[a-z0-9_-]{1,32}$');

/// Whether [value] is a well-formed font ID (known to this version or not).
bool isMessageFontId(String value) => messageFontIdPattern.hasMatch(value);

/// One bundled typeface (SIL Open Font License 1.1, from google/fonts).
@immutable
class MessageFont {
  const MessageFont({
    required this.id,
    required this.label,
    required this.family,
    required this.licenceAsset,
  });

  /// Stable ID sent in event content. Never rename or reuse one: messages
  /// already sent carry it.
  final String id;

  /// Name shown in the picker.
  final String label;

  /// Flutter `fontFamily` declared in pubspec.yaml.
  final String family;

  /// The family's OFL.txt, carrying its copyright notice.
  final String licenceAsset;
}

/// Every font a message can be sent in, in picker order. Append new fonts;
/// do not remove or rename IDs that may already have been sent.
const messageFonts = <MessageFont>[
  MessageFont(
    id: 'dmserif',
    label: 'DM Serif Display',
    family: 'DMSerifDisplay',
    licenceAsset: 'assets/fonts/licenses/DMSerifDisplay-OFL.txt',
  ),
  MessageFont(
    id: 'indieflower',
    label: 'Indie Flower',
    family: 'IndieFlower',
    licenceAsset: 'assets/fonts/licenses/IndieFlower-OFL.txt',
  ),
  MessageFont(
    id: 'pacifico',
    label: 'Pacifico',
    family: 'Pacifico',
    licenceAsset: 'assets/fonts/licenses/Pacifico-OFL.txt',
  ),
  MessageFont(
    id: 'lobster',
    label: 'Lobster',
    family: 'Lobster',
    licenceAsset: 'assets/fonts/licenses/Lobster-OFL.txt',
  ),
  MessageFont(
    id: 'comicneue',
    label: 'Comic Neue',
    family: 'ComicNeue',
    licenceAsset: 'assets/fonts/licenses/ComicNeue-OFL.txt',
  ),
  MessageFont(
    id: 'spacemono',
    label: 'Space Mono',
    family: 'SpaceMono',
    licenceAsset: 'assets/fonts/licenses/SpaceMono-OFL.txt',
  ),
  MessageFont(
    id: 'pressstart2p',
    label: 'Press Start 2P',
    family: 'PressStart2P',
    licenceAsset: 'assets/fonts/licenses/PressStart2P-OFL.txt',
  ),
  MessageFont(
    id: 'bangers',
    label: 'Bangers',
    family: 'Bangers',
    licenceAsset: 'assets/fonts/licenses/Bangers-OFL.txt',
  ),
];

/// The catalogue font with [id]; null (the default font) for null, unknown
/// or malformed IDs.
MessageFont? messageFontById(String? id) {
  if (id == null) return null;
  for (final font in messageFonts) {
    if (font.id == id) return font;
  }
  return null;
}

/// The font a message's display content asks for, or null for the default.
/// Pass the content after edits are applied (`m.new_content` of the latest
/// edit), so an edit can change or drop the font.
MessageFont? messageFontOf(Map<String, Object?> content) {
  final id = content[messageFontContentKey];
  return id is String ? messageFontById(id) : null;
}

/// [content] with the font ID added for a known, non-default [fontId]; an
/// edit's `m.new_content` gets it too, since receivers render that. Returns
/// [content] unchanged for null or unknown IDs.
Map<String, Object?> withMessageFont(
  Map<String, Object?> content,
  String? fontId,
) {
  final font = messageFontById(fontId);
  if (font == null) return content;
  final newContent = content['m.new_content'];
  return {
    ...content,
    messageFontContentKey: font.id,
    if (newContent is Map)
      'm.new_content': <String, Object?>{
        ...newContent.cast<String, Object?>(),
        messageFontContentKey: font.id,
      },
  };
}

bool _licencesRegistered = false;

/// Adds each font's OFL to the app's licence page. The files are read only
/// when that page collects licences, so startup does not load them.
void registerMessageFontLicences() {
  if (_licencesRegistered) return;
  _licencesRegistered = true;
  LicenseRegistry.addLicense(messageFontLicences);
}

/// One licence entry per message font, read from the bundled OFL files.
@visibleForTesting
Stream<LicenseEntry> messageFontLicences() async* {
  for (final font in messageFonts) {
    final text = await rootBundle.loadString(font.licenceAsset);
    yield LicenseEntryWithLineBreaks([
      '${font.label} font',
    ], text.replaceAll('\r\n', '\n').trim());
  }
}

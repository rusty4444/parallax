// App font: one typeface for every screen of Parallax (Settings →
// Appearance → Font). It is a local display preference only; nothing is
// sent. A message sent in a message font (`message_fonts.dart`) keeps that
// font, whatever the app font is.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TextTheme, Typography;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../message_fonts/message_fonts.dart' show messageFonts;

/// One typeface the whole app can be drawn in.
@immutable
class AppFont {
  const AppFont({
    required this.id,
    required this.label,
    required this.description,
    this.family,
    this.licenceAsset,
  });

  /// Stable ID stored in the preferences. Never rename or reuse one.
  final String id;

  /// Name shown in Settings and the picker.
  final String label;

  /// A few words on the font's character, shown under its name.
  final String description;

  /// Flutter `fontFamily` declared in pubspec.yaml; null means the
  /// platform's own font (Roboto, San Francisco, Segoe UI …).
  final String? family;

  /// The family's OFL.txt, carrying its copyright notice. Null for the
  /// platform's font, which Parallax does not bundle.
  final String? licenceAsset;

  /// Whether this is the platform's own font rather than a bundled one.
  bool get isSystem => family == null;
}

/// Parallax's own font, used until the user picks another.
const defaultAppFont = AppFont(
  id: 'spacegrotesk',
  label: 'Space Grotesk',
  description: 'Parallax’s own font',
  family: 'SpaceGrotesk',
  licenceAsset: 'assets/fonts/licenses/SpaceGrotesk-OFL.txt',
);

/// Every app font, in picker order. Append new fonts; do not remove or
/// rename IDs that may already be saved.
const appFonts = <AppFont>[
  defaultAppFont,
  AppFont(id: 'system', label: 'System', description: 'Your device’s own font'),
  AppFont(
    id: 'figtree',
    label: 'Figtree',
    description: 'Clean and friendly',
    family: 'Figtree',
    licenceAsset: 'assets/fonts/licenses/Figtree-OFL.txt',
  ),
  AppFont(
    id: 'outfit',
    label: 'Outfit',
    description: 'Geometric and modern',
    family: 'Outfit',
    licenceAsset: 'assets/fonts/licenses/Outfit-OFL.txt',
  ),
  AppFont(
    id: 'manrope',
    label: 'Manrope',
    description: 'Crisp and open',
    family: 'Manrope',
    licenceAsset: 'assets/fonts/licenses/Manrope-OFL.txt',
  ),
  AppFont(
    id: 'karla',
    label: 'Karla',
    description: 'Quirky grotesque',
    family: 'Karla',
    licenceAsset: 'assets/fonts/licenses/Karla-OFL.txt',
  ),
  AppFont(
    id: 'nunito',
    label: 'Nunito',
    description: 'Soft and rounded',
    family: 'Nunito',
    licenceAsset: 'assets/fonts/licenses/Nunito-OFL.txt',
  ),
  AppFont(
    id: 'quicksand',
    label: 'Quicksand',
    description: 'Light and rounded',
    family: 'Quicksand',
    licenceAsset: 'assets/fonts/licenses/Quicksand-OFL.txt',
  ),
  AppFont(
    id: 'josefinsans',
    label: 'Josefin Sans',
    description: 'Elegant and vintage',
    family: 'JosefinSans',
    licenceAsset: 'assets/fonts/licenses/JosefinSans-OFL.txt',
  ),
  AppFont(
    id: 'atkinson',
    label: 'Atkinson Hyperlegible',
    description: 'Made for low-vision readers',
    family: 'AtkinsonHyperlegibleNext',
    licenceAsset: 'assets/fonts/licenses/AtkinsonHyperlegibleNext-OFL.txt',
  ),
  AppFont(
    id: 'lexend',
    label: 'Lexend',
    description: 'Wide and easy to read',
    family: 'Lexend',
    licenceAsset: 'assets/fonts/licenses/Lexend-OFL.txt',
  ),
  AppFont(
    id: 'lora',
    label: 'Lora',
    description: 'Calligraphic serif',
    family: 'Lora',
    licenceAsset: 'assets/fonts/licenses/Lora-OFL.txt',
  ),
  AppFont(
    id: 'librebaskerville',
    label: 'Libre Baskerville',
    description: 'Classic book serif',
    family: 'LibreBaskerville',
    licenceAsset: 'assets/fonts/licenses/LibreBaskerville-OFL.txt',
  ),
  AppFont(
    id: 'bitter',
    label: 'Bitter',
    description: 'Sturdy slab serif',
    family: 'Bitter',
    licenceAsset: 'assets/fonts/licenses/Bitter-OFL.txt',
  ),
  AppFont(
    id: 'jetbrainsmono',
    label: 'JetBrains Mono',
    description: 'Monospaced, like code',
    family: 'JetBrainsMono',
    licenceAsset: 'assets/fonts/licenses/JetBrainsMono-OFL.txt',
  ),
  AppFont(
    id: 'comicneue',
    label: 'Comic Neue',
    description: 'Casual comic lettering',
    family: 'ComicNeue',
    licenceAsset: 'assets/fonts/licenses/ComicNeue-OFL.txt',
  ),
  AppFont(
    id: 'caveat',
    label: 'Caveat',
    description: 'Handwritten',
    family: 'Caveat',
    licenceAsset: 'assets/fonts/licenses/Caveat-OFL.txt',
  ),
];

/// The app font with [id]; null for null, unknown or malformed IDs.
AppFont? appFontById(String? id) {
  if (id == null) return null;
  for (final font in appFonts) {
    if (font.id == id) return font;
  }
  return null;
}

/// The platform's own text theme (light glyphs) for [platform]: Roboto on
/// Android, San Francisco on Apple devices, Segoe UI on Windows.
TextTheme platformTextTheme(TargetPlatform platform) =>
    Typography.material2021(platform: platform).white;

/// A style that draws text in [font] whatever the surrounding theme is, for
/// previews (the picker shows each font in its own face). The system font
/// names the platform's family explicitly, since a null family would
/// inherit the current app font.
TextStyle appFontPreviewStyle(AppFont font, {TargetPlatform? platform}) {
  final family = font.family;
  if (family != null) return TextStyle(fontFamily: family);
  final body = platformTextTheme(platform ?? defaultTargetPlatform).bodyLarge;
  return TextStyle(
    fontFamily: body?.fontFamily,
    fontFamilyFallback: body?.fontFamilyFallback,
  );
}

bool _licencesRegistered = false;

/// Adds the licence of every bundled app font to the app's licence page
/// (families already listed as message fonts are not repeated). The files
/// are read only when that page collects licences.
void registerAppFontLicences() {
  if (_licencesRegistered) return;
  _licencesRegistered = true;
  LicenseRegistry.addLicense(appFontLicences);
}

/// One licence entry per bundled app font that is not also a message font.
@visibleForTesting
Stream<LicenseEntry> appFontLicences() async* {
  final listed = {for (final font in messageFonts) font.licenceAsset};
  for (final font in appFonts) {
    final asset = font.licenceAsset;
    if (asset == null || listed.contains(asset)) continue;
    final text = await rootBundle.loadString(asset);
    yield LicenseEntryWithLineBreaks([
      '${font.label} font',
    ], text.replaceAll('\r\n', '\n').trim());
  }
}

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'settings_widgets.dart';

/// Keep in step with `version:` in pubspec.yaml.
const parallaxVersion = '1.5.3';
const parallaxBuild = '31';

/// Where problems are reported: an email to the developer.
const reportProblemEmail = 'sam@samrusselltech.net';

/// A `mailto:` link with the app version in the subject and a short template.
/// Spaces are encoded as `%20`: mail apps show the `+` that query encoding
/// would produce literally.
final reportProblemUrl = Uri.parse(
  'mailto:$reportProblemEmail'
  '?subject=${Uri.encodeComponent('Parallax $parallaxVersion ($parallaxBuild) problem report')}'
  '&body=${Uri.encodeComponent('What happened:\n\n\nWhat you expected to happen:\n\n\n'
  'Parallax $parallaxVersion ($parallaxBuild)\n')}',
);

/// Parallax's public source code (AGPL-3.0-or-later). Builds must point here
/// so everyone who installs one can get the matching source.
final sourceCodeUrl = Uri.parse('https://github.com/rusty4444/parallax');

/// The licence notice shown under the Legal group.
const licenceNotice =
    'Parallax is free software under the GNU Affero General Public '
    'License, version 3 or later, and comes with no warranty.';

/// About, licences, legal links and problem reporting (Element X About and
/// "Report a problem").
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return SettingsPage(
      palette: p,
      eyebrow: 'Every angle of the conversation',
      title: 'About',
      children: [
        Center(child: BrandMark(palette: p, size: 72)),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'Parallax $parallaxVersion ($parallaxBuild)',
            style: TextStyle(
              color: p.foreground,
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            'A Matrix messenger for Android by Sam Russell.',
            textAlign: TextAlign.center,
            style: TextStyle(color: p.muted),
          ),
        ),
        const SizedBox(height: 22),
        SettingsGroup(
          palette: p,
          title: 'Legal',
          footer: licenceNotice,
          children: [
            ListTile(
              leading: const Icon(Icons.code_rounded),
              title: const Text('Source code'),
              subtitle: const Text('GNU AGPL v3 or later'),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: () => openExternalLink(context, sourceCodeUrl),
            ),
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: const Text('Open source licences'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Parallax',
                applicationVersion: '$parallaxVersion ($parallaxBuild)',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Matrix privacy notice'),
              subtitle: const Text('Your homeserver’s own policies also apply'),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: () => openExternalLink(
                context,
                Uri.parse('https://matrix.org/legal/privacy-notice/'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.gavel_outlined),
              title: const Text('Matrix specification'),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: () => openExternalLink(
                context,
                Uri.parse('https://spec.matrix.org/latest/'),
              ),
            ),
          ],
        ),
        SettingsGroup(
          palette: p,
          title: 'Help',
          footer:
              'Reports open an email to the developer. Don’t include '
              'passwords, recovery keys or message contents.',
          children: [
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Report a problem'),
              subtitle: const Text(reportProblemEmail),
              trailing: const Icon(Icons.mail_outline_rounded),
              onTap: () => openExternalLink(context, reportProblemUrl),
            ),
          ],
        ),
      ],
    );
  }
}

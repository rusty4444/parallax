import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'settings_widgets.dart';

/// Keep in step with `version:` in pubspec.yaml.
const parallaxVersion = '1.1.1';
const parallaxBuild = '23';

/// Where problems are reported (private Gitea issue tracker).
final reportProblemUrl = Uri.parse(
  'http://192.168.68.247:3300/rusty4444/parallax/issues/new',
);

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
          children: [
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
              'Reports open the Parallax issue tracker. Don’t include '
              'passwords, recovery keys or message contents.',
          children: [
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Report a problem'),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: () => openExternalLink(context, reportProblemUrl),
            ),
          ],
        ),
      ],
    );
  }
}

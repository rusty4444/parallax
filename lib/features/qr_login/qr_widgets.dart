// Shared building blocks for the QR sign-in and link-device screens, in the
// Parallax visual language (GlowBackdrop, rounded cards, AccentButton).
import 'package:flutter/material.dart';

import '../../app_theme.dart';

/// Element X `FlowStepPage`: icon, title, subtitle, content, buttons.
class QrStepPage extends StatelessWidget {
  const QrStepPage({
    super.key,
    required this.palette,
    required this.icon,
    required this.title,
    this.subtitle,
    this.content,
    this.buttons = const [],
    this.onBack,
    this.iconColor,
  });

  final AppPalette palette;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? content;
  final List<Widget> buttons;
  final VoidCallback? onBack;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Column(
            children: [
              if (onBack != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: 'Back',
                    onPressed: onBack,
                    icon: Icon(Icons.arrow_back_rounded, color: p.foreground),
                  ),
                ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: p.raised,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: p.stroke),
                              ),
                              child: Icon(
                                icon,
                                size: 32,
                                color: iconColor ?? p.accent,
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: p.foreground,
                              fontSize: 24,
                              height: 1.2,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              subtitle!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: p.muted, height: 1.4),
                            ),
                          ],
                          if (content != null) ...[
                            const SizedBox(height: 24),
                            content!,
                          ],
                          if (buttons.isNotEmpty) ...[
                            const SizedBox(height: 28),
                            for (final (i, button) in buttons.indexed) ...[
                              if (i > 0) const SizedBox(height: 10),
                              button,
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Large digit tiles (check code, verification code).
class QrDigits extends StatelessWidget {
  const QrDigits({super.key, required this.palette, required this.code});
  final AppPalette palette;
  final String code;

  @override
  Widget build(BuildContext context) => Semantics(
    label: code.split('').join(' '),
    excludeSemantics: true,
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final char in code.characters)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: palette.raised,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.stroke),
            ),
            child: Text(
              char,
              style: TextStyle(
                color: palette.foreground,
                fontSize: 30,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    ),
  );
}

class QrWaiting extends StatelessWidget {
  const QrWaiting({
    super.key,
    required this.palette,
    this.label = 'Waiting for your other device',
  });
  final AppPalette palette;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: palette.accent),
      ),
      const SizedBox(height: 8),
      Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(color: palette.muted, fontSize: 13),
      ),
    ],
  );
}

/// Numbered instructions (Element X `NumberedListOrganism`).
class QrNumberedSteps extends StatelessWidget {
  const QrNumberedSteps({
    super.key,
    required this.palette,
    required this.steps,
  });
  final AppPalette palette;
  final List<String> steps;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: palette.stroke),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, step) in steps.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: palette.raised,
                    border: Border.all(color: palette.stroke),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: palette.secondary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      step,
                      style: TextStyle(color: palette.foreground, height: 1.35),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class QrOutlinedButton extends StatelessWidget {
  const QrOutlinedButton({
    super.key,
    required this.label,
    required this.onPressed,
  });
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 50,
    child: OutlinedButton(onPressed: onPressed, child: Text(label)),
  );
}

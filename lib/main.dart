import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'inbox_screen.dart';
import 'login_screen.dart';
import 'matrix_backend.dart';
import 'widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MatrixpressApp());
}

class MatrixpressApp extends StatefulWidget {
  const MatrixpressApp({super.key, this.backend});
  final ChatBackend? backend;

  @override
  State<MatrixpressApp> createState() => _MatrixpressAppState();
}

class _MatrixpressAppState extends State<MatrixpressApp> {
  late final ChatBackend _backend = widget.backend ?? MatrixBackend();
  VisualTheme _style = VisualTheme.ultraviolet;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_backend.initialize());
      unawaited(_loadTheme());
    });
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getString('visual_theme');
    for (final theme in VisualTheme.values) {
      if (theme.name == saved) setState(() => _style = theme);
    }
  }

  void _changeTheme(VisualTheme style) {
    setState(() => _style = style);
    unawaited(_saveTheme(style));
  }

  Future<void> _saveTheme(VisualTheme style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('visual_theme', style.name);
  }

  @override
  void dispose() {
    if (widget.backend == null) _backend.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteFor(_style);
    return MaterialApp(
      title: 'MatriXpress',
      debugShowCheckedModeBanner: false,
      theme: themeFor(_style),
      home: AnimatedBuilder(
        animation: _backend,
        builder: (context, _) => switch (_backend.connection) {
          SessionStatus.loading => Scaffold(
            body: GlowBackdrop(
              palette: p,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BrandMark(palette: p, size: 72),
                    const SizedBox(height: 20),
                    Text(
                      'MatriXpress',
                      style: TextStyle(
                        color: p.foreground,
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 18),
                    CircularProgressIndicator(color: p.accent),
                  ],
                ),
              ),
            ),
          ),
          SessionStatus.signedOut => LoginScreen(backend: _backend, palette: p),
          SessionStatus.ready => InboxScreen(
            backend: _backend,
            palette: p,
            style: _style,
            onThemeChanged: _changeTheme,
          ),
          SessionStatus.offline => Scaffold(
            body: GlowBackdrop(
              palette: p,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, color: p.accent, size: 48),
                      const SizedBox(height: 18),
                      Text(
                        'Couldn’t start MatriXpress',
                        style: TextStyle(
                          color: p.foreground,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _backend.error ?? 'Something went wrong.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: p.muted),
                      ),
                      const SizedBox(height: 24),
                      AccentButton(
                        palette: p,
                        label: 'Try again',
                        onPressed: () => unawaited(_backend.initialize()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        },
      ),
    );
  }
}

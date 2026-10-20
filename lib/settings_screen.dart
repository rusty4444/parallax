import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'chat_backend.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.style,
    required this.onThemeChanged,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final VisualTheme style;
  final ValueChanged<VisualTheme> onThemeChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late VisualTheme _style = widget.style;
  late Future<CryptoStatus> _cryptoFuture;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _cryptoFuture = widget.backend.cryptoStatus();
  }

  void _refreshCrypto() => setState(() {
    _cryptoFuture = widget.backend.cryptoStatus();
  });

  Future<void> _restoreCrypto() async {
    if (_restoring) return;
    final credential = await showDialog<String>(
      context: context,
      builder: (_) => const _RecoveryDialog(),
    );
    if (credential == null || credential.isEmpty || !mounted) return;
    setState(() => _restoring = true);
    try {
      await widget.backend.restoreCryptoIdentity(credential);
      if (mounted) {
        _refreshCrypto();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Encryption identity restored on this device.'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recovery failed. Check your key or passphrase.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _restoreHistory() async {
    if (_restoring) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore message history?'),
        content: const Text(
          'Downloading backed-up encryption keys may take '
          'time and use mobile data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _restoring = true);
    try {
      await widget.backend.restoreBackedUpKeys();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backed-up message keys restored.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t restore backed-up keys.')),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This removes your local session from this device. '
          'You can sign in again at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.backend.logout();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t sign out. Try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteFor(_style);
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 34),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const SizedBox(height: 18),
              Eyebrow('Make it yours', palette: p),
              const SizedBox(height: 4),
              Text(
                'Settings',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 38,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.7,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: p.stroke),
                ),
                child: Row(
                  children: [
                    BrandMark(palette: p),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.backend.userId ?? 'Matrix account',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.foreground,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'CONNECTED TO MATRIX',
                            style: TextStyle(
                              color: p.secondary,
                              fontSize: 10,
                              letterSpacing: 1.1,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Eyebrow('Appearance', palette: p),
              const SizedBox(height: 10),
              Text(
                'Pick your frequency',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 13),
              for (final style in VisualTheme.values) ...[
                _ThemeCard(
                  style: style,
                  palette: p,
                  selected: style == _style,
                  onTap: () {
                    setState(() => _style = style);
                    widget.onThemeChanged(style);
                  },
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 28),
              Eyebrow('Encryption', palette: p),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: p.stroke),
                ),
                child: FutureBuilder<CryptoStatus>(
                  future: _cryptoFuture,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            snapshot.hasError
                                ? 'Status unavailable'
                                : 'Checking encryption identity…',
                            style: TextStyle(
                              color: p.foreground,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (snapshot.hasError)
                            TextButton(
                              onPressed: _refreshCrypto,
                              child: const Text('Retry'),
                            ),
                        ],
                      );
                    }
                    final status = snapshot.data!;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status.connected
                              ? 'Identity connected on this device'
                              : status.initialized
                              ? 'Recovery required on this device'
                              : 'No complete identity on this account',
                          style: TextStyle(
                            color: p.foreground,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          status.initialized
                              ? 'Key backup: ${status.keyBackupEnabled ? 'on' : 'off'} · '
                                    'Cross-signing: ${status.crossSigningEnabled ? 'on' : 'off'}'
                              : 'Set up or repair your encryption identity in a '
                                    'mature Matrix client first. This app will not reset it.',
                          style: TextStyle(color: p.muted, fontSize: 12),
                        ),
                        if (status.initialized && !status.connected) ...[
                          const SizedBox(height: 14),
                          FilledButton.icon(
                            onPressed: _restoring ? null : _restoreCrypto,
                            icon: const Icon(Icons.key_rounded),
                            label: Text(
                              _restoring ? 'Restoring…' : 'Enter recovery key',
                            ),
                          ),
                        ],
                        if (status.connected && status.keyBackupEnabled) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _restoring ? null : _restoreHistory,
                            icon: const Icon(Icons.cloud_download_outlined),
                            label: const Text('Restore backed-up history'),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 28),
              OutlinedButton.icon(
                onPressed: _logout,
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Sign out'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: p.foreground,
                  side: BorderSide(color: p.stroke),
                  minimumSize: const Size.fromHeight(54),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'MatriXpress 0.2 · Built for speed, made for people.',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog();

  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Restore encryption identity'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Enter your existing recovery key or passphrase. '
          'It will not be saved by MatriXpress. Never share it.',
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: const InputDecoration(
            labelText: 'Recovery key or passphrase',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Restore'),
      ),
    ],
  );
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.style,
    required this.palette,
    required this.selected,
    required this.onTap,
  });
  final VisualTheme style;
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = paletteFor(style);
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? palette.accent : palette.stroke,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 53,
                height: 53,
                decoration: BoxDecoration(
                  color: preview.background,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: preview.stroke),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 22,
                      decoration: BoxDecoration(
                        color: preview.accent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Container(
                      width: 12,
                      height: 13,
                      decoration: BoxDecoration(
                        color: preview.secondary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      style.label,
                      style: TextStyle(
                        color: palette.foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      style.caption,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: palette.accent),
            ],
          ),
        ),
      ),
    );
  }
}

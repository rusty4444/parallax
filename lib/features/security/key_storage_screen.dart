import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'security_features.dart';
import 'security_ui.dart';

/// Element X SecureBackupDisable: explains what deleting key storage loses
/// and asks twice before deleting the server backup. Pops `true` once done.
class DisableKeyStorageScreen extends StatefulWidget {
  const DisableKeyStorageScreen({
    super.key,
    required this.security,
    required this.palette,
  });
  final SecurityFeatures security;
  final AppPalette palette;

  @override
  State<DisableKeyStorageScreen> createState() =>
      _DisableKeyStorageScreenState();
}

class _DisableKeyStorageScreenState extends State<DisableKeyStorageScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Are you sure you want to delete key storage?'),
        content: const Text(
          'You will lose your encrypted chat history if you remove all your '
          'devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.security.disableKeyStorage();
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Key storage was not fully deleted. Check your connection and '
              'try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final error = Theme.of(context).colorScheme.error;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        body: GlowBackdrop(
          palette: p,
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 40),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: 'Back',
                    onPressed: _busy ? null : () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ),
                const SizedBox(height: 16),
                Icon(Icons.cloud_off_outlined, color: error, size: 40),
                const SizedBox(height: 12),
                Eyebrow('Key storage', palette: p),
                const SizedBox(height: 6),
                Text(
                  'Are you sure you want to turn off key storage and delete '
                  'it?',
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 16),
                SecurityCard(
                  palette: p,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Deleting key storage removes your message keys from '
                        'the server and turns off the following security '
                        'features:',
                        style: TextStyle(color: p.foreground),
                      ),
                      const SizedBox(height: 8),
                      SecurityBullet(
                        palette: p,
                        icon: Icons.history_toggle_off,
                        critical: true,
                        text:
                            'You will not have encrypted message history on '
                            'new devices',
                      ),
                      SecurityBullet(
                        palette: p,
                        icon: Icons.lock_outline,
                        critical: true,
                        text:
                            'You will lose access to your encrypted messages '
                            'if you are signed out of Parallax everywhere',
                      ),
                      SecurityBullet(
                        palette: p,
                        icon: Icons.key_outlined,
                        text:
                            'Your recovery key still confirms your digital '
                            'identity on new devices',
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: TextStyle(color: error)),
                ],
                const SizedBox(height: 22),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: _busy ? null : _delete,
                  child: Text(_busy ? 'Deleting…' : 'Delete key storage'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

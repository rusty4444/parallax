import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../crypto_setup_policy.dart';
import '../../crypto_setup_screen.dart';
import '../../feature_settings_scope.dart';
import '../../widgets.dart';
import 'change_recovery_key_screen.dart';
import 'key_export_features.dart';
import 'key_export_screens.dart';
import 'key_storage_screen.dart';
import 'reset_identity_screen.dart';
import 'security_features.dart';
import 'security_gate.dart';
import 'security_ui.dart';

/// Settings → Security → Key storage and recovery: this device, key storage,
/// recovery, room keys and reset (Element X securebackup root).
class SecuritySettingsSection extends StatefulWidget {
  const SecuritySettingsSection({
    super.key,
    required this.backend,
    required this.security,
    required this.palette,
    this.setSecureWindow,
    this.openUrl,
    this.keyTransfer,
  });

  final ChatBackend backend;
  final SecurityFeatures security;
  final AppPalette palette;
  final SetSecureWindow? setSecureWindow;
  final ExternalUrlOpener? openUrl;

  /// Room key export/import; resolved from [backend] when null.
  final RoomKeyTransfer? keyTransfer;

  @override
  State<SecuritySettingsSection> createState() =>
      _SecuritySettingsSectionState();
}

class _SecuritySettingsSectionState extends State<SecuritySettingsSection> {
  late final _owner = BackendSessionOwner(widget.backend);
  late Future<SecurityOverview> _overview;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _overview = widget.security.loadOverview();
  }

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  bool get _current => mounted && _owner.isCurrent;

  RoomKeyTransfer? get _keyTransfer =>
      widget.keyTransfer ?? RoomKeyTransfer.of(widget.backend);

  void _reload() {
    if (!_current) return;
    final overview = widget.security.loadOverview();
    // Block body: an arrow would return the Future to setState.
    setState(() {
      _overview = overview;
    });
  }

  void _snack(String text) {
    if (!_current) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<T?> _push<T>(Widget screen) async {
    if (!_current || _busy) return null;
    final result = await Navigator.of(
      context,
    ).push<T>(MaterialPageRoute(builder: (_) => screen));
    _reload();
    return result;
  }

  Future<void> _verifyDevice() => _push<bool>(
    ConfirmIdentityScreen(
      backend: widget.backend,
      security: widget.security,
      palette: widget.palette,
      setSecureWindow: widget.setSecureWindow,
      openUrl: widget.openUrl,
    ),
  );

  Future<void> _setUpRecovery() => _push<bool>(
    CryptoSetupScreen(
      backend: widget.backend,
      palette: widget.palette,
      setSecureWindow: widget.setSecureWindow,
    ),
  );

  Future<void> _changeRecoveryKey() => _push<bool>(
    ChangeRecoveryKeyScreen(
      security: widget.security,
      palette: widget.palette,
      setSecureWindow: widget.setSecureWindow,
    ),
  );

  Future<void> _reset() => _push<bool>(
    ResetIdentityScreen(
      security: widget.security,
      palette: widget.palette,
      setSecureWindow: widget.setSecureWindow,
      openUrl: widget.openUrl,
    ),
  );

  Future<void> _exportRoomKeys(RoomKeyTransfer transfer) => _push<bool>(
    KeyExportScreen(
      transfer: transfer,
      palette: widget.palette,
      setSecureWindow: widget.setSecureWindow,
    ),
  );

  Future<void> _importRoomKeys(RoomKeyTransfer transfer) => _push<bool>(
    KeyImportScreen(
      transfer: transfer,
      palette: widget.palette,
      setSecureWindow: widget.setSecureWindow,
    ),
  );

  Future<void> _turnOffKeyStorage() async {
    final done = await _push<bool>(
      DisableKeyStorageScreen(
        security: widget.security,
        palette: widget.palette,
      ),
    );
    if (done == true) _snack('Key storage deleted.');
  }

  Future<void> _turnOnKeyStorage(SecurityOverview overview) async {
    if (_busy || !_current) return;
    if (overview.setupAvailability == CryptoSetupAvailability.create) {
      await _setUpRecovery();
      return;
    }
    final credential = await askRecoveryCredential(
      context,
      setSecureWindow: widget.setSecureWindow,
      title: 'Turn on key storage',
      description:
          'Enter your recovery key or passphrase. A new backup is created '
          'and protected by your existing recovery key.',
      action: 'Turn on',
    );
    if (credential == null || !_current) return;
    setState(() => _busy = true);
    try {
      await widget.security.enableKeyStorage(credential);
      _snack('Key storage is on.');
    } catch (_) {
      _snack(
        'Couldn’t turn on key storage. Check your recovery key; nothing was '
        'reset.',
      );
    } finally {
      if (_current) setState(() => _busy = false);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Eyebrow('Key storage and recovery', palette: p),
        const SizedBox(height: 10),
        SecurityCard(
          palette: p,
          child: FutureBuilder<SecurityOverview>(
            future: _overview,
            builder: (context, snapshot) {
              final overview = snapshot.data;
              if (overview == null) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snapshot.hasError
                          ? 'Security status unavailable'
                          : 'Checking security…',
                      style: TextStyle(
                        color: p.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (snapshot.hasError)
                      TextButton(
                        onPressed: _reload,
                        child: const Text('Retry'),
                      ),
                  ],
                );
              }
              return _content(context, p, overview);
            },
          ),
        ),
        // Same spacing as SettingsGroup on the settings pages.
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _content(BuildContext context, AppPalette p, SecurityOverview o) {
    final error = Theme.of(context).colorScheme.error;
    TextStyle title() => TextStyle(
      color: p.foreground,
      fontSize: 16,
      fontWeight: FontWeight.w700,
    );
    final muted = TextStyle(color: p.muted, fontSize: 12, height: 1.35);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // This device.
        Row(
          children: [
            Icon(
              o.deviceVerified
                  ? Icons.verified_user_rounded
                  : Icons.gpp_maybe_outlined,
              color: o.deviceVerified ? p.secondary : error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    o.deviceVerified
                        ? 'This device is verified'
                        : 'This device is not verified',
                    style: title(),
                  ),
                  Text(
                    o.deviceVerified
                        ? 'Signed by your digital identity.'
                        : 'Confirm it to read encrypted history and be '
                              'trusted by people you chat with.',
                    style: muted,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!o.deviceVerified) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _verifyDevice,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('Verify this device'),
          ),
        ],
        Divider(height: 30, color: p.stroke),
        // Key storage.
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Allow key storage', style: title()),
                  Text(switch (o.keyStorage) {
                    KeyStorageState.on =>
                      'Message keys are backed up with end-to-end '
                          'encryption, so new devices can read your chat '
                          'history.',
                    KeyStorageState.off =>
                      'Key storage is off. New devices won’t be able to '
                          'read your encrypted history.',
                    KeyStorageState.incomplete =>
                      'Key storage is only partly set up, for example '
                          'after an interrupted change.',
                  }, style: muted),
                ],
              ),
            ),
            Switch(
              value: o.keyStorage == KeyStorageState.on,
              onChanged:
                  _busy ||
                      o.keyStorage == KeyStorageState.incomplete ||
                      (o.keyStorage == KeyStorageState.off &&
                          o.setupAvailability !=
                              CryptoSetupAvailability.repair &&
                          o.setupAvailability != CryptoSetupAvailability.create)
                  ? null
                  : (value) => value
                        ? unawaited(_turnOnKeyStorage(o))
                        : unawaited(_turnOffKeyStorage()),
            ),
          ],
        ),
        if (o.keyStorage == KeyStorageState.incomplete) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _turnOffKeyStorage,
            child: const Text('Finish turning off key storage'),
          ),
        ],
        Divider(height: 30, color: p.stroke),
        // Recovery.
        Text('Recovery', style: title()),
        const SizedBox(height: 2),
        Text(
          o.recoverySetUp
              ? 'Your recovery key restores your digital identity and key '
                    'storage if you lose access to all your devices.'
              : 'Set up recovery to keep your digital identity and chat '
                    'history if you lose all your devices.',
          style: muted,
        ),
        const SizedBox(height: 10),
        if (o.setupAvailability == CryptoSetupAvailability.create)
          FilledButton.icon(
            onPressed: _busy ? null : _setUpRecovery,
            icon: const Icon(Icons.key_rounded),
            label: const Text('Set up recovery'),
          )
        else if (o.canChangeRecoveryKey)
          OutlinedButton.icon(
            onPressed: _busy ? null : _changeRecoveryKey,
            icon: const Icon(Icons.key_rounded),
            label: const Text('Change recovery key'),
          )
        else
          Text(
            'Recovery can’t be changed until your identity is complete on '
            'this account.',
            style: muted,
          ),
        if (_keyTransfer case final transfer?) ...[
          Divider(height: 30, color: p.stroke),
          // Manual room key export/import (Element Web's Cryptography panel).
          Text('Room keys', style: title()),
          const SizedBox(height: 2),
          Text(
            'Keep a passphrase-protected copy of your message keys, or bring '
            'in keys exported from Element or another Matrix app.',
            style: muted,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.file_upload_outlined, color: p.secondary),
            title: Text(
              'Export room keys',
              style: TextStyle(
                color: p.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text('Save them to an encrypted file', style: muted),
            onTap: _busy ? null : () => _exportRoomKeys(transfer),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.file_download_outlined, color: p.secondary),
            title: Text(
              'Import room keys',
              style: TextStyle(
                color: p.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text('Restore keys from an exported file', style: muted),
            onTap: _busy ? null : () => _importRoomKeys(transfer),
          ),
        ],
        Divider(height: 30, color: p.stroke),
        // Reset.
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.restart_alt_rounded, color: error),
          title: Text(
            'Reset digital identity',
            style: TextStyle(color: error, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            'Only if you’ve lost your recovery key and every verified device.',
            style: muted,
          ),
          onTap: _busy ? null : _reset,
        ),
      ],
    );
  }
}

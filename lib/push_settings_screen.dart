import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'push_notifications.dart';

/// Edits client configuration only, never gateway/server credentials. The app
/// owns [notifications]; leaving this route must not dispose the shared owner.
class PushSettingsScreen extends StatefulWidget {
  const PushSettingsScreen({super.key, required this.notifications});
  final PushNotifications notifications;

  @override
  State<PushSettingsScreen> createState() => _PushSettingsScreenState();
}

class _PushSettingsScreenState extends State<PushSettingsScreen> {
  late final TextEditingController _gateway;
  late final TextEditingController _matrixAppId;
  late final TextEditingController _apiKey;
  late final TextEditingController _firebaseAppId;
  late final TextEditingController _sender;
  late final TextEditingController _project;
  bool _actionBusy = false;

  @override
  void initState() {
    super.initState();
    final config = widget.notifications.configuration;
    _gateway = TextEditingController(text: config.gatewayUrl?.toString() ?? '');
    _matrixAppId = TextEditingController(text: config.appId);
    _apiKey = TextEditingController(text: config.firebaseOptions?.apiKey ?? '');
    _firebaseAppId = TextEditingController(
      text: config.firebaseOptions?.appId ?? '',
    );
    _sender = TextEditingController(
      text: config.firebaseOptions?.messagingSenderId ?? '',
    );
    _project = TextEditingController(
      text: config.firebaseOptions?.projectId ?? '',
    );
  }

  @override
  void dispose() {
    for (final controller in [
      _gateway,
      _matrixAppId,
      _apiKey,
      _firebaseAppId,
      _sender,
      _project,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Push cleanup failed. Retry before signing out.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _toggle(bool enabled) => _run(() async {
    final notifications = widget.notifications;
    if (!enabled) {
      await notifications.disable();
      return;
    }
    // Missing configuration/account cannot cause even a permission prompt.
    if (notifications.configurationIssues.isNotEmpty ||
        !notifications.hasSession) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Save your complete HTTPS gateway/Firebase configuration and sign in before enabling push.',
          ),
        ),
      );
      return;
    }
    final consentRevision = notifications.consentRevision;
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Enable push with your own services?'),
        content: const Text(
          'Your Matrix homeserver will send event/room identifiers and a device push token '
          'to your configured gateway. That gateway uses your matching Firebase project '
          'and Google FCM to deliver notifications.\n\n'
          'Only generic alerts are displayed; no sender names or message previews. '
          'Your gateway must send data-only payloads and echo the registration ID. '
          'Never use a friend’s service without authorization.\n\n'
          'Continue only if you own or are authorized to use this gateway and Firebase project. '
          'Android will also ask for notification permission. Live delivery is unverified.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep off'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('I agree — enable'),
          ),
        ],
      ),
    );
    if (!mounted ||
        consent != true ||
        consentRevision != notifications.consentRevision) {
      return;
    }
    await notifications.enable(consent: true);
  });

  Future<void> _save() => _run(
    () => widget.notifications.configure(
      PushConfiguration(
        gatewayUrl: Uri.tryParse(_gateway.text.trim()),
        appId: _matrixAppId.text.trim(),
        firebaseOptions: FirebaseOptions(
          apiKey: _apiKey.text.trim(),
          appId: _firebaseAppId.text.trim(),
          messagingSenderId: _sender.text.trim(),
          projectId: _project.text.trim(),
        ),
      ),
    ),
  );

  Widget _field(
    String label,
    TextEditingController controller,
    bool enabled, {
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Push notifications')),
    body: ListenableBuilder(
      listenable: widget.notifications,
      builder: (context, _) {
        final notifications = widget.notifications;
        final editable =
            !notifications.enabled && !notifications.busy && !_actionBusy;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable push notifications'),
              subtitle: const Text(
                'Off by default. Requires your own configured services and consent.',
              ),
              value: notifications.enabled,
              onChanged: _actionBusy ? null : _toggle,
            ),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notifications.active
                            ? 'Registered — delivery unverified'
                            : 'Push is not active',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(notifications.message),
                      if (notifications.busy || _actionBusy) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your gateway and Firebase configuration',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'No service credentials are bundled. Use a gateway you control or are authorized '
              'to use, configured for the same Firebase project. Client identifiers below are not gateway '
              'service-account keys. Configuration alone never enables push.',
            ),
            const SizedBox(height: 16),
            for (final issue in notifications.configurationIssues)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(issue),
              ),
            _field(
              'HTTPS Matrix gateway URL',
              _gateway,
              editable,
              hint: 'https://your-host/_matrix/push/v1/notify',
            ),
            _field(
              'Matrix pusher app ID',
              _matrixAppId,
              editable,
              hint: 'org.yourdomain.parallax',
            ),
            _field('Firebase project ID', _project, editable),
            _field('Firebase messaging sender ID', _sender, editable),
            _field(
              'Firebase Android app ID',
              _firebaseAppId,
              editable,
              hint: '1:sender:android:application',
            ),
            _field('Firebase client API key', _apiKey, editable),
            FilledButton.tonal(
              onPressed: editable ? _save : null,
              child: const Text('Save configuration (keep push off)'),
            ),
            if (notifications.status == PushStatus.error) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _actionBusy
                    ? null
                    : () => _run(notifications.disable),
                child: const Text('Retry push cleanup'),
              ),
            ],
            const SizedBox(height: 20),
            const Text(
              'Android only. Permission is not proof of delivery. A live test with your own '
              'Firebase project, gateway and Matrix account is still required. Configuration is kept for '
              'this app session; foreground restarts and account changes require enabling again. '
              'Background alerts are generic and stale notification taps are discarded.',
            ),
          ],
        );
      },
    ),
  );
}

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'features/platform/background_connection.dart';
import 'features/platform/unified_push.dart';
import 'features/platform/windows_bootstrap.dart';
import 'push_notifications.dart';

/// Edits client configuration only, never gateway/server credentials. The app
/// owns [notifications]; leaving this route must not dispose the shared owner.
class PushSettingsScreen extends StatefulWidget {
  const PushSettingsScreen({
    super.key,
    required this.notifications,
    this.connection = const MethodChannelBackgroundConnection(),
  });
  final PushNotifications notifications;

  /// Battery optimisation state for the built-in delivery (fake in tests).
  final BackgroundConnectionPlatform connection;

  @override
  State<PushSettingsScreen> createState() => _PushSettingsScreenState();
}

class _PushSettingsScreenState extends State<PushSettingsScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _gateway;
  late final TextEditingController _matrixAppId;
  late final TextEditingController _apiKey;
  late final TextEditingController _firebaseAppId;
  late final TextEditingController _sender;
  late final TextEditingController _project;
  late final TextEditingController _unifiedPushGateway;
  late PushProvider _provider;
  String? _distributor;
  Future<List<String>>? _distributors;
  Future<bool>? _batteryExempt;
  bool _actionBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _batteryExempt = widget.connection.isIgnoringBatteryOptimizations();
    final config = widget.notifications.configuration;
    final firebase = config.isUnifiedPush ? null : config;
    // UnifiedPush and the Firebase driver are Android-only; Apple platforms
    // always use the built-in in-app connection.
    _provider = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? config.provider
        : PushProvider.inApp;
    _gateway = TextEditingController(
      text: firebase?.gatewayUrl?.toString() ?? '',
    );
    _matrixAppId = TextEditingController(text: firebase?.appId ?? '');
    _apiKey = TextEditingController(
      text: firebase?.firebaseOptions?.apiKey ?? '',
    );
    _firebaseAppId = TextEditingController(
      text: firebase?.firebaseOptions?.appId ?? '',
    );
    _sender = TextEditingController(
      text: firebase?.firebaseOptions?.messagingSenderId ?? '',
    );
    _project = TextEditingController(
      text: firebase?.firebaseOptions?.projectId ?? '',
    );
    _unifiedPushGateway = TextEditingController(
      text: config.isUnifiedPush ? config.gatewayUrl?.toString() ?? '' : '',
    );
    _distributor = config.isUnifiedPush ? config.distributor : null;
    // Also used by the built-in section to suggest ntfy.
    _loadDistributors();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Android's battery prompt, settings or the Play Store.
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {
        _batteryExempt = widget.connection.isIgnoringBatteryOptimizations();
        _loadDistributors();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in [
      _gateway,
      _matrixAppId,
      _apiKey,
      _firebaseAppId,
      _sender,
      _project,
      _unifiedPushGateway,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _loadDistributors() {
    _distributors = widget.notifications.unifiedPushDistributors();
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

  PushConfiguration _firebaseConfiguration() => PushConfiguration(
    gatewayUrl: Uri.tryParse(_gateway.text.trim()),
    appId: _matrixAppId.text.trim(),
    firebaseOptions: FirebaseOptions(
      apiKey: _apiKey.text.trim(),
      appId: _firebaseAppId.text.trim(),
      messagingSenderId: _sender.text.trim(),
      projectId: _project.text.trim(),
    ),
  );

  PushConfiguration _unifiedPushConfiguration() {
    final gateway = _unifiedPushGateway.text.trim();
    return PushConfiguration.unifiedPush(
      // An unparsable URL becomes an invalid one so the issue is shown.
      gatewayUrl: gateway.isEmpty
          ? null
          : Uri.tryParse(gateway) ?? Uri(scheme: 'invalid'),
      distributor: _distributor,
    );
  }

  bool _matchesUnifiedPush(PushConfiguration current) {
    final desired = _unifiedPushConfiguration();
    return current.isUnifiedPush &&
        current.distributor == desired.distributor &&
        current.gatewayUrl == desired.gatewayUrl;
  }

  Future<void> _selectProvider(PushProvider provider) async {
    if (provider == _provider) return;
    setState(() {
      _provider = provider;
      if (provider == PushProvider.unifiedPush) _loadDistributors();
    });
    await _run(() async {
      final notifications = widget.notifications;
      // Remembered: the app starts with this choice next time.
      if (provider != PushProvider.firebase) {
        await InAppNotificationPreferences.setDelivery(
          provider == PushProvider.inApp
              ? NotificationDelivery.builtIn
              : NotificationDelivery.unifiedPush,
        );
      }
      await notifications.configure(switch (provider) {
        PushProvider.inApp => const PushConfiguration.inApp(),
        PushProvider.unifiedPush => _unifiedPushConfiguration(),
        PushProvider.firebase => _firebaseConfiguration(),
      });
      await _startWithoutConsent();
    });
  }

  Future<void> _selectDistributor(String distributor) async {
    setState(() => _distributor = distributor);
    await _run(() async {
      await widget.notifications.configure(_unifiedPushConfiguration());
      await _startWithoutConsent();
    });
  }

  /// The built-in connection and UnifiedPush need no consent: they turn on
  /// unless notifications were turned off on this device. UnifiedPush waits
  /// for an installed distributor.
  Future<void> _startWithoutConsent() async {
    final notifications = widget.notifications;
    if (_provider == PushProvider.firebase ||
        !notifications.hasSession ||
        notifications.enabled ||
        await InAppNotificationPreferences.turnedOff()) {
      return;
    }
    if (_provider == PushProvider.unifiedPush &&
        (await notifications.unifiedPushDistributors()).isEmpty) {
      return;
    }
    await notifications.enable(consent: true);
  }

  Future<void> _toggle(bool enabled) => _run(() async {
    final notifications = widget.notifications;
    if (_provider != PushProvider.firebase) {
      await InAppNotificationPreferences.setTurnedOff(!enabled);
      if (!enabled) {
        await notifications.disable();
        return;
      }
      if (_provider == PushProvider.inApp &&
          !notifications.configuration.isInApp) {
        await notifications.configure(const PushConfiguration.inApp());
      }
      if (_provider == PushProvider.unifiedPush &&
          !_matchesUnifiedPush(notifications.configuration)) {
        await notifications.configure(_unifiedPushConfiguration());
      }
      if (!notifications.hasSession) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Sign in before turning on notifications.'),
            ),
          );
        }
        return;
      }
      await notifications.enable(consent: true);
      return;
    }
    if (!enabled) {
      await notifications.disable();
      return;
    }
    // Your own Firebase project and gateway: explicit consent first.
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
          'No message content passes through them: Parallax fetches and decrypts each '
          'notified message on this device to show the sender, text and media previews '
          '(hide content under Settings → Notifications). '
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

  Future<void> _save() =>
      _run(() => widget.notifications.configure(_firebaseConfiguration()));

  Future<void> _saveUnifiedPush() => _run(() async {
    await widget.notifications.configure(_unifiedPushConfiguration());
    await _startWithoutConsent();
  });

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

  List<Widget> _firebaseSection(
    PushNotifications notifications,
    bool editable,
  ) => [
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
      Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(issue)),
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
  ];

  Widget _distributorList(bool editable) => FutureBuilder<List<String>>(
    future: _distributors,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Looking for UnifiedPush distributors…'),
        );
      }
      final installed = snapshot.data ?? const <String>[];
      final refresh = TextButton.icon(
        onPressed: editable ? () => setState(_loadDistributors) : null,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Refresh'),
      );
      if (installed.isEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No UnifiedPush distributor found. Install one, such as ntfy, '
              'connect it to its server, then refresh.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => unawaited(
                    launchUrl(
                      unifiedPushDistributorsUrl,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Find a distributor'),
                ),
                refresh,
              ],
            ),
          ],
        );
      }
      final selected =
          _distributor ?? (installed.length == 1 ? installed.single : null);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final distributor in installed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              enabled: editable,
              selected: distributor == selected,
              leading: Icon(
                distributor == selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
              ),
              title: Text(unifiedPushDistributorLabel(distributor)),
              subtitle: Text(distributor),
              onTap: () => unawaited(_selectDistributor(distributor)),
            ),
          Align(alignment: Alignment.centerLeft, child: refresh),
        ],
      );
    },
  );

  List<Widget> _inAppSection() => [
    const Text(
      'Built into Parallax',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 8),
    const Text(
      'Parallax stays connected to your homeserver in the background and '
      'shows new messages itself, like Element does but without Google, a '
      'push gateway or another app. Messages are fetched and decrypted on '
      'this device.',
    ),
    const SizedBox(height: 8),
    FutureBuilder<List<String>>(
      future: _distributors,
      builder: (context, snapshot) {
        final installed = snapshot.data;
        if (installed == null || installed.isNotEmpty) {
          return const SizedBox.shrink();
        }
        return ListTile(
          key: const ValueKey('push.get_ntfy'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_rounded),
          title: const Text('Get push through ntfy'),
          subtitle: const Text(
            'Install ntfy from Google Play and open it once. Parallax then '
            'uses it automatically, with no ongoing notification and less '
            'battery use.',
          ),
          trailing: TextButton(
            onPressed: () => unawaited(
              launchUrl(ntfyPlayStoreUrl, mode: LaunchMode.externalApplication),
            ),
            child: const Text('Get ntfy'),
          ),
        );
      },
    ),
    FutureBuilder<bool>(
      future: _batteryExempt,
      builder: (context, snapshot) {
        final exempt = snapshot.data ?? false;
        return ListTile(
          key: const ValueKey('push.battery'),
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            exempt ? Icons.battery_full_rounded : Icons.battery_alert_rounded,
          ),
          title: const Text('Background activity'),
          subtitle: Text(
            exempt
                ? 'Allowed. Android won’t stop the connection to save battery.'
                : 'Android may pause Parallax to save battery, which can '
                      'delay notifications. Allow background activity to '
                      'keep them on time.',
          ),
          trailing: exempt
              ? null
              : TextButton(
                  onPressed: () => unawaited(
                    widget.connection.requestIgnoreBatteryOptimizations(),
                  ),
                  child: const Text('Allow'),
                ),
        );
      },
    ),
  ];

  List<Widget> _unifiedPushSection(
    PushNotifications notifications,
    bool editable,
  ) => [
    const Text(
      'UnifiedPush distributor',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 8),
    const Text(
      'UnifiedPush delivers notifications through a distributor app you '
      'choose, such as ntfy, instead of Google. Parallax registers with it '
      'automatically, then checks its server for a Matrix gateway, as '
      'Element X does.',
    ),
    const SizedBox(height: 8),
    _distributorList(editable),
    const SizedBox(height: 12),
    for (final issue in notifications.configurationIssues)
      Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(issue)),
    _field(
      'Matrix gateway URL (optional)',
      _unifiedPushGateway,
      editable,
      hint: 'Leave empty to use your distributor’s gateway',
    ),
    FilledButton.tonal(
      onPressed: editable ? _saveUnifiedPush : null,
      child: const Text('Save UnifiedPush settings'),
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notifications on this device')),
    body: ListenableBuilder(
      listenable: widget.notifications,
      builder: (context, _) {
        final notifications = widget.notifications;
        final editable =
            !notifications.enabled && !notifications.busy && !_actionBusy;
        final androidDelivery =
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
        final unifiedPush = _provider == PushProvider.unifiedPush;
        final inApp = _provider == PushProvider.inApp;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SwitchListTile(
              key: const ValueKey('push.enable'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                inApp || unifiedPush
                    ? 'Notifications on this device'
                    : 'Enable push notifications',
              ),
              subtitle: Text(
                inApp || unifiedPush
                    ? 'On by default. Turn off to stop notifications on this device.'
                    : 'Off by default. Requires your own configured services and consent.',
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
                        inApp || unifiedPush
                            ? (notifications.active
                                  ? 'Notifications are on'
                                  : 'Notifications are off')
                            : notifications.active
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
              'How notifications arrive',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (!androidDelivery)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    isWindowsDesktop
                        ? 'Built-in connection: Parallax keeps its own Matrix '
                              'sync running and shows notifications fetched and '
                              'decrypted on this device. It keeps running in the '
                              'notification area when you close the window. '
                              'UnifiedPush and Firebase delivery are Android-only.'
                        : 'Built-in connection: Parallax keeps its own Matrix sync '
                              'running and shows notifications fetched and decrypted '
                              'on this device. On iPhone, iPad and Mac this works while '
                              'Parallax is running; iOS does not allow the persistent '
                              'background connection Android uses. UnifiedPush and '
                              'Firebase delivery are Android-only for now.',
                  ),
                ),
              )
            else ...[
              SegmentedButton<PushProvider>(
                segments: const [
                  ButtonSegment(
                    value: PushProvider.inApp,
                    icon: Icon(Icons.sync_rounded),
                    label: Text('Built in'),
                  ),
                  ButtonSegment(
                    value: PushProvider.firebase,
                    icon: Icon(Icons.cloud_outlined),
                    label: Text('Firebase'),
                  ),
                  ButtonSegment(
                    value: PushProvider.unifiedPush,
                    icon: Icon(Icons.hub_outlined),
                    label: Text('UnifiedPush'),
                  ),
                ],
                selected: {_provider},
                // Switching turns the current delivery off first.
                onSelectionChanged: !notifications.busy && !_actionBusy
                    ? (selection) => unawaited(_selectProvider(selection.first))
                    : null,
              ),
              const SizedBox(height: 16),
              if (inApp)
                ..._inAppSection()
              else if (unifiedPush)
                ..._unifiedPushSection(notifications, editable)
              else
                ..._firebaseSection(notifications, editable),
            ],
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
            Text(
              !androidDelivery
                  ? (isWindowsDesktop
                        ? 'Parallax keeps its Matrix connection running while the '
                              'app is open, and keeps running in the notification '
                              'area when you close the window, so notifications '
                              'still arrive. Use the tray icon’s Quit to stop it '
                              'completely. Notifications show content fetched and '
                              'decrypted on this device; you can hide it under '
                              'Settings → Notifications.'
                        : 'Notifications show content fetched and decrypted on this '
                              'device; you can hide it under Settings → Notifications. '
                              'While Parallax is closed, new messages appear when you '
                              'next open it.')
                  : inApp
                  ? 'Android shows a small “Parallax is connected” notification '
                        'while the connection runs; you can hide it in Android’s '
                        'notification settings without stopping it. Some phone '
                        'makers stop background apps anyway. Notifications show '
                        'content fetched and decrypted on this device; you can '
                        'hide it under Settings → Notifications.'
                  : unifiedPush
                  ? 'Parallax uses UnifiedPush automatically when a distributor '
                        'app such as ntfy is installed, and its built-in '
                        'connection otherwise or if UnifiedPush can’t start. Your '
                        'homeserver sends only room and event IDs through your '
                        'distributor’s server and its Matrix gateway (or the '
                        'UnifiedPush project’s public gateway when it has none); '
                        'Parallax fetches and decrypts each message on this device.'
                  : 'Android only. Permission is not proof of delivery. A live test with your own '
                        'Firebase project, gateway and Matrix account is still required. Configuration is kept for '
                        'this app session; foreground restarts and account changes require enabling again. '
                        'Notifications show content fetched on this device, falling back to a generic alert '
                        'when it can’t be decrypted in time; stale notification taps are discarded.',
            ),
          ],
        );
      },
    ),
  );
}

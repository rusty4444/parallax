import 'package:flutter/material.dart';

import 'chat_backend.dart';

/// Keeps incoming verification and send-time trust decisions visible on any route.
class SecurityOverlay extends StatelessWidget {
  const SecurityOverlay({
    super.key,
    required this.backend,
    required this.child,
  });

  final ChatBackend backend;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: backend,
    builder: (context, _) {
      final verification = backend.verification;
      final trust = backend.trustWarning;
      if (verification == null && trust == null) return child;
      return PopScope(
        canPop: false,
        child: Stack(
          children: [
            child,
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black87,
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: verification != null
                            ? _VerificationCard(
                                key: ValueKey(verification.id),
                                backend: backend,
                                details: verification,
                              )
                            : _TrustCard(backend: backend, warning: trust!),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _VerificationCard extends StatefulWidget {
  const _VerificationCard({
    super.key,
    required this.backend,
    required this.details,
  });

  final ChatBackend backend;
  final VerificationDetails details;

  @override
  State<_VerificationCard> createState() => _VerificationCardState();
}

class _VerificationCardState extends State<_VerificationCard> {
  final _secret = TextEditingController();
  bool _showNumbers = false;
  String? _localError;

  @override
  void dispose() {
    _secret.clear();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _localError = null);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => _localError = 'This step failed. Try again or cancel.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final details = widget.details;
    final busy = details.busy;
    final stage = details.stage;
    final useNumbers = _showNumbers || details.emojis.isEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Verify identity',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            SelectableText(
              details.userId,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (details.deviceId != null && details.deviceId != '*')
              SelectableText('Device: ${details.deviceId}'),
            const SizedBox(height: 18),
            switch (stage) {
              VerificationStage.accept => const Text(
                'This device received a verification request. Only accept if you '
                'started it on another device or are speaking to this person now.',
              ),
              VerificationStage.waiting => const Text(
                'Waiting for the other device. Keep both clients open. '
                'Do not confirm until you can compare the codes on both screens.',
              ),
              VerificationStage.choose => const Text(
                'Start a short authentication string comparison on both devices.',
              ),
              VerificationStage.compare => _comparison(details, useNumbers),
              VerificationStage.secret => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Unlock your existing recovery key or passphrase to sign the '
                    'verified keys. This is not sent to the other device.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _secret,
                    onChanged: (_) => setState(() {}),
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Recovery key or passphrase',
                    ),
                  ),
                ],
              ),
              VerificationStage.done => Text(
                details.secretSkipped
                    ? 'The comparison completed, but signing was skipped. '
                          'Some keys may remain unverified on other devices.'
                    : 'Verification completed. The devices agreed on their keys.',
              ),
              VerificationStage.error => Text(
                'Verification did not complete${details.error == null ? '.' : ': ${details.error}'} '
                'Do not treat this device as verified.',
              ),
            },
            if (_localError != null ||
                (stage != VerificationStage.error &&
                    details.error != null)) ...[
              const SizedBox(height: 10),
              Text(
                _localError ?? details.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (busy) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
            const SizedBox(height: 18),
            if (stage == VerificationStage.accept)
              FilledButton(
                onPressed: busy
                    ? null
                    : () => _run(widget.backend.acceptVerification),
                child: const Text('Accept request'),
              ),
            if (stage == VerificationStage.choose)
              FilledButton(
                onPressed: busy
                    ? null
                    : () => _run(widget.backend.chooseEmojiVerification),
                child: const Text('Compare emoji or numbers'),
              ),
            if (stage == VerificationStage.compare &&
                (details.emojis.length == 7 ||
                    details.numbers.length == 3)) ...[
              FilledButton(
                onPressed: busy
                    ? null
                    : () => _run(
                        () => widget.backend.confirmVerification(matches: true),
                      ),
                child: const Text('They match exactly'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _run(
                        () =>
                            widget.backend.confirmVerification(matches: false),
                      ),
                child: const Text('They do not match'),
              ),
            ],
            if (stage == VerificationStage.secret) ...[
              FilledButton(
                onPressed: busy || _secret.text.isEmpty
                    ? null
                    : () => _run(() async {
                        await widget.backend.unlockVerification(_secret.text);
                        _secret.clear();
                      }),
                child: const Text('Unlock and sign'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => _run(widget.backend.skipVerificationSigning),
                child: const Text('Continue without signing'),
              ),
            ],
            if (stage == VerificationStage.done ||
                stage == VerificationStage.error)
              FilledButton(
                onPressed: busy
                    ? null
                    : () => _run(widget.backend.cancelVerification),
                child: const Text('Close'),
              )
            else
              TextButton(
                onPressed: busy
                    ? null
                    : () => _run(widget.backend.cancelVerification),
                child: const Text('Cancel verification'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _comparison(VerificationDetails details, bool useNumbers) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Compare these on BOTH devices, in the same order. If even one differs, '
        'choose “They do not match”. Never confirm based only on a screenshot or message.',
      ),
      const SizedBox(height: 16),
      if (useNumbers && details.numbers.length == 3)
        SelectableText(
          details.numbers.join('  '),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 27, fontWeight: FontWeight.bold),
        )
      else if (!useNumbers && details.emojis.length == 7)
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final emoji in details.emojis)
              SizedBox(
                width: 78,
                child: Column(
                  children: [
                    Text(emoji.symbol, style: const TextStyle(fontSize: 30)),
                    Text(
                      emoji.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
          ],
        )
      else
        const Text('No comparison code available. Cancel and try again.'),
      if (details.emojis.length == 7 && details.numbers.length == 3)
        TextButton(
          onPressed: () => setState(() => _showNumbers = !_showNumbers),
          child: Text(
            useNumbers ? 'Show emoji instead' : 'Show numbers instead',
          ),
        ),
    ],
  );
}

class _TrustCard extends StatelessWidget {
  const _TrustCard({required this.backend, required this.warning});

  final ChatBackend backend;
  final TrustWarning warning;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Unverified recipients',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          SelectableText('Room: ${warning.roomId}'),
          const SizedBox(height: 10),
          const Text(
            'This encrypted room includes identities you have not verified. '
            'Encryption alone does not prove who controls their keys. '
            'To verify first, choose Do not send, verify a participant from '
            'the room, then retry. '
            'Continuing trusts the displayed keys on first use; missing keys '
            'cannot be trusted and will prompt again.',
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 230),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final recipient in warning.recipients)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(recipient.userId),
                    subtitle: SelectableText(
                      recipient.masterKey ??
                          'No cross-signing master key available',
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: () => backend.respondToTrustWarning(false),
            child: const Text('Do not send'),
          ),
          TextButton(
            onPressed: () => backend.respondToTrustWarning(true),
            child: const Text('Send without verification'),
          ),
        ],
      ),
    ),
  );
}

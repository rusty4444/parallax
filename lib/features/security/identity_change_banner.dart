import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import 'security_features.dart';
import 'security_ui.dart';

/// Element X IdentityChangeState: warns under the room header when a member's
/// digital identity was reset since this device pinned (or verified) it.
class IdentityChangeBanner extends StatefulWidget {
  const IdentityChangeBanner({
    super.key,
    required this.backend,
    required this.security,
    required this.roomId,
    required this.palette,
    this.openUrl,
  });

  final ChatBackend backend;
  final SecurityFeatures security;
  final String roomId;
  final AppPalette palette;
  final ExternalUrlOpener? openUrl;

  @override
  State<IdentityChangeBanner> createState() => _IdentityChangeBannerState();
}

class _IdentityChangeBannerState extends State<IdentityChangeBanner> {
  final _busy = <String>{};
  final _gestures = <TapGestureRecognizer>[];

  /// Checking a room walks its members' identities (up to 500 in a large
  /// group). The backend notifies up to once a frame while a room is busy,
  /// so its notifications re-check at most every [_backendInterval];
  /// security changes and this banner's own actions re-check at once.
  static const _backendInterval = Duration(milliseconds: 500);
  List<IdentityChange> _changes = const [];
  Timer? _cooldown;
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    _subscribe(widget);
    _changes = _read();
  }

  @override
  void didUpdateWidget(IdentityChangeBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend) ||
        !identical(oldWidget.security, widget.security)) {
      _unsubscribe(oldWidget);
      _subscribe(widget);
    }
    _changes = _read();
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    _unsubscribe(widget);
    for (final gesture in _gestures) {
      gesture.dispose();
    }
    super.dispose();
  }

  void _subscribe(IdentityChangeBanner w) {
    w.backend.addListener(_backendChanged);
    w.security.securityChanges.addListener(_refresh);
  }

  void _unsubscribe(IdentityChangeBanner w) {
    w.backend.removeListener(_backendChanged);
    w.security.securityChanges.removeListener(_refresh);
  }

  List<IdentityChange> _read() =>
      widget.security.identityChanges(widget.roomId);

  void _refresh() {
    if (!mounted) return;
    final next = _read();
    if (_sameChanges(next, _changes)) return;
    setState(() => _changes = next);
  }

  void _backendChanged() {
    if (_cooldown?.isActive ?? false) {
      _pending = true;
      return;
    }
    _refresh();
    _cooldown = Timer(_backendInterval, () {
      if (_pending) {
        _pending = false;
        _refresh();
      }
    });
  }

  static bool _sameChanges(List<IdentityChange> a, List<IdentityChange> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].userId != b[i].userId ||
          a[i].displayName != b[i].displayName ||
          a[i].trust.level != b[i].trust.level ||
          a[i].trust.masterKey != b[i].trust.masterKey) {
        return false;
      }
    }
    return true;
  }

  Future<void> _act(
    IdentityChange change,
    Future<void> Function() action,
    String failure,
  ) async {
    if (_busy.contains(change.userId)) return;
    setState(() => _busy.add(change.userId));
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await action();
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(failure)));
    } finally {
      if (mounted) {
        setState(() {
          _busy.remove(change.userId);
          _changes = _read();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final changes = _changes;
    if (changes.isEmpty) return const SizedBox.shrink();
    return _banner(context, changes.first, changes.length - 1);
  }

  Widget _banner(BuildContext context, IdentityChange change, int others) {
    final p = widget.palette;
    final critical = change.trust.level == UserTrustLevel.verificationViolation;
    final colour = critical ? Theme.of(context).colorScheme.error : p.accent;
    final busy = _busy.contains(change.userId);
    final masterKey = change.trust.masterKey;
    for (final gesture in _gestures) {
      gesture.dispose();
    }
    _gestures.clear();
    final learnMore = TapGestureRecognizer()
      ..onTap = () => unawaited(
        (widget.openUrl ?? openExternalHttpsUrl)(identityChangeHelpUrl),
      );
    _gestures.add(learnMore);
    final name = change.displayName.trim().isEmpty
        ? change.userId
        : change.displayName.trim();
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colour.withValues(alpha: 0.75)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  critical ? Icons.gpp_bad_outlined : Icons.info_outline,
                  color: colour,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: TextStyle(color: p.foreground, height: 1.35),
                      children: [
                        TextSpan(text: '$name’s '),
                        TextSpan(
                          text: '(${change.userId})',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(
                          text: critical
                              ? ' verified digital identity was reset. '
                              : ' digital identity was reset. ',
                        ),
                        TextSpan(
                          text: 'Learn more',
                          recognizer: learnMore,
                          style: TextStyle(
                            color: p.foreground,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        if (others > 0)
                          TextSpan(
                            text: others == 1
                                ? '\n1 other person’s identity also changed.'
                                : '\n$others other people’s identities also '
                                      'changed.',
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _act(
                          change,
                          () => widget.security.verifyUser(change.userId),
                          'Couldn’t start verification. Try again.',
                        ),
                  child: Text(critical ? 'Verify again' : 'Verify'),
                ),
                FilledButton(
                  style: critical
                      ? FilledButton.styleFrom(
                          backgroundColor: colour,
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onError,
                        )
                      : null,
                  onPressed: busy || masterKey == null
                      ? null
                      : () => _act(
                          change,
                          () => widget.security.acknowledgeIdentityChange(
                            change.userId,
                            masterKey,
                          ),
                          'Couldn’t update this identity. Review it again.',
                        ),
                  child: Text(critical ? 'Withdraw verification' : 'Dismiss'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_theme.dart';
import 'app_lock_controller.dart';

/// Four PIN dots and a numeric keypad (no text field, so no keyboard history
/// or clipboard). Calls [onCompleted] once all digits are entered.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.palette,
    required this.onCompleted,
    this.enabled = true,
    this.onBiometric,
  });

  final AppPalette palette;
  final Future<void> Function(String pin) onCompleted;
  final bool enabled;
  final VoidCallback? onBiometric;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';
  bool _submitting = false;

  Future<void> _digit(String digit) async {
    if (!widget.enabled ||
        _submitting ||
        _pin.length >= AppLockConfig.pinLength) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _pin += digit);
    if (_pin.length < AppLockConfig.pinLength) return;
    final value = _pin;
    setState(() => _submitting = true);
    try {
      await widget.onCompleted(value);
    } finally {
      if (mounted) {
        setState(() {
          _pin = '';
          _submitting = false;
        });
      }
    }
  }

  void _backspace() {
    if (_pin.isEmpty || _submitting) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    Widget key(String digit) => _PadButton(
      palette: p,
      semanticLabel: digit,
      onTap: () => _digit(digit),
      child: Text(
        digit,
        style: TextStyle(
          color: p.foreground,
          fontSize: 28,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${_pin.length} of ${AppLockConfig.pinLength} digits entered',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < AppLockConfig.pinLength; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: const EdgeInsets.symmetric(horizontal: 9),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? p.accent : Colors.transparent,
                    border: Border.all(
                      color: i < _pin.length ? p.accent : p.muted,
                      width: 2,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final digit in row) key(digit)],
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.onBiometric == null
                ? const SizedBox(width: 92, height: 76)
                : _PadButton(
                    palette: p,
                    semanticLabel: 'Use biometric',
                    onTap: widget.onBiometric!,
                    child: Icon(
                      Icons.fingerprint_rounded,
                      color: p.secondary,
                      size: 32,
                    ),
                  ),
            key('0'),
            _PadButton(
              palette: p,
              semanticLabel: 'Delete digit',
              onTap: _backspace,
              child: Icon(Icons.backspace_outlined, color: p.muted),
            ),
          ],
        ),
      ],
    );
  }
}

class _PadButton extends StatelessWidget {
  const _PadButton({
    required this.palette,
    required this.onTap,
    required this.child,
    required this.semanticLabel,
  });
  final AppPalette palette;
  final VoidCallback onTap;
  final Widget child;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: Material(
        color: palette.surface,
        shape: const CircleBorder(),
        child: InkWell(
          key: ValueKey('pin-key-$semanticLabel'),
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 76, height: 60, child: Center(child: child)),
        ),
      ),
    ),
  );
}

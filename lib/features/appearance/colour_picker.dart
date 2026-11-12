import 'package:flutter/material.dart';

import 'bubble_colours.dart';

/// Swatches plus hue, saturation and brightness sliders and a hex field.
/// [value] null means "theme default"/"automatic", offered as [defaultLabel].
class ColourPicker extends StatefulWidget {
  const ColourPicker({
    super.key,
    required this.value,
    required this.fallback,
    required this.onChanged,
    required this.defaultLabel,
    this.swatches = bubbleSwatches,
  });

  final Color? value;

  /// Shown for the default choice and as the sliders' start point.
  final Color fallback;
  final ValueChanged<Color?> onChanged;
  final String defaultLabel;
  final List<Color> swatches;

  @override
  State<ColourPicker> createState() => _ColourPickerState();
}

/// Bubble presets: Messenger-like blues and purples, greens, warm tones,
/// neutrals.
const bubbleSwatches = [
  Color(0xFF0A7CFF),
  Color(0xFF0084FF),
  Color(0xFF5B5FE3),
  Color(0xFF8E44EC),
  Color(0xFFC13584),
  Color(0xFFE5395F),
  Color(0xFFFF5A36),
  Color(0xFFF2994A),
  Color(0xFFF2C94C),
  Color(0xFF27AE60),
  Color(0xFF00A884),
  Color(0xFF128C7E),
  Color(0xFF2D9CDB),
  Color(0xFF34495E),
  Color(0xFF3A3B3C),
  Color(0xFFE4E6EB),
  Color(0xFFFFFFFF),
  Color(0xFF000000),
];

class _ColourPickerState extends State<ColourPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.value ?? widget.fallback);
  late final _hex = TextEditingController(
    text: colourToHex(widget.value ?? widget.fallback),
  );
  String? _hexError;

  @override
  void didUpdateWidget(ColourPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = widget.value ?? widget.fallback;
    if (current != _hsv.toColor()) {
      _hsv = HSVColor.fromColor(current);
      _hex.text = colourToHex(current);
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _hex.text = colourToHex(hsv.toColor());
      _hexError = null;
    });
    widget.onChanged(hsv.toColor());
  }

  Widget _slider({
    required String label,
    required double value,
    required double max,
    required List<Color> track,
    required ValueChanged<double> onChanged,
  }) => Row(
    children: [
      SizedBox(
        width: 82,
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 10,
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: track),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                thumbColor: _hsv.toColor(),
                overlayColor: Colors.white24,
                trackHeight: 10,
              ),
              child: Slider(
                key: ValueKey('colour-$label'),
                value: value.clamp(0, max),
                max: max,
                semanticFormatterCallback: (v) => '$label ${v.round()}',
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final selected = widget.value;
    final scheme = Theme.of(context).colorScheme;
    Widget swatch(Color? colour, {required String tooltip}) {
      final shown = colour ?? widget.fallback;
      final active = colour == selected;
      return Tooltip(
        message: tooltip,
        child: InkResponse(
          key: ValueKey(
            colour == null ? 'swatch-default' : 'swatch-${colourToHex(colour)}',
          ),
          onTap: () {
            widget.onChanged(colour);
            if (colour != null) {
              setState(() {
                _hsv = HSVColor.fromColor(colour);
                _hex.text = colourToHex(colour);
              });
            }
          },
          radius: 22,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: shown,
              shape: BoxShape.circle,
              // A visible ring on every swatch, so black and white ones
              // stand out on any background.
              border: Border.all(
                color: active ? scheme.primary : scheme.outline,
                width: active ? 3 : 1.5,
              ),
            ),
            child: colour == null
                ? Icon(Icons.auto_awesome, size: 16, color: readableOn(shown))
                : active
                ? Icon(Icons.check, size: 18, color: readableOn(shown))
                : null,
          ),
        ),
      );
    }

    final hue = _hsv.hue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            swatch(null, tooltip: widget.defaultLabel),
            for (final colour in widget.swatches)
              swatch(colour, tooltip: colourToHex(colour)),
          ],
        ),
        const SizedBox(height: 16),
        _slider(
          label: 'Hue',
          value: hue,
          max: 360,
          track: [
            for (var h = 0; h <= 360; h += 60)
              HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
          ],
          onChanged: (v) => _set(_hsv.withHue(v)),
        ),
        _slider(
          label: 'Saturation',
          value: _hsv.saturation * 100,
          max: 100,
          track: [
            HSVColor.fromAHSV(1, hue, 0, _hsv.value).toColor(),
            HSVColor.fromAHSV(1, hue, 1, _hsv.value).toColor(),
          ],
          onChanged: (v) => _set(_hsv.withSaturation(v / 100)),
        ),
        _slider(
          label: 'Brightness',
          value: _hsv.value * 100,
          max: 100,
          track: [
            Colors.black,
            HSVColor.fromAHSV(1, hue, _hsv.saturation, 1).toColor(),
          ],
          onChanged: (v) => _set(_hsv.withValue(v / 100)),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('colour-hex'),
          controller: _hex,
          decoration: InputDecoration(
            labelText: 'Hex colour',
            hintText: '#0A7CFF',
            errorText: _hexError,
            prefixIcon: Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: _hsv.toColor(),
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outlineVariant),
                ),
              ),
            ),
          ),
          onSubmitted: (text) {
            final colour = colourFromHex(text);
            if (colour == null) {
              setState(() => _hexError = 'Use #RRGGBB');
              return;
            }
            _set(HSVColor.fromColor(colour));
          },
        ),
      ],
    );
  }
}

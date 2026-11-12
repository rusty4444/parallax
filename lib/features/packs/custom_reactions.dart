import 'pack_model.dart';

/// MSC4027 custom-emoji reactions: the key is an `mxc://` URI and the
/// content carries the shortcode for clients without the pack.
const reactionShortcodeKey = 'com.beeper.reaction.shortcode';

bool isCustomReactionKey(String key) => key.startsWith('mxc://');

/// Whether [key] may be sent as a reaction: a short emoji/text key, or a
/// well-formed `mxc://` URI.
bool isValidReactionKey(String key) {
  if (key.isEmpty) return false;
  if (isCustomReactionKey(key)) return parseMxcUri(key) != null;
  return key.runes.length <= 8;
}

/// Normalises a reaction shortcode to `:code:`, or null when unusable.
String? normaliseReactionShortcode(Object? value) {
  if (value is! String) return null;
  var code = value.trim();
  if (code.length > 2 && code.startsWith(':') && code.endsWith(':')) {
    code = code.substring(1, code.length - 1);
  }
  return isValidShortcode(code) ? ':$code:' : null;
}

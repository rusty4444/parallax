/// Removes the plain-text Matrix reply fallback only for a real reply event.
/// Never remove quoted text from an unrelated message.
String visibleMessageBody(String body, {required bool isReply}) {
  if (!isReply || !body.startsWith('> <@')) return body;
  final separator = body.indexOf('\n\n');
  if (separator < 0) return body;
  final quoted = body.substring(0, separator).split('\n');
  if (quoted.any((line) => !line.startsWith('> '))) return body;
  return body.substring(separator + 2);
}

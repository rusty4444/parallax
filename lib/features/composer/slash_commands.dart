import 'dart:convert';

import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import '../rich_timeline/message_composition.dart';
import 'chat_effects.dart';

/// Element Web-compatible slash commands, applied when a text message is
/// transmitted (the draft and outbox keep the typed text).
@immutable
class SlashCommand {
  const SlashCommand(
    this.name,
    this.description, {
    this.args = '<message>',
    this.requiresMessage = false,
    this.effect,
  });
  final String name;
  final String description;
  final String args;
  final bool requiresMessage;
  final ChatEffect? effect;
}

const _shrug = r'¯\_(ツ)_/¯';
const _tableflip = '(╯°□°）╯︵ ┻━┻';
const _unflip = '┬──┬ ノ( ゜-゜ノ)';
const _lenny = '( ͡° ͜ʖ ͡°)';

const _emoticons = {
  'shrug': _shrug,
  'tableflip': _tableflip,
  'unflip': _unflip,
  'lenny': _lenny,
};

/// Built-in commands offered after typing `/` at the start of the composer.
final List<SlashCommand> slashCommands = [
  const SlashCommand('me', 'Displays action'),
  const SlashCommand('shrug', 'Prepends $_shrug to a plain-text message'),
  const SlashCommand(
    'tableflip',
    'Prepends $_tableflip to a plain-text message',
  ),
  const SlashCommand('unflip', 'Prepends $_unflip to a plain-text message'),
  const SlashCommand('lenny', 'Prepends $_lenny to a plain-text message'),
  const SlashCommand(
    'plain',
    'Sends a message as plain text, without interpreting it as markdown',
  ),
  const SlashCommand(
    'spoiler',
    'Sends the given message as a spoiler',
    requiresMessage: true,
  ),
  for (final effect in chatEffects)
    SlashCommand(effect.command, effect.description, effect: effect),
];

SlashCommand? slashCommandNamed(String name) {
  for (final command in slashCommands) {
    if (command.name == name) return command;
  }
  return null;
}

/// A `/command args` typed at the start of the composer.
@immutable
class ParsedSlashCommand {
  const ParsedSlashCommand(this.name, this.args);

  /// Lower-case command name without the slash.
  final String name;
  final String args;
}

final _commandPattern = RegExp(
  r'^/([A-Za-z][A-Za-z0-9_-]*)(?:[ \t\n]+([\s\S]*))?$',
);

/// Parses a command at the start of [text]; `//text` escapes a slash and
/// paths such as `/usr/bin` are not commands.
ParsedSlashCommand? parseSlashCommand(String text) {
  if (text.startsWith('//')) return null;
  final match = _commandPattern.firstMatch(text);
  if (match == null) return null;
  return ParsedSlashCommand(match[1]!.toLowerCase(), match[2] ?? '');
}

/// A reason not to send [text] as typed, or null. Unknown commands and
/// `/spoiler` without a message are refused in the composer (like Element
/// Web), so a mistyped command is not sent to the room.
String? slashCommandError(String text) {
  final command = parseSlashCommand(text.trim());
  if (command == null) return null;
  final known = slashCommandNamed(command.name);
  if (known == null) {
    return 'Unrecognised command: /${command.name}. '
        'Begin your message with // to start it with a slash.';
  }
  if (known.requiresMessage && command.args.trim().isEmpty) {
    return 'Usage: /${known.name} ${known.args}';
  }
  return null;
}

Map<String, Object?> _plain(Map<String, Object?> content, String body) =>
    Map<String, Object?>.of(content)
      ..['body'] = body
      ..remove('format')
      ..remove('formatted_body');

Map<String, Object?> _formatted(Map<String, Object?> content, String body) {
  final next = _plain(content, body);
  final html = markdownToMatrixHtml(body);
  if (html != null) {
    next['format'] = 'org.matrix.custom.html';
    next['formatted_body'] = html;
  }
  return next;
}

/// Applies slash commands to outgoing text content (see
/// `composerTransformOutgoing`). Edits are never commands. `m.mentions` and
/// other keys derived from the full text are kept.
Map<String, Object?> applySlashCommand(
  OutgoingTextContext ctx,
  Map<String, Object?> content,
) {
  if (ctx.editing) return content;
  final text = ctx.text;
  if (text.startsWith('//')) {
    final body = content['body'];
    if (body is! String || !body.startsWith('//')) return content;
    return _formatted(content, body.substring(1));
  }
  final command = parseSlashCommand(text);
  if (command == null) return content;
  final args = command.args;
  final emoticon = _emoticons[command.name];
  if (emoticon != null) {
    return _plain(content, args.isEmpty ? emoticon : '$emoticon $args')
      ..['msgtype'] = 'm.text';
  }
  switch (command.name) {
    case 'plain':
      return _plain(content, args)..['msgtype'] = 'm.text';
    case 'spoiler':
      if (args.trim().isEmpty) return content;
      final html =
          markdownToMatrixHtml(args) ??
          const HtmlEscape(
            HtmlEscapeMode.element,
          ).convert(args).replaceAll('\n', '<br/>');
      return _plain(content, args)
        ..['msgtype'] = 'm.text'
        ..['format'] = 'org.matrix.custom.html'
        ..['formatted_body'] = '<span data-mx-spoiler>$html</span>';
  }
  final effect = chatEffectForCommand(command.name);
  if (effect != null) {
    if (args.trim().isEmpty) {
      return _plain(content, effect.fallbackMessage)..['msgtype'] = 'm.emote';
    }
    return _formatted(content, args)..['msgtype'] = effect.msgType;
  }
  return content;
}

/// Command suggestions for the text typed after `/`.
List<ComposerSuggestion> slashCommandSuggestions(String query) {
  final needle = query.toLowerCase();
  return [
    for (final command in slashCommands)
      if (command.name.startsWith(needle))
        ComposerSuggestion(
          id: '/${command.name}',
          label: '/${command.name} ${command.args}',
          subtitle: command.description,
          insertText: '/${command.name} ',
          leading: SizedBox(
            width: 32,
            child: Center(
              child: command.effect == null
                  ? const Icon(Icons.keyboard_command_key_rounded, size: 18)
                  : Text(
                      command.effect!.emojis.last,
                      style: const TextStyle(fontSize: 20),
                    ),
            ),
          ),
        ),
  ];
}

/// The built-in `/` source; only offered at the start of the composer.
const slashCommandSourceId = 'composer.slash_commands';

final slashCommandSource = ComposerSuggestionSource(
  id: slashCommandSourceId,
  trigger: '/',
  search: slashCommandSuggestions,
);

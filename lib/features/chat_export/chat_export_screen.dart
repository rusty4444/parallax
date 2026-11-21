import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'chat_export.dart';
import 'chat_export_features.dart';

enum _Format { text, html, zip }

/// Room details → Export chat.
class ChatExportScreen extends StatefulWidget {
  const ChatExportScreen({
    super.key,
    required this.features,
    required this.roomId,
    required this.roomName,
    required this.palette,
  });

  final ChatExportFeatures features;
  final String roomId;
  final String roomName;
  final AppPalette palette;

  @override
  State<ChatExportScreen> createState() => _ChatExportScreenState();
}

class _ChatExportScreenState extends State<ChatExportScreen> {
  _Format _format = _Format.text;
  int _limit = 500;
  bool _busy = false;
  String? _error;

  Future<void> _export() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export is unencrypted'),
        content: const Text(
          'The exported file is plaintext and is no longer end-to-end '
          'encrypted. Anyone who gets the file can read it. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('export-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Export'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final messages = await widget.features.loadMessages(
        widget.roomId,
        _limit,
      );
      if (!mounted) return;
      if (messages.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'No messages to export.';
        });
        return;
      }
      String fileName;
      String mime;
      Uint8List bytes;
      switch (_format) {
        case _Format.text:
          fileName = 'parallax-export.txt';
          mime = 'text/plain';
          bytes = Uint8List.fromList(
            utf8.encode(buildTextExport(widget.roomName, messages)),
          );
        case _Format.html:
          fileName = 'parallax-export.html';
          mime = 'text/html';
          bytes = Uint8List.fromList(
            utf8.encode(buildHtmlExport(widget.roomName, messages)),
          );
        case _Format.zip:
          fileName = 'parallax-export.zip';
          mime = 'application/zip';
          final media = <({String name, Uint8List bytes})>[];
          var count = 0;
          for (final m in messages) {
            if (!m.hasMedia || count >= 50) continue;
            final data = await widget.features.mediaBytes(
              widget.roomId,
              m.eventId,
            );
            if (!mounted) return;
            if (data != null && data.length <= 25 * 1024 * 1024) {
              media.add((name: m.mediaName ?? m.eventId, bytes: data));
              count++;
            }
          }
          bytes = buildZipExport(widget.roomName, messages, media);
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mime, name: fileName)],
        ),
      );
      if (mounted) setState(() => _busy = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t export the chat. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('Export chat'),
        backgroundColor: p.background,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Export ${widget.roomName} as a file you can save or share.',
            style: TextStyle(color: p.muted),
          ),
          const SizedBox(height: 16),
          Text('Format', style: Theme.of(context).textTheme.titleSmall),
          RadioGroup<_Format>(
            groupValue: _format,
            onChanged: (value) => setState(() => _format = value!),
            child: Column(
              children: [
                RadioListTile<_Format>(
                  key: const ValueKey('export-format-text'),
                  value: _Format.text,
                  title: Text(
                    'Plain text (.txt)',
                    style: TextStyle(color: p.foreground),
                  ),
                ),
                RadioListTile<_Format>(
                  key: const ValueKey('export-format-html'),
                  value: _Format.html,
                  title: Text(
                    'Styled HTML (.html)',
                    style: TextStyle(color: p.foreground),
                  ),
                ),
                RadioListTile<_Format>(
                  key: const ValueKey('export-format-zip'),
                  value: _Format.zip,
                  title: Text(
                    'ZIP with media (.zip)',
                    style: TextStyle(color: p.foreground),
                  ),
                  subtitle: Text(
                    'Includes up to 50 photos, videos and files',
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('Messages', style: Theme.of(context).textTheme.titleSmall),
          RadioGroup<int>(
            groupValue: _limit,
            onChanged: (value) => setState(() => _limit = value!),
            child: Column(
              children: [
                for (final count in [100, 500, 1000])
                  RadioListTile<int>(
                    key: ValueKey('export-limit-$count'),
                    value: count,
                    title: Text(
                      'Last $count',
                      style: TextStyle(color: p.foreground),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.raised,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.stroke),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: p.secondary, size: 20),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Exports are unencrypted plaintext. Keep the file safe — '
                    'anyone who gets it can read the conversation.',
                    style: TextStyle(color: p.muted, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: p.accent)),
          ],
          const SizedBox(height: 20),
          AccentButton(
            key: const ValueKey('export-run'),
            palette: p,
            label: _busy ? 'Exporting…' : 'Export chat',
            icon: Icons.ios_share_rounded,
            onPressed: _busy ? null : _export,
          ),
        ],
      ),
    );
  }
}

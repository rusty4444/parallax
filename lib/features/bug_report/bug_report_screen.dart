import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'diagnostic_log.dart';

/// In-app problem report with optional sanitised diagnostic logs.
class BugReportScreen extends StatefulWidget {
  const BugReportScreen({
    super.key,
    required this.palette,
    this.appVersion = '',
  });

  final AppPalette palette;
  final String appVersion;

  @override
  State<BugReportScreen> createState() => _BugReportScreenState();
}

class _BugReportScreenState extends State<BugReportScreen> {
  final _description = TextEditingController();
  bool _includeLogs = true;
  bool _showLogs = false;
  bool _busy = false;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  String _buildReport() {
    final buffer = StringBuffer()
      ..writeln('Parallax problem report')
      ..writeln('App version: ${widget.appVersion}')
      ..writeln(
        'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln('Date: ${DateTime.now().toIso8601String()}')
      ..writeln()
      ..writeln('Description:')
      ..writeln(
        _description.text.trim().isEmpty ? '(none)' : _description.text.trim(),
      );
    if (_includeLogs) {
      buffer
        ..writeln()
        ..writeln('--- Sanitised diagnostic logs (secrets redacted) ---')
        ..writeln(DiagnosticLogBuffer.instance.export());
    }
    return buffer.toString();
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final report = _buildReport();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/parallax-report.txt');
      await file.writeAsString(report, flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              file.path,
              mimeType: 'text/plain',
              name: 'parallax-report.txt',
            ),
          ],
          text: 'Parallax problem report',
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t prepare the report.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _buildReport()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report copied to clipboard.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final logs = DiagnosticLogBuffer.instance.lines;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('Report a problem'),
        backgroundColor: p.background,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            key: const ValueKey('bug-description'),
            controller: _description,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'What went wrong?',
              hintText: 'Describe the problem and steps to reproduce it…',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('bug-include-logs'),
            value: _includeLogs,
            onChanged: (value) => setState(() => _includeLogs = value),
            title: const Text('Include diagnostic logs'),
            subtitle: const Text(
              'Sanitised on your device — tokens, passwords and keys are redacted.',
            ),
          ),
          if (_includeLogs) ...[
            TextButton.icon(
              key: const ValueKey('bug-toggle-preview'),
              onPressed: () => setState(() => _showLogs = !_showLogs),
              icon: Icon(_showLogs ? Icons.expand_less : Icons.expand_more),
              label: Text(
                '${_showLogs ? 'Hide' : 'Preview'} ${logs.length} log lines',
              ),
            ),
            if (_showLogs)
              Container(
                constraints: const BoxConstraints(maxHeight: 240),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: p.raised,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    logs.isEmpty ? '(no logs captured yet)' : logs.join('\n'),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 16),
          AccentButton(
            key: const ValueKey('bug-share'),
            palette: p,
            label: _busy ? 'Preparing…' : 'Share report',
            icon: Icons.ios_share_rounded,
            onPressed: _busy ? null : _share,
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const ValueKey('bug-copy'),
            onPressed: _copy,
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy report'),
          ),
        ],
      ),
    );
  }
}

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

/// One message prepared for export.
@immutable
class ExportMessage {
  const ExportMessage({
    required this.eventId,
    required this.time,
    required this.sender,
    required this.body,
    this.mediaKind,
    this.mediaName,
  });

  final String eventId;
  final DateTime time;
  final String sender;
  final String body;

  /// image / video / audio / file, or null for text.
  final String? mediaKind;
  final String? mediaName;

  bool get hasMedia => mediaKind != null;
}

String _two(int n) => n.toString().padLeft(2, '0');

String _timestamp(DateTime time) {
  final t = time.toLocal();
  return '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}';
}

String _line(ExportMessage m) {
  final body = m.hasMedia
      ? '[${m.mediaKind}${m.mediaName == null ? '' : ': ${m.mediaName}'}]'
      : m.body;
  return '[${_timestamp(m.time)}] ${m.sender}: $body';
}

/// Plain-text export.
String buildTextExport(String roomName, List<ExportMessage> messages) {
  final buffer = StringBuffer()
    ..writeln('Parallax chat export')
    ..writeln('Room: $roomName')
    ..writeln('Exported: ${_timestamp(DateTime.now())}')
    ..writeln('Messages: ${messages.length}')
    ..writeln()
    ..writeln('NOTE: This export is unencrypted plaintext. Keep it safe.');
  for (final m in messages) {
    buffer.writeln(_line(m));
  }
  return buffer.toString();
}

String escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Styled HTML export.
String buildHtmlExport(String roomName, List<ExportMessage> messages) {
  final buffer = StringBuffer()
    ..writeln('<!DOCTYPE html>')
    ..writeln('<html lang="en"><head><meta charset="utf-8">')
    ..writeln(
      '<meta name="viewport" content="width=device-width, initial-scale=1">',
    )
    ..writeln('<title>${escapeHtml(roomName)} — Parallax export</title>')
    ..writeln('<style>')
    ..writeln(
      'body{font-family:system-ui,sans-serif;background:#faf7f2;color:#1c1b1a;margin:0;padding:24px;}',
    )
    ..writeln(
      'h1{font-size:20px;} .meta{color:#7a756e;font-size:13px;margin-bottom:20px;}',
    )
    ..writeln(
      '.msg{margin:0 0 14px;padding:12px 14px;background:#fff;border:1px solid #ece7df;border-radius:14px;}',
    )
    ..writeln(
      '.sender{font-weight:700;font-size:13px;color:#c2410c;} .time{color:#9a948c;font-size:11px;margin-left:8px;}',
    )
    ..writeln(
      '.body{margin-top:4px;white-space:pre-wrap;word-wrap:break-word;} .media{color:#7a756e;font-style:italic;}',
    )
    ..writeln(
      '.warn{background:#fff3e0;border:1px solid #ffcc80;padding:10px 12px;border-radius:10px;font-size:12px;margin-bottom:20px;}',
    )
    ..writeln('</style></head><body>')
    ..writeln('<h1>${escapeHtml(roomName)}</h1>')
    ..writeln(
      '<div class="meta">Exported ${_timestamp(DateTime.now())} · ${messages.length} messages</div>',
    )
    ..writeln(
      '<div class="warn">This export is unencrypted plaintext. Keep it safe.</div>',
    );
  for (final m in messages) {
    buffer.writeln('<div class="msg">');
    buffer.writeln(
      '<span class="sender">${escapeHtml(m.sender)}</span>'
      '<span class="time">${_timestamp(m.time)}</span>',
    );
    if (m.hasMedia) {
      final name = m.mediaName == null ? '' : ' — ${escapeHtml(m.mediaName!)}';
      buffer.writeln(
        '<div class="body media">[${escapeHtml(m.mediaKind!)}$name]</div>',
      );
      if (m.body.trim().isNotEmpty) {
        buffer.writeln('<div class="body">${escapeHtml(m.body)}</div>');
      }
    } else {
      buffer.writeln('<div class="body">${escapeHtml(m.body)}</div>');
    }
    buffer.writeln('</div>');
  }
  buffer.writeln('</body></html>');
  return buffer.toString();
}

/// ZIP export: the HTML transcript plus any provided media files.
Uint8List buildZipExport(
  String roomName,
  List<ExportMessage> messages,
  List<({String name, Uint8List bytes})> media,
) {
  final archive = Archive();
  archive.addFile(
    ArchiveFile.bytes(
      'chat.html',
      utf8.encode(buildHtmlExport(roomName, messages)),
    ),
  );
  archive.addFile(
    ArchiveFile.bytes(
      'chat.txt',
      utf8.encode(buildTextExport(roomName, messages)),
    ),
  );
  final used = <String>{};
  for (final item in media) {
    var name = 'media/${item.name}';
    var suffix = 1;
    while (used.contains(name)) {
      name = 'media/${suffix++}_${item.name}';
    }
    used.add(name);
    archive.addFile(ArchiveFile.bytes(name, item.bytes));
  }
  return ZipEncoder().encodeBytes(archive);
}

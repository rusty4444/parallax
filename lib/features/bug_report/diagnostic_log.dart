import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

/// An in-memory ring buffer of sanitised diagnostic logs for bug reports.
/// Nothing is written to disk unless the user explicitly exports a report.
/// Secrets (bearer tokens, passwords, recovery keys) are redacted before a
/// line is ever stored.
class DiagnosticLogBuffer {
  DiagnosticLogBuffer._();

  static final instance = DiagnosticLogBuffer._();

  static const maxLines = 500;
  final _lines = Queue<String>();
  bool _installed = false;

  List<String> get lines => List.unmodifiable(_lines);

  /// Hooks SDK logs and Flutter errors once. Safe to call repeatedly.
  void install() {
    if (_installed) return;
    _installed = true;
    try {
      matrix.Logs().level = matrix.Level.info;
      final previous = matrix.Logs().onLog;
      matrix.Logs().onLog = (event) {
        try {
          add('[${event.level.name}] ${event.toFormattedString()}');
        } catch (_) {}
        previous?.call(event);
      };
    } catch (_) {}
    final previousError = FlutterError.onError;
    FlutterError.onError = (details) {
      add('FLUTTER ERROR: ${details.exceptionAsString()}');
      previousError?.call(details);
    };
  }

  void add(String line) {
    final sanitised = scrub(line);
    _lines.addLast('${DateTime.now().toIso8601String()} $sanitised');
    while (_lines.length > maxLines) {
      _lines.removeFirst();
    }
  }

  String export() => _lines.join('\n');

  void clear() => _lines.clear();
}

/// Redacts credentials and secrets from a log line.
String scrub(String line) {
  var out = line;
  // Bearer tokens.
  out = out.replaceAllMapped(
    RegExp(r'Bearer\s+[A-Za-z0-9_\-\.=]+'),
    (_) => 'Bearer [redacted]',
  );
  // access_token / refresh_token / password / secret / recovery key fields.
  out = out.replaceAllMapped(
    RegExp(
      r'(access_token|refresh_token|password|secret|recovery_key|recoveryKey|passphrase)'
      r'(["\x27]?\s*[:=]\s*["\x27]?)([^\s"\x27,}&]+)',
      caseSensitive: false,
    ),
    (m) => '${m[1]}${m[2]}[redacted]',
  );
  // Long standalone base58 recovery keys (Matrix recovery keys are ~48 chars).
  out = out.replaceAllMapped(
    RegExp(r'\b[1-9A-HJ-NP-Za-km-z]{40,}\b'),
    (_) => '[redacted-key]',
  );
  return out;
}

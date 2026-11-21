import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/bug_report/diagnostic_log.dart';

void main() {
  test('scrub redacts bearer tokens', () {
    final out = scrub('Authorization: Bearer syt_abcDEF123.xyz');
    expect(out, contains('Bearer [redacted]'));
    expect(out, isNot(contains('syt_abcDEF123')));
  });

  test('scrub redacts password and token fields', () {
    final out = scrub('login password=hunter2 access_token: "tok_999"');
    expect(out, isNot(contains('hunter2')));
    expect(out, isNot(contains('tok_999')));
    expect(out, contains('[redacted]'));
  });

  test('scrub redacts long recovery keys', () {
    const key = 'EsTc LaBn 9zKp Qr4x Wm2v Bn7y Hd3s Jf6g Kp8t Lq5w Xz2c Vb9n';
    final compact = key.replaceAll(' ', '');
    final out = scrub('recovery key $compact');
    expect(out, isNot(contains(compact)));
  });

  test('scrub keeps ordinary text', () {
    const line = 'Sync finished for room !abc:example.org with 3 events';
    expect(scrub(line), line);
  });

  test('ring buffer caps lines and sanitises', () {
    final buffer = DiagnosticLogBuffer.instance;
    buffer.clear();
    for (var i = 0; i < 600; i++) {
      buffer.add('line $i Bearer secrettoken123');
    }
    expect(buffer.lines.length, DiagnosticLogBuffer.maxLines);
    expect(buffer.export(), isNot(contains('secrettoken123')));
    expect(buffer.lines.last, contains('line 599'));
    buffer.clear();
  });
}

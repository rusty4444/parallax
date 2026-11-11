import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/homeserver_security.dart';

void main() {
  test('accepts HTTPS homeserver URLs including reverse-proxy paths', () {
    expect(isSecureHomeserver(Uri.parse('https://matrix.example')), isTrue);
    expect(
      isSecureHomeserver(Uri.parse('https://matrix.example:8448/matrix')),
      isTrue,
    );
  });

  test('rejects insecure well-known targets before password login', () {
    expect(isSecureHomeserver(Uri.parse('http://matrix.example')), isFalse);
    expect(
      isSecureHomeserver(Uri.parse('https://user:pass@matrix.example')),
      isFalse,
    );
    expect(
      isSecureHomeserver(Uri.parse('https://matrix.example/?token=abc')),
      isFalse,
    );
    expect(
      isSecureHomeserver(Uri.parse('https://matrix.example/#fragment')),
      isFalse,
    );
    expect(isSecureHomeserver(null), isFalse);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/attachment_picker.dart';

void main() {
  test('attachment filenames are safe suggestions for document providers', () {
    expect(
      safeAttachmentName('../Private\\report:2026.pdf'),
      '_Private_report_2026.pdf',
    );
    expect(safeAttachmentName('...'), 'attachment');
    expect(safeAttachmentName('a' * 140).length, 120);
  });
}

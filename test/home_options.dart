import 'package:flutter_test/flutter_test.dart';

/// Opens the home screen's options menu (search, filters, Spaces, folders)
/// when it is collapsed. No-op with "Show all home options" on.
Future<void> openHomeOptions(WidgetTester tester) async {
  final toggle = find.byTooltip('Show options');
  if (toggle.evaluate().isEmpty) return;
  await tester.tap(toggle);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

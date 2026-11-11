import 'package:share_plus/share_plus.dart';

/// Opens the system share sheet. Replaceable in tests.
Future<void> Function(String text, {String? subject}) shareText = _share;

Future<void> _share(String text, {String? subject}) async {
  await SharePlus.instance.share(ShareParams(text: text, subject: subject));
}

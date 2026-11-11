import 'package:image_picker/image_picker.dart';

import 'rooms_admin_models.dart';

/// Picks a room avatar from the gallery, downscaled by the platform picker
/// and bounded in size. Replaceable in tests.
Future<PickedImage?> Function() pickAvatarImage = _pick;

Future<PickedImage?> _pick() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1024,
    maxHeight: 1024,
    imageQuality: 88,
    requestFullMetadata: false,
  );
  if (file == null) return null;
  final length = await file.length();
  if (length > maxAvatarBytes) {
    throw ArgumentError('Choose an image smaller than 10 MB.');
  }
  final bytes = await file.readAsBytes();
  return PickedImage(
    bytes: bytes,
    name: file.name,
    mimeType: file.mimeType ?? imageMimeType(file.name),
  );
}

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The platform temporary directory, created when it is missing.
///
/// On macOS `getTemporaryDirectory` returns `Library/Caches/<bundle id>`
/// inside the app's sandbox container without creating it
/// (path_provider_foundation 2.6), so `createTemp` and file writes under it
/// fail with "No such file or directory" until something else makes it.
Future<Directory> appTemporaryDirectory() async =>
    (await getTemporaryDirectory()).create(recursive: true);

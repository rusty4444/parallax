// Windows desktop bootstrap: swaps the Android-only platform pieces for
// their Windows implementations before the app starts. A no-op everywhere
// else, so tests and the Android app keep their own platform behaviour.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:video_player_win/video_player_win_plugin.dart';

import '../file_preview/pdf_tools.dart';
import '../file_preview/windows_pdf_tools.dart';
import '../media/video_prep.dart';
import '../media/windows_video_tools.dart';

/// True when running as the Windows desktop app.
bool get isWindowsDesktop => !kIsWeb && Platform.isWindows;

/// Call once from main() before runApp. On Windows:
/// - the SDK database runs on sqlite3 via FFI (sqflite has no Windows
///   plugin; sqlite3_flutter_libs bundles sqlite3.dll with the app),
/// - video_player is backed by Media Foundation (video_player_win),
/// - video probing/compression and PDF previews use the Windows tools.
void initializeWindowsPlatform() {
  if (!isWindowsDesktop) return;
  sqflite.databaseFactory = databaseFactoryFfi;
  WindowsVideoPlayer.registerWith();
  VideoTools.instance = WindowsVideoTools();
  PdfTools.instance = WindowsPdfTools();
}

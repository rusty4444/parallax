// Apple (iOS/macOS) bootstrap: swaps the Android-only platform pieces for
// their Apple implementations before the app starts. A no-op everywhere
// else, so tests and the Android app keep their own platform behaviour.
//
// - macOS has no sqflite plugin: the SDK database runs on sqlite3 via FFI
//   (sqlite3_flutter_libs bundles the dylib with the app). iOS keeps
//   sqflite's native implementation.
// - PDF previews use PDFium through pdfx instead of Android's isolated
//   PdfRenderer process (same timeouts and pixel caps, see pdfx_pdf_tools).
// - Video probing/compression (parallax/video), runtime permissions
//   (parallax/permissions), the secure window (parallax/secure_window) and
//   link intents (parallax/platform_intents) are answered by the Swift
//   handlers in apple/ParallaxApple.swift, so their Dart callers are
//   unchanged. UnifiedPush, Direct Share and the foreground-service
//   background connection stay Android-only; their Dart guards already
//   fall back to the built-in in-app delivery on Apple platforms.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../file_preview/pdf_tools.dart';
import '../file_preview/pdfx_pdf_tools.dart';

/// True when running as the iPhone, iPad or Mac app.
bool get isApplePlatform => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

/// Call once from main() before runApp.
void initializeApplePlatform() {
  if (!isApplePlatform) return;
  if (Platform.isMacOS) {
    sqflite.databaseFactory = databaseFactoryFfi;
  }
  PdfTools.instance = PdfxPdfTools();
}

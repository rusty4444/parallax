# macOS clipboard image regression

Run from the repository root:

```sh
bash apple/tests/run_clipboard_tests.sh
```

Prerequisites: macOS, Xcode/Swift, and an already cached Flutter macOS engine.
The script resolves `flutter` on `PATH` only to locate its SDK; **it never runs
Flutter**, downloads anything, or changes SDK/project build outputs. Override
`FLUTTER_ROOT` or `FLUTTER_MACOS_FRAMEWORK_DIR` (the directory containing
`FlutterMacOS.framework`) if needed. Compiler caches, executable and logs live
in an owned directory under `~/.hermes/cache/scratch/` printed by the script.

The harness compiles the **actual `apple/ParallaxApple.swift`** with
`ClipboardImageTests.swift`, links the real `FlutterMacOS.framework`, and calls
the production channel registration through a fake binary messenger. Requests
and responses cross the real `FlutterStandardMethodCodec`; the reader, decoder
and PNG encoder are not mocked. Tests create a unique **named** `NSPasteboard`,
inject it into the native reader, and release it on exit. They never access,
inspect, clear, save or restore the user's general clipboard.

## Contract

`parallax/clipboard.readImage` takes no arguments and returns:

- a bare `FlutterStandardTypedData(bytes:)` containing a PNG, decoded in Dart
  as `Uint8List`; or
- success with `null` for text/no inline image, malformed/unsupported/oversized
  images, or an overlapping request. The composer then uses ordinary text paste.

Unknown methods return `FlutterMethodNotImplemented` without reading the board.
**This is not a map response.** The current composer invokes
`invokeMethod<Uint8List>('readImage')`, like the existing Windows implementation;
Dart supplies `pasted-image.png` and MIME type `image/png`. A map with `bytes` and
`mimeType` would be rejected by that caller and silently fall back to text.

Registration retains the channel in `ParallaxAppleChannels.channels`; its
handler retains the clipboard reader for the engine lifetime. All new imports,
implementation and registration are conditional on macOS. iOS is unchanged.

## Limits and behavior

- Only explicit inline PNG, TIFF, JPEG, GIF, BMP and HEIC representations.
- No `NSImage(pasteboard:)`, `readObjects`, URL/file opening, remote fetches,
  file promises, or clipboard paths in the result.
- Encoded input and PNG result: at most 20 MiB each.
- Before raster decode: each edge at most 8192, at most 16,777,216 pixels,
  component depth 1–8 bits. Unsupported/high-bit-depth images fall back to text.
- Decode only frame zero with ImageIO's bounded thumbnail API, applying image
  orientation, with no upscaling. Result must have at most 32 bits per pixel and
  at most 64 MiB of raster rows. Fresh PNG encoding omits source file metadata.
- A serial utility queue decodes one immutable snapshot; replies return on the
  main thread. Single-flight admission prevents repeated Cmd+V presses from
  queueing unbounded clipboard snapshots. Reads never mutate the pasteboard.
- The pasteboard API materializes its inline `Data` before its length can be
  inspected; the input cap prevents decoding/retaining an oversized value, not
  the OS's initial pasteboard transfer. ImageIO is an in-process native decoder;
  these are resource bounds, not decoder crash isolation or a CPU deadline.

The native suite covers typed-data/PNG/pixel correctness for every allowed
format, first-frame-only GIF conversion, handler lifetime, null versus
NotImplemented, unmodified text/image contents, concurrent admission and
snapshot stability, forbidden file/remote sources, malformed/empty input,
high-bit-depth input, exact/over input-byte, edge and pixel limits, and an
independently exercised PNG-output byte cap.

This CLI gate does not prove AppDelegate startup, a real Cmd+V event, attachment
staging or sending in a running Flutter app. Run the app's platform builds and
composer widget/UI checks separately; do not use the real user clipboard for
an automated smoke test.

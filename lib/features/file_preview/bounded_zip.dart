import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads parts of a ZIP container (.docx, .xlsx, .pptx) from an untrusted
/// attachment without trusting anything the archive says about itself.
///
/// The declared uncompressed size of a part is ignored: a part is inflated
/// in chunks and reading stops at the caller's byte limit, so a file that
/// expands to gigabytes costs no more than that limit. Only stored and
/// deflated parts are supported; ZIP64 and encrypted archives are refused.
class BoundedZip {
  BoundedZip._(this._bytes, this._entries);

  /// Parses the central directory of [bytes]. Throws [FormatException] when
  /// it is not a ZIP file this reader supports.
  factory BoundedZip.parse(Uint8List bytes, {int maxEntries = 5000}) {
    final data = ByteData.sublistView(bytes);
    // End of central directory: 22 bytes plus a comment of up to 65535.
    final lowest = bytes.length - 22 - 0xFFFF;
    var end = -1;
    for (var at = bytes.length - 22; at >= 0 && at >= lowest; at--) {
      if (data.getUint32(at, Endian.little) == 0x06054b50) {
        end = at;
        break;
      }
    }
    if (end < 0) throw const FormatException('Not a ZIP file');
    final count = data.getUint16(end + 10, Endian.little);
    final offset = data.getUint32(end + 16, Endian.little);
    if (count == 0xFFFF || offset == 0xFFFFFFFF) {
      throw const FormatException('ZIP64 is not supported');
    }
    if (count > maxEntries) throw const FormatException('Too many ZIP entries');
    final entries = <String, _Entry>{};
    var at = offset;
    for (var index = 0; index < count; index++) {
      if (at < 0 ||
          at + 46 > bytes.length ||
          data.getUint32(at, Endian.little) != 0x02014b50) {
        throw const FormatException('Damaged ZIP directory');
      }
      final flags = data.getUint16(at + 8, Endian.little);
      final method = data.getUint16(at + 10, Endian.little);
      final compressed = data.getUint32(at + 20, Endian.little);
      final nameLength = data.getUint16(at + 28, Endian.little);
      final extraLength = data.getUint16(at + 30, Endian.little);
      final commentLength = data.getUint16(at + 32, Endian.little);
      final local = data.getUint32(at + 42, Endian.little);
      final nameEnd = at + 46 + nameLength;
      if (nameEnd > bytes.length) {
        throw const FormatException('Damaged ZIP directory');
      }
      final name = utf8.decode(
        Uint8List.sublistView(bytes, at + 46, nameEnd),
        allowMalformed: true,
      );
      entries.putIfAbsent(
        name,
        () => _Entry(
          method: method,
          compressedSize: compressed,
          localOffset: local,
          encrypted: flags & 1 != 0,
        ),
      );
      at = nameEnd + extraLength + commentLength;
    }
    return BoundedZip._(bytes, entries);
  }

  final Uint8List _bytes;
  final Map<String, _Entry> _entries;

  Iterable<String> get names => _entries.keys;
  bool contains(String name) => _entries.containsKey(name);

  /// The part called [name], inflated up to [maxBytes]; null when the
  /// archive has no such part. Throws [FormatException] for a damaged or
  /// unsupported part.
  ZipPart? read(String name, {required int maxBytes}) {
    final entry = _entries[name];
    if (entry == null) return null;
    if (entry.encrypted) throw const FormatException('Encrypted ZIP entry');
    final data = ByteData.sublistView(_bytes);
    final local = entry.localOffset;
    if (local < 0 ||
        local + 30 > _bytes.length ||
        data.getUint32(local, Endian.little) != 0x04034b50) {
      throw const FormatException('Damaged ZIP entry');
    }
    final start =
        local +
        30 +
        data.getUint16(local + 26, Endian.little) +
        data.getUint16(local + 28, Endian.little);
    final end = start + entry.compressedSize;
    if (start > _bytes.length || end > _bytes.length || end < start) {
      throw const FormatException('Damaged ZIP entry');
    }
    final source = Uint8List.sublistView(_bytes, start, end);
    switch (entry.method) {
      case 0:
        return source.length <= maxBytes
            ? ZipPart(source, truncated: false)
            : ZipPart(
                Uint8List.sublistView(source, 0, maxBytes),
                truncated: true,
              );
      case 8:
        return _inflate(source, maxBytes);
      default:
        throw const FormatException('Unsupported ZIP compression');
    }
  }

  /// [read] decoded as UTF-8 (malformed sequences become U+FFFD).
  ZipText? readText(String name, {required int maxBytes}) {
    final part = read(name, maxBytes: maxBytes);
    if (part == null) return null;
    return ZipText(
      utf8.decode(part.bytes, allowMalformed: true),
      truncated: part.truncated,
    );
  }

  static ZipPart _inflate(Uint8List source, int maxBytes) {
    final filter = RawZLibFilter.inflateFilter(raw: true);
    final out = BytesBuilder(copy: false);
    var truncated = false;
    try {
      filter.process(source, 0, source.length);
      // The filter hands back one buffer at a time; first what the input
      // produced, then (end: true) whatever it still holds.
      for (final end in const [false, true]) {
        while (!truncated) {
          final chunk = end
              ? filter.processed(end: true)
              : filter.processed(flush: false);
          if (chunk == null) break;
          final room = maxBytes - out.length;
          if (chunk.length > room) {
            if (room > 0) out.add(chunk.sublist(0, room));
            truncated = true;
          } else {
            out.add(chunk);
          }
        }
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      // dart:io reports corrupt deflate data as an ArgumentError or a
      // platform exception depending on where it stops.
      throw const FormatException('Damaged ZIP entry');
    }
    return ZipPart(out.takeBytes(), truncated: truncated);
  }
}

class _Entry {
  const _Entry({
    required this.method,
    required this.compressedSize,
    required this.localOffset,
    required this.encrypted,
  });
  final int method;
  final int compressedSize;
  final int localOffset;
  final bool encrypted;
}

class ZipPart {
  const ZipPart(this.bytes, {required this.truncated});
  final Uint8List bytes;

  /// The part is longer than the limit; [bytes] holds its start.
  final bool truncated;
}

class ZipText {
  const ZipText(this.text, {required this.truncated});
  final String text;
  final bool truncated;
}

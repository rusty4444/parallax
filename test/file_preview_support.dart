import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Builds a ZIP archive in memory from part name → content (a [String],
/// encoded as UTF-8, or bytes). Parts are deflated unless named in [store].
Uint8List buildZip(Map<String, Object> parts, {Set<String> store = const {}}) {
  final out = BytesBuilder();
  final directory = BytesBuilder();
  var count = 0;
  parts.forEach((name, content) {
    final nameBytes = utf8.encode(name);
    final data = content is String
        ? Uint8List.fromList(utf8.encode(content))
        : content as Uint8List;
    final stored = store.contains(name);
    final packed = stored
        ? data
        : Uint8List.fromList(ZLibCodec(raw: true).encode(data));
    final offset = out.length;
    ByteData header(int size) => ByteData(size);
    final local = header(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(8, stored ? 0 : 8, Endian.little)
      ..setUint32(18, packed.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(nameBytes)
      ..add(packed);
    final central = header(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(10, stored ? 0 : 8, Endian.little)
      ..setUint32(20, packed.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    directory
      ..add(central.buffer.asUint8List())
      ..add(nameBytes);
    count++;
  });
  final directoryOffset = out.length;
  final directoryBytes = directory.takeBytes();
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, directoryBytes.length, Endian.little)
    ..setUint32(16, directoryOffset, Endian.little);
  out
    ..add(directoryBytes)
    ..add(end.buffer.asUint8List());
  return out.takeBytes();
}

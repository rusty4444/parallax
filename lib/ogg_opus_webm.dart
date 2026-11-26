import 'dart:typed_data';

/// Rewraps an Ogg Opus file (the voice notes Element, Element X and the
/// WhatsApp/Signal bridges send) as WebM, without re-encoding.
///
/// Windows' Media Foundation, which plays audio for Parallax on Windows, has
/// an Opus decoder but no Ogg reader: an `.ogg` voice note never opens, while
/// the same Opus audio inside WebM plays. The Opus packets are copied as they
/// are; only the container changes.
///
/// Returns null when [bytes] is not a well-formed single-stream Ogg Opus
/// file, so the caller can fall back to the original.
Uint8List? oggOpusToWebm(Uint8List bytes) {
  try {
    final stream = _readOggPackets(bytes);
    if (stream == null || stream.packets.length < 3) return null;
    final head = stream.packets[0];
    if (!_startsWith(head, _opusHead) || head.length < 19) return null;
    final channels = head[9];
    final preSkip = head[10] | (head[11] << 8);
    if (channels == 0) return null;
    // packets[1] is OpusTags (metadata); the rest is audio.
    final audio = stream.packets.sublist(2);
    return _writeWebm(
      opusHead: head,
      channels: channels,
      preSkip: preSkip,
      packets: audio,
    );
  } on RangeError {
    return null;
  } on FormatException {
    return null;
  }
}

/// True when [bytes] look like an Ogg file carrying Opus.
bool isOggOpus(Uint8List bytes) {
  if (bytes.length < 36 || !_startsWith(bytes, _oggS)) return false;
  final segments = bytes[26];
  final start = 27 + segments;
  return bytes.length >= start + 8 &&
      _startsWith(Uint8List.sublistView(bytes, start), _opusHead);
}

const _oggS = [0x4F, 0x67, 0x67, 0x53]; // "OggS"
const _opusHead = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64];

bool _startsWith(List<int> data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

class _OggStream {
  _OggStream(this.packets);
  final List<Uint8List> packets;
}

/// Packets of the first logical stream, reassembled across pages.
_OggStream? _readOggPackets(Uint8List bytes) {
  final packets = <Uint8List>[];
  var partial = BytesBuilder(copy: false);
  int? serial;
  var offset = 0;
  while (offset + 27 <= bytes.length) {
    if (!_startsWith(Uint8List.sublistView(bytes, offset), _oggS)) {
      throw const FormatException('Lost Ogg page sync');
    }
    final view = ByteData.sublistView(bytes, offset);
    final pageSerial = view.getUint32(14, Endian.little);
    final segmentCount = bytes[offset + 26];
    final tableStart = offset + 27;
    var dataStart = tableStart + segmentCount;
    if (dataStart > bytes.length) throw const FormatException('Short page');
    serial ??= pageSerial;
    final ours = pageSerial == serial;
    for (var i = 0; i < segmentCount; i++) {
      final length = bytes[tableStart + i];
      if (dataStart + length > bytes.length) {
        throw const FormatException('Short segment');
      }
      if (ours) {
        partial.add(
          Uint8List.sublistView(bytes, dataStart, dataStart + length),
        );
        if (length < 255) {
          packets.add(partial.takeBytes());
          partial = BytesBuilder(copy: false);
        }
      }
      dataStart += length;
    }
    offset = dataStart;
  }
  return packets.isEmpty ? null : _OggStream(packets);
}

/// Opus packet length in 48 kHz samples, from its TOC byte (RFC 6716 §3.1).
int _opusSamples(Uint8List packet) {
  if (packet.isEmpty) return 0;
  final toc = packet[0];
  final config = toc >> 3;
  final int frame;
  if (config < 12) {
    frame = const [480, 960, 1920, 2880][config % 4];
  } else if (config < 16) {
    frame = const [480, 960][config % 2];
  } else {
    frame = const [120, 240, 480, 960][config % 4];
  }
  final code = toc & 3;
  final frames = switch (code) {
    0 => 1,
    1 || 2 => 2,
    _ => packet.length > 1 ? packet[1] & 0x3F : 0,
  };
  return frame * frames;
}

// --- EBML/WebM writing ----------------------------------------------------

Uint8List _vintSize(int size) {
  for (var length = 1; length <= 8; length++) {
    // All-ones is reserved for "unknown size".
    if (size < (1 << (7 * length)) - 1) {
      final out = Uint8List(length);
      var value = size;
      for (var i = length - 1; i >= 0; i--) {
        out[i] = value & 0xFF;
        value >>= 8;
      }
      out[0] |= 1 << (8 - length);
      return out;
    }
  }
  throw const FormatException('Element too large');
}

Uint8List _id(int id) {
  final bytes = <int>[];
  var value = id;
  while (value > 0) {
    bytes.insert(0, value & 0xFF);
    value >>= 8;
  }
  return Uint8List.fromList(bytes);
}

Uint8List _element(int id, List<int> data) {
  final out = BytesBuilder(copy: false)
    ..add(_id(id))
    ..add(_vintSize(data.length))
    ..add(data);
  return out.takeBytes();
}

Uint8List _master(int id, List<Uint8List> children) {
  final body = BytesBuilder(copy: false);
  for (final child in children) {
    body.add(child);
  }
  return _element(id, body.takeBytes());
}

Uint8List _uint(int id, int value, {int? width}) {
  var length = width ?? 1;
  if (width == null) {
    while (length < 8 && value >= (1 << (8 * length))) {
      length++;
    }
  }
  final data = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    data[i] = v & 0xFF;
    v >>= 8;
  }
  return _element(id, data);
}

Uint8List _float(int id, double value) =>
    _element(id, (ByteData(8)..setFloat64(0, value)).buffer.asUint8List());

Uint8List _string(int id, String value) => _element(id, value.codeUnits);

const _clusterMs = 5000;

Uint8List _writeWebm({
  required Uint8List opusHead,
  required int channels,
  required int preSkip,
  required List<Uint8List> packets,
}) {
  // Timestamps (ms) of every packet, and the clusters they fall into.
  final starts = <int>[];
  var samples = 0;
  for (final packet in packets) {
    starts.add(samples * 1000 ~/ 48000);
    samples += _opusSamples(packet);
  }
  final durationMs = (samples - preSkip).clamp(0, samples) * 1000 / 48000;

  final clusters = <Uint8List>[];
  final clusterTimes = <int>[];
  var i = 0;
  while (i < packets.length) {
    final base = starts[i];
    final children = <Uint8List>[_uint(0xE7, base)];
    while (i < packets.length && starts[i] - base < _clusterMs) {
      final relative = starts[i] - base;
      final block = BytesBuilder(copy: false)
        ..addByte(0x81) // track 1
        ..addByte((relative >> 8) & 0xFF)
        ..addByte(relative & 0xFF)
        ..addByte(0x80) // keyframe
        ..add(packets[i]);
      children.add(_element(0xA3, block.takeBytes()));
      i++;
    }
    clusters.add(_master(0x1F43B675, children));
    clusterTimes.add(base);
  }

  final ebml = _master(0x1A45DFA3, [
    _uint(0x4286, 1),
    _uint(0x42F7, 1),
    _uint(0x42F2, 4),
    _uint(0x42F3, 8),
    _string(0x4282, 'webm'),
    _uint(0x4287, 4),
    _uint(0x4285, 2),
  ]);
  final info = _master(0x1549A966, [
    _uint(0x2AD7B1, 1000000),
    _string(0x4D80, 'Parallax'),
    _string(0x5741, 'Parallax'),
    _float(0x4489, durationMs.toDouble()),
  ]);
  final tracks = _master(0x1654AE6B, [
    _master(0xAE, [
      _uint(0xD7, 1),
      _uint(0x73C5, 1),
      _uint(0x83, 2),
      _string(0x86, 'A_OPUS'),
      _element(0x63A2, opusHead),
      _uint(0x56AA, preSkip * 1000000000 ~/ 48000),
      _uint(0x56BB, 80000000),
      _master(0xE1, [_float(0xB5, 48000), _uint(0x9F, channels)]),
    ]),
  ]);

  // Cues before the clusters, so a reader finds them without a SeekHead.
  // Positions are fixed-width, so the Cues size does not depend on them.
  Uint8List cues(List<int> positions) => _master(0x1C53BB6B, [
    for (var c = 0; c < clusters.length; c++)
      _master(0xBB, [
        _uint(0xB3, clusterTimes[c]),
        _master(0xB7, [_uint(0xF7, 1), _uint(0xF1, positions[c], width: 8)]),
      ]),
  ]);
  final cuesSize = cues(List.filled(clusters.length, 0)).length;
  final positions = <int>[];
  var position = info.length + tracks.length + cuesSize;
  for (final cluster in clusters) {
    positions.add(position);
    position += cluster.length;
  }
  final segment = _master(0x18538067, [
    info,
    tracks,
    cues(positions),
    ...clusters,
  ]);
  return (BytesBuilder(copy: false)
        ..add(ebml)
        ..add(segment))
      .takeBytes();
}

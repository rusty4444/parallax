import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/chat_export/chat_export.dart';

void main() {
  final messages = [
    ExportMessage(
      eventId: r'$a',
      time: DateTime(2026, 11, 21, 10, 30),
      sender: 'Alice',
      body: 'Hello <world> & "friends"',
    ),
    ExportMessage(
      eventId: r'$b',
      time: DateTime(2026, 11, 21, 10, 31),
      sender: 'Bob',
      body: 'photo.jpg',
      mediaKind: 'image',
      mediaName: 'photo.jpg',
    ),
  ];

  test('text export includes messages and a plaintext warning', () {
    final text = buildTextExport('Test room', messages);
    expect(text, contains('Room: Test room'));
    expect(text, contains('Alice: Hello <world> & "friends"'));
    expect(text, contains('[image: photo.jpg]'));
    expect(text, contains('unencrypted plaintext'));
  });

  test('html export escapes user content', () {
    final html = buildHtmlExport('Test room', messages);
    expect(html, contains('&lt;world&gt;'));
    expect(html, contains('&amp;'));
    expect(html, contains('&quot;friends&quot;'));
    expect(html, isNot(contains('<world>')));
    expect(html, contains('Alice'));
  });

  test('zip export round-trips transcript and media', () {
    final media = [
      (name: 'photo.jpg', bytes: Uint8List.fromList([1, 2, 3, 4])),
    ];
    final zip = buildZipExport('Test room', messages, media);
    final archive = ZipDecoder().decodeBytes(zip);
    final names = archive.files.map((f) => f.name).toSet();
    expect(names, containsAll(['chat.html', 'chat.txt', 'media/photo.jpg']));
    final photo = archive.files.firstWhere((f) => f.name == 'media/photo.jpg');
    expect(photo.content as List<int>, [1, 2, 3, 4]);
    final html = utf8.decode(
      archive.files.firstWhere((f) => f.name == 'chat.html').content
          as List<int>,
    );
    expect(html, contains('&lt;world&gt;'));
  });

  test('zip deduplicates media names', () {
    final media = [
      (name: 'a.jpg', bytes: Uint8List.fromList([1])),
      (name: 'a.jpg', bytes: Uint8List.fromList([2])),
    ];
    final archive = ZipDecoder().decodeBytes(
      buildZipExport('R', messages, media),
    );
    final mediaNames = archive.files
        .map((f) => f.name)
        .where((n) => n.startsWith('media/'))
        .toList();
    expect(mediaNames.length, 2);
    expect(mediaNames.toSet().length, 2);
  });
}

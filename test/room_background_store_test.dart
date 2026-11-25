import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:parallax/room_background_store.dart';

void main() {
  late Directory root;
  late RoomBackgroundStore store;

  setUp(() async {
    final parent = Directory('build/room_background_tests');
    await parent.create(recursive: true);
    root = await parent.createTemp('case-');
    store = RoomBackgroundStore(root: root);
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'persists room-isolated images and replaces without stale files',
    () async {
      expect(await store.fileFor('!a:server'), isNull);
      final first = await store.replace(
        '!a:server',
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'first.png'),
      );
      final other = await store.replace(
        '!b:server',
        XFile.fromData(Uint8List.fromList([9, 8]), name: 'other.png'),
      );
      expect(first.path, isNot(other.path));
      expect(await (await store.fileFor('!a:server'))!.readAsBytes(), [
        1,
        2,
        3,
      ]);
      final replaced = await store.replace(
        '!a:server',
        XFile.fromData(Uint8List.fromList([4, 5]), name: 'second.jpg'),
      );
      expect(replaced.path, first.path);
      expect(await replaced.readAsBytes(), [4, 5]);
      expect(await other.readAsBytes(), [9, 8]);
      expect(await Directory(first.parent.path).list().length, 2);
      await store.clear('!a:server');
      expect(await store.fileFor('!a:server'), isNull);
      expect(await store.fileFor('!b:server'), isNotNull);
    },
  );

  test('invalid replacement preserves the old image', () async {
    final old = await store.replace(
      '!a:server',
      XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'old.png'),
    );
    final oversized = File('${root.path}/oversized.png');
    await (await oversized.open(
      mode: FileMode.write,
    )).truncate(RoomBackgroundStore.maxBytes + 1).then((file) => file.close());
    await expectLater(
      store.replace('!a:server', XFile(oversized.path)),
      throwsArgumentError,
    );
    expect(await old.readAsBytes(), [1, 2, 3]);
    expect(await store.fileFor('!a:server'), isNotNull);
  });

  test('a background rewritten in place gets a new image cache key', () async {
    final file = File('${root.path}/room.image');
    ResizeImage shown(int version) => ResizeImage(
      VersionedFileImage(file, version),
      width: 1200,
      height: 1200,
      policy: ResizeImagePolicy.fit,
    );
    Future<Object> key(ImageProvider<Object> image) =>
        image.obtainKey(ImageConfiguration.empty);

    // Same picture: same key, so rebuilds reuse the decoded image.
    expect(shown(1), shown(1));
    expect(await key(shown(1)), await key(shown(1)));
    // Re-chosen or replaced picture at the same path: a new key, so the
    // cached old picture is not shown.
    expect(shown(2), isNot(shown(1)));
    expect(await key(shown(2)), isNot(await key(shown(1))));
    // Plain FileImage keys (the old behaviour) collide.
    expect(await key(FileImage(file)), await key(FileImage(file)));
  });
}

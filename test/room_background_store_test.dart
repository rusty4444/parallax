import 'dart:io';
import 'dart:typed_data';

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
}

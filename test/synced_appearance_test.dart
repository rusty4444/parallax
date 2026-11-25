import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/features/appearance/appearance_sync.dart';
import 'package:parallax/features/appearance/bubble_colours.dart';
import 'package:parallax/features/appearance/room_theme_sync.dart';
import 'package:parallax/features/appearance/sync_ledger.dart';
import 'package:parallax/room_background_store.dart';
import 'package:parallax/room_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scheduled_fakes.dart'
    show RecordingTransport, ScheduledDatabase, jsonResponse;

const _user = '@sam:matrix.example';
const _roomId = '!room:matrix.example';
const _coloursPath =
    '/_matrix/client/v3/user/%40sam%3Amatrix.example/rooms/'
    '!room%3Amatrix.example/account_data/net.samrusselltech.parallax.room_theme';
const _backgroundPath =
    '/_matrix/client/v3/user/%40sam%3Amatrix.example/rooms/'
    '!room%3Amatrix.example/account_data/'
    'net.samrusselltech.parallax.room_background';
const _appearancePath =
    '/_matrix/client/v3/user/%40sam%3Amatrix.example/account_data/'
    'net.samrusselltech.parallax.appearance';

/// A small valid JPEG header (enough for the picture sniffing).
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);
final _otherJpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 9, 9, 9]);

/// The homeserver: account data by path, plus failure switches.
class _Server {
  final data = <String, Map<String, Object?>>{};
  bool offline = false;
  final puts = <String, List<Map<String, Object?>>>{};

  Future<http.Response> respond(http.Request request) async {
    if (offline) return jsonResponse({'errcode': 'M_UNKNOWN'}, 500);
    final path = request.url.path;
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      data[path] = body;
      puts.putIfAbsent(path, () => []).add(body);
      return jsonResponse({});
    }
    final stored = data[path];
    if (stored == null) {
      return jsonResponse({'errcode': 'M_NOT_FOUND', 'error': 'none'}, 404);
    }
    return jsonResponse(stored);
  }
}

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super('sync-test', database: ScheduledDatabase(), httpClient: transport) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }

  final uploads = <Uint8List>[];

  @override
  String? get userID => _user;
  @override
  String? get deviceID => 'DEVICE';

  @override
  Future<Uri> uploadContent(
    Uint8List file, {
    String? filename,
    String? contentType,
  }) async {
    uploads.add(file);
    return Uri.parse('mxc://matrix.example/upload${uploads.length}');
  }

  void markSynced() => onSync.add(matrix.SyncUpdate(nextBatch: 'batch'));

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Access extends ChangeNotifier implements MatrixSdkAccess {
  _Access(this.client);
  final matrix.Client client;
  bool current = true;
  @override
  matrix.Client? get sdkClient => current ? client : null;
  @override
  bool isSessionCurrent(matrix.Client client) =>
      current && identical(client, this.client);
}

Map<String, Object?> _coloursContent(String mine, {int updatedAt = 0}) => {
  'version': 1,
  'updatedAt': updatedAt,
  'bubbleColours': {'mine': mine},
};

void main() {
  late _Server server;
  late _Client client;
  late _Access access;
  late matrix.Room room;
  late SharedPreferences prefs;
  late SyncLedger ledger;
  late RoomBubbleColourStore colours;
  late Directory root;
  late RoomBackgroundStore backgrounds;
  var clock = 1000;
  final decrypted = <String, Uint8List>{};

  RoomThemeSync themeSync() => RoomThemeSync(
    access,
    colours: colours,
    backgrounds: backgrounds,
    ledger: ledger,
    now: () => clock,
    prepareImage: (_) async => null,
    // "Encryption" in tests: the key names the plaintext.
    encrypt: (bytes) async {
      final k = 'key${decrypted.length}';
      decrypted[k] = bytes;
      return matrix.EncryptedFile(
        data: Uint8List.fromList(utf8.encode(k)),
        k: k,
        iv: 'iv',
        sha256: 'hash-$k',
      );
    },
    download: (client, mxc, maxBytes) async =>
        Uint8List.fromList(utf8.encode('cipher:${mxc.pathSegments.single}')),
    decrypt: (file) async =>
        file.sha256 == 'hash-${file.k}' ? decrypted[file.k] : null,
  );

  void remote(String type, Map<String, Object?> content) {
    room.roomAccountData[type] = matrix.BasicEvent(
      type: type,
      content: content,
    );
  }

  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    ledger = SyncLedger(preferences: prefs);
    colours = RoomBubbleColourStore(preferences: prefs);
    OwnWrites.clear();
    server = _Server();
    client = _Client(RecordingTransport(server.respond));
    client.markSynced();
    access = _Access(client);
    room = matrix.Room(
      id: _roomId,
      client: client,
      membership: matrix.Membership.join,
    );
    client.rooms.add(room);
    final parent = Directory('build/synced_appearance_tests');
    await parent.create(recursive: true);
    root = await parent.createTemp('case-');
    backgrounds = RoomBackgroundStore(root: root);
    clock = 1000;
    decrypted.clear();
  });
  tearDown(() async => root.delete(recursive: true));

  group('decideSync', () {
    SyncEntry entry({String? seen, int? pending, bool localOnly = false}) =>
        SyncEntry(
          userId: _user,
          type: 't',
          seen: seen,
          pending: pending,
          localOnly: localOnly,
        );
    final account = {'updatedAt': 50, 'value': 1};

    test('the account copy wins over a device that only has old values', () {
      expect(
        decideSync(remote: account, entry: entry(), hasLocal: true),
        SyncAction.adoptRemote,
      );
      expect(
        decideSync(
          remote: account,
          entry: entry(seen: 'older'),
          hasLocal: true,
        ),
        SyncAction.adoptRemote,
      );
      expect(
        decideSync(
          remote: account,
          entry: entry(seen: contentHash(account)),
          hasLocal: true,
        ),
        SyncAction.none,
      );
    });

    test('an unsent change uploads unless the account has a newer one', () {
      expect(
        decideSync(
          remote: account,
          entry: entry(seen: contentHash(account), pending: 10),
          hasLocal: true,
        ),
        SyncAction.pushLocal,
      );
      expect(
        decideSync(
          remote: account,
          entry: entry(seen: 'older', pending: 10),
          hasLocal: true,
        ),
        SyncAction.adoptRemote,
      );
      expect(
        decideSync(
          remote: account,
          entry: entry(seen: 'older', pending: 60),
          hasLocal: true,
        ),
        SyncAction.pushLocal,
      );
    });

    test('settings the account never had are uploaded', () {
      expect(
        decideSync(remote: null, entry: entry(), hasLocal: true),
        SyncAction.pushLocal,
      );
      expect(
        decideSync(remote: null, entry: entry(), hasLocal: false),
        SyncAction.none,
      );
    });

    test('device-only settings and own echoes are left alone', () {
      expect(
        decideSync(
          remote: account,
          entry: entry(localOnly: true),
          hasLocal: true,
        ),
        SyncAction.none,
      );
      expect(
        decideSync(
          remote: account,
          entry: entry(seen: 'newer'),
          hasLocal: true,
          ownWrites: {contentHash(account)},
        ),
        SyncAction.none,
      );
    });

    test('content hashes ignore key order', () {
      expect(
        contentHash({
          'a': 1,
          'b': {'x': 1, 'y': 2},
        }),
        contentHash({
          'b': {'y': 2, 'x': 1},
          'a': 1,
        }),
      );
      expect(contentHash({'a': 1}), isNot(contentHash({'a': 2})));
    });
  });

  group('bubble colours', () {
    test('a change from another device replaces colours this device already '
        'had (the old version kept its own)', () async {
      await colours.save(_roomId, const BubbleColours(mine: Color(0xFF112233)));
      remote(RoomThemeSync.coloursType, _coloursContent('#AA0000'));

      expect(await themeSync().reconcileColours(_roomId), isTrue);
      expect(colours.cached(_roomId)!.mine, const Color(0xFFAA0000));

      // Android changes it again while Windows is closed.
      remote(
        RoomThemeSync.coloursType,
        _coloursContent('#00BB00', updatedAt: 5),
      );
      expect(await themeSync().reconcileColours(_roomId), isTrue);
      expect(colours.cached(_roomId)!.mine, const Color(0xFF00BB00));
      expect(await themeSync().reconcileColours(_roomId), isFalse);
      expect(server.puts, isEmpty);
    });

    test('colours chosen before syncing existed are uploaded', () async {
      await colours.save(_roomId, const BubbleColours(mine: Color(0xFF112233)));

      await themeSync().reconcileColours(_roomId);

      final put = server.puts[_coloursPath]!.single;
      expect(put['bubbleColours'], {'mine': '#112233'});
      expect(put['updatedAt'], 1000);
      final entry = await ledger.read(
        _user,
        RoomThemeSync.coloursType,
        _roomId,
      );
      expect(entry.pending, isNull);
      expect(entry.seen, contentHash(put));
    });

    test('a change made offline is uploaded later', () async {
      final helper = themeSync();
      server.offline = true;
      await colours.save(_roomId, const BubbleColours(mine: Color(0xFF445566)));
      clock = 2000;
      await helper.coloursChanged(_roomId);
      await settle();
      expect(
        (await ledger.read(_user, RoomThemeSync.coloursType, _roomId)).pending,
        2000,
      );

      server.offline = false;
      await themeSync().flushPending();

      final put = server.puts[_coloursPath]!.single;
      expect(put['bubbleColours'], {'mine': '#445566'});
      expect(put['updatedAt'], 2000);
      expect(
        (await ledger.read(_user, RoomThemeSync.coloursType, _roomId)).pending,
        isNull,
      );
    });

    test('a newer change from another device beats an unsent one', () async {
      server.offline = true;
      await colours.save(_roomId, const BubbleColours(mine: Color(0xFF445566)));
      clock = 2000;
      await themeSync().coloursChanged(_roomId);
      await settle();
      server.offline = false;
      remote(
        RoomThemeSync.coloursType,
        _coloursContent('#0000CC', updatedAt: 3000),
      );

      await themeSync().reconcileColours(_roomId);

      expect(colours.cached(_roomId)!.mine, const Color(0xFF0000CC));
      expect(server.puts[_coloursPath], isNull);
    });

    test(
      'nothing is uploaded from a stale copy before the first sync',
      () async {
        final fresh = _Client(RecordingTransport(server.respond));
        access = _Access(fresh);
        fresh.rooms.add(
          matrix.Room(
            id: _roomId,
            client: fresh,
            membership: matrix.Membership.join,
          ),
        );
        await colours.save(
          _roomId,
          const BubbleColours(mine: Color(0xFF112233)),
        );

        await themeSync().reconcileColours(_roomId);
        expect(server.puts, isEmpty);

        fresh.markSynced();
        await themeSync().reconcileColours(_roomId);
        expect(server.puts[_coloursPath], hasLength(1));
      },
    );

    test(
      'a late echo of an earlier upload does not undo a newer edit',
      () async {
        final helper = themeSync();
        await colours.save(
          _roomId,
          const BubbleColours(mine: Color(0xFF111111)),
        );
        await helper.coloursChanged(_roomId);
        await settle();
        final first = server.puts[_coloursPath]!.last;
        clock = 1500;
        await colours.save(
          _roomId,
          const BubbleColours(mine: Color(0xFF222222)),
        );
        await helper.coloursChanged(_roomId);
        await settle();

        // Sync delivers the first write after the second was made.
        remote(RoomThemeSync.coloursType, first);
        await helper.reconcileColours(_roomId);

        expect(colours.cached(_roomId)!.mine, const Color(0xFF222222));
      },
    );

    test('remoteChanged follows the synced event identity', () {
      final helper = themeSync();
      expect(helper.remoteChanged(_roomId), isTrue);
      expect(helper.remoteChanged(_roomId), isFalse);
      remote(RoomThemeSync.coloursType, _coloursContent('#123456'));
      expect(helper.remoteChanged(_roomId), isTrue);
      expect(helper.remoteChanged(_roomId), isFalse);
    });
  });

  group('backgrounds', () {
    test('a background chosen here is encrypted and uploaded', () async {
      final helper = themeSync();
      await backgrounds.replaceBytes(_roomId, _jpeg);
      clock = 4000;
      await helper.backgroundChanged(_roomId);
      await settle();

      expect(client.uploads.single, utf8.encode('key0'));
      expect(decrypted['key0'], _jpeg);
      final put = server.puts[_backgroundPath]!.single;
      expect(put['updatedAt'], 4000);
      final file = put['file']! as Map;
      expect(file['url'], 'mxc://matrix.example/upload1');
      expect((file['key']! as Map)['k'], 'key0');
      expect((file['hashes']! as Map)['sha256'], 'hash-key0');
      expect(file['mimetype'], 'image/jpeg');
    });

    test('a background from another device is downloaded and shown', () async {
      await backgrounds.replaceBytes(_roomId, _otherJpeg);
      decrypted['remote'] = _jpeg;
      remote(RoomThemeSync.backgroundType, {
        'version': 1,
        'updatedAt': 10,
        'file': {
          'url': 'mxc://matrix.example/abc',
          'key': {'k': 'remote'},
          'iv': 'iv',
          'hashes': {'sha256': 'hash-remote'},
          'v': 'v2',
        },
      });

      expect(await themeSync().reconcileBackground(_roomId), isTrue);
      expect(await (await backgrounds.fileFor(_roomId))!.readAsBytes(), _jpeg);
      expect(await themeSync().reconcileBackground(_roomId), isFalse);
    });

    test('a download that fails its hash check changes nothing', () async {
      await backgrounds.replaceBytes(_roomId, _otherJpeg);
      decrypted['remote'] = _jpeg;
      remote(RoomThemeSync.backgroundType, {
        'version': 1,
        'updatedAt': 10,
        'file': {
          'url': 'mxc://matrix.example/abc',
          'key': {'k': 'remote'},
          'iv': 'iv',
          'hashes': {'sha256': 'tampered'},
        },
      });

      expect(await themeSync().reconcileBackground(_roomId), isFalse);
      expect(
        await (await backgrounds.fileFor(_roomId))!.readAsBytes(),
        _otherJpeg,
      );
      final entry = await ledger.read(
        _user,
        RoomThemeSync.backgroundType,
        _roomId,
      );
      expect(entry.seen, isNull, reason: 'tried again next time');
    });

    test('removing a background removes it on other devices', () async {
      final helper = themeSync();
      await backgrounds.replaceBytes(_roomId, _jpeg);
      await helper.backgroundChanged(_roomId);
      await settle();
      await backgrounds.clear(_roomId);
      clock = 5000;
      await helper.backgroundChanged(_roomId);
      await settle();
      expect(server.puts[_backgroundPath]!.last, {
        'version': 1,
        'updatedAt': 5000,
        'removed': true,
      });

      // The other device.
      final other = Directory('${root.path}/other');
      await other.create();
      final otherStore = RoomBackgroundStore(root: other);
      await otherStore.replaceBytes(_roomId, _otherJpeg);
      final otherSync = RoomThemeSync(
        access,
        colours: colours,
        backgrounds: otherStore,
        ledger: SyncLedger(preferences: prefs),
      );
      // A different device has its own ledger: start it empty.
      await prefs.clear();
      expect(await otherSync.reconcileBackground(_roomId), isTrue);
      expect(await otherStore.fileFor(_roomId), isNull);
    });

    test(
      'a background kept to this device is neither uploaded nor replaced',
      () async {
        final helper = themeSync();
        await backgrounds.replaceBytes(_roomId, _otherJpeg);
        await helper.setBackgroundDeviceOnly(_roomId, true);
        expect(await helper.backgroundDeviceOnly(_roomId), isTrue);
        await helper.backgroundChanged(_roomId);
        await settle();
        expect(server.puts[_backgroundPath], isNull);

        decrypted['remote'] = _jpeg;
        remote(RoomThemeSync.backgroundType, {
          'version': 1,
          'updatedAt': 10,
          'file': {
            'url': 'mxc://matrix.example/abc',
            'key': {'k': 'remote'},
            'iv': 'iv',
            'hashes': {'sha256': 'hash-remote'},
          },
        });
        expect(await helper.reconcileBackground(_roomId), isFalse);
        expect(
          await (await backgrounds.fileFor(_roomId))!.readAsBytes(),
          _otherJpeg,
        );

        // Syncing again takes the account's background.
        expect(await helper.setBackgroundDeviceOnly(_roomId, false), isTrue);
        expect(
          await (await backgrounds.fileFor(_roomId))!.readAsBytes(),
          _jpeg,
        );
      },
    );

    test('syncing a device-only background again takes the account copy, '
        'even one this device uploaded', () async {
      final helper = themeSync();
      await backgrounds.replaceBytes(_roomId, _jpeg);
      await helper.backgroundChanged(_roomId);
      await settle();
      expect(server.puts[_backgroundPath], hasLength(1));

      await helper.setBackgroundDeviceOnly(_roomId, true);
      await backgrounds.replaceBytes(_roomId, _otherJpeg);
      await helper.backgroundChanged(_roomId);
      await settle();
      expect(server.puts[_backgroundPath], hasLength(1));

      expect(await helper.setBackgroundDeviceOnly(_roomId, false), isTrue);
      expect(await (await backgrounds.fileFor(_roomId))!.readAsBytes(), _jpeg);
    });

    test('a non-picture is never uploaded', () async {
      await backgrounds.replaceBytes(_roomId, Uint8List.fromList([1, 2, 3]));
      await themeSync().backgroundChanged(_roomId);
      await settle();
      expect(client.uploads, isEmpty);
      expect(server.puts[_backgroundPath], isNull);
    });

    test('sniffs picture formats', () {
      expect(sniffImageMimeType(_jpeg), 'image/jpeg');
      expect(
        sniffImageMimeType(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0])),
        'image/png',
      );
      expect(
        sniffImageMimeType(
          Uint8List.fromList([
            ...ascii.encode('RIFF'),
            0,
            0,
            0,
            0,
            ...ascii.encode('WEBP'),
          ]),
        ),
        'image/webp',
      );
      expect(sniffImageMimeType(Uint8List.fromList([0, 1, 2])), isNull);
    });
  });

  group('theme and font', () {
    late AppearancePreferences preferences;
    late String theme;
    late List<String> applied;

    AppearanceSync appearance() => AppearanceSync(
      backend: access,
      preferences: preferences,
      currentTheme: () => theme,
      applyTheme: (value) async {
        applied.add(value);
        theme = value;
      },
      isKnownTheme: (value) =>
          value == 'system' || ['parallax', 'parallaxDay'].contains(value),
      ledger: ledger,
      now: () => clock,
      roomSync: themeSync,
    );

    void accountAppearance(Map<String, Object?> content) {
      client.accountData[AppearanceSync.eventType] = matrix.BasicEvent(
        type: AppearanceSync.eventType,
        content: content,
      );
    }

    setUp(() async {
      preferences = AppearancePreferences(prefs: prefs);
      await preferences.load();
      theme = 'parallax';
      applied = [];
    });

    test('takes the theme and font chosen on another device', () async {
      accountAppearance({
        'version': 1,
        'updatedAt': 10,
        'theme': 'parallaxDay',
        'font': 'figtree',
      });
      final sync = appearance()..start();
      await settle();

      expect(applied, ['parallaxDay']);
      expect(preferences.appFont.id, 'figtree');
      expect(server.puts[_appearancePath], isNull);

      // Another change arrives through sync.
      accountAppearance({
        'version': 1,
        'updatedAt': 20,
        'theme': 'system',
        'font': 'figtree',
      });
      access.notifyListeners();
      await settle();
      expect(applied, ['parallaxDay', 'system']);
      expect(server.puts[_appearancePath], isNull);
      sync.dispose();
    });

    test('uploads a theme or font picked here', () async {
      final sync = appearance()..start();
      await settle();
      // The account had none: this device's look was uploaded.
      expect(server.puts[_appearancePath]!.single['theme'], 'parallax');

      clock = 2000;
      theme = 'parallaxDay';
      await sync.themeChanged();
      await settle();
      expect(server.puts[_appearancePath]!.last, {
        'version': 1,
        'updatedAt': 2000,
        'theme': 'parallaxDay',
        'font': 'spacegrotesk',
      });

      clock = 3000;
      await preferences.setAppFont('outfit');
      await settle();
      expect(server.puts[_appearancePath]!.last['font'], 'outfit');
      expect(applied, isEmpty, reason: 'own uploads are not re-applied');
      sync.dispose();
    });

    test('ignores themes this version does not have', () async {
      accountAppearance({
        'version': 1,
        'updatedAt': 10,
        'theme': 'futureTheme',
        'font': 'nosuchfont',
      });
      final sync = appearance()..start();
      await settle();
      expect(applied, isEmpty);
      expect(preferences.appFont.id, 'spacegrotesk');
      sync.dispose();
    });

    test('with syncing off nothing moves; turning it on takes the account '
        'look', () async {
      await preferences.setSyncAppearance(false);
      accountAppearance({
        'version': 1,
        'updatedAt': 10,
        'theme': 'parallaxDay',
        'font': 'manrope',
      });
      final sync = appearance()..start();
      await settle();
      theme = 'parallax';
      await sync.themeChanged();
      await settle();
      expect(applied, isEmpty);
      expect(server.puts[_appearancePath], isNull);

      await preferences.setSyncAppearance(true);
      await settle();
      expect(applied, ['parallaxDay']);
      expect(preferences.appFont.id, 'manrope');
      expect(server.puts[_appearancePath], isNull);
      sync.dispose();
    });

    test('the first sync also uploads room themes changed offline', () async {
      server.offline = true;
      await colours.save(_roomId, const BubbleColours(mine: Color(0xFF445566)));
      await themeSync().coloursChanged(_roomId);
      await settle();
      server.offline = false;

      final fresh = _Client(RecordingTransport(server.respond));
      fresh.rooms.add(
        matrix.Room(
          id: _roomId,
          client: fresh,
          membership: matrix.Membership.join,
        ),
      );
      access = _Access(fresh);
      final sync = appearance()..start();
      await settle();
      expect(server.puts[_coloursPath], isNull, reason: 'not synced yet');

      fresh.markSynced();
      access.notifyListeners();
      await settle();
      expect(server.puts[_coloursPath]!.single['bubbleColours'], {
        'mine': '#445566',
      });
      sync.dispose();
    });
  });
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/features/settings_sync/settings_sync.dart';
import 'package:parallax/features/settings_sync/synced_settings.dart';
import 'package:parallax/room_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scheduled_fakes.dart'
    show RecordingTransport, ScheduledDatabase, jsonResponse;

const _user = '@sam:matrix.example';
const _path =
    '/_matrix/client/v3/user/%40sam%3Amatrix.example/account_data/'
    'net.samrusselltech.parallax.settings';

/// The homeserver's account data, plus an offline switch.
class _Server {
  Map<String, Object?>? record;
  bool offline = false;
  final puts = <Map<String, Object?>>[];

  Future<http.Response> respond(http.Request request) async {
    if (offline) return jsonResponse({'errcode': 'M_UNKNOWN'}, 500);
    if (request.url.path != _path) return jsonResponse({}, 404);
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      record = body;
      puts.add(body);
      return jsonResponse({});
    }
    final stored = record;
    if (stored == null) {
      return jsonResponse({'errcode': 'M_NOT_FOUND', 'error': 'none'}, 404);
    }
    return jsonResponse(stored);
  }

  /// The settings the account holds now, as id -> [value, at].
  Map<String, List<Object?>> get settings => {
    for (final MapEntry(:key, :value) in SettingsSync.parseSettingsRecord(
      record,
    ).entries)
      key: [value.value, value.at],
  };
}

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super('sync-test', database: ScheduledDatabase(), httpClient: transport) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }

  @override
  String? get userID => _user;
  @override
  String? get deviceID => 'DEVICE';

  void markSynced() => onSync.add(matrix.SyncUpdate(nextBatch: 'batch'));

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Access extends ChangeNotifier implements MatrixSdkAccess {
  _Access(this.client);
  final matrix.Client client;
  @override
  matrix.Client? get sdkClient => client;
  @override
  bool isSessionCurrent(matrix.Client client) => identical(client, this.client);

  /// A sync delivered new account data.
  void synced() => notifyListeners();
}

/// Settings stores of a fake device: `a` (bool), `b` (x, y or z), `list`.
class _Store extends ChangeNotifier {
  final values = <String, Object?>{'a': false, 'b': 'x', 'list': <String>[]};

  void set(String id, Object? value) {
    values[id] = value;
    notifyListeners();
  }

  List<SyncedSetting> get settings => [
    SyncedSetting(
      'a',
      defaultValue: false,
      read: () async => values['a'],
      apply: (value) async {
        if (value is! bool) return false;
        set('a', value);
        return true;
      },
    ),
    SyncedSetting(
      'b',
      defaultValue: 'x',
      read: () async => values['b'],
      apply: (value) async {
        if (value is! String || !{'x', 'y', 'z'}.contains(value)) return false;
        set('b', value);
        return true;
      },
    ),
    SyncedSetting(
      'list',
      defaultValue: const <String>[],
      read: () async => values['list'],
      apply: (value) async {
        if (value is! List) return false;
        set('list', value.cast<String>());
        return true;
      },
    ),
  ];
}

Map<String, Object?> _record(Map<String, List<Object?>> settings) => {
  'version': 1,
  'settings': {
    for (final MapEntry(:key, :value) in settings.entries)
      key: {'value': value[0], 'at': value[1]},
  },
};

void main() {
  late _Server server;
  late _Client client;
  late _Access access;
  late SharedPreferences prefs;
  late _Store store;
  late ValueNotifier<bool> enabled;
  var clock = 1000;
  final syncs = <SettingsSync>[];

  SettingsSync start({List<SyncedSetting>? settings, Listenable? edits}) {
    final sync = SettingsSync(
      backend: access,
      settings: settings ?? store.settings,
      enabled: () => enabled.value,
      enabledChanges: enabled,
      edits: edits ?? store,
      preferences: prefs,
      now: () => clock,
      debounce: Duration.zero,
    )..start();
    syncs.add(sync);
    return sync;
  }

  /// Lets timers, the debounce and the fake HTTP round trips finish.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Another device wrote [record]; this one receives it in a sync.
  void otherDeviceWrote(Map<String, Object?> record) {
    server.record = record;
    client.accountData[SettingsSync.eventType] = matrix.BasicEvent(
      type: SettingsSync.eventType,
      content: record,
    );
    access.synced();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    server = _Server();
    client = _Client(RecordingTransport(server.respond));
    client.markSynced();
    access = _Access(client);
    store = _Store();
    enabled = ValueNotifier(true);
    clock = 1000;
  });

  tearDown(() {
    for (final sync in syncs) {
      sync.dispose();
    }
    syncs.clear();
  });

  test('a device offers only what it changed from the defaults', () async {
    store.values['a'] = true;
    start();
    await settle();
    // Chosen before syncing existed: stamped as oldest (0).
    expect(server.settings, {
      'a': [true, 0],
    });
  });

  test('a new device takes the account settings, uploading nothing', () async {
    otherDeviceWrote(
      _record({
        'a': [true, 500],
        'b': ['y', 600],
      }),
    );
    start();
    await settle();
    expect(store.values, {'a': true, 'b': 'y', 'list': <String>[]});
    expect(server.puts, isEmpty);
  });

  test('the account wins over choices made before syncing existed', () async {
    store.values['a'] = true;
    otherDeviceWrote(
      _record({
        'a': [false, 100],
      }),
    );
    start();
    await settle();
    expect(store.values['a'], false);
    expect(server.puts, isEmpty);
  });

  test('a change here goes up with its time and keeps the rest', () async {
    otherDeviceWrote(
      _record({
        'b': ['y', 600],
        // A setting from a newer version of the app.
        'future': ['q', 700],
      }),
    );
    start();
    await settle();
    clock = 2000;
    store.set('list', ['👍', '🎉']);
    await settle();
    expect(server.settings, {
      'b': ['y', 600],
      'future': ['q', 700],
      'list': [
        ['👍', '🎉'],
        2000,
      ],
    });
    expect(server.puts, hasLength(1));
  });

  test('changes to different settings on two devices both survive', () async {
    start();
    await settle();
    server.offline = true;
    clock = 2000;
    store.set('a', true);
    await settle();
    expect(server.record, isNull);
    // Meanwhile another device changed b.
    server.offline = false;
    otherDeviceWrote(
      _record({
        'b': ['z', 2500],
      }),
    );
    await settle();
    expect(store.values['b'], 'z');
    expect(server.settings, {
      'a': [true, 2000],
      'b': ['z', 2500],
    });
  });

  test('the newer change to the same setting wins', () async {
    start();
    await settle();
    server.offline = true;
    clock = 2000;
    store.set('a', true);
    await settle();
    server.offline = false;
    // Changed later on another device: it wins, nothing goes up.
    otherDeviceWrote(
      _record({
        'a': [false, 3000],
      }),
    );
    await settle();
    expect(store.values['a'], false);
    expect(server.puts, isEmpty);

    // Changed earlier on another device: this device's change goes up.
    clock = 4000;
    store.set('b', 'y');
    await settle();
    otherDeviceWrote(
      _record({
        'a': [false, 3000],
        'b': ['z', 3500],
      }),
    );
    await settle();
    expect(store.values['b'], 'y');
    expect(server.settings['b'], ['y', 4000]);
  });

  test('a choice this version does not know is left alone and kept', () async {
    otherDeviceWrote(
      _record({
        'b': ['w', 600],
      }),
    );
    start();
    await settle();
    expect(store.values['b'], 'x');
    clock = 2000;
    store.set('a', true);
    await settle();
    expect(server.settings, {
      'a': [true, 2000],
      'b': ['w', 600],
    });
  });

  test('its own upload coming back in a sync is not uploaded again', () async {
    start();
    await settle();
    clock = 2000;
    store.set('a', true);
    await settle();
    expect(server.puts, hasLength(1));
    otherDeviceWrote(
      jsonDecode(jsonEncode(server.record)) as Map<String, Object?>,
    );
    await settle();
    expect(server.puts, hasLength(1));
    expect(store.values['a'], true);
  });

  test('a change made offline goes up on resume', () async {
    final sync = start();
    await settle();
    server.offline = true;
    clock = 2000;
    store.set('a', true);
    await settle();
    server.offline = false;
    await sync.retryPending();
    await settle();
    expect(server.settings, {
      'a': [true, 2000],
    });
  });

  test('off: nothing goes up or comes down; on again takes the account '
      'copy', () async {
    enabled.value = false;
    start();
    await settle();
    clock = 2000;
    store.set('a', true);
    await settle();
    otherDeviceWrote(
      _record({
        'a': [false, 100],
        'b': ['y', 100],
      }),
    );
    await settle();
    expect(server.puts, isEmpty);
    expect(store.values, {'a': true, 'b': 'x', 'list': <String>[]});

    enabled.value = true;
    await settle();
    expect(store.values, {'a': false, 'b': 'y', 'list': <String>[]});
    expect(server.puts, isEmpty);
  });

  group('app settings', () {
    late AppearancePreferences preferences;

    setUp(() async {
      preferences = AppearancePreferences(prefs: prefs);
      await preferences.load();
    });
    tearDown(() => preferences.dispose());

    test('link previews in encrypted chats follow the account', () async {
      otherDeviceWrote(
        _record({
          'linkPreviewsInEncryptedChats': [true, 500],
        }),
      );
      start(
        settings: appSyncedSettings(preferences),
        edits: appSettingsEdits(preferences),
      );
      await settle();
      expect(preferences.linkPreviewsInEncryptedRooms, isTrue);
      expect(server.puts, isEmpty);

      clock = 2000;
      await preferences.setLinkPreviews(false);
      await settle();
      expect(server.settings, {
        'linkPreviewsInEncryptedChats': [true, 500],
        'linkPreviews': [false, 2000],
      });
    });

    test('every synced setting has a unique, stable id', () {
      final ids = [
        for (final setting in appSyncedSettings(preferences)) setting.id,
      ];
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, isNot(contains('textScale')));
      expect(ids, contains('linkPreviewsInEncryptedChats'));
    });
  });
}

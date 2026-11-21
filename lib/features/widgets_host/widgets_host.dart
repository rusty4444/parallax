import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';

/// A Matrix widget (room state widget or a personal account-data widget).
@immutable
class MatrixWidget {
  const MatrixWidget({
    required this.id,
    required this.name,
    required this.url,
    required this.type,
    this.personal = false,
  });

  final String id;
  final String name;
  final Uri url;
  final String type;
  final bool personal;

  static const roomStateType = 'im.vector.modular.widgets';
  static const newStateType = 'm.widget';
  static const personalAccountData = 'm.widgets';
}

/// Only plain HTTPS widget URLs are ever loaded.
Uri? parseWidgetUrl(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty) return null;
  return uri;
}

abstract interface class WidgetsFeatures {
  List<MatrixWidget> roomWidgets(String roomId);
  List<MatrixWidget> personalWidgets();
  Future<void> addRoomWidget(
    String roomId, {
    required String id,
    required String name,
    required Uri url,
    String type = 'custom',
  });
  Future<void> removeRoomWidget(String roomId, String id);
  Future<void> addPersonalWidget({
    required String id,
    required String name,
    required Uri url,
    String type = 'custom',
  });
  Future<void> removePersonalWidget(String id);
}

final _features = Expando<WidgetsFeatures>();

WidgetsFeatures? widgetsFeaturesOf(ChatBackend backend) {
  if (backend is WidgetsFeatures) return backend as WidgetsFeatures;
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _features[backend] ??= MatrixWidgets(backend);
  }
  return null;
}

class MatrixWidgets implements WidgetsFeatures {
  MatrixWidgets(this.backend);

  final ChatBackend backend;
  MatrixSdkAccess get _sdk => backend as MatrixSdkAccess;
  RoomEventFeatures get _events => backend as RoomEventFeatures;

  matrix.Client _client() {
    final client = _sdk.sdkClient;
    if (client == null || !client.isLogged()) throw StateError('Not signed in');
    return client;
  }

  bool _current(matrix.Client client) => _sdk.isSessionCurrent(client);

  MatrixWidget? _parse(String id, Object? content, {bool personal = false}) {
    if (content is! Map) return null;
    final url = content['url'];
    if (url is! String) return null;
    final parsed = parseWidgetUrl(url);
    if (parsed == null) return null;
    final name = content['name'];
    final type = content['type'];
    return MatrixWidget(
      id: id,
      name: name is String && name.isNotEmpty ? name : parsed.host,
      url: parsed,
      type: type is String ? type : 'custom',
      personal: personal,
    );
  }

  @override
  List<MatrixWidget> roomWidgets(String roomId) {
    final room = _sdk.sdkClient?.getRoomById(roomId);
    if (room == null) return const [];
    final widgets = <MatrixWidget>[];
    for (final type in [
      MatrixWidget.roomStateType,
      MatrixWidget.newStateType,
    ]) {
      final byKey = room.states[type];
      if (byKey == null) continue;
      for (final entry in byKey.entries) {
        final widget = _parse(entry.key, entry.value.content);
        if (widget != null) widgets.add(widget);
      }
    }
    return widgets;
  }

  @override
  List<MatrixWidget> personalWidgets() {
    final client = _sdk.sdkClient;
    final content =
        client?.accountData[MatrixWidget.personalAccountData]?.content;
    if (content == null) return const [];
    final widgets = <MatrixWidget>[];
    for (final entry in content.entries) {
      final value = entry.value;
      final widgetContent = value is Map ? value['content'] : null;
      final widget = _parse(entry.key, widgetContent, personal: true);
      if (widget != null) widgets.add(widget);
    }
    return widgets;
  }

  @override
  Future<void> addRoomWidget(
    String roomId, {
    required String id,
    required String name,
    required Uri url,
    String type = 'custom',
  }) async {
    final client = _client();
    await _events.setRoomState(roomId, MatrixWidget.roomStateType, {
      'type': type,
      'url': url.toString(),
      'name': name,
      'creatorUserId': client.userID,
      'id': id,
    }, stateKey: id);
    if (!_current(client)) throw StateError('Session changed');
  }

  @override
  Future<void> removeRoomWidget(String roomId, String id) async {
    final client = _client();
    await _events.setRoomState(
      roomId,
      MatrixWidget.roomStateType,
      {},
      stateKey: id,
    );
    if (!_current(client)) throw StateError('Session changed');
  }

  Future<Map<String, Object?>> _personalContent() async {
    final client = _client();
    try {
      final content = await client.request(
        matrix.RequestType.GET,
        '/client/v3/user/${Uri.encodeComponent(client.userID!)}'
        '/account_data/${MatrixWidget.personalAccountData}',
      );
      return Map<String, Object?>.from(content);
    } catch (_) {
      return {};
    }
  }

  Future<void> _writePersonal(Map<String, Object?> content) async {
    final client = _client();
    await client.request(
      matrix.RequestType.PUT,
      '/client/v3/user/${Uri.encodeComponent(client.userID!)}'
      '/account_data/${MatrixWidget.personalAccountData}',
      data: content,
    );
    if (!_current(client)) throw StateError('Session changed');
  }

  @override
  Future<void> addPersonalWidget({
    required String id,
    required String name,
    required Uri url,
    String type = 'custom',
  }) async {
    final content = await _personalContent();
    content[id] = {
      'content': {'type': type, 'url': url.toString(), 'name': name, 'id': id},
      'type': MatrixWidget.personalAccountData,
      'state_key': id,
    };
    await _writePersonal(content);
  }

  @override
  Future<void> removePersonalWidget(String id) async {
    final content = await _personalContent();
    content.remove(id);
    await _writePersonal(content);
  }
}

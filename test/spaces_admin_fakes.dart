// Shared fake for the Space administration widget tests (not a test file).
import 'dart:async';

import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/spaces_admin/spaces_admin_features.dart';
import 'package:parallax/features/spaces_admin/spaces_admin_models.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/room_details.dart';

import 'rooms_admin_fakes.dart';

const spaceId = '!space:example.org';
const general = '!general:example.org';
const random = '!random:example.org';
const ops = '!ops:example.org';
const club = '!club:example.org';

RoomDetails spaceDetails({int myPower = 100, String? alias}) =>
    RoomDetails.fromState(
      roomId: spaceId,
      userId: me,
      state: [
        const RoomStateEntry('m.room.create', '', {
          'room_version': '11',
          'type': 'm.space',
        }, me),
        const RoomStateEntry('m.room.name', '', {'name': 'Team'}, me),
        RoomStateEntry('m.room.power_levels', '', {
          'users': {me: myPower},
        }, me),
        const RoomStateEntry('m.room.join_rules', '', {
          'join_rule': 'invite',
        }, me),
        if (alias != null)
          RoomStateEntry('m.room.canonical_alias', '', {'alias': alias}, me),
        memberState(me, 'join', name: 'Me'),
        memberState(guest, 'join', name: 'Guest'),
      ],
    );

SpaceChildEntry child(
  String id,
  String name, {
  bool suggested = false,
  int members = 3,
  bool joined = true,
}) => SpaceChildEntry(
  roomId: id,
  via: const ['example.org'],
  suggested: suggested,
  name: name,
  members: members,
  joined: joined,
);

class SpacesBackend extends AdminBackend implements SpacesAdminFeatures {
  SpacesBackend() {
    roomList = [
      ...roomList,
      const ChatRoom(
        id: spaceId,
        name: 'Team',
        preview: '',
        lastActivity: null,
        isSpace: true,
      ),
    ];
  }

  RoomDetails space = spaceDetails();
  List<SpaceChildEntry> children = [
    child(general, 'General', suggested: true),
    child(random, 'Random'),
  ];
  List<SpaceRoomCandidate> candidates = const [
    SpaceRoomCandidate(id: general, name: 'General', members: 4),
    SpaceRoomCandidate(id: random, name: 'Random', alias: '#random:x.org'),
  ];
  LeaveSpacePlan? plan;
  AuthorisedSpaces authorised = const AuthorisedSpaces(
    selectable: [SpaceRef(id: spaceId, name: 'Team')],
    unknown: [],
  );
  final failAdd = <String>{};
  Object? leaveFailure;

  @override
  Future<RoomDetails> getRoomDetails(String roomId) async =>
      roomId == spaceId ? space : details;

  void _created(String id, String name, {bool isSpace = false}) {
    roomList = [
      ...roomList,
      ChatRoom(
        id: id,
        name: name,
        preview: '',
        lastActivity: null,
        isSpace: isSpace,
      ),
    ];
    scheduleMicrotask(notifyListeners);
  }

  // --- MessagingFeatures (Space browser) ---------------------------------
  @override
  List<SpaceSummary> get spaces => const [
    SpaceSummary(id: spaceId, name: 'Team', isSpace: true, joined: true),
  ];
  @override
  Future<SpacePage> loadSpace(String spaceId, {String? nextBatch}) async =>
      const SpacePage([SpaceSummary(id: general, name: 'General')]);

  // --- SpacesAdminFeatures -----------------------------------------------
  @override
  bool isJoinedSpace(String roomId) => roomId == spaceId;
  @override
  List<SpaceRef> get joinedSpaceRefs => const [
    SpaceRef(id: spaceId, name: 'Team'),
  ];
  @override
  List<SpaceRef> spacesAcceptingChild(String roomId) => roomId == spaceId
      ? const []
      : const [SpaceRef(id: spaceId, name: 'Team')];
  @override
  List<SpaceRoomCandidate> addableRooms(String spaceId) => candidates;

  @override
  Future<String> createSpace(SpaceCreationOptions options) async {
    calls.add(
      'createSpace:${options.name}:${options.access.name}:'
      '${options.aliasLocalpart}',
    );
    const id = '!newspace:example.org';
    _created(id, options.name, isSpace: true);
    return id;
  }

  @override
  Future<String> createRoomInSpace(
    String spaceId,
    SpaceCreationOptions options,
  ) async {
    calls.add('createIn:$spaceId:${options.name}:${options.access.name}');
    const id = '!newroom:example.org';
    _created(id, options.name);
    return id;
  }

  @override
  Future<SpaceGraph> loadSpaceGraph(String spaceId) async =>
      SpaceGraph(details: space, children: children);

  @override
  Future<List<String>> addChildren(
    String spaceId,
    List<String> roomIds, {
    bool suggested = false,
  }) async {
    calls.add('add:$spaceId:${roomIds.join(',')}:$suggested');
    return [
      for (final id in roomIds)
        if (failAdd.contains(id)) id,
    ];
  }

  @override
  Future<void> removeChild(String spaceId, String roomId) async {
    calls.add('remove:$roomId');
    children = [
      for (final c in children)
        if (c.roomId != roomId) c,
    ];
  }

  @override
  Future<void> setChildSuggested(
    String spaceId,
    String roomId,
    bool suggested,
  ) async => calls.add('suggest:$roomId:$suggested');

  @override
  Future<void> moveChild(String spaceId, String roomId, int toIndex) async =>
      calls.add('move:$roomId:$toIndex');

  @override
  Future<LeaveSpacePlan> leavePlan(String spaceId) async => plan!;

  @override
  Future<void> leaveSpaceAndRooms(String spaceId, List<String> roomIds) async {
    calls.add('leaveSpace:$spaceId:${roomIds.join(',')}');
    if (leaveFailure case final failure?) throw failure;
  }

  @override
  AuthorisedSpaces authorisedSpacesFor(String roomId, List<String> allowed) =>
      authorised;

  @override
  Future<void> setAuthorisedSpaces(
    String roomId,
    List<String> spaceIds, {
    required bool askToJoin,
  }) async => calls.add('authorised:${spaceIds.join(',')}:$askToJoin');
}

LeaveSpacePlan leavePlanFor({bool lastAdmin = false}) => LeaveSpacePlan(
  spaceId: spaceId,
  spaceName: 'Team',
  details: spaceDetails(),
  lastAdmin: lastAdmin,
  rooms: const [
    LeaveSpaceRoom(id: general, name: 'General', members: 4),
    LeaveSpaceRoom(id: random, name: 'Random', members: 2),
    LeaveSpaceRoom(id: ops, name: 'Ops', members: 3, lastAdmin: true),
  ],
);

// Backend surface of the Space administration module (Element X
// features/space: AddRoomToSpace, LeaveSpace, SpaceSettings, root Space
// screen; features/securityandprivacy: ManageAuthorizedSpaces;
// features/createroom: new Space).
//
// Screens resolve it with [spacesAdminFeaturesOf]. Test fakes implement
// [SpacesAdminFeatures] directly; the live implementation wraps
// [MatrixSdkAccess] + [RoomEventFeatures] (see docs/parity/architecture.md).
import '../../chat_backend.dart';
import '../../room_events.dart';
import 'matrix_spaces_admin.dart';
import 'spaces_admin_models.dart';

abstract interface class SpacesAdminFeatures {
  /// Server name of the signed-in account (Space addresses, `via`).
  String? get homeserverName;

  /// Whether [roomId] is a joined Space (synced state).
  bool isJoinedSpace(String roomId);

  /// Joined Spaces, sorted by name (synced state).
  List<SpaceRef> get joinedSpaceRefs;

  /// Joined Spaces that [roomId] may be added to according to synced power
  /// levels and that do not already list it. Writes re-check fresh state.
  List<SpaceRef> spacesAcceptingChild(String roomId);

  /// Joined rooms that can be added to [spaceId]: not Spaces, not DMs and
  /// not already children (Element X AddRoomToSpace).
  List<SpaceRoomCandidate> addableRooms(String spaceId);

  /// Creates an `m.space` room (one non-idempotent POST). Throws
  /// [RoomCreationFailure] only for definite non-creation.
  Future<String> createSpace(SpaceCreationOptions options);

  /// Creates a room whose `m.space.parent` points at [spaceId]. The caller
  /// adds it as a child once synced ([addChildren]); throws
  /// [RoomCreationFailure] only for definite non-creation.
  Future<String> createRoomInSpace(
    String spaceId,
    SpaceCreationOptions options,
  );

  /// Fresh server state: permissions and children in spec order.
  Future<SpaceGraph> loadSpaceGraph(String spaceId);

  /// Writes `m.space.child` for each room (and `m.space.parent` on the
  /// child when permitted). Returns the room IDs that failed.
  Future<List<String>> addChildren(
    String spaceId,
    List<String> roomIds, {
    bool suggested = false,
  });

  /// Removes a child (empty `m.space.child` content) and, when permitted,
  /// the child's `m.space.parent` for this Space.
  Future<void> removeChild(String spaceId, String roomId);

  Future<void> setChildSuggested(String spaceId, String roomId, bool suggested);

  /// Moves a child to [toIndex] of the spec-ordered list by writing `order`.
  Future<void> moveChild(String spaceId, String roomId, int toIndex);

  /// Rooms that could be left with the Space and last-admin warnings.
  Future<LeaveSpacePlan> leavePlan(String spaceId);

  /// Leaves [roomIds], then the Space. Throws [LeaveSpaceFailure] when a
  /// room could not be left (the Space is then kept).
  Future<void> leaveSpaceAndRooms(String spaceId, List<String> roomIds);

  /// Spaces offered for [roomId]'s "Space members" access, given the
  /// currently [allowed] Space IDs (synced state).
  AuthorisedSpaces authorisedSpacesFor(String roomId, List<String> allowed);

  /// Sets `restricted` (or `knock_restricted` when [askToJoin]) with an
  /// allow list of [spaceIds], after a fresh permission check.
  Future<void> setAuthorisedSpaces(
    String roomId,
    List<String> spaceIds, {
    required bool askToJoin,
  });
}

final _features = Expando<SpacesAdminFeatures>();

/// Resolves Space administration for [backend]; null for backends without
/// Matrix access (older fakes).
SpacesAdminFeatures? spacesAdminFeaturesOf(ChatBackend backend) {
  if (backend is SpacesAdminFeatures) return backend as SpacesAdminFeatures;
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _features[backend] ??= MatrixSpacesAdmin(backend);
  }
  return null;
}

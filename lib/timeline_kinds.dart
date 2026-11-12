import 'chat_backend.dart';

/// Event types shown in the main timeline. Relations such as reactions,
/// edits and poll responses are aggregated onto their target instead.
const timelineStateTypes = {
  'm.room.member',
  'm.room.name',
  'm.room.topic',
  'm.room.avatar',
  'm.room.create',
  'm.room.encryption',
  'm.room.join_rules',
  'm.room.history_visibility',
  'm.room.power_levels',
  'm.room.pinned_events',
  'm.room.tombstone',
  'm.room.canonical_alias',
  'm.room.guest_access',
  'm.room.server_acl',
};

/// Live location share (MSC3672 beacon_info state). Individual beacons
/// (MSC3672 `beacon`) are references and are aggregated, not shown.
const beaconInfoTypes = {'m.beacon_info', 'org.matrix.msc3672.beacon_info'};
const beaconTypes = {'m.beacon', 'org.matrix.msc3672.beacon'};

const pollStartTypes = {'m.poll.start', 'org.matrix.msc3381.poll.start'};
const pollResponseTypes = {
  'm.poll.response',
  'org.matrix.msc3381.poll.response',
};
const pollEndTypes = {'m.poll.end', 'org.matrix.msc3381.poll.end'};

/// Call events rendered in the timeline. MatrixRTC membership state
/// (`m.call.member`) is intentionally hidden, as in Element X.
const callTimelineTypes = {
  'm.call.invite',
  'm.rtc.notification',
  'org.matrix.msc4075.rtc.notification',
};

bool isTimelineVisibleType(String type) =>
    type == 'm.room.message' ||
    type == 'm.room.encrypted' ||
    type == 'm.sticker' ||
    pollStartTypes.contains(type) ||
    beaconInfoTypes.contains(type) ||
    callTimelineTypes.contains(type) ||
    timelineStateTypes.contains(type);

/// Whether a voice message (MSC3245) rather than a plain audio file.
bool isVoiceContent(Map<String, Object?> content) =>
    content.containsKey('org.matrix.msc3245.voice') ||
    content.containsKey('org.matrix.msc3245.voice.v2');

EntryKind entryKindFor({
  required String type,
  required String? msgtype,
  required Map<String, Object?> content,
  required bool redacted,
}) {
  if (redacted) return EntryKind.redacted;
  if (type == 'm.room.encrypted') return EntryKind.undecryptable;
  if (type == 'm.sticker') return EntryKind.sticker;
  if (pollStartTypes.contains(type)) return EntryKind.poll;
  if (beaconInfoTypes.contains(type)) return EntryKind.liveLocation;
  if (callTimelineTypes.contains(type)) return EntryKind.call;
  if (timelineStateTypes.contains(type)) return EntryKind.state;
  if (type != 'm.room.message') return EntryKind.unknown;
  return switch (msgtype) {
    'm.emote' => EntryKind.emote,
    'm.notice' => EntryKind.notice,
    'm.image' => EntryKind.image,
    'm.video' => EntryKind.video,
    'm.audio' => isVoiceContent(content) ? EntryKind.voice : EntryKind.audio,
    'm.file' => EntryKind.file,
    'm.location' => EntryKind.location,
    _ => EntryKind.text,
  };
}

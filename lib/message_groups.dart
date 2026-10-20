import 'chat_backend.dart';

class MessageGroup {
  MessageGroup(List<ChatEntry> entries) : entries = List.unmodifiable(entries);

  final List<ChatEntry> entries;
  bool get isGallery => entries.length > 1 && entries.first.isImage;
}

/// Group only consecutive photos from the same sender, never across a text
/// message or a time gap. A five-photo run becomes a grid of four plus one.
List<MessageGroup> groupTimeline(List<ChatEntry> messages) {
  final groups = <MessageGroup>[];
  var index = 0;
  while (index < messages.length) {
    final first = messages[index];
    if (!first.isImage) {
      groups.add(MessageGroup([first]));
      index++;
      continue;
    }
    final images = <ChatEntry>[first];
    while (images.length < 4 && index + images.length < messages.length) {
      final next = messages[index + images.length];
      final gap = next.time.difference(images.last.time);
      if (!next.isImage ||
          next.sender != first.sender ||
          gap.isNegative ||
          gap > const Duration(minutes: 5)) {
        break;
      }
      images.add(next);
    }
    groups.add(MessageGroup(images));
    index += images.length;
  }
  return groups;
}

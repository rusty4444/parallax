import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';

/// Which thread roots the threads list shows (`include` on
/// `GET /_matrix/client/v1/rooms/{roomId}/threads`).
enum ThreadListFilter { all, participated }

/// One thread in a room's threads list.
@immutable
class ThreadSummary {
  const ThreadSummary({
    required this.root,
    required this.replyCount,
    this.latest,
    this.participated = false,
    this.unread,
  });

  /// The thread root (main-timeline event).
  final ChatEntry root;

  /// Server-side reply count from the bundled `m.thread` aggregation.
  final int replyCount;

  /// Latest reply, when the server bundled one.
  final ChatEntry? latest;

  /// Whether the current user has sent or been mentioned in the thread.
  final bool participated;

  /// Whether the latest reply is newer than this device's threaded read
  /// receipt. Null when unknown (for example no threaded receipt yet).
  final bool? unread;

  /// Time of the latest activity, for ordering and display.
  DateTime get activity => latest?.time ?? root.time;
}

@immutable
class ThreadListPage {
  const ThreadListPage(this.threads, {this.nextBatch});
  final List<ThreadSummary> threads;
  final String? nextBatch;
}

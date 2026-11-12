// Settings → Media → "Sync thumbnails": goes through every chat and saves
// the pictures it shows (chat and profile photos, image, sticker and video
// thumbnails from the history stored on this device) to the thumbnail
// store, so they appear straight away and offline.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../media_disk_cache.dart';
import '../../room_events.dart';
import 'matrix_thumbnail_sync.dart';

/// One thumbnail to save: its store key and how to download it.
@immutable
class ThumbnailJob {
  const ThumbnailJob(this.key, this.download);
  final String key;

  /// The bytes to store, or null when there is nothing to save.
  final Future<Uint8List?> Function() download;
}

/// A sync pass, pinned to the session that started it.
abstract interface class ThumbnailSyncPass {
  ThumbnailStore get store;

  /// Chats to go through, in room list order.
  List<String> get roomIds;

  /// False once the session that started the pass has ended.
  bool get isCurrent;

  /// Avatars and media thumbnails shown for [roomId].
  Future<List<ThumbnailJob>> jobsFor(String roomId);
}

/// Starts sync passes; implemented for Matrix by [MatrixThumbnailSyncSource].
abstract interface class ThumbnailSyncSource {
  /// The thumbnail store for the signed-in session (null when unavailable).
  Future<ThumbnailStore?> thumbnailStore();

  /// A pass for the signed-in session, or null when signed out.
  Future<ThumbnailSyncPass?> beginThumbnailSync();
}

/// Progress of the latest pass.
@immutable
class ThumbnailSyncState {
  const ThumbnailSyncState({
    this.running = false,
    this.roomsDone = 0,
    this.roomsTotal = 0,
    this.saved = 0,
    this.alreadySaved = 0,
    this.failed = 0,
    this.finished = false,
    this.stopped = false,
    this.error,
  });

  final bool running;
  final int roomsDone;
  final int roomsTotal;

  /// Newly downloaded and saved.
  final int saved;

  /// Already on this device before the pass.
  final int alreadySaved;

  /// Couldn't be downloaded or saved.
  final int failed;

  /// The last pass went through every chat.
  final bool finished;

  /// The last pass was stopped before the end.
  final bool stopped;

  /// Why the last pass couldn't run or ended early.
  final String? error;

  /// Share of chats done, null before the chat list is known.
  double? get fraction => roomsTotal == 0 ? null : roomsDone / roomsTotal;
}

/// Runs thumbnail sync passes for one backend. Keeps going when Settings is
/// closed; a pass stops when asked to, or when its session ends.
class ThumbnailSync extends ChangeNotifier {
  ThumbnailSync(this.source, {this.parallel = 4});

  final ThumbnailSyncSource source;

  /// Downloads at once.
  final int parallel;

  ThumbnailSyncState _state = const ThumbnailSyncState();
  ThumbnailSyncState get state => _state;

  MediaCacheUsage? _usage;

  /// Space used on this device, once [refreshUsage] has read it.
  MediaCacheUsage? get usage => _usage;

  int _run = 0;
  bool _disposed = false;
  Future<void>? _current;

  /// Completes when the running pass has stopped (for tests).
  @visibleForTesting
  Future<void> get idle => _current ?? Future<void>.value();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refreshUsage() async {
    MediaCacheUsage usage;
    try {
      usage =
          await (await source.thumbnailStore())?.usage() ??
          MediaCacheUsage.empty;
    } catch (_) {
      usage = MediaCacheUsage.empty;
    }
    _usage = usage;
    _notify();
  }

  /// Starts a pass unless one is running.
  Future<void> start() {
    if (_state.running) return idle;
    final run = ++_run;
    _state = const ThumbnailSyncState(running: true);
    _notify();
    return _current = _sync(run).whenComplete(() {
      if (run == _run) _current = null;
      unawaited(refreshUsage());
    });
  }

  /// Stops the running pass; downloads already under way still finish.
  void stop() {
    if (!_state.running) return;
    _run++;
    final state = _state;
    _state = ThumbnailSyncState(
      roomsDone: state.roomsDone,
      roomsTotal: state.roomsTotal,
      saved: state.saved,
      alreadySaved: state.alreadySaved,
      failed: state.failed,
      stopped: true,
    );
    _notify();
  }

  /// Deletes every saved thumbnail (not while a pass runs).
  Future<void> clear() async {
    if (_state.running) return;
    await (await source.thumbnailStore())?.clear();
    _state = const ThumbnailSyncState();
    await refreshUsage();
  }

  Future<void> _sync(int run) async {
    ThumbnailSyncPass? pass;
    try {
      pass = await source.beginThumbnailSync();
    } catch (_) {
      pass = null;
    }
    if (run != _run) return;
    if (pass == null) {
      _state = const ThumbnailSyncState(
        error: 'Thumbnails can’t be saved right now. Check you’re signed in.',
      );
      _notify();
      return;
    }
    final store = pass.store;
    final rooms = pass.roomIds;
    final seen = <String>{};
    var roomsDone = 0;
    var saved = 0;
    var alreadySaved = 0;
    var failed = 0;
    bool active() => run == _run && !_disposed && pass!.isCurrent;
    void publish({bool running = true}) {
      if (run != _run) return;
      _state = ThumbnailSyncState(
        running: running,
        roomsDone: roomsDone,
        roomsTotal: rooms.length,
        saved: saved,
        alreadySaved: alreadySaved,
        failed: failed,
        finished: !running && roomsDone == rooms.length,
        error: !running && !pass!.isCurrent
            ? 'Stopped because you signed out.'
            : null,
      );
      _notify();
    }

    publish();
    var downloading = 0;
    final waiters = Queue<Completer<void>>();
    final pending = <Future<void>>{};

    Future<void> save(ThumbnailJob job) async {
      try {
        if (await store.contains(job.key)) {
          alreadySaved++;
          return;
        }
        final bytes = await job.download();
        if (bytes != null &&
            bytes.isNotEmpty &&
            await store.write(job.key, bytes)) {
          saved++;
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }

    // Chats are read one after another while up to [parallel] downloads run,
    // so the next chat's list is ready when a download slot frees up. A chat
    // counts as done once all of its downloads have finished.
    for (final roomId in rooms) {
      if (!active()) break;
      List<ThumbnailJob> jobs;
      try {
        jobs = await pass.jobsFor(roomId);
      } catch (_) {
        jobs = const [];
      }
      final roomTasks = <Future<void>>[];
      var queuedAll = true;
      for (final job in jobs) {
        if (!active()) {
          queuedAll = false;
          break;
        }
        if (!seen.add(job.key)) continue;
        if (downloading >= parallel) {
          final waiter = Completer<void>();
          waiters.add(waiter);
          await waiter.future;
          if (!active()) {
            queuedAll = false;
            break;
          }
        } else {
          downloading++;
        }
        late final Future<void> task;
        task = save(job).whenComplete(() {
          pending.remove(task);
          if (waiters.isNotEmpty) {
            waiters.removeFirst().complete();
          } else {
            downloading--;
          }
        });
        pending.add(task);
        roomTasks.add(task);
      }
      if (!queuedAll) break;
      late final Future<void> roomDone;
      roomDone = Future.wait(roomTasks).then((_) {
        pending.remove(roomDone);
        roomsDone++;
        publish();
      });
      pending.add(roomDone);
    }
    // Let started downloads finish so the counts are final.
    while (pending.isNotEmpty) {
      await Future.wait(pending.toList());
    }
    publish(running: false);
  }

  @override
  void dispose() {
    _disposed = true;
    _run++;
    super.dispose();
  }
}

final _syncs = Expando<ThumbnailSync>('thumbnail sync');

/// The thumbnail sync for [backend], or null when it has no thumbnail store.
ThumbnailSync? thumbnailSyncOf(ChatBackend backend) {
  final existing = _syncs[backend];
  if (existing != null) return existing;
  final ThumbnailSyncSource? source = backend is ThumbnailSyncSource
      ? backend as ThumbnailSyncSource
      : backend is MatrixSdkAccess && backend is MediaCacheAccess
      ? MatrixThumbnailSyncSource(backend)
      : null;
  if (source == null) return null;
  return _syncs[backend] = ThumbnailSync(source);
}

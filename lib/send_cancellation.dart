import 'dart:async';

class SendCancelled implements Exception {
  const SendCancelled();
  @override
  String toString() => 'Send cancelled';
}

/// A cancellation request. Callers still own joining and resource cleanup.
class SendCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const SendCancelled();
  }
}

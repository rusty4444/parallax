// Hand-off between background isolates (FCM handler, UnifiedPush service,
// notification actions) and the main isolate, which owns the Matrix client
// and database. Background entries try the main isolate first; only when no
// main isolate answers may they open a short-lived client of their own.
//
// The main isolate registers a port with IsolateNameServer while the signed-in
// app is mounted (wrapWithNotifications). A port left behind by a dead isolate
// never acknowledges, so after a short timeout it is removed and treated as
// absent.
import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

/// Name of the main isolate's hand-off port.
const pushHandoffPortName = 'net.samrussell.parallax.push.v1';

/// How long a background isolate waits for the main isolate to acknowledge.
/// A live main isolate acknowledges synchronously on receipt.
const pushHandoffAckTimeout = Duration(seconds: 2);

/// Process-wide port registry (IsolateNameServer), behind an interface for
/// tests.
abstract interface class PortDirectory {
  SendPort? lookup(String name);
  bool register(SendPort port, String name);
  bool remove(String name);
}

class IsolateNameServerDirectory implements PortDirectory {
  const IsolateNameServerDirectory();
  @override
  SendPort? lookup(String name) => IsolateNameServer.lookupPortByName(name);
  @override
  bool register(SendPort port, String name) =>
      IsolateNameServer.registerPortWithName(port, name);
  @override
  bool remove(String name) => IsolateNameServer.removePortNameMapping(name);
}

enum HandoffResult {
  /// The main isolate took the message and will handle it.
  accepted,

  /// The main isolate is alive but refused the message (stale registration,
  /// other account …). Do not handle it in the background either.
  rejected,

  /// No main isolate answered: the background isolate may handle it.
  unavailable,
}

/// Kinds of handed-off messages.
const handoffKindPush = 'push';
const handoffKindReply = 'reply';
const handoffKindMarkRead = 'mark_read';

/// Sends [payload] (plain JSON-like data only) to the main isolate.
Future<HandoffResult> handOffToMainIsolate(
  String kind,
  Map<String, Object?> payload, {
  PortDirectory directory = const IsolateNameServerDirectory(),
  Duration ackTimeout = pushHandoffAckTimeout,
}) async {
  final port = directory.lookup(pushHandoffPortName);
  if (port == null) return HandoffResult.unavailable;
  final answers = ReceivePort();
  try {
    port.send({'kind': kind, 'payload': payload, 'reply': answers.sendPort});
    final answer = await answers.first.timeout(
      ackTimeout,
      onTimeout: () => null,
    );
    if (answer == true) return HandoffResult.accepted;
    if (answer == false) return HandoffResult.rejected;
    // Nobody answered: the registration belongs to an isolate that died.
    // Only remove it if it is still the same stale port.
    if (directory.lookup(pushHandoffPortName) == port) {
      directory.remove(pushHandoffPortName);
    }
    return HandoffResult.unavailable;
  } catch (_) {
    return HandoffResult.unavailable;
  } finally {
    answers.close();
  }
}

/// Synchronously decides whether the main isolate accepts a message. The
/// actual work is scheduled by the handler and must not delay the answer.
typedef HandoffHandler =
    bool Function(String kind, Map<String, Object?> payload);

/// Main-isolate end of the hand-off.
class PushHandoffServer {
  PushHandoffServer(
    this._handler, {
    this.directory = const IsolateNameServerDirectory(),
  });

  final HandoffHandler _handler;
  final PortDirectory directory;
  ReceivePort? _port;

  bool get running => _port != null;

  /// Registers this isolate as the hand-off target (replacing a stale
  /// registration left by a previous engine).
  void start() {
    if (_port != null) return;
    final port = ReceivePort();
    port.listen(_receive);
    directory.remove(pushHandoffPortName);
    if (!directory.register(port.sendPort, pushHandoffPortName)) {
      port.close();
      return;
    }
    _port = port;
  }

  void _receive(Object? message) {
    if (message is! Map) return;
    final reply = message['reply'];
    final kind = message['kind'];
    final payload = message['payload'];
    var accepted = false;
    if (kind is String && payload is Map) {
      try {
        accepted = _handler(kind, Map<String, Object?>.from(payload));
      } catch (_) {
        accepted = false;
      }
    }
    if (reply is SendPort) reply.send(accepted);
  }

  void stop() {
    final port = _port;
    if (port == null) return;
    _port = null;
    if (directory.lookup(pushHandoffPortName) == port.sendPort) {
      directory.remove(pushHandoffPortName);
    }
    port.close();
  }
}

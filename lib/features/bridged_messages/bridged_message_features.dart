import '../../chat_backend.dart';
import '../../room_events.dart';
import 'bridged_message_models.dart';
import 'mautrix_bridged_messages.dart';

/// Optional new-message operations supplied by configured Mautrix bridges.
/// Implementations do not send messages; sending remains in RoomScreen.
abstract interface class BridgedMessageFeatures {
  String? get defaultPhoneRegion;
  List<String> get serviceWarnings;
  Future<List<BridgeAccount>> loadAccounts();
  Future<List<BridgeRecipient>> searchRecipients(
    BridgeAccount account,
    String query,
  );
  Future<BridgeRecipient> resolveRecipient(
    BridgeAccount account,
    String identifier,
  );
  Future<BridgeConversation> ensureDirectConversation(
    BridgeAccount account,
    BridgeRecipient recipient,
  );
}

final _features = Expando<BridgedMessageFeatures>();

BridgedMessageFeatures? bridgedMessageFeaturesOf(ChatBackend backend) {
  if (backend is BridgedMessageFeatures) {
    return backend as BridgedMessageFeatures;
  }
  if (backend is! MatrixSdkAccess) return null;
  final config = BridgedMessageConfig.fromEnvironment();
  if (!config.available) return null;
  return _features[backend] ??= MatrixBridgedMessages(backend, config);
}

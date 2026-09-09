import '../../models/hub_models.dart';

/// Produces short-lived channel bindings for the current Mobile body.
///
/// Hub remains Provider-neutral; implementations validate and consume only the
/// binding format understood by this client.
abstract interface class ConversationProvisioner {
  String get serviceName;

  Uri get serviceUri;

  Future<HubConfig> provision({String sessionIntent = ''});
}

/// Restores an existing registration after an explicit user action. This is
/// not enrollment: implementations must prove the Device identity before
/// replacing a local reference, and must never create or approve a Claim.
abstract interface class RecoverableConversationProvisioner
    implements ConversationProvisioner {
  Future<void> recoverClaim();
}

class ConversationRecoveryUnavailable implements Exception {
  const ConversationRecoveryUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

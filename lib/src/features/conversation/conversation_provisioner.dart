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

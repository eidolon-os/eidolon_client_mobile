class LocalControllerChallenge {
  const LocalControllerChallenge({
    required this.controllerId,
    required this.challenge,
    required this.resetEpoch,
  });

  factory LocalControllerChallenge.fromJson(Map<String, dynamic> value) {
    final controllerId = value['controller_id'];
    final challenge = value['challenge'];
    final resetEpoch = value['reset_epoch'];
    if (value.length != 5 ||
        value['contract_version'] != '1' ||
        value['purpose'] != 'eidolon-controller-local-auth-v1' ||
        controllerId is! String ||
        !RegExp(r'^ectrl-[0-9a-f]{20}$').hasMatch(controllerId) ||
        challenge is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(challenge) ||
        resetEpoch is! int ||
        resetEpoch < 0) {
      throw const FormatException(
        'Local API 返回了无效的 Controller challenge',
      );
    }
    return LocalControllerChallenge(
      controllerId: controllerId,
      challenge: challenge,
      resetEpoch: resetEpoch,
    );
  }

  final String controllerId;
  final String challenge;
  final int resetEpoch;

  Map<String, dynamic> toJson() => {
        'contract_version': '1',
        'purpose': 'eidolon-controller-local-auth-v1',
        'controller_id': controllerId,
        'challenge': challenge,
        'reset_epoch': resetEpoch,
      };
}

class LocalControllerSession {
  const LocalControllerSession({
    required this.accessToken,
    required this.expiresAt,
    required this.controllerId,
    required this.resetEpoch,
  });

  /// The session, validated on the members this app actually uses.
  ///
  /// It used to require `controller.length == 7`, and the seventh was
  /// `owner_id`. Bootstrap stopped publishing that — it was Host state
  /// asserting an Owner scope the Data plane might have no Workspace for, and
  /// the Owner is now resolved per request by the plane that holds it — so the
  /// principal came back with six members and this threw on every connect.
  ///
  /// The count is gone rather than adjusted. It pinned the shape of a document
  /// this app does not own, in a place where being wrong makes the first
  /// request fail; a member this app has no use for should not be able to do
  /// that. What is required is what is read, and extras are ignored — the same
  /// rule `HostOverview.fromJson` already followed, which is why that payload
  /// survived the same change.
  factory LocalControllerSession.fromJson(Map<String, dynamic> value) {
    final controller = value['controller'];
    final expiresAt = DateTime.tryParse(value['expires_at'] as String? ?? '');
    final token = value['access_token'];
    if (value['contract_version'] != '1' ||
        value['token_type'] != 'Bearer' ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ||
        expiresAt == null ||
        controller is! Map ||
        controller['contract_version'] != '1' ||
        controller['controller_id'] is! String ||
        !RegExp(r'^ectrl-[0-9a-f]{20}$')
            .hasMatch(controller['controller_id'] as String) ||
        controller['role'] != 'host_admin' ||
        !{'android', 'ios'}.contains(controller['platform']) ||
        controller['reset_epoch'] is! int ||
        (controller['reset_epoch'] as int) < 0) {
      throw const FormatException(
        'Local API 返回了无效的 Controller session',
      );
    }
    return LocalControllerSession(
      accessToken: token,
      expiresAt: expiresAt.toUtc(),
      controllerId: controller['controller_id'] as String,
      resetEpoch: controller['reset_epoch'] as int,
    );
  }

  final String accessToken;
  final DateTime expiresAt;
  final String controllerId;
  final int resetEpoch;
}

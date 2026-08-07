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
    required this.ownerId,
  });

  factory LocalControllerSession.fromJson(Map<String, dynamic> value) {
    final controller = value['controller'];
    final expiresAt = DateTime.tryParse(value['expires_at'] as String? ?? '');
    final token = value['access_token'];
    final ownerId = controller is Map ? controller['owner_id'] : null;
    if (value.length != 5 ||
        value['contract_version'] != '1' ||
        value['token_type'] != 'Bearer' ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ||
        expiresAt == null ||
        controller is! Map ||
        controller.length != 7 ||
        controller['contract_version'] != '1' ||
        controller['controller_id'] is! String ||
        !RegExp(r'^ectrl-[0-9a-f]{20}$')
            .hasMatch(controller['controller_id'] as String) ||
        controller['role'] != 'host_admin' ||
        !{'android', 'ios'}.contains(controller['platform']) ||
        controller['reset_epoch'] is! int ||
        (controller['reset_epoch'] as int) < 0 ||
        (ownerId != null &&
            (ownerId is! String ||
                !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')
                    .hasMatch(ownerId)))) {
      throw const FormatException(
        'Local API 返回了无效的 Controller session',
      );
    }
    return LocalControllerSession(
      accessToken: token,
      expiresAt: expiresAt.toUtc(),
      controllerId: controller['controller_id'] as String,
      resetEpoch: controller['reset_epoch'] as int,
      ownerId: ownerId as String?,
    );
  }

  final String accessToken;
  final DateTime expiresAt;
  final String controllerId;
  final int resetEpoch;
  final String? ownerId;
}

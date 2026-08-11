enum BootstrapMode { development, production }

enum HostClaimState { unclaimed, claimed }

enum HostNetworkState {
  unconfigured,
  staging,
  connected,
  degraded,
  rollingBack,
}

/// Whether this Host has an Owner's workspace on it yet. Provisioning and
/// degraded were modelled on both sides and written by neither.
enum HostWorkspaceState { absent, ready }

class HostDescriptor {
  const HostDescriptor({
    required this.contractVersion,
    required this.hostId,
    required this.hostPublicKey,
    required this.hostPublicKeyFingerprint,
    required this.bleServiceUuid,
  });

  factory HostDescriptor.fromJson(Map<String, dynamic> json) {
    final contractVersion = _requiredString(json, 'contract_version');
    if (contractVersion != '1') {
      throw FormatException(
        'Unsupported Bootstrap descriptor version: $contractVersion',
      );
    }
    final hostId = _requiredString(json, 'host_id');
    if (!RegExp(r'^ehost-[0-9a-f]{20}$').hasMatch(hostId)) {
      throw const FormatException('Invalid Eidolon Host ID');
    }
    final fingerprint = _requiredString(
      json,
      'host_public_key_fingerprint',
    );
    if (!fingerprint.startsWith('sha256:')) {
      throw const FormatException('Invalid Host public-key fingerprint');
    }
    final bleServiceUuid = _requiredString(json, 'ble_service_uuid');
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(bleServiceUuid)) {
      throw const FormatException('Invalid commissioning service UUID');
    }
    return HostDescriptor(
      contractVersion: contractVersion,
      hostId: hostId,
      hostPublicKey: _requiredString(json, 'host_public_key'),
      hostPublicKeyFingerprint: fingerprint,
      bleServiceUuid: bleServiceUuid,
    );
  }

  final String contractVersion;
  final String hostId;
  final String hostPublicKey;
  final String hostPublicKeyFingerprint;
  final String bleServiceUuid;
}

class HostBootstrapState {
  const HostBootstrapState({
    required this.resetEpoch,
    required this.claim,
    required this.network,
    required this.workspace,
    required this.updatedAt,
  });

  factory HostBootstrapState.fromJson(Map<String, dynamic> json) {
    final resetEpoch = json['reset_epoch'];
    if (resetEpoch is! int || resetEpoch < 0) {
      throw const FormatException('Invalid reset epoch');
    }
    final updatedAt = DateTime.tryParse(_requiredString(json, 'updated_at'));
    if (updatedAt == null) {
      throw const FormatException('Invalid Bootstrap state timestamp');
    }
    return HostBootstrapState(
      resetEpoch: resetEpoch,
      claim: _parseClaim(_requiredString(json, 'claim_state')),
      network: _parseNetwork(_requiredString(json, 'network_state')),
      workspace: _parseWorkspace(_requiredString(json, 'workspace_state')),
      updatedAt: updatedAt,
    );
  }

  final int resetEpoch;
  final HostClaimState claim;
  final HostNetworkState network;
  final HostWorkspaceState workspace;
  final DateTime updatedAt;
}

class HostOverview {
  const HostOverview({
    required this.contractVersion,
    required this.status,
    required this.mode,
    required this.descriptor,
    required this.state,
  });

  factory HostOverview.fromJson(Map<String, dynamic> json) {
    final contractVersion = _requiredString(json, 'contract_version');
    if (contractVersion != '1') {
      throw FormatException(
        'Unsupported Local API contract version: $contractVersion',
      );
    }
    final status = _requiredString(json, 'status');
    if (status != 'running') {
      throw FormatException('Unexpected Bootstrap status: $status');
    }
    return HostOverview(
      contractVersion: contractVersion,
      status: status,
      mode: switch (_requiredString(json, 'mode')) {
        'development' => BootstrapMode.development,
        'production' => BootstrapMode.production,
        final value => throw FormatException('Unknown Bootstrap mode: $value'),
      },
      descriptor: HostDescriptor.fromJson(
        _requiredMap(json, 'descriptor'),
      ),
      state: HostBootstrapState.fromJson(_requiredMap(json, 'state')),
    );
  }

  final String contractVersion;
  final String status;
  final BootstrapMode mode;
  final HostDescriptor descriptor;
  final HostBootstrapState state;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Missing or invalid $key');
  }
  return value;
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map<String, dynamic>) {
    throw FormatException('Missing or invalid $key');
  }
  return value;
}

HostClaimState _parseClaim(String value) => switch (value) {
      'unclaimed' => HostClaimState.unclaimed,
      'claimed' => HostClaimState.claimed,
      _ => throw FormatException('Unknown claim state: $value'),
    };

HostNetworkState _parseNetwork(String value) => switch (value) {
      'unconfigured' => HostNetworkState.unconfigured,
      'staging' => HostNetworkState.staging,
      'connected' => HostNetworkState.connected,
      'degraded' => HostNetworkState.degraded,
      'rolling_back' => HostNetworkState.rollingBack,
      _ => throw FormatException('Unknown network state: $value'),
    };

HostWorkspaceState _parseWorkspace(String value) => switch (value) {
      'absent' => HostWorkspaceState.absent,
      'ready' => HostWorkspaceState.ready,
      _ => throw FormatException('Unknown workspace state: $value'),
    };


// GENERATED from eidolon_sdk/contracts/device_foundation/v1/common/schemas.schema.json.
// Do not edit by hand; contracts/device_foundation/v1/generation/generate.py owns this file.

class OwnerDomainDescriptorV1 {
  const OwnerDomainDescriptorV1({
    required this.ownerDomainId,
    required this.directoryRevision,
    required this.trustRootRefs,
    required this.endpoints,
    required this.issuedAt,
    required this.expiresAt,
    required this.signingKeyId,
    required this.signature,
  });

  final String ownerDomainId;
  final int directoryRevision;
  final List<AuthorityEndpointV1> endpoints;
  final List<String> trustRootRefs;
  final String issuedAt;
  final String expiresAt;
  final String signingKeyId;
  final String signature;

  factory OwnerDomainDescriptorV1.fromJson(Map<String, dynamic> value) {
    const keys = {
      'owner_domain_id',
      'directory_revision',
      'trust_root_refs',
      'endpoints',
      'issued_at',
      'expires_at',
      'signing_key_id',
      'signature',
    };
    if (value.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(value.keys.toSet()).isNotEmpty) {
      throw const FormatException('Invalid Owner Domain descriptor fields');
    }
    final ownerDomainId = _text(value['owner_domain_id'], 128);
    final revision = value['directory_revision'];
    final roots = value['trust_root_refs'];
    final rawEndpoints = value['endpoints'];
    final issuedAt = DateTime.tryParse(value['issued_at'] as String? ?? '');
    final expiresAt = DateTime.tryParse(value['expires_at'] as String? ?? '');
    if (revision is! int ||
        revision < 1 ||
        roots is! List ||
        roots.isEmpty ||
        roots.length > 16 ||
        rawEndpoints is! List ||
        rawEndpoints.isEmpty ||
        rawEndpoints.length > 32 ||
        issuedAt == null ||
        expiresAt == null ||
        !expiresAt.isAfter(issuedAt)) {
      throw const FormatException('Invalid Owner Domain descriptor');
    }
    final trustRoots =
        roots.map((item) => _digest(item)).toList(growable: false);
    if (trustRoots.toSet().length != trustRoots.length) {
      throw const FormatException('Duplicate Owner root reference');
    }
    return OwnerDomainDescriptorV1(
      ownerDomainId: ownerDomainId,
      directoryRevision: revision,
      trustRootRefs: trustRoots,
      endpoints: rawEndpoints.map((item) {
        if (item is! Map) {
          throw const FormatException('Invalid Authority endpoint');
        }
        return AuthorityEndpointV1.fromJson(Map<String, dynamic>.from(item));
      }).toList(growable: false),
      issuedAt: value['issued_at']! as String,
      expiresAt: value['expires_at']! as String,
      signingKeyId: _digest(value['signing_key_id']),
      signature: _signature(value['signature']),
    );
  }

  Map<String, dynamic> toJson() => {
        'owner_domain_id': ownerDomainId,
        'directory_revision': directoryRevision,
        'trust_root_refs': trustRootRefs,
        'endpoints':
            endpoints.map((item) => item.toJson()).toList(growable: false),
        'issued_at': issuedAt,
        'expires_at': expiresAt,
        'signing_key_id': signingKeyId,
        'signature': signature,
      };
}

class AuthorityEndpointV1 {
  const AuthorityEndpointV1({
    required this.authority,
    required this.logicalAudience,
    required this.uri,
    required this.transportProfile,
    required this.priority,
  });

  final String authority;
  final String logicalAudience;
  final Uri uri;
  final String transportProfile;
  final int priority;

  factory AuthorityEndpointV1.fromJson(Map<String, dynamic> value) {
    const keys = {
      'authority',
      'logical_audience',
      'uri',
      'transport_profile',
      'priority',
    };
    if (value.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(value.keys.toSet()).isNotEmpty) {
      throw const FormatException('Invalid Authority endpoint fields');
    }
    final authority = _text(value['authority'], 32);
    final audience = _text(value['logical_audience'], 128);
    final uri = Uri.tryParse(_text(value['uri'], 2048));
    final profile = _text(value['transport_profile'], 32);
    final priority = value['priority'];
    if (!const {'admission', 'device-control', 'body-mesh', 'companion'}
            .contains(authority) ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !const {'https-json', 'mqtt-tls', 'nats-tls'}.contains(profile) ||
        priority is! int ||
        priority < 0 ||
        priority > 65535) {
      throw const FormatException('Invalid Authority endpoint');
    }
    return AuthorityEndpointV1(
      authority: authority,
      logicalAudience: audience,
      uri: uri,
      transportProfile: profile,
      priority: priority,
    );
  }

  Map<String, dynamic> toJson() => {
        'authority': authority,
        'logical_audience': logicalAudience,
        'uri': uri.toString(),
        'transport_profile': transportProfile,
        'priority': priority,
      };
}

enum CommissioningStatusStateV1 {
  applyingConfiguration('applying-configuration'),
  committed('committed'),
  rolledBack('rolled-back'),
  failed('failed');

  const CommissioningStatusStateV1(this.wireValue);
  final String wireValue;
}

class CommissioningConditionsV1 {
  const CommissioningConditionsV1({
    required this.wifiConnected,
    required this.ownerRouteValidated,
    required this.trustCommitted,
    required this.networkCommitted,
  });

  final bool wifiConnected;
  final bool ownerRouteValidated;
  final bool trustCommitted;
  final bool networkCommitted;

  factory CommissioningConditionsV1.fromJson(Map<String, dynamic> value) {
    const keys = {
      'wifi_connected',
      'owner_route_validated',
      'trust_committed',
      'network_committed',
    };
    if (value.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(value.keys.toSet()).isNotEmpty ||
        value.values.any((item) => item is! bool)) {
      throw const FormatException('Invalid commissioning conditions');
    }
    return CommissioningConditionsV1(
      wifiConnected: value['wifi_connected']! as bool,
      ownerRouteValidated: value['owner_route_validated']! as bool,
      trustCommitted: value['trust_committed']! as bool,
      networkCommitted: value['network_committed']! as bool,
    );
  }
}

class CommissioningStatusEvidenceV1 {
  const CommissioningStatusEvidenceV1({
    required this.sessionId,
    required this.setupGeneration,
    required this.stateRevision,
    required this.state,
    required this.conditions,
    required this.failureCode,
  });

  final String sessionId;
  final int setupGeneration;
  final int stateRevision;
  final CommissioningStatusStateV1 state;
  final CommissioningConditionsV1 conditions;
  final String? failureCode;

  bool get isCommittedTerminal =>
      state == CommissioningStatusStateV1.committed &&
      conditions.wifiConnected &&
      conditions.ownerRouteValidated &&
      conditions.trustCommitted &&
      conditions.networkCommitted &&
      failureCode == null;

  factory CommissioningStatusEvidenceV1.fromJson(Map<String, dynamic> value) {
    const keys = {
      'contract',
      'contract_version',
      'profile_id',
      'session_id',
      'setup_generation',
      'state_revision',
      'state',
      'conditions',
      'failure_code',
    };
    if (value.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(value.keys.toSet()).isNotEmpty ||
        value['contract'] != 'eidolon.device-foundation.commissioning-status' ||
        value['contract_version'] != '1.0' ||
        value['profile_id'] != 'eidolon-trust-p256-hpke-v1') {
      throw const FormatException('Invalid commissioning status envelope');
    }
    final sessionId = _text(value['session_id'], 128);
    if (sessionId.length < 16 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionId)) {
      throw const FormatException('Invalid commissioning session id');
    }
    final generation = value['setup_generation'];
    final revision = value['state_revision'];
    CommissioningStatusStateV1? state;
    for (final candidate in CommissioningStatusStateV1.values) {
      if (candidate.wireValue == value['state']) state = candidate;
    }
    final rawConditions = value['conditions'];
    final failure = value['failure_code'];
    const failures = {
      'NETWORK_REJECTED',
      'OWNER_ROUTE_UNAVAILABLE',
      'OWNER_IDENTITY_MISMATCH',
      'STORAGE_UNAVAILABLE',
      'WINDOW_EXPIRED',
      'CANCELLED',
      'INTERNAL',
    };
    if (generation is! int ||
        generation < 1 ||
        revision is! int ||
        revision < 1 ||
        state == null ||
        rawConditions is! Map ||
        (failure != null &&
            (failure is! String || !failures.contains(failure)))) {
      throw const FormatException('Invalid commissioning status');
    }
    final evidence = CommissioningStatusEvidenceV1(
      sessionId: sessionId,
      setupGeneration: generation,
      stateRevision: revision,
      state: state,
      conditions: CommissioningConditionsV1.fromJson(
        Map<String, dynamic>.from(rawConditions),
      ),
      failureCode: failure as String?,
    );
    if (state == CommissioningStatusStateV1.committed &&
        !evidence.isCommittedTerminal) {
      throw const FormatException(
          'Incomplete committed commissioning evidence');
    }
    if ((state == CommissioningStatusStateV1.rolledBack ||
            state == CommissioningStatusStateV1.failed) &&
        (failure == null ||
            evidence.conditions.trustCommitted ||
            evidence.conditions.networkCommitted)) {
      throw const FormatException('Invalid failed commissioning evidence');
    }
    return evidence;
  }
}

class CommissioningTerminalAckV1 {
  const CommissioningTerminalAckV1({
    required this.sessionId,
    required this.setupGeneration,
    required this.observedStateRevision,
  });

  final String sessionId;
  final int setupGeneration;
  final int observedStateRevision;

  Map<String, dynamic> toJson() => {
        'contract': 'eidolon.device-foundation.commissioning-terminal-ack',
        'contract_version': '1.0',
        'session_id': sessionId,
        'setup_generation': setupGeneration,
        'observed_state_revision': observedStateRevision,
      };
}

String _text(Object? value, int maximum) {
  if (value is! String || value.isEmpty || value.length > maximum) {
    throw const FormatException('Invalid bounded contract string');
  }
  return value;
}

String _digest(Object? value) {
  final text = _text(value, 71);
  if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(text)) {
    throw const FormatException('Invalid SHA-256 digest');
  }
  return text;
}

String _signature(Object? value) {
  final text = _text(value, 86);
  if (!RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(text)) {
    throw const FormatException('Invalid P-256 signature');
  }
  return text;
}

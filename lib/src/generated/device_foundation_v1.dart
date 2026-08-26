// GENERATED from eidolon_sdk/contracts/device_foundation/v1/common/schemas.schema.json.
// Do not edit by hand; contracts/device_foundation/v1/generation/generate.py owns this file.

final class OwnerDomainIdV1 {
  const OwnerDomainIdV1._(this.value);
  final String value;
  factory OwnerDomainIdV1.parse(Object? raw) {
    final value = _text(raw, 128);
    if (!RegExp(r'^owner-[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(value)) {
      throw const FormatException(
        'Business Owner ID is not an Owner Domain ID',
      );
    }
    return OwnerDomainIdV1._(value);
  }
}

final class DeviceInstanceIdV1 {
  const DeviceInstanceIdV1._(this.value);
  final String value;

  /// A device instance identity is a statement about the device's own
  /// operational key, not a name a client may choose. An invented id — this
  /// app once derived `mobile-android-<hash>` from ANDROID_ID — is refused
  /// here rather than compared unequal forever against Hub's records.
  factory DeviceInstanceIdV1.parse(Object? raw) {
    final value = _text(raw, 80);
    if (!RegExp(r'^device-instance-[0-9a-f]{64}$').hasMatch(value)) {
      throw const FormatException(
        'Device instance ID is not derived from an operational key',
      );
    }
    return DeviceInstanceIdV1._(value);
  }
}

final class BusinessOwnerIdV1 {
  const BusinessOwnerIdV1._(this.value);
  final String value;
  factory BusinessOwnerIdV1.parse(Object? raw) {
    final value = _text(raw, 128);
    if (!RegExp(r'^owner_[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(value)) {
      throw const FormatException('Owner Domain ID is not a business Owner ID');
    }
    return BusinessOwnerIdV1._(value);
  }
}

final class DeviceRefV1 {
  const DeviceRefV1({
    required this.deviceInstanceId,
    required this.ownerDomainId,
    required this.ownerDomainGeneration,
    required this.claimGeneration,
    required this.trustEpoch,
  });
  final String deviceInstanceId;
  final OwnerDomainIdV1 ownerDomainId;
  final int ownerDomainGeneration;
  final int claimGeneration;
  final int trustEpoch;
  factory DeviceRefV1.fromJson(Map<String, dynamic> value) {
    const keys = {
      'device_instance_id',
      'owner_domain_id',
      'owner_domain_generation',
      'claim_generation',
      'trust_epoch',
    };
    if (value.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(value.keys.toSet()).isNotEmpty) {
      throw const FormatException('Invalid DeviceRef fields');
    }
    final domainGeneration = value['owner_domain_generation'];
    final claimGeneration = value['claim_generation'];
    final trustEpoch = value['trust_epoch'];
    if (domainGeneration is! int ||
        domainGeneration < 1 ||
        claimGeneration is! int ||
        claimGeneration < 1 ||
        trustEpoch is! int ||
        trustEpoch < 1) {
      throw const FormatException('Invalid DeviceRef generation');
    }
    return DeviceRefV1(
      deviceInstanceId: DeviceInstanceIdV1.parse(
        value['device_instance_id'],
      ).value,
      ownerDomainId: OwnerDomainIdV1.parse(value['owner_domain_id']),
      ownerDomainGeneration: domainGeneration,
      claimGeneration: claimGeneration,
      trustEpoch: trustEpoch,
    );
  }

  Map<String, dynamic> toJson() => {
    'device_instance_id': deviceInstanceId,
    'owner_domain_id': ownerDomainId.value,
    'owner_domain_generation': ownerDomainGeneration,
    'claim_generation': claimGeneration,
    'trust_epoch': trustEpoch,
  };
}

final class ManifestRefV1 {
  const ManifestRefV1({
    required this.manifestId,
    required this.revision,
    required this.digest,
  });
  final String manifestId;
  final int revision;
  final String digest;
  factory ManifestRefV1.fromJson(Map<String, dynamic> value) {
    _strictObject(value, const {'manifest_id', 'revision', 'digest'});
    return ManifestRefV1(
      manifestId: _identifier(value['manifest_id']),
      revision: _positive(value['revision']),
      digest: _digest(value['digest']),
    );
  }
}

class OwnerDomainDescriptorV1 {
  const OwnerDomainDescriptorV1({
    required this.ownerDomainId,
    required this.ownerDomainGeneration,
    required this.directoryRevision,
    required this.descriptorUri,
    required this.trustRootRefs,
    required this.endpoints,
    required this.issuedAt,
    required this.expiresAt,
    required this.signingKeyId,
    required this.signature,
  });

  final String ownerDomainId;
  final int ownerDomainGeneration;
  final int directoryRevision;
  final String descriptorUri;
  final List<AuthorityEndpointV1> endpoints;
  final List<String> trustRootRefs;
  final String issuedAt;
  final String expiresAt;
  final String signingKeyId;
  final String signature;

  factory OwnerDomainDescriptorV1.fromJson(Map<String, dynamic> value) {
    const keys = {
      'owner_domain_id',
      'owner_domain_generation',
      'directory_revision',
      'descriptor_uri',
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
    final ownerDomainGeneration = value['owner_domain_generation'];
    final revision = value['directory_revision'];
    final descriptorUri = _text(value['descriptor_uri'], 2048);
    final parsedDescriptorUri = Uri.tryParse(descriptorUri);
    final roots = value['trust_root_refs'];
    final rawEndpoints = value['endpoints'];
    final issuedAt = DateTime.tryParse(value['issued_at'] as String? ?? '');
    final expiresAt = DateTime.tryParse(value['expires_at'] as String? ?? '');
    if (ownerDomainGeneration is! int ||
        ownerDomainGeneration < 1 ||
        revision is! int ||
        revision < 1 ||
        parsedDescriptorUri == null ||
        parsedDescriptorUri.scheme != 'https' ||
        parsedDescriptorUri.host.isEmpty ||
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
    final trustRoots = roots
        .map((item) => _digest(item))
        .toList(growable: false);
    if (trustRoots.toSet().length != trustRoots.length) {
      throw const FormatException('Duplicate Owner root reference');
    }
    return OwnerDomainDescriptorV1(
      ownerDomainId: ownerDomainId,
      ownerDomainGeneration: ownerDomainGeneration,
      directoryRevision: revision,
      descriptorUri: descriptorUri,
      trustRootRefs: trustRoots,
      endpoints: rawEndpoints
          .map((item) {
            if (item is! Map) {
              throw const FormatException('Invalid Authority endpoint');
            }
            return AuthorityEndpointV1.fromJson(
              Map<String, dynamic>.from(item),
            );
          })
          .toList(growable: false),
      issuedAt: value['issued_at']! as String,
      expiresAt: value['expires_at']! as String,
      signingKeyId: _digest(value['signing_key_id']),
      signature: _signature(value['signature']),
    );
  }

  Map<String, dynamic> toJson() => {
    'owner_domain_id': ownerDomainId,
    'owner_domain_generation': ownerDomainGeneration,
    'directory_revision': directoryRevision,
    'descriptor_uri': descriptorUri,
    'trust_root_refs': trustRootRefs,
    'endpoints': endpoints.map((item) => item.toJson()).toList(growable: false),
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
    if (!const {
          'admission',
          'device-control',
          'body-mesh',
          'companion',
        }.contains(authority) ||
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

enum DeliveryKindV1 {
  twinDelta('twin_delta'),
  operation('operation'),
  stopGeneration('stop_generation');

  const DeliveryKindV1(this.wireValue);
  final String wireValue;
}

final class DeliverEnvelopeV1 {
  const DeliverEnvelopeV1({
    required this.deliveryAttemptId,
    required this.messageId,
    required this.kind,
    required this.deviceRef,
    required this.deadline,
    required this.payloadSchema,
    required this.payload,
  });

  final String deliveryAttemptId;
  final String messageId;
  final DeliveryKindV1 kind;
  final DeviceRefV1 deviceRef;
  final DateTime deadline;
  final Uri payloadSchema;
  final Map<String, dynamic> payload;

  factory DeliverEnvelopeV1.fromJson(Map<String, dynamic> value) {
    _strictObject(value, const {
      'delivery_attempt_id', 'message_id', 'kind', 'device_ref',
      'deadline', 'payload_schema', 'payload',
    });
    final kind = DeliveryKindV1.values.where(
      (candidate) => candidate.wireValue == value['kind'],
    ).firstOrNull;
    final deadline = DateTime.tryParse(value['deadline'] as String? ?? '');
    final payloadSchema = Uri.tryParse(_text(value['payload_schema'], 2048));
    if (kind == null || deadline == null || !deadline.isUtc ||
        payloadSchema == null || !payloadSchema.hasScheme) {
      throw const FormatException('Invalid delivery envelope');
    }
    return DeliverEnvelopeV1(
      deliveryAttemptId: _identifier(value['delivery_attempt_id']),
      messageId: _identifier(value['message_id']),
      kind: kind,
      deviceRef: DeviceRefV1.fromJson(_map(value['device_ref'])),
      deadline: deadline,
      payloadSchema: payloadSchema,
      payload: _map(value['payload']),
    );
  }

  Map<String, dynamic> toJson() => {
    'delivery_attempt_id': deliveryAttemptId,
    'message_id': messageId,
    'kind': kind.wireValue,
    'device_ref': deviceRef.toJson(),
    'deadline': deadline.toIso8601String(),
    'payload_schema': payloadSchema.toString(),
    'payload': payload,
  };
}

enum DeliveryAcceptanceStateV1 {
  accepted('accepted'),
  rejected('rejected');

  const DeliveryAcceptanceStateV1(this.wireValue);
  final String wireValue;
}

final class DeliveryAcceptanceV1 {
  const DeliveryAcceptanceV1({
    required this.deliveryAttemptId,
    required this.state,
    required this.adapterCode,
  });

  final String deliveryAttemptId;
  final DeliveryAcceptanceStateV1 state;
  final String? adapterCode;

  factory DeliveryAcceptanceV1.fromJson(Map<String, dynamic> value) {
    _strictObject(value, const {'delivery_attempt_id', 'state', 'adapter_code'});
    final state = DeliveryAcceptanceStateV1.values.where(
      (candidate) => candidate.wireValue == value['state'],
    ).firstOrNull;
    final adapterCode = value['adapter_code'];
    if (state == null ||
        (state == DeliveryAcceptanceStateV1.accepted) != (adapterCode == null) ||
        (adapterCode != null && adapterCode is! String)) {
      throw const FormatException('Invalid delivery acceptance');
    }
    return DeliveryAcceptanceV1(
      deliveryAttemptId: _identifier(value['delivery_attempt_id']),
      state: state,
      adapterCode: adapterCode as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'delivery_attempt_id': deliveryAttemptId,
    'state': state.wireValue,
    'adapter_code': adapterCode,
  };
}

final class DeviceEvidenceEnvelopeV1 {
  const DeviceEvidenceEnvelopeV1({
    required this.deliveryAttemptId,
    required this.messageId,
    required this.deviceRef,
    required this.payloadSchema,
    required this.payload,
  });

  final String deliveryAttemptId;
  final String messageId;
  final DeviceRefV1 deviceRef;
  final Uri payloadSchema;
  final Map<String, dynamic> payload;

  factory DeviceEvidenceEnvelopeV1.fromJson(Map<String, dynamic> value) {
    _strictObject(value, const {
      'delivery_attempt_id', 'message_id', 'kind', 'device_ref',
      'payload_schema', 'payload',
    });
    final payloadSchema = Uri.tryParse(_text(value['payload_schema'], 2048));
    if (value['kind'] != 'operation_ack' || payloadSchema == null ||
        !payloadSchema.hasScheme) {
      throw const FormatException('Invalid device evidence envelope');
    }
    return DeviceEvidenceEnvelopeV1(
      deliveryAttemptId: _identifier(value['delivery_attempt_id']),
      messageId: _identifier(value['message_id']),
      deviceRef: DeviceRefV1.fromJson(_map(value['device_ref'])),
      payloadSchema: payloadSchema,
      payload: _map(value['payload']),
    );
  }

  Map<String, dynamic> toJson() => {
    'delivery_attempt_id': deliveryAttemptId,
    'message_id': messageId,
    'kind': 'operation_ack',
    'device_ref': deviceRef.toJson(),
    'payload_schema': payloadSchema.toString(),
    'payload': payload,
  };
}

enum DeviceLocalEraseStateV1 {
  accepted('accepted'),
  pending('pending'),
  deliveryAccepted('delivery-accepted'),
  acknowledged('acknowledged'),
  expired('expired'),
  permanentFailure('permanent-failure');

  const DeviceLocalEraseStateV1(this.wireValue);
  final String wireValue;
}

class DeviceLocalEraseOperationStatusV1 {
  const DeviceLocalEraseOperationStatusV1({
    required this.operationId,
    required this.requestFingerprint,
    required this.state,
    required this.claimGeneration,
    required this.trustEpoch,
    required this.terminalResult,
  });

  final String operationId;
  final String requestFingerprint;
  final DeviceLocalEraseStateV1 state;
  final int claimGeneration;
  final int trustEpoch;
  final String? terminalResult;

  bool get deviceErased =>
      state == DeviceLocalEraseStateV1.acknowledged &&
      terminalResult == 'erased';

  factory DeviceLocalEraseOperationStatusV1.fromJson(
    Map<String, dynamic> value,
  ) {
    const keys = {
      'contract',
      'contract_version',
      'operation_id',
      'operation_type',
      'request_fingerprint',
      'device_ref',
      'created_at',
      'deadline',
      'state',
      'attempt_count',
      'terminal_result',
    };
    if (value.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(value.keys.toSet()).isNotEmpty ||
        value['contract'] !=
            'eidolon.device-foundation.device-operation-status' ||
        value['contract_version'] != '1.0' ||
        value['operation_type'] != 'device-local.erase') {
      throw const FormatException('Invalid device-local.erase status');
    }
    final ref = value['device_ref'];
    final generation = ref is Map ? ref['claim_generation'] : null;
    final epoch = ref is Map ? ref['trust_epoch'] : null;
    DeviceLocalEraseStateV1? state;
    for (final candidate in DeviceLocalEraseStateV1.values) {
      if (candidate.wireValue == value['state']) state = candidate;
    }
    final result = value['terminal_result'];
    if (state == null ||
        generation is! int ||
        generation < 1 ||
        epoch is! int ||
        epoch < 1 ||
        (result != null &&
            !const {
              'erased',
              'permanent-failure',
              'deadline-expired',
            }.contains(result))) {
      throw const FormatException('Invalid device-local.erase state');
    }
    final expectedResult = switch (state) {
      DeviceLocalEraseStateV1.acknowledged => 'erased',
      DeviceLocalEraseStateV1.expired => 'deadline-expired',
      DeviceLocalEraseStateV1.permanentFailure => 'permanent-failure',
      _ => null,
    };
    if (result != expectedResult) {
      throw const FormatException(
        'Incoherent device-local.erase terminal state',
      );
    }
    return DeviceLocalEraseOperationStatusV1(
      operationId: _text(value['operation_id'], 128),
      requestFingerprint: _digest(value['request_fingerprint']),
      state: state,
      claimGeneration: generation,
      trustEpoch: epoch,
      terminalResult: result as String?,
    );
  }
}

/// Whether a descriptor's identity is bound to a product credential.
///
/// Development and production devices differ in this value only; the setup act
/// that follows is the same one either way.
enum SetupDescriptorTrustV1 {
  developmentTofu('development-tofu'),
  manufacturerBound('manufacturer-bound');

  const SetupDescriptorTrustV1(this.wireValue);
  final String wireValue;
}

/// How much longer a setup offer lasts, when it lasts a bounded time at all.
///
/// The type exists so that "this offer does not end" cannot be written as a
/// number. There is no public constructor, and the only way in refuses anything
/// that is not a duration a controller could act on — so 0, the sentinel the
/// descriptor used to carry for an endless window, cannot survive being read.
/// Absence of a deadline is `null`, and on the wire it is an absent field.
final class SetupWindowRemainingSecondsV1 {
  const SetupWindowRemainingSecondsV1._(this.seconds);

  final int seconds;

  /// Reads a duration that is present. Absence is the caller's to notice: this
  /// type is only reached once the field is there, and a field that is there
  /// has to name a duration a controller could act on. `null`, 0 and negatives
  /// are all refused for the same reason — none of them is a duration, and
  /// letting any of them through is what a sentinel is.
  factory SetupWindowRemainingSecondsV1.parse(Object? raw) {
    if (raw is! int || raw is bool || raw < 1) {
      throw const FormatException('Invalid setup window duration');
    }
    return SetupWindowRemainingSecondsV1._(raw);
  }
}

/// What a device says about itself before it belongs to anyone.
class SetupDescriptorV1 {
  const SetupDescriptorV1({
    required this.deviceId,
    required this.deviceKind,
    required this.displayName,
    required this.identityFingerprint,
    required this.sessionId,
    required this.expiresIn,
    required this.trust,
  });

  /// The descriptor's own wire version, not the Device Foundation `1.0`: this
  /// document predates a device having any Owner.
  static const String contractVersion = '1';

  static const Set<String> requiredFields = {
    'contract_version',
    'device_id',
    'device_kind',
    'display_name',
    'identity_fingerprint',
    'session_id',
    'trust',
  };

  /// The one field a descriptor may leave out, and the only way to say that
  /// this setup offer does not end.
  static const Set<String> optionalFields = {'expires_in_seconds'};

  final String deviceId;
  final String deviceKind;
  final String displayName;
  final String identityFingerprint;
  final String sessionId;

  /// How long this offer still lasts, or null when it does not end.
  ///
  /// A duration, not an instant: the device has not joined a network and has no
  /// wall clock, so the absolute expiry is the reader's to compute against its
  /// own. Null is neither "already expired" nor "expires now" — nothing may
  /// substitute an instant for the absence.
  final SetupWindowRemainingSecondsV1? expiresIn;
  final SetupDescriptorTrustV1 trust;

  factory SetupDescriptorV1.fromJson(Map<String, dynamic> value) {
    final keys = value.keys.toSet();
    if (requiredFields.difference(keys).isNotEmpty ||
        keys.difference(requiredFields.union(optionalFields)).isNotEmpty ||
        value['contract_version'] != contractVersion) {
      throw const FormatException('Invalid setup descriptor envelope');
    }
    final fingerprint = _text(value['identity_fingerprint'], 128);
    if (!RegExp(r'^p256:[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('Invalid device identity fingerprint');
    }
    final sessionId = _text(value['session_id'], 128);
    if (sessionId.length < 16 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionId)) {
      throw const FormatException('Invalid setup session id');
    }
    SetupDescriptorTrustV1? trust;
    for (final candidate in SetupDescriptorTrustV1.values) {
      if (candidate.wireValue == value['trust']) trust = candidate;
    }
    if (trust == null) {
      // A trust level this build does not know is not something to guess at in
      // the safe direction or the unsafe one.
      throw const FormatException('Unknown setup descriptor trust level');
    }
    return SetupDescriptorV1(
      deviceId: DeviceInstanceIdV1.parse(value['device_id']).value,
      deviceKind: _identifier(value['device_kind']),
      displayName: _text(value['display_name'], 128),
      identityFingerprint: fingerprint,
      sessionId: sessionId,
      // A field that is there names a duration; a field that is not there is
      // the offer that does not end. Nothing in between: writing the key with
      // no value is the same mistake as writing 0 in it.
      expiresIn: value.containsKey('expires_in_seconds')
          ? SetupWindowRemainingSecondsV1.parse(value['expires_in_seconds'])
          : null,
      trust: trust,
    );
  }

  /// The wire form. An offer with no deadline carries no duration field at all:
  /// writing `null` there would be the same mistake as writing 0.
  Map<String, dynamic> toJson() => {
    'contract_version': contractVersion,
    'device_id': deviceId,
    'device_kind': deviceKind,
    'display_name': displayName,
    if (expiresIn != null) 'expires_in_seconds': expiresIn!.seconds,
    'identity_fingerprint': identityFingerprint,
    'session_id': sessionId,
    'trust': trust.wireValue,
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
        'Incomplete committed commissioning evidence',
      );
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

enum EnrollmentProposalStateV1 {
  pendingReview('pending_review'),
  approvedAwaitingHandoff('approved_awaiting_handoff'),
  grantDelivered('grant_delivered'),
  grantAcknowledged('grant_acknowledged'),
  rejected('rejected'),
  expired('expired'),
  canceled('canceled'),
  claimRevoked('claim_revoked');

  const EnrollmentProposalStateV1(this.wireValue);
  final String wireValue;
}

enum AdmissionEventTypeV1 {
  proposalCreated('live.eidolon.device.enrollment-proposal-created.v1'),
  approved('live.eidolon.device.enrollment-approved.v1'),
  rejected('live.eidolon.device.enrollment-rejected.v1'),
  expired('live.eidolon.device.enrollment-expired.v1'),
  canceled('live.eidolon.device.enrollment-canceled.v1'),
  grantDelivered('live.eidolon.device.claim-grant-delivered.v1'),
  grantAcknowledged('live.eidolon.device.claim-grant-acknowledged.v1'),
  claimActivated('live.eidolon.device.claim-activated.v1'),
  claimSuspended('live.eidolon.device.claim-suspended.v1'),
  claimResumed('live.eidolon.device.claim-resumed.v1'),
  claimRevoked('live.eidolon.device.claim-revoked.v1'),
  trustEpochChanged('live.eidolon.device.claim-trust-epoch-changed.v1'),
  manifestAccepted('live.eidolon.device.manifest-accepted.v1');

  const AdmissionEventTypeV1(this.wireValue);
  final String wireValue;
}

const admissionEventSourceV1 = 'urn:eidolon:authority:admission';

enum ClaimStateV1 {
  active('active'),
  suspended('suspended'),
  revoked('revoked');

  const ClaimStateV1(this.wireValue);
  final String wireValue;
}

class _AdmissionMapV1 {
  _AdmissionMapV1(Map<String, dynamic> value, Set<String> fields)
    : json = Map.unmodifiable(_strictObject(value, fields));
  final Map<String, dynamic> json;
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(json);
}

class CommandEnvelopeV1 extends _AdmissionMapV1 {
  CommandEnvelopeV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'contract',
        'contract_version',
        'command_type',
        'command_id',
        'correlation_id',
        'causation_id',
        'issued_at',
        'deadline',
        'payload',
        'extensions',
      });
}

class CommandResultV1 extends _AdmissionMapV1 {
  CommandResultV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'command_id',
        'outcome',
        'resource_ref',
        'resource_revision',
        'occurred_at',
        'extensions',
      });
}

class DeviceProblemV1 extends _AdmissionMapV1 {
  DeviceProblemV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'code',
        'category',
        'retryable',
        'authority',
        'command_id',
        'resource_ref',
        'current_revision',
        'current_generation',
        'retry_after_ms',
        'detail',
        'incident_id',
      });
}

class RevokeClaimV1 extends _AdmissionMapV1 {
  RevokeClaimV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'operation',
        'command_id',
        'correlation_id',
        'device_ref',
        'reason',
      }) {
    if (json['operation'] != 'device.claim-revocation') {
      throw const FormatException('Invalid revoke operation');
    }
    DeviceRefV1.fromJson(_map(json['device_ref']));
  }
}

class RevokeClaimResultV1 extends _AdmissionMapV1 {
  RevokeClaimResultV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'operation',
        'command_id',
        'outcome',
        'device_ref',
        'aggregate_revision',
        'occurred_at',
        'event_id',
        'lifecycle_state',
      }) {
    if (json['operation'] != 'device.claim-revocation-result') {
      throw const FormatException('Invalid revoke result');
    }
    DeviceRefV1.fromJson(_map(json['device_ref']));
  }
}

class EnrollmentProposalV1 extends _AdmissionMapV1 {
  EnrollmentProposalV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'enrollment_id',
        'proposal_revision',
        'state',
        'device_instance_candidate_id',
        'requested_owner_domain_id',
        'hardware_evidence_digest',
        'manifest_ref',
        'handoff_key_id',
        'created_at',
        'expires_at',
      }) {
    DeviceInstanceIdV1.parse(json['device_instance_candidate_id']);
    OwnerDomainIdV1.parse(json['requested_owner_domain_id']);
    ManifestRefV1.fromJson(_map(json['manifest_ref']));
    _positive(json['proposal_revision']);
  }
}

class ApprovalDecisionV1 extends _AdmissionMapV1 {
  ApprovalDecisionV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'decision_id',
        'enrollment_id',
        'decision',
        'actor',
        'target_owner_domain_id',
        'target_business_owner_id',
        'reviewed_manifest_ref',
        'expected_proposal_revision',
        'decided_at',
      }) {
    final actor = _map(json['actor']);
    _strictObject(actor, const {
      'principal_id',
      'principal_type',
      'owner_domain_id',
      'granted_scopes',
      'authentication_strength',
    });
    final owner = OwnerDomainIdV1.parse(json['target_owner_domain_id']).value;
    if (actor['principal_type'] != 'controller' ||
        actor['owner_domain_id'] != owner) {
      throw const FormatException('Decision actor Owner Domain mismatch');
    }
    BusinessOwnerIdV1.parse(json['target_business_owner_id']);
  }
}

class ClaimGrantV1 extends _AdmissionMapV1 {
  ClaimGrantV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'grant_id',
        'enrollment_id',
        'device_ref',
        'manifest_ref',
        'approval_decision_id',
        'handoff_key_id',
        'operational_key_id',
        'issued_at',
        'expires_at',
      }) {
    DeviceRefV1.fromJson(_map(json['device_ref']));
    ManifestRefV1.fromJson(_map(json['manifest_ref']));
  }
}

class GrantAckV1 extends _AdmissionMapV1 {
  GrantAckV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'enrollment_id',
        'grant_id',
        'device_ref',
        'acknowledged_at',
      }) {
    DeviceRefV1.fromJson(_map(json['device_ref']));
  }
}

class ClaimRecordV1 extends _AdmissionMapV1 {
  ClaimRecordV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'device_ref',
        'business_owner_id',
        'manifest_ref',
        'state',
        'revision',
        'updated_at',
      }) {
    DeviceRefV1.fromJson(_map(json['device_ref']));
    BusinessOwnerIdV1.parse(json['business_owner_id']);
    ManifestRefV1.fromJson(_map(json['manifest_ref']));
  }
}

class CreateEnrollmentV1 extends _AdmissionMapV1 {
  CreateEnrollmentV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'profile_id',
        'device_instance_candidate_id',
        'requested_owner_domain_id',
        'hardware_identity_evidence',
        'commissioning_proof',
        'manifest',
        'handoff_key',
        'operational_key',
      }) {
    DeviceInstanceIdV1.parse(json['device_instance_candidate_id']);
    if (json['profile_id'] != 'eidolon-trust-p256-hpke-v1') {
      throw const FormatException('Invalid Admission profile');
    }
    OwnerDomainIdV1.parse(json['requested_owner_domain_id']);
  }
}

class CreateEnrollmentResultV1 extends _AdmissionMapV1 {
  CreateEnrollmentResultV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'enrollment_id',
        'proposal_revision',
        'state',
        'expires_at',
        'reviewed_manifest_digest',
        'collection_challenge',
      });
}

class CancelEnrollmentV1 extends _AdmissionMapV1 {
  CancelEnrollmentV1.fromJson(Map<String, dynamic> value)
    : super(value, const {'enrollment_id', 'reason'});
}

class CancelEnrollmentResultV1 extends _AdmissionMapV1 {
  CancelEnrollmentResultV1.fromJson(Map<String, dynamic> value)
    : super(value, const {'enrollment_id', 'proposal_state', 'canceled_at'}) {
    if (json['proposal_state'] != 'canceled') {
      throw const FormatException('Invalid canceled Proposal state');
    }
  }
}

class DecideEnrollmentV1 extends _AdmissionMapV1 {
  DecideEnrollmentV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'enrollment_id',
        'expected_proposal_revision',
        'decision',
        'target_owner_domain_id',
        'target_business_owner_id',
        'target_space_id',
        'reviewed_manifest_ref',
        'initial_assignment_intent',
        'initial_capability_policy_refs',
      }) {
    OwnerDomainIdV1.parse(json['target_owner_domain_id']);
    BusinessOwnerIdV1.parse(json['target_business_owner_id']);
    ManifestRefV1.fromJson(_map(json['reviewed_manifest_ref']));
  }
}

class DecideEnrollmentResultV1 extends _AdmissionMapV1 {
  DecideEnrollmentResultV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'decision_id',
        'decision',
        'decided_by',
        'decided_at',
        'proposal_revision',
      });
}

class CollectClaimGrantV1 extends _AdmissionMapV1 {
  CollectClaimGrantV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'enrollment_id',
        'proposal_revision',
        'collection_challenge',
        'handoff_key_proof',
      });
}

class ClaimGrantAADV1 extends _AdmissionMapV1 {
  ClaimGrantAADV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'contract',
        'profile_id',
        'enrollment_id',
        'proposal_revision',
        'device_instance_id',
        'hardware_evidence_digest',
        'manifest_ref',
        'owner_domain_id',
        'owner_domain_generation',
        'claim_generation',
        'trust_epoch',
        'grant_id',
      }) {
    DeviceInstanceIdV1.parse(json['device_instance_id']);
    if (json['contract'] != 'eidolon.device-foundation.claim-grant-aad' ||
        json['profile_id'] != 'eidolon-trust-p256-hpke-v1') {
      throw const FormatException('Invalid ClaimGrant AAD profile');
    }
    OwnerDomainIdV1.parse(json['owner_domain_id']);
    ManifestRefV1.fromJson(_map(json['manifest_ref']));
    for (final name in const [
      'proposal_revision',
      'owner_domain_generation',
      'claim_generation',
      'trust_epoch',
    ]) {
      _positive(json[name]);
    }
  }
}

class ClaimGrantWireEnvelopeV1 extends _AdmissionMapV1 {
  ClaimGrantWireEnvelopeV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'contract',
        'profile_id',
        'kem',
        'kdf',
        'aead',
        'recipient_handoff_key_id',
        'encapsulated_key',
        'ciphertext',
        'aad',
      }) {
    if (json['contract'] != 'eidolon.device-foundation.claim-grant-envelope' ||
        json['profile_id'] != 'eidolon-trust-p256-hpke-v1' ||
        json['kem'] != 'DHKEM-P256-HKDF-SHA256' ||
        json['kdf'] != 'HKDF-SHA256' ||
        json['aead'] != 'AES-128-GCM') {
      throw const FormatException('Invalid ClaimGrant HPKE suite');
    }
    _digest(json['recipient_handoff_key_id']);
    ClaimGrantAADV1.fromJson(_map(json['aad']));
  }
}

class CollectClaimGrantResultV1 extends _AdmissionMapV1 {
  CollectClaimGrantResultV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'grant_id',
        'wire_envelope',
        'expires_at',
        'approval_decision_id',
      }) {
    final envelope = ClaimGrantWireEnvelopeV1.fromJson(
      _map(json['wire_envelope']),
    );
    if (envelope.json['aad'] is! Map ||
        _map(envelope.json['aad'])['grant_id'] != json['grant_id']) {
      throw const FormatException('Collect result Grant mismatch');
    }
  }
}

class AckClaimGrantV1 extends _AdmissionMapV1 {
  AckClaimGrantV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'enrollment_id',
        'grant_id',
        'operational_key_proof',
        'stored_claim_generation',
        'stored_trust_epoch',
      });
}

class AckClaimGrantResultV1 extends _AdmissionMapV1 {
  AckClaimGrantResultV1.fromJson(Map<String, dynamic> value)
    : super(value, const {'device_ref', 'claim_state'}) {
    DeviceRefV1.fromJson(_map(json['device_ref']));
  }
}

class AdmissionListCursorV1 extends _AdmissionMapV1 {
  AdmissionListCursorV1.fromJson(Map<String, dynamic> value)
    : super(value, const {'owner_domain_id', 'sort_key', 'resource_id'}) {
    OwnerDomainIdV1.parse(json['owner_domain_id']);
  }
}

class EnrollmentRecoveryProjectionV1 extends _AdmissionMapV1 {
  EnrollmentRecoveryProjectionV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'proposal',
        'approval_decision',
        'grant_delivery',
        'claim',
        'source_revision',
        'observed_at',
      }) {
    EnrollmentProposalV1.fromJson(_map(json['proposal']));
  }
}

class GrantDeliveryRecordV1 extends _AdmissionMapV1 {
  GrantDeliveryRecordV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'grant_id',
        'approval_decision_id',
        'state',
        'delivered_at',
        'acknowledged_at',
      });
}

class EnrollmentProposalQueryV1 extends _AdmissionMapV1 {
  EnrollmentProposalQueryV1.fromJson(Map<String, dynamic> value)
    : super(value, const {'owner_domain_id', 'states', 'cursor', 'limit'}) {
    OwnerDomainIdV1.parse(json['owner_domain_id']);
  }
}

class EnrollmentProposalPageV1 extends _AdmissionMapV1 {
  EnrollmentProposalPageV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'owner_domain_id',
        'items',
        'next_cursor',
        'observed_at',
      }) {
    OwnerDomainIdV1.parse(json['owner_domain_id']);
  }
}

class ClaimQueryV1 extends _AdmissionMapV1 {
  ClaimQueryV1.fromJson(Map<String, dynamic> value)
    : super(value, const {'owner_domain_id', 'states', 'cursor', 'limit'}) {
    OwnerDomainIdV1.parse(json['owner_domain_id']);
  }
}

class ClaimPageV1 extends _AdmissionMapV1 {
  ClaimPageV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'owner_domain_id',
        'items',
        'next_cursor',
        'observed_at',
      }) {
    OwnerDomainIdV1.parse(json['owner_domain_id']);
  }
}

class ClaimActivatedEventV1 extends _AdmissionMapV1 {
  ClaimActivatedEventV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'specversion',
        'id',
        'source',
        'type',
        'subject',
        'time',
        'datacontenttype',
        'dataschema',
        'audience',
        'ownerdomainid',
        'aggregaterev',
        'correlationid',
        'causationid',
        'data',
      }) {
    _claimEventMetadata(
      json,
      'live.eidolon.device.claim-activated.v1',
      'https://contracts.eidolon.live/device-foundation/v1/events/claim-activated-data.schema.json',
    );
  }
}

class ClaimActivatedDataV1 extends _AdmissionMapV1 {
  ClaimActivatedDataV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'device_ref',
        'business_owner_id',
        'manifest_ref',
        'approval_decision_id',
        'activated_at',
      }) {
    DeviceRefV1.fromJson(_map(json['device_ref']));
    BusinessOwnerIdV1.parse(json['business_owner_id']);
    ManifestRefV1.fromJson(_map(json['manifest_ref']));
  }
}

class ClaimRevokedEventV1 extends _AdmissionMapV1 {
  ClaimRevokedEventV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'specversion',
        'id',
        'source',
        'type',
        'subject',
        'time',
        'datacontenttype',
        'dataschema',
        'audience',
        'ownerdomainid',
        'aggregaterev',
        'correlationid',
        'causationid',
        'data',
      }) {
    _claimEventMetadata(
      json,
      'live.eidolon.device.claim-revoked.v1',
      'https://contracts.eidolon.live/device-foundation/v1/events/claim-revoked-data.schema.json',
    );
  }
}

class ClaimRevokedDataV1 extends _AdmissionMapV1 {
  ClaimRevokedDataV1.fromJson(Map<String, dynamic> value)
    : super(value, const {'device_ref', 'reason', 'revoked_at'}) {
    DeviceRefV1.fromJson(_map(json['device_ref']));
  }
}

class ClaimEventCursorV1 extends _AdmissionMapV1 {
  ClaimEventCursorV1.fromJson(Map<String, dynamic> value)
    : super(value, const {'stream_id', 'stream_position'}) {
    if (json['stream_id'] != 'admission-claims-v1' ||
        json['stream_position'] is! int ||
        (json['stream_position'] as int) < 0) {
      throw const FormatException('Invalid Claim event cursor');
    }
  }
}

class ClaimEventStreamItemV1 extends _AdmissionMapV1 {
  ClaimEventStreamItemV1.fromJson(Map<String, dynamic> value)
    : super(value, const {'stream_position', 'event'}) {
    _positive(json['stream_position']);
  }
}

class ClaimEventPageV1 extends _AdmissionMapV1 {
  ClaimEventPageV1.fromJson(Map<String, dynamic> value)
    : super(value, const {
        'stream_id',
        'requested_after',
        'events',
        'next_cursor',
        'high_watermark',
        'observed_at',
      }) {
    if (json['stream_id'] != 'admission-claims-v1') {
      throw const FormatException('Invalid Claim event stream');
    }
    ClaimEventCursorV1.fromJson(_map(json['requested_after']));
    ClaimEventCursorV1.fromJson(_map(json['next_cursor']));
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map) throw const FormatException('Expected contract object');
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> _strictObject(
  Map<String, dynamic> value,
  Set<String> fields,
) {
  if (value.keys.toSet().difference(fields).isNotEmpty ||
      fields.difference(value.keys.toSet()).isNotEmpty) {
    throw const FormatException('Invalid canonical contract fields');
  }
  return value;
}

int _positive(Object? value) {
  if (value is! int || value < 1) {
    throw const FormatException('Expected positive generation/revision');
  }
  return value;
}

void _claimEventMetadata(
  Map<String, dynamic> value,
  String type,
  String schema,
) {
  if (value['specversion'] != '1.0' ||
      value['source'] != 'urn:eidolon:authority:admission' ||
      value['type'] != type ||
      value['dataschema'] != schema ||
      value['audience'] != 'eidolon-claim-consumers' ||
      value['datacontenttype'] != 'application/json') {
    throw const FormatException('Invalid Claim CloudEvent metadata');
  }
  final data = _map(value['data']);
  final ref = DeviceRefV1.fromJson(_map(data['device_ref']));
  if (value['ownerdomainid'] != ref.ownerDomainId.value ||
      value['subject'] != 'device-instances/${ref.deviceInstanceId}') {
    throw const FormatException('Claim CloudEvent identity mismatch');
  }
}

String _text(Object? value, int maximum) {
  if (value is! String || value.isEmpty || value.length > maximum) {
    throw const FormatException('Invalid bounded contract string');
  }
  return value;
}

String _identifier(Object? value) {
  final text = _text(value, 128);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(text) ||
      text.length < 3) {
    throw const FormatException('Invalid canonical identifier');
  }
  return text;
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

import 'dart:convert';

import '../../generated/device_foundation_v1.dart';

enum DeviceProvisioningTrust {
  /// Development-only discovery without a manufacturer-bound identity.
  developmentTofu,

  /// Descriptor identity is bound to a product credential or equivalent proof.
  manufacturerBound,
}

enum DeviceProvisioningState {
  notStarted,
  discovering,
  selected,
  configuringNetwork,
  networkConfigured,
  failed,
}

enum DeviceAdmissionState {
  notStarted,
  awaitingEnrollment,
  pendingReview,
  approvedAwaitingHandoff,
  grantDelivered,
  claimActive,
  rejected,
  failed,
}

/// What an act on the Host came to, in the only terms that change what
/// someone does next.
///
/// The Host used to answer with three fields — a state that mixed how far the
/// act got with whether it had ended, the name of an internal authority
/// hand-off, and a retry flag — and every screen reassembled a decision out
/// of them slightly differently. These three are the decision:
///
///  * [done] — it finished; there is nothing to offer.
///  * [unfinished] — it stopped partway and asking again can finish it.
///  * [refused] — the Host decided; asking again gets the same answer.
enum ActOutcome { done, unfinished, refused }

ActOutcome _actOutcome(Object? value) => switch (value) {
      'done' => ActOutcome.done,
      'unfinished' => ActOutcome.unfinished,
      'refused' => ActOutcome.refused,
      _ => throw const FormatException('Local API 返回了未知的执行结果'),
    };

class DeviceProvisioningCandidate {
  const DeviceProvisioningCandidate({
    required this.transportId,
    required this.displayName,
    required this.transportKind,
    required this.trust,
    this.signalStrength,
  });

  final String transportId;
  final String displayName;
  final String transportKind;
  final DeviceProvisioningTrust trust;
  final int? signalStrength;
}

class DeviceProvisioningDescriptor {
  const DeviceProvisioningDescriptor({
    required this.contractVersion,
    required this.deviceId,
    required this.deviceKind,
    required this.displayName,
    required this.identityFingerprint,
    required this.sessionId,
    required this.expiresAt,
    required this.trust,
  });

  final String contractVersion;
  final String deviceId;
  final String deviceKind;
  final String displayName;
  final String identityFingerprint;
  final String sessionId;
  final DateTime expiresAt;
  final DeviceProvisioningTrust trust;
}

class DeviceWifiNetwork {
  const DeviceWifiNetwork({
    required this.ssid,
    required this.signalStrength,
    required this.security,
  });

  final String ssid;
  final int signalStrength;
  final String security;
}

class DeviceWifiCredentials {
  const DeviceWifiCredentials({required this.ssid, required this.password});

  final String ssid;
  final String password;
}

/// A device answering on its own setup hotspot, before it belongs to anyone.

class DeviceOnboardingTarget {
  const DeviceOnboardingTarget({
    required this.ownerDomainId,
    required this.ownerDomainDescriptor,
    required this.ownerRootCertificate,
    required this.authoritySigningCertificate,
    this.hostAddress,
  });

  final String ownerDomainId;
  final OwnerDomainDescriptorV1 ownerDomainDescriptor;
  final String ownerRootCertificate;
  final String authoritySigningCertificate;

  /// The address the Host answered on when it handed this target over.
  ///
  /// Deliberately absent from the wire and from the checkpoint: it describes
  /// one client's route to a deployment at one moment, not the Owner Domain.
  /// The signed descriptor is the durable fact.
  final String? hostAddress;

  /// This target, as reached at [hostAddress].
  DeviceOnboardingTarget reachedAt(String hostAddress) =>
      DeviceOnboardingTarget(
        ownerDomainId: ownerDomainId,
        ownerDomainDescriptor: ownerDomainDescriptor,
        ownerRootCertificate: ownerRootCertificate,
        authoritySigningCertificate: authoritySigningCertificate,
        hostAddress: hostAddress,
      );

  factory DeviceOnboardingTarget.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'local.device-onboarding-target' ||
        value['contract_version'] != '1') {
      throw const FormatException(
        'Local API 返回了无效的 Owner Domain onboarding target',
      );
    }
    final rawDescriptor = value['owner_domain_descriptor'];
    if (rawDescriptor is! Map) {
      throw const FormatException('Local API 返回了无效的 Owner Domain descriptor');
    }
    final root = _boundedWireString(value, 'owner_root_certificate', 4096);
    final authority =
        _boundedWireString(value, 'authority_signing_certificate', 4096);
    if (!root.startsWith('-----BEGIN CERTIFICATE-----') ||
        !authority.startsWith('-----BEGIN CERTIFICATE-----')) {
      throw const FormatException('Local API 返回了无效的 Owner Domain trust chain');
    }
    final descriptor = OwnerDomainDescriptorV1.fromJson(
      Map<String, dynamic>.from(rawDescriptor),
    );
    final ownerDomainId = _boundedWireString(value, 'owner_domain_id', 128);
    if (descriptor.ownerDomainId != ownerDomainId) {
      throw const FormatException('Owner Domain descriptor 身份不一致');
    }
    return DeviceOnboardingTarget(
      ownerDomainId: ownerDomainId,
      ownerDomainDescriptor: descriptor,
      ownerRootCertificate: root,
      authoritySigningCertificate: authority,
    );
  }
}

/// What removing a device accomplished on the Host.
///
/// [DeviceRemovalState.revoked] means the grant is gone — the device is off —
/// but the Host still lists it, so the removal is worth retrying.
class DeviceRemovalProgress {
  const DeviceRemovalProgress({
    required this.requestId,
    required this.deviceId,
    required this.ownerId,
    required this.intentId,
    required this.outcome,
    required this.conditions,
  });

  final String requestId;
  final String deviceId;
  final String ownerId;
  final String intentId;
  final ActOutcome outcome;
  final Map<String, String> conditions;

  /// The grant is gone but the mount is not, which is worth saying out loud:
  /// the device is already off, and what is left to retry is the unmount.
  bool get platformAccessRevoked =>
      conditions['platform_access_revoked'] == 'true';
  bool get mountRemoved => conditions['mount_removed'] == 'true';
  bool get deviceEraseAcknowledged =>
      conditions['device_erase_acknowledged'] == 'true';

  factory DeviceRemovalProgress.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'local.device-removal-progress' ||
        value['contract_version'] != '1') {
      throw const FormatException('Local API 返回了无效的设备移除状态');
    }
    final rawConditions = value['conditions'];
    if (rawConditions is! List) {
      throw const FormatException('Local API 返回了无效的设备移除条件');
    }
    final conditions = <String, String>{};
    for (final raw in rawConditions) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Local API 返回了无效的设备移除条件');
      }
      final name = _boundedWireString(raw, 'name', 64);
      final state = _boundedWireString(raw, 'state', 16);
      if (!const {'true', 'false', 'unknown'}.contains(state) ||
          conditions.containsKey(name)) {
        throw const FormatException('Local API 返回了冲突的设备移除条件');
      }
      conditions[name] = state;
    }
    const required = {
      'platform_access_revoked',
      'mount_removed',
      'device_erase_acknowledged',
    };
    final names = conditions.keys.toSet();
    if (names.difference(required).isNotEmpty ||
        required.difference(names).isNotEmpty) {
      throw const FormatException('Local API 返回了不完整的设备移除条件');
    }
    return DeviceRemovalProgress(
      requestId: _boundedWireString(value, 'request_id', 128),
      deviceId: _boundedWireString(value, 'device_id', 128),
      ownerId: _boundedWireString(value, 'owner_id', 64),
      intentId: _boundedWireString(value, 'intent_id', 128),
      outcome: _actOutcome(value['outcome']),
      conditions: Map.unmodifiable(conditions),
    );
  }
}

class DeviceSetupFailure {
  const DeviceSetupFailure({
    required this.stage,
    required this.code,
    required this.message,
    required this.retryable,
  });

  final String stage;
  final String code;
  final String message;
  final bool retryable;

  Map<String, dynamic> toJson() => {
        'stage': stage,
        'code': code,
        'message': message,
        'retryable': retryable,
      };

  factory DeviceSetupFailure.fromJson(Map<String, dynamic> value) =>
      DeviceSetupFailure(
        stage: _requiredCheckpointString(value, 'stage'),
        code: _requiredCheckpointString(value, 'code'),
        message: _requiredCheckpointString(value, 'message'),
        retryable: _requiredCheckpointBool(value, 'retryable'),
      );
}

/// Non-secret checkpoint for resuming the forward-only Device Setup workflow.
class DeviceSetupCheckpoint {
  const DeviceSetupCheckpoint({
    required this.contractVersion,
    required this.setupId,
    required this.requestId,
    required this.createCommandId,
    required this.decisionCommandId,
    required this.collectCommandId,
    required this.ackCommandId,
    required this.provisioningState,
    required this.admissionState,
    required this.updatedAt,
    required this.onboardingTarget,
    this.deviceId,
    this.enrollmentId,
    this.expectedProposalRevision,
    this.recoveryCursor,
    this.companionId,
    this.failure,
  });

  static const currentContractVersion = '3';

  final String contractVersion;
  final String setupId;
  final String requestId;
  final String createCommandId;
  final String decisionCommandId;
  final String collectCommandId;
  final String ackCommandId;
  final DeviceProvisioningState provisioningState;
  final DeviceAdmissionState admissionState;
  final DateTime updatedAt;
  final DeviceOnboardingTarget onboardingTarget;
  final String? deviceId;
  final String? enrollmentId;
  final int? expectedProposalRevision;
  final AdmissionListCursorV1? recoveryCursor;
  final String? companionId;
  final DeviceSetupFailure? failure;

  bool get isReady =>
      provisioningState == DeviceProvisioningState.networkConfigured &&
      admissionState == DeviceAdmissionState.claimActive;

  DeviceSetupCheckpoint copyWith({
    DeviceProvisioningState? provisioningState,
    DeviceAdmissionState? admissionState,
    DateTime? updatedAt,
    String? deviceId,
    String? enrollmentId,
    int? expectedProposalRevision,
    AdmissionListCursorV1? recoveryCursor,
    String? companionId,
    DeviceSetupFailure? failure,
    bool clearFailure = false,
    bool clearRecoveryCursor = false,
  }) =>
      DeviceSetupCheckpoint(
        contractVersion: contractVersion,
        setupId: setupId,
        requestId: requestId,
        createCommandId: createCommandId,
        decisionCommandId: decisionCommandId,
        collectCommandId: collectCommandId,
        ackCommandId: ackCommandId,
        provisioningState: provisioningState ?? this.provisioningState,
        admissionState: admissionState ?? this.admissionState,
        updatedAt: updatedAt ?? this.updatedAt,
        onboardingTarget: onboardingTarget,
        deviceId: deviceId ?? this.deviceId,
        enrollmentId: enrollmentId ?? this.enrollmentId,
        expectedProposalRevision:
            expectedProposalRevision ?? this.expectedProposalRevision,
        recoveryCursor:
            clearRecoveryCursor ? null : recoveryCursor ?? this.recoveryCursor,
        companionId: companionId ?? this.companionId,
        failure: clearFailure ? null : failure ?? this.failure,
      );

  Map<String, dynamic> toJson() => {
        'contract_version': contractVersion,
        'setup_id': setupId,
        'request_id': requestId,
        'create_command_id': createCommandId,
        'decision_command_id': decisionCommandId,
        'collect_command_id': collectCommandId,
        'ack_command_id': ackCommandId,
        'provisioning_state': provisioningState.name,
        'admission_state': admissionState.name,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'owner_domain_id': onboardingTarget.ownerDomainId,
        'owner_domain_descriptor':
            onboardingTarget.ownerDomainDescriptor.toJson(),
        'owner_root_certificate': onboardingTarget.ownerRootCertificate,
        'authority_signing_certificate':
            onboardingTarget.authoritySigningCertificate,
        'device_id': deviceId,
        'enrollment_id': enrollmentId,
        'expected_proposal_revision': expectedProposalRevision,
        'recovery_cursor': recoveryCursor?.toJson(),
        'companion_id': companionId,
        'failure': failure?.toJson(),
      };

  String encode() => jsonEncode(toJson());

  factory DeviceSetupCheckpoint.fromJson(Map<String, dynamic> value) {
    if (value['contract_version'] != currentContractVersion) {
      throw const FormatException('Unsupported Device Setup checkpoint');
    }
    final provisioning = DeviceProvisioningState.values
        .where((item) => item.name == value['provisioning_state'])
        .firstOrNull;
    final admission = DeviceAdmissionState.values
        .where((item) => item.name == value['admission_state'])
        .firstOrNull;
    if (provisioning == null || admission == null) {
      throw const FormatException('Invalid Device Setup checkpoint state');
    }
    final failureValue = value['failure'];
    final setupId = _requiredCheckpointString(value, 'setup_id');
    final requestId = _requiredCheckpointString(value, 'request_id');
    final updatedAt = DateTime.tryParse(
      _requiredCheckpointString(value, 'updated_at'),
    );
    if (setupId.length > 128 || requestId.length > 128 || updatedAt == null) {
      throw const FormatException('Invalid Device Setup checkpoint identity');
    }
    return DeviceSetupCheckpoint(
      contractVersion: currentContractVersion,
      setupId: setupId,
      requestId: requestId,
      createCommandId: _boundedWireString(value, 'create_command_id', 128),
      decisionCommandId: _boundedWireString(value, 'decision_command_id', 128),
      collectCommandId: _boundedWireString(value, 'collect_command_id', 128),
      ackCommandId: _boundedWireString(value, 'ack_command_id', 128),
      provisioningState: provisioning,
      admissionState: admission,
      updatedAt: updatedAt.toUtc(),
      onboardingTarget: DeviceOnboardingTarget(
        ownerDomainId: _boundedWireString(value, 'owner_domain_id', 128),
        ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson(
          Map<String, dynamic>.from(
            value['owner_domain_descriptor']! as Map,
          ),
        ),
        ownerRootCertificate:
            _boundedWireString(value, 'owner_root_certificate', 4096),
        authoritySigningCertificate:
            _boundedWireString(value, 'authority_signing_certificate', 4096),
      ),
      deviceId: _optionalCheckpointString(value, 'device_id'),
      enrollmentId: _optionalCheckpointString(value, 'enrollment_id'),
      expectedProposalRevision:
          _optionalPositiveCheckpointInt(value, 'expected_proposal_revision'),
      recoveryCursor: value['recovery_cursor'] == null
          ? null
          : AdmissionListCursorV1.fromJson(
              Map<String, dynamic>.from(value['recovery_cursor']! as Map),
            ),
      companionId: _optionalCheckpointString(value, 'companion_id'),
      failure: failureValue == null
          ? null
          : failureValue is Map
              ? DeviceSetupFailure.fromJson(
                  Map<String, dynamic>.from(failureValue),
                )
              : throw const FormatException(
                  'Invalid Device Setup checkpoint failure',
                ),
    );
  }
}

int? _optionalPositiveCheckpointInt(
  Map<String, dynamic> value,
  String key,
) {
  final result = value[key];
  if (result == null) return null;
  if (result is! int || result < 1) {
    throw FormatException('Invalid Device Setup checkpoint $key');
  }
  return result;
}

String _requiredCheckpointString(Map<String, dynamic> value, String key) {
  final result = value[key];
  if (result is! String || result.isEmpty) {
    throw FormatException('Invalid Device Setup checkpoint $key');
  }
  return result;
}

String? _optionalCheckpointString(Map<String, dynamic> value, String key) {
  final result = value[key];
  if (result == null) return null;
  if (result is! String || result.isEmpty || result.length > 256) {
    throw FormatException('Invalid Device Setup checkpoint $key');
  }
  return result;
}

bool _requiredCheckpointBool(Map<String, dynamic> value, String key) {
  final result = value[key];
  if (result is! bool) {
    throw FormatException('Invalid Device Setup checkpoint $key');
  }
  return result;
}

String _boundedWireString(
  Map<String, dynamic> value,
  String key,
  int maxLength,
) {
  final result = value[key];
  if (result is! String || result.isEmpty || result.length > maxLength) {
    throw FormatException('Invalid Device Setup $key');
  }
  return result;
}

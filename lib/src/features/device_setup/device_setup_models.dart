import 'dart:convert';

import '../../generated/management_v1.dart';

import '../../generated/device_foundation_v1.dart';

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
  final SetupDescriptorTrustV1 trust;
  final int? signalStrength;
}

/// What a device said about itself, plus the one thing it could not say.
///
/// The device's own words are [setup], read through the canonical binding — the
/// field table is the SDK's, not a second one written out here. What this adds
/// is [expiresAt]: the device reports a duration because it has not joined a
/// network and has no wall clock, so only the phone holding the clock can turn
/// that into an instant.
class DeviceProvisioningDescriptor {
  const DeviceProvisioningDescriptor({
    required this.setup,
    required this.expiresAt,
  });

  final SetupDescriptorV1 setup;

  /// When this setup offer stops being valid, or null when it does not end.
  ///
  /// Null is not "already expired" and not "expires now": a device that has
  /// never been commissioned keeps its offer open until it is claimed,
  /// cancelled or powered off, and has no deadline to report. Nothing may
  /// substitute an instant for the absence — that is how a factory device ends
  /// up looking like one whose window closed before anybody reached it.
  final DateTime? expiresAt;

  String get deviceId => setup.deviceId;
  String get displayName => setup.displayName;
  String get sessionId => setup.sessionId;
  String get identityFingerprint => setup.identityFingerprint;
  SetupDescriptorTrustV1 get trust => setup.trust;
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

/// What the Host signed, and what it named the device while signing it.
class CommissioningVoucher {
  const CommissioningVoucher({
    required this.voucher,
    required this.jti,
    required this.deviceBaseId,
    required this.expiresAt,
  });

  final String voucher;
  final String jti;
  final String deviceBaseId;
  final DateTime expiresAt;

  factory CommissioningVoucher.fromJson(Map<String, dynamic> value) {
    final voucher = value['voucher'];
    final jti = value['jti'];
    final baseId = value['device_base_id'];
    final expiresAt = value['expires_at'];
    if (voucher is! String ||
        voucher.isEmpty ||
        voucher.length > 4096 ||
        jti is! String ||
        jti.isEmpty ||
        baseId is! String ||
        baseId.isEmpty ||
        expiresAt is! String) {
      throw const FormatException('Unsupported commissioning voucher');
    }
    return CommissioningVoucher(
      voucher: voucher,
      jti: jti,
      deviceBaseId: baseId,
      expiresAt: DateTime.parse(expiresAt).toUtc(),
    );
  }
}

class DeviceOnboardingTarget {
  const DeviceOnboardingTarget({
    required this.ownerDomainId,
    required this.ownerDomainDescriptor,
    required this.ownerRootCertificate,
    required this.authoritySigningCertificate,
    this.commissioningVoucher,
    this.hostAddress,
  });

  final String ownerDomainId;
  final OwnerDomainDescriptorV1 ownerDomainDescriptor;
  final String ownerRootCertificate;
  final String authoritySigningCertificate;

  /// The standing this device will have when it asks to be admitted.
  ///
  /// The device ships with no identity material at all, so this one-shot
  /// voucher — signed by the Host for the key the device generated itself — is
  /// what makes a first Proposal possible. Absent when a device that is already
  /// known is only being pointed at a new network, because nothing about its
  /// identity is changing then. Deliberately not in the checkpoint: it is spent
  /// once and re-issued on demand, and a copy left on disk would outlive the
  /// commissioning it belonged to.
  final String? commissioningVoucher;

  /// The address the Host answered on when it handed this target over.
  ///
  /// Deliberately absent from the wire and from the checkpoint: it describes
  /// one client's route to a deployment at one moment, not the Owner Domain.
  /// The signed descriptor is the durable fact.
  final String? hostAddress;

  /// This target, carrying the standing the Host just signed for one device.
  DeviceOnboardingTarget withCommissioningVoucher(String voucher) =>
      DeviceOnboardingTarget(
        ownerDomainId: ownerDomainId,
        ownerDomainDescriptor: ownerDomainDescriptor,
        ownerRootCertificate: ownerRootCertificate,
        authoritySigningCertificate: authoritySigningCertificate,
        commissioningVoucher: voucher,
        hostAddress: hostAddress,
      );

  /// This target, as reached at [hostAddress].
  DeviceOnboardingTarget reachedAt(String hostAddress) =>
      DeviceOnboardingTarget(
        ownerDomainId: ownerDomainId,
        ownerDomainDescriptor: ownerDomainDescriptor,
        ownerRootCertificate: ownerRootCertificate,
        authoritySigningCertificate: authoritySigningCertificate,
        commissioningVoucher: commissioningVoucher,
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

/// What the Host's Admission workflow did with one Decision.
///
/// The Host, not this phone, owns the Decision as a durable intent: it derives
/// the canonical command, submits it to the Admission Authority, and re-reads
/// the resulting projection before answering. So this carries both halves — the
/// checkpoint the workflow reached, and the Authority's own account of the
/// Enrollment afterwards — and the phone never has to infer one from the other.
class AdmissionDecisionOutcome {
  const AdmissionDecisionOutcome({
    required this.requestId,
    required this.intentId,
    required this.commandId,
    required this.checkpoint,
    required this.decisionId,
    required this.recovery,
  });

  final String requestId;
  final String intentId;
  final String commandId;

  /// `intent_recorded` means the Host holds the intent but the Authority has
  /// not committed it. Deliberately not collapsed into a failure: the intent is
  /// durable, so the same request ID resumes it rather than deciding twice.
  final String checkpoint;

  /// The committed Decision's identity, absent while the checkpoint is only
  /// `intent_recorded`.
  final String? decisionId;
  final EnrollmentRecoveryProjectionV1 recovery;

  bool get isCommitted => checkpoint == 'decision_committed';

  factory AdmissionDecisionOutcome.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'admin.admission-decision-intent') {
      throw const FormatException('主机返回了无效的设备批准结果');
    }
    final checkpoint = value['checkpoint'];
    if (checkpoint != 'intent_recorded' && checkpoint != 'decision_committed') {
      throw const FormatException('主机返回了未知的设备批准阶段');
    }
    final result = value['decision_result'];
    if (result != null && result is! Map) {
      throw const FormatException('主机返回了无效的设备批准结果');
    }
    if ((checkpoint == 'decision_committed') != (result != null)) {
      throw const FormatException('主机的批准阶段与结果不一致');
    }
    final recovery = value['recovery'];
    if (recovery is! Map) {
      throw const FormatException('主机没有返回设备接入投影');
    }
    return AdmissionDecisionOutcome(
      requestId: _boundedWireString(value, 'request_id', 128),
      intentId: _boundedWireString(value, 'intent_id', 128),
      commandId: _boundedWireString(value, 'command_id', 128),
      checkpoint: checkpoint as String,
      decisionId: result == null
          ? null
          : _boundedWireString(
              Map<String, dynamic>.from(result),
              'decision_id',
              128,
            ),
      recovery: EnrollmentRecoveryProjectionV1.fromJson(
        Map<String, dynamic>.from(recovery),
      ),
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
    required this.outcome,
    required this.conditions,
  });

  /// Built from the Host's own answer.
  ///
  /// The parsing that used to live here — three required condition names, each
  /// with a tri-state — is the management contract's now. What stays is the
  /// reading: which of those conditions a screen turns into a sentence, and the
  /// fact that a condition nobody has observed is neither true nor false.
  factory DeviceRemovalProgress.fromView(DeviceRemovalView view) =>
      DeviceRemovalProgress(
        requestId: view.requestId,
        deviceId: view.deviceId,
        outcome: switch (view.outcome) {
          'done' => ActOutcome.done,
          'unfinished' => ActOutcome.unfinished,
          'refused' => ActOutcome.refused,
          // An outcome this version has never heard of is treated as still
          // converging: it is the one reading that neither claims success nor
          // throws away a request id that may still be needed.
          _ => ActOutcome.unfinished,
        },
        conditions: {
          for (final condition in view.conditions)
            condition.name: condition.state,
        },
      );

  final String requestId;
  final String deviceId;
  final ActOutcome outcome;
  final Map<String, String> conditions;

  /// The grant is gone but the mount is not, which is worth saying out loud:
  /// the device is already off, and what is left to retry is the unmount.
  bool get platformAccessRevoked => _met('platform_access_revoked');
  bool get mountRemoved => _met('mount_removed');
  bool get deviceEraseAcknowledged => _met('device_erase_acknowledged');

  /// Only an explicit yes counts. "Nobody has looked" and "no" are different
  /// answers, and the difference is the whole reason these are conditions
  /// rather than a percentage.
  bool _met(String name) => const {'true', 'met'}.contains(conditions[name]);
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
    required this.decisionRequestId,
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

  static const currentContractVersion = '4';

  final String contractVersion;
  final String setupId;
  final String requestId;
  final String createCommandId;

  /// Idempotency key for this setup's one Decision, as the Host names it.
  ///
  /// Not a Hub command ID: the Decision is submitted to the Host's own
  /// Admission workflow, which owns the durable intent and derives the
  /// canonical command from it. Replaying this ID replays that intent rather
  /// than creating a second Decision.
  final String decisionRequestId;
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
        decisionRequestId: decisionRequestId,
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
        'decision_request_id': decisionRequestId,
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
      decisionRequestId: _boundedWireString(value, 'decision_request_id', 128),
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

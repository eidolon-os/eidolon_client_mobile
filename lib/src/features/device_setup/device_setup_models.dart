import 'dart:convert';

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
  pendingApproval,
  approved,
  binding,
  ready,
  failed,
}

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

class DeviceOnboardingTarget {
  const DeviceOnboardingTarget({
    required this.hubId,
    required this.descriptorUri,
  });

  final String hubId;
  final Uri descriptorUri;
}

class DeviceEnrollmentReceipt {
  const DeviceEnrollmentReceipt({
    required this.deviceId,
    required this.enrollmentId,
    required this.lifecycleState,
  });

  final String deviceId;
  final String enrollmentId;
  final String lifecycleState;
}

class DeviceAdmissionProgress {
  const DeviceAdmissionProgress({
    required this.deviceId,
    required this.enrollmentId,
    required this.state,
    required this.completedStage,
    this.companionId,
    this.retryable = false,
  });

  final String deviceId;
  final String enrollmentId;
  final DeviceAdmissionState state;
  final String completedStage;
  final String? companionId;
  final bool retryable;
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
        stage: value['stage'] as String,
        code: value['code'] as String,
        message: value['message'] as String,
        retryable: value['retryable'] as bool,
      );
}

/// Non-secret checkpoint for resuming the forward-only Device Setup workflow.
class DeviceSetupCheckpoint {
  const DeviceSetupCheckpoint({
    required this.contractVersion,
    required this.setupId,
    required this.requestId,
    required this.provisioningState,
    required this.admissionState,
    required this.updatedAt,
    this.deviceId,
    this.enrollmentId,
    this.companionId,
    this.failure,
  });

  static const currentContractVersion = '1';

  final String contractVersion;
  final String setupId;
  final String requestId;
  final DeviceProvisioningState provisioningState;
  final DeviceAdmissionState admissionState;
  final DateTime updatedAt;
  final String? deviceId;
  final String? enrollmentId;
  final String? companionId;
  final DeviceSetupFailure? failure;

  bool get isReady =>
      provisioningState == DeviceProvisioningState.networkConfigured &&
      admissionState == DeviceAdmissionState.ready;

  DeviceSetupCheckpoint copyWith({
    DeviceProvisioningState? provisioningState,
    DeviceAdmissionState? admissionState,
    DateTime? updatedAt,
    String? deviceId,
    String? enrollmentId,
    String? companionId,
    DeviceSetupFailure? failure,
    bool clearFailure = false,
  }) =>
      DeviceSetupCheckpoint(
        contractVersion: contractVersion,
        setupId: setupId,
        requestId: requestId,
        provisioningState: provisioningState ?? this.provisioningState,
        admissionState: admissionState ?? this.admissionState,
        updatedAt: updatedAt ?? this.updatedAt,
        deviceId: deviceId ?? this.deviceId,
        enrollmentId: enrollmentId ?? this.enrollmentId,
        companionId: companionId ?? this.companionId,
        failure: clearFailure ? null : failure ?? this.failure,
      );

  Map<String, dynamic> toJson() => {
        'contract_version': contractVersion,
        'setup_id': setupId,
        'request_id': requestId,
        'provisioning_state': provisioningState.name,
        'admission_state': admissionState.name,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'device_id': deviceId,
        'enrollment_id': enrollmentId,
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
    return DeviceSetupCheckpoint(
      contractVersion: currentContractVersion,
      setupId: value['setup_id'] as String,
      requestId: value['request_id'] as String,
      provisioningState: provisioning,
      admissionState: admission,
      updatedAt: DateTime.parse(value['updated_at'] as String).toUtc(),
      deviceId: value['device_id'] as String?,
      enrollmentId: value['enrollment_id'] as String?,
      companionId: value['companion_id'] as String?,
      failure: failureValue is Map<String, dynamic>
          ? DeviceSetupFailure.fromJson(failureValue)
          : null,
    );
  }
}

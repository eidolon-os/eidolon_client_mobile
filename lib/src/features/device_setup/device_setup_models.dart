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

/// A device answering on its own setup hotspot, before it belongs to anyone.

class DeviceOnboardingTarget {
  const DeviceOnboardingTarget({
    required this.hubId,
    required this.descriptorUri,
    required this.tlsSpkiFingerprint,
    required this.hubCertificate,
  });

  final String hubId;
  final Uri descriptorUri;
  final String tlsSpkiFingerprint;

  /// The Host's own certificate, carried to a device being set up. A device
  /// cannot obtain it from anywhere it could already trust, so the Owner
  /// delivers it.
  final String hubCertificate;

  factory DeviceOnboardingTarget.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'local.device-onboarding-target' ||
        value['contract_version'] != '1') {
      throw const FormatException('Local API 返回了无效的 Hub onboarding target');
    }
    final fingerprint = _boundedWireString(
      value,
      'tls_spki_fingerprint',
      71,
    );
    if (!RegExp(r'^sha256:[A-Za-z0-9_-]{43}$').hasMatch(fingerprint)) {
      throw const FormatException('Local API 返回了无效的 Hub TLS 身份');
    }
    final certificate = _boundedWireString(value, 'hub_certificate', 8192);
    if (!certificate.startsWith('-----BEGIN CERTIFICATE-----')) {
      throw const FormatException('Local API 返回了无效的 Hub 证书');
    }
    return DeviceOnboardingTarget(
      hubId: _boundedWireString(value, 'hub_id', 128),
      descriptorUri: _checkpointHttpsUri(value, 'descriptor_uri'),
      tlsSpkiFingerprint: fingerprint,
      hubCertificate: certificate,
    );
  }
}

class PendingDeviceEnrollment {
  const PendingDeviceEnrollment({
    required this.deviceId,
    required this.displayName,
    required this.deviceKind,
    required this.enrolledAt,
  });

  final String deviceId;
  final String displayName;
  final String deviceKind;
  final DateTime enrolledAt;

  factory PendingDeviceEnrollment.fromJson(Map<String, dynamic> value) {
    final enrolledAt = DateTime.tryParse(
      _boundedWireString(value, 'enrolled_at', 64),
    );
    if (enrolledAt == null) {
      throw const FormatException('Local API 返回了无效的设备接入时间');
    }
    return PendingDeviceEnrollment(
      deviceId: _boundedWireString(value, 'device_id', 128),
      displayName: _boundedWireString(value, 'display_name', 128),
      deviceKind: _boundedWireString(value, 'device_kind', 96),
      enrolledAt: enrolledAt.toUtc(),
    );
  }
}

class PendingDeviceEnrollmentPage {
  const PendingDeviceEnrollmentPage({required this.devices});

  final List<PendingDeviceEnrollment> devices;

  factory PendingDeviceEnrollmentPage.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'local.pending-device-enrollments' ||
        value['contract_version'] != '1') {
      throw const FormatException('Local API 返回了无效的待认领设备目录');
    }
    final raw = value['devices'];
    if (raw is! List || raw.length > 100) {
      throw const FormatException('Local API 返回了无效的待认领设备目录');
    }
    final devices = raw
        .map((item) => item is Map
            ? PendingDeviceEnrollment.fromJson(Map<String, dynamic>.from(item))
            : throw const FormatException('待认领设备条目无效'))
        .toList(growable: false);
    if (devices.map((item) => item.deviceId).toSet().length != devices.length) {
      throw const FormatException('待认领设备目录包含重复设备');
    }
    return PendingDeviceEnrollmentPage(devices: devices);
  }
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
    required this.requestId,
    required this.deviceId,
    required this.ownerId,
    required this.state,
    required this.completedStage,
    this.companionId,
    this.retryable = false,
  });

  final String requestId;
  final String deviceId;
  final String ownerId;
  final DeviceAdmissionState state;
  final String completedStage;
  final String? companionId;
  final bool retryable;

  factory DeviceAdmissionProgress.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'local.device-admission-progress' ||
        value['contract_version'] != '1') {
      throw const FormatException('Local API 返回了无效的设备接入状态');
    }
    final rawState = value['state'];
    final state = switch (rawState) {
      'approved' => DeviceAdmissionState.approved,
      'binding' => DeviceAdmissionState.binding,
      'ready' => DeviceAdmissionState.ready,
      'failed' => DeviceAdmissionState.failed,
      _ => throw const FormatException('Local API 返回了未知的设备接入状态'),
    };
    final retryable = value['retryable'];
    if (retryable is! bool) {
      throw const FormatException('Local API 返回了无效的设备重试状态');
    }
    return DeviceAdmissionProgress(
      requestId: _boundedWireString(value, 'request_id', 128),
      deviceId: _boundedWireString(value, 'device_id', 128),
      ownerId: _boundedWireString(value, 'owner_id', 64),
      state: state,
      completedStage: _boundedWireString(value, 'completed_stage', 64),
      companionId: _optionalBoundedWireString(value, 'companion_id', 64),
      retryable: retryable,
    );
  }
}

enum DeviceRemovalState { revoked, removed, failed }

/// What removing a device accomplished on the Host.
///
/// [DeviceRemovalState.revoked] means the grant is gone — the device is off —
/// but the Host still lists it, so the removal is worth retrying.
class DeviceRemovalProgress {
  const DeviceRemovalProgress({
    required this.requestId,
    required this.deviceId,
    required this.ownerId,
    required this.state,
    required this.completedStage,
    this.retryable = false,
  });

  final String requestId;
  final String deviceId;
  final String ownerId;
  final DeviceRemovalState state;
  final String completedStage;
  final bool retryable;

  factory DeviceRemovalProgress.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'local.device-removal-progress' ||
        value['contract_version'] != '1') {
      throw const FormatException('Local API 返回了无效的设备移除状态');
    }
    final state = switch (value['state']) {
      'revoked' => DeviceRemovalState.revoked,
      'removed' => DeviceRemovalState.removed,
      'failed' => DeviceRemovalState.failed,
      _ => throw const FormatException('Local API 返回了未知的设备移除状态'),
    };
    final retryable = value['retryable'];
    if (retryable is! bool) {
      throw const FormatException('Local API 返回了无效的设备重试状态');
    }
    return DeviceRemovalProgress(
      requestId: _boundedWireString(value, 'request_id', 128),
      deviceId: _boundedWireString(value, 'device_id', 128),
      ownerId: _boundedWireString(value, 'owner_id', 64),
      state: state,
      completedStage: _boundedWireString(value, 'completed_stage', 64),
      retryable: retryable,
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
    required this.provisioningState,
    required this.admissionState,
    required this.updatedAt,
    required this.onboardingTarget,
    this.deviceId,
    this.enrollmentId,
    this.companionId,
    this.failure,
  });

  static const currentContractVersion = '2';

  final String contractVersion;
  final String setupId;
  final String requestId;
  final DeviceProvisioningState provisioningState;
  final DeviceAdmissionState admissionState;
  final DateTime updatedAt;
  final DeviceOnboardingTarget onboardingTarget;
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
        onboardingTarget: onboardingTarget,
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
        'hub_id': onboardingTarget.hubId,
        'descriptor_uri': onboardingTarget.descriptorUri.toString(),
        'tls_spki_fingerprint': onboardingTarget.tlsSpkiFingerprint,
        // Public material, and the checkpoint must be able to resume a setup
        // without a second round-trip to the Host.
        'hub_certificate': onboardingTarget.hubCertificate,
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
      provisioningState: provisioning,
      admissionState: admission,
      updatedAt: updatedAt.toUtc(),
      onboardingTarget: DeviceOnboardingTarget(
        hubId: _boundedWireString(value, 'hub_id', 128),
        descriptorUri: _checkpointHttpsUri(value, 'descriptor_uri'),
        tlsSpkiFingerprint: _checkpointFingerprint(value),
        hubCertificate: _boundedWireString(value, 'hub_certificate', 8192),
      ),
      deviceId: _optionalCheckpointString(value, 'device_id'),
      enrollmentId: _optionalCheckpointString(value, 'enrollment_id'),
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

String? _optionalBoundedWireString(
  Map<String, dynamic> value,
  String key,
  int maxLength,
) {
  if (value[key] == null) return null;
  return _boundedWireString(value, key, maxLength);
}

Uri _checkpointHttpsUri(Map<String, dynamic> value, String key) {
  final raw = _boundedWireString(value, key, 2048);
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw FormatException('Invalid Device Setup $key');
  }
  return uri;
}

String _checkpointFingerprint(Map<String, dynamic> value) {
  final fingerprint = _boundedWireString(value, 'tls_spki_fingerprint', 71);
  if (!RegExp(r'^sha256:[A-Za-z0-9_-]{43}$').hasMatch(fingerprint)) {
    throw const FormatException('Invalid Device Setup tls_spki_fingerprint');
  }
  return fingerprint;
}

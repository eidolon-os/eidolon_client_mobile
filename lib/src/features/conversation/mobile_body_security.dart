import 'package:flutter/services.dart';

import 'hub_onboarding_models.dart';

abstract interface class MobileBodySecurity {
  Future<DeviceEnrollmentMaterial> loadOrCreateMaterial(String hubId);

  Future<void> saveEnrollmentReceipt({
    required String hubId,
    required String enrollmentId,
    required DateTime retrievalExpiresAt,
  });

  Future<void> clearPairingSecret(String hubId);

  Future<void> clearMaterial(String hubId);

  Future<DeviceEnrollmentIdentityProof> signEnrollmentProof({
    required String requestId,
    required String deviceId,
    required String retrievalTokenHash,
    required String pairingMethod,
    required String pairingCommitment,
    required String deviceKind,
    required String displayName,
    required String manifestRevision,
  });
}

class PlatformMobileBodySecurity implements MobileBodySecurity {
  const PlatformMobileBodySecurity({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final MethodChannel _channel;

  @override
  Future<DeviceEnrollmentMaterial> loadOrCreateMaterial(String hubId) async {
    final normalized = _hubId(hubId);
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'loadOrCreateDeviceEnrollmentMaterial',
      {'hubId': normalized},
    );
    if (value == null) {
      throw StateError('Platform did not return enrollment material');
    }
    return DeviceEnrollmentMaterial.fromMap(value);
  }

  @override
  Future<void> saveEnrollmentReceipt({
    required String hubId,
    required String enrollmentId,
    required DateTime retrievalExpiresAt,
  }) async {
    final normalizedEnrollmentId = enrollmentId.trim();
    if (normalizedEnrollmentId.isEmpty || normalizedEnrollmentId.length > 128) {
      throw const FormatException('Enrollment ID is invalid');
    }
    await _channel.invokeMethod<void>(
      'saveDeviceEnrollmentReceipt',
      {
        'hubId': _hubId(hubId),
        'enrollmentId': normalizedEnrollmentId,
        'retrievalExpiresAtMs':
            retrievalExpiresAt.toUtc().millisecondsSinceEpoch,
      },
    );
  }

  @override
  Future<void> clearPairingSecret(String hubId) => _channel.invokeMethod<void>(
        'clearDevicePairingSecret',
        {'hubId': _hubId(hubId)},
      );

  @override
  Future<void> clearMaterial(String hubId) => _channel.invokeMethod<void>(
        'clearDeviceEnrollmentMaterial',
        {'hubId': _hubId(hubId)},
      );

  @override
  Future<DeviceEnrollmentIdentityProof> signEnrollmentProof({
    required String requestId,
    required String deviceId,
    required String retrievalTokenHash,
    required String pairingMethod,
    required String pairingCommitment,
    required String deviceKind,
    required String displayName,
    required String manifestRevision,
  }) async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'signDeviceEnrollmentProof',
      {
        'requestId': requestId,
        'deviceId': deviceId,
        'retrievalTokenHash': retrievalTokenHash,
        'pairingMethod': pairingMethod,
        'pairingCommitment': pairingCommitment,
        'deviceKind': deviceKind,
        'displayName': displayName,
        'manifestRevision': manifestRevision,
      },
    );
    if (value == null) {
      throw StateError('Platform did not return an enrollment proof');
    }
    return DeviceEnrollmentIdentityProof.fromMap(value);
  }
}

String _hubId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw const FormatException('Hub ID is invalid');
  }
  return normalized;
}

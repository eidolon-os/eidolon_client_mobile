import 'package:flutter/services.dart';

import 'hub_onboarding_models.dart';

abstract interface class MobileBodySecurity {
  Future<DeviceEnrollmentMaterial> loadOrCreateMaterial(String ownerDomainId);

  Future<void> saveEnrollmentReceipt({
    required String ownerDomainId,
    required String enrollmentId,
    required DateTime retrievalExpiresAt,
  });

  Future<void> clearMaterial(String ownerDomainId);
}

class PlatformMobileBodySecurity implements MobileBodySecurity {
  const PlatformMobileBodySecurity({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final MethodChannel _channel;

  @override
  Future<DeviceEnrollmentMaterial> loadOrCreateMaterial(
      String ownerDomainId) async {
    final normalized = _ownerDomainId(ownerDomainId);
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'loadOrCreateDeviceEnrollmentMaterial',
      {'ownerDomainId': normalized},
    );
    if (value == null) {
      throw StateError('Platform did not return enrollment material');
    }
    return DeviceEnrollmentMaterial.fromMap(value);
  }

  @override
  Future<void> saveEnrollmentReceipt({
    required String ownerDomainId,
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
        'ownerDomainId': _ownerDomainId(ownerDomainId),
        'enrollmentId': normalizedEnrollmentId,
        'retrievalExpiresAtMs':
            retrievalExpiresAt.toUtc().millisecondsSinceEpoch,
      },
    );
  }

  @override
  Future<void> clearMaterial(String ownerDomainId) =>
      _channel.invokeMethod<void>(
        'clearDeviceEnrollmentMaterial',
        {'ownerDomainId': _ownerDomainId(ownerDomainId)},
      );
}

String _ownerDomainId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw const FormatException('Owner Domain ID is invalid');
  }
  return normalized;
}

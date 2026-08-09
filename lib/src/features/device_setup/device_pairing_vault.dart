import 'package:flutter/services.dart';

import 'device_setup_models.dart';

/// A pending, replayable Device admission request protected by the platform
/// keystore. It is deliberately separate from the non-secret setup checkpoint.
class PendingDevicePairingClaim {
  const PendingDevicePairingClaim({
    required this.setupId,
    required this.requestId,
    required this.pairing,
  });

  final String setupId;
  final String requestId;
  final DevicePairingPayload pairing;

  factory PendingDevicePairingClaim.fromPlatform(Map<Object?, Object?> value) {
    final setupId = _boundedString(value, 'setupId', 128);
    final requestId = _boundedString(value, 'requestId', 128);
    return PendingDevicePairingClaim(
      setupId: setupId,
      requestId: requestId,
      pairing: DevicePairingPayload(
        enrollmentId: _enrollmentId(value),
        pairingSecret: _pairingSecret(value),
      ),
    );
  }
}

abstract interface class DevicePairingVault {
  Future<PendingDevicePairingClaim?> load(String hostId);

  Future<void> save({
    required String hostId,
    required PendingDevicePairingClaim claim,
  });

  Future<void> clear(String hostId);
}

/// Stores only the short-lived physical-access proof in Android Keystore-backed
/// encrypted storage. The platform's ordinary application preferences bridge
/// never receives the secret.
class PlatformDevicePairingVault implements DevicePairingVault {
  const PlatformDevicePairingVault({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final MethodChannel _channel;

  @override
  Future<PendingDevicePairingClaim?> load(String hostId) async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'loadPendingDevicePairing',
      {'hostId': hostId},
    );
    if (value == null) return null;
    return PendingDevicePairingClaim.fromPlatform(value);
  }

  @override
  Future<void> save({
    required String hostId,
    required PendingDevicePairingClaim claim,
  }) =>
      _channel.invokeMethod<void>('savePendingDevicePairing', {
        'hostId': hostId,
        'setupId': claim.setupId,
        'requestId': claim.requestId,
        'enrollmentId': claim.pairing.enrollmentId,
        'pairingSecret': claim.pairing.pairingSecret,
      });

  @override
  Future<void> clear(String hostId) => _channel.invokeMethod<void>(
        'clearPendingDevicePairing',
        {'hostId': hostId},
      );
}

String _boundedString(
  Map<Object?, Object?> value,
  String key,
  int maxLength,
) {
  final result = value[key];
  if (result is! String || result.isEmpty || result.length > maxLength) {
    throw FormatException('Invalid pending Device pairing $key');
  }
  return result;
}

String _pairingSecret(Map<Object?, Object?> value) {
  final result = _boundedString(value, 'pairingSecret', 256);
  if (result.length != 43 ||
      !result.codeUnits.every(
        (unit) =>
            unit >= 0x30 && unit <= 0x39 ||
            unit >= 0x41 && unit <= 0x5a ||
            unit >= 0x61 && unit <= 0x7a ||
            unit == 0x2d ||
            unit == 0x5f,
      )) {
    throw const FormatException('Invalid pending Device pairing secret');
  }
  return result;
}

String _enrollmentId(Map<Object?, Object?> value) {
  final result = _boundedString(value, 'enrollmentId', 128);
  if (!RegExp(r'^enrollment_[A-Za-z0-9_-]{24}$').hasMatch(result)) {
    throw const FormatException('Invalid pending Device enrollment ID');
  }
  return result;
}

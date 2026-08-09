import 'package:flutter/services.dart';

import 'device_setup_models.dart';

abstract interface class DevicePairingScanner {
  /// Returns null when the user closes the system scanner.
  Future<DevicePairingPayload?> scan();
}

class PlatformDevicePairingScanner implements DevicePairingScanner {
  const PlatformDevicePairingScanner({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final MethodChannel _channel;

  @override
  Future<DevicePairingPayload?> scan() async {
    final value = await _channel.invokeMethod<String>('scanDevicePairingCode');
    if (value == null) return null;
    return DevicePairingPayload.parse(value);
  }
}

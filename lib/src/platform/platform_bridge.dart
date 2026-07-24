import 'package:flutter/services.dart';

import '../models/hub_models.dart';

class PlatformBridge {
  const PlatformBridge();

  static const _channel = MethodChannel('live.eidolon.mobile/platform');

  Future<HubService> discoverHub({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'discoverHub',
      {'timeoutMs': timeout.inMilliseconds},
    );
    if (result == null) {
      throw StateError('mDNS discovery returned no Hub');
    }
    final service = HubService.fromMap(result);
    if (service.api != 'v1' || service.registerUrl.isEmpty) {
      throw StateError('Hub mDNS TXT record is incompatible');
    }
    return service;
  }

  Future<DeviceIdentity> getDeviceIdentity() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'getDeviceIdentity',
    );
    if (result == null) {
      throw StateError('Platform did not return a device identity');
    }
    return DeviceIdentity.fromMap(result);
  }

  Future<SignedRequest> signRequest({
    required String method,
    required String pathQuery,
    required String body,
  }) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'signRequest',
      {'method': method, 'pathQuery': pathQuery, 'body': body},
    );
    if (result == null) {
      throw StateError('Platform did not return signed headers');
    }
    return SignedRequest.fromMap(result);
  }

  Future<bool> requestMicrophonePermission() async =>
      await _channel.invokeMethod<bool>('requestMicrophonePermission') ?? false;

  Future<bool> playIdentifyFeedback() async {
    await HapticFeedback.heavyImpact();
    await SystemSound.play(SystemSoundType.alert);
    return true;
  }

  Future<bool> playWiggleFeedback() async {
    await HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await HapticFeedback.mediumImpact();
    await SystemSound.play(SystemSoundType.click);
    return true;
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'setup_models.dart';

/// Access to the Host Controller identity held by the platform keystore.
///
/// This is deliberately independent from BLE commissioning. The same
/// Controller key authenticates an already-claimed app to the LAN Local API,
/// while external devices and the Mobile Body use separate identities.
abstract interface class ControllerKeyBridge {
  Future<ControllerIdentity> getIdentity();

  Future<String> signChallenge(Map<String, dynamic> challenge);
}

class PlatformControllerKeyBridge implements ControllerKeyBridge {
  PlatformControllerKeyBridge({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final MethodChannel _channel;

  void _requireAndroid() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw const CommissioningRequestException(
        'unsupported_platform',
        '当前 Controller 凭据先支持 Android；iPhone 版本将在协议稳定后接入。',
      );
    }
  }

  @override
  Future<ControllerIdentity> getIdentity() async {
    _requireAndroid();
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'getControllerIdentity',
    );
    if (result == null) {
      throw const CommissioningRequestException(
        'controller_key_failed',
        '无法创建本机管理凭据',
      );
    }
    return ControllerIdentity.fromMap(result);
  }

  @override
  Future<String> signChallenge(Map<String, dynamic> challenge) async {
    _requireAndroid();
    final result = await _channel.invokeMethod<String>(
      'signControllerChallenge',
      challenge,
    );
    if (result == null || result.isEmpty) {
      throw const CommissioningRequestException(
        'controller_key_failed',
        '无法使用本机 Controller 凭据完成验证',
      );
    }
    return result;
  }
}

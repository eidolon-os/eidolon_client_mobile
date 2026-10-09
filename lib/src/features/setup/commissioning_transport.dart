import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'setup_models.dart';
import 'controller_key_bridge.dart';

abstract interface class CommissioningTransport {
  Future<bool> requestPermission();

  Future<List<NearbyEidolonHost>> scan({
    required String serviceUuid,
    Duration timeout,
  });

  Future<String> open({
    required String address,
    required String serviceUuid,
  });

  Future<void> secure({required String tlsSpkiFingerprint});

  Future<Map<String, dynamic>> request(
    String operation,
    Map<String, dynamic> payload,
  );

  Future<void> close();
}

class PlatformBleCommissioningTransport implements CommissioningTransport {
  PlatformBleCommissioningTransport({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final MethodChannel _channel;
  final Random _random = Random.secure();

  void _requireAndroid() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw const CommissioningRequestException(
        'unsupported_platform',
        '当前 BLE Setup 先支持 Android；iPhone 版本将在协议稳定后接入。',
      );
    }
  }

  @override
  Future<bool> requestPermission() async {
    _requireAndroid();
    return await _channel.invokeMethod<bool>('requestBluetoothPermissions') ??
        false;
  }

  @override
  Future<List<NearbyEidolonHost>> scan({
    required String serviceUuid,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _requireAndroid();
    final raw = await _channel.invokeListMethod<Object?>('scanSetupHosts', {
      'serviceUuid': serviceUuid,
      'timeoutMs': timeout.inMilliseconds,
    });
    return (raw ?? const <Object?>[])
        .map((item) => NearbyEidolonHost.fromMap(
              Map<Object?, Object?>.from(item! as Map),
            ))
        .toList(growable: false);
  }

  @override
  Future<String> open({
    required String address,
    required String serviceUuid,
  }) async {
    _requireAndroid();
    final result =
        await _channel.invokeMethod<String>('openCommissioningLink', {
      'address': address,
      'serviceUuid': serviceUuid,
    });
    if (result == null || result.isEmpty) {
      throw const CommissioningRequestException(
        'link_failed',
        '无法读取附近主机身份',
      );
    }
    return result;
  }

  @override
  Future<void> secure({required String tlsSpkiFingerprint}) async {
    _requireAndroid();
    await _channel.invokeMethod<void>('startCommissioningTls', {
      'tlsSpkiFingerprint': tlsSpkiFingerprint,
    });
  }

  @override
  Future<Map<String, dynamic>> request(
    String operation,
    Map<String, dynamic> payload,
  ) async {
    _requireAndroid();
    final requestId = _uuidV4();
    final request = {
      'contract_version': '1',
      'request_id': requestId,
      'operation': operation,
      'payload': payload,
    };
    final raw = await _channel.invokeMethod<String>('commissioningRequest', {
      'requestJson': jsonEncode(request),
    });
    if (raw == null) {
      throw const CommissioningRequestException(
        'empty_response',
        '主机没有返回 Setup 结果',
      );
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const CommissioningRequestException(
        'invalid_response',
        '主机返回了无效的 Setup 结果',
      );
    }
    if (decoded['contract_version'] != '1' ||
        decoded['request_id'] != requestId) {
      throw const CommissioningRequestException(
        'invalid_response',
        '主机返回的 Setup 响应与本次请求不匹配',
      );
    }
    if (decoded['ok'] != true) {
      final error = decoded['error'];
      final code = error is Map ? error['code'] : null;
      final message = error is Map ? error['message'] : null;
      throw CommissioningRequestException(
        code is String ? code : 'request_failed',
        message is String ? message : '主机拒绝了 Setup 请求',
      );
    }
    final result = decoded['result'];
    if (result is! Map<String, dynamic>) {
      throw const CommissioningRequestException(
        'invalid_response',
        '主机返回的 Setup 结果缺少数据',
      );
    }
    return result;
  }

  @override
  Future<void> close() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _channel.invokeMethod<void>('closeCommissioningLink');
    }
  }

  String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// Prove possession of this installation's key on an already pinned BLE link.
/// Enrollment and subsequent visits use the same Controller authentication.
extension ControllerCommissioning on CommissioningTransport {
  Future<void> configureWifi(
      {required String operationId,
      required String ssid,
      required String? passphrase,
      required bool hidden}) async {
    var staged = false;
    try {
      final result = await request('wifi.configure', {
        'operation_id': operationId,
        'ssid': ssid,
        'passphrase': passphrase,
        'hidden': hidden,
      });
      final operation = result['operation'];
      if (operation is! Map ||
          !{'waiting_confirmation', 'succeeded'}.contains(operation['state'])) {
        throw const CommissioningRequestException(
            'network_stage_failed', '主机没有完成 Wi-Fi 连接。');
      }
      if (operation['state'] == 'succeeded') return;
      staged = true;
      final confirmed =
          await request('wifi.confirm', {'operation_id': operationId});
      if (confirmed['operation'] is! Map ||
          (confirmed['operation'] as Map)['state'] != 'succeeded') {
        throw const CommissioningRequestException(
            'network_confirm_failed', '主机没有确认新 Wi-Fi 已保存。');
      }
    } catch (_) {
      if (staged) {
        try {
          await request('wifi.rollback', {'operation_id': operationId});
        } catch (_) {
          // NetworkManager's checkpoint also rolls back without a confirmation.
        }
      }
      rethrow;
    }
  }

  Future<void> authenticateController(ControllerKeyBridge keys,
      {String? expectedControllerId}) async {
    final identity = await keys.getIdentity();
    if (expectedControllerId != null &&
        identity.controllerId != expectedControllerId) {
      throw const CommissioningRequestException(
          'controller_denied', '本机管理凭据已变化，请重新添加管理授权。');
    }
    final challenge = await request('controller.challenge', {
      'controller_id': identity.controllerId,
    });
    if (challenge['contract_version'] != '1' ||
        challenge['purpose'] != 'eidolon-controller-ble-auth-v1' ||
        challenge['controller_id'] != identity.controllerId ||
        challenge['challenge'] is! String ||
        challenge['reset_epoch'] is! int) {
      throw const CommissioningRequestException(
          'invalid_response', '主机返回的管理员身份验证请求无效。');
    }
    final signature = await keys.signChallenge(challenge);
    await request(
        'controller.authenticate', {...challenge, 'signature': signature});
  }
}

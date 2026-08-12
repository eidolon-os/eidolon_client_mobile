import 'package:flutter/services.dart';

import 'device_setup_models.dart';
import 'device_setup_ports.dart';

class LegacyHotspotProvisioningException implements Exception {
  const LegacyHotspotProvisioningException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Android adapter for a device's own setup hotspot: the vendor `Xiaozhi-*`
/// portal supplies the scan, and Eidolon's commissioning endpoint beside it
/// takes the Host this device is being given.
class PlatformLegacyHotspotProvisioning
    implements LegacyHotspotProvisioningPort {
  const PlatformLegacyHotspotProvisioning();

  static const _channel = MethodChannel('live.eidolon.mobile/platform');

  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestWifiProvisioningPermission') ??
      false;

  @override
  Future<List<DeviceWifiNetwork>> openAndScan() async {
    try {
      final response = await _channel.invokeMapMethod<Object?, Object?>(
        'openLegacyHotspotProvisioning',
      );
      final rawNetworks = response?['networks'];
      if (rawNetworks is! List) {
        throw const LegacyHotspotProvisioningException(
          code: 'invalid_response',
          message: '设备返回的 Wi-Fi 列表格式不兼容',
        );
      }
      final networks = rawNetworks.map(_parseNetwork).toList(growable: false)
        ..sort(
          (left, right) => right.signalStrength.compareTo(left.signalStrength),
        );
      return networks;
    } on PlatformException catch (error) {
      throw LegacyHotspotProvisioningException(
        code: error.code,
        message: _platformMessage(error),
      );
    }
  }

  @override
  Future<CommissionableDevice> identify() async {
    try {
      final response = await _channel.invokeMapMethod<Object?, Object?>(
        'identifyDeviceOnHotspot',
      );
      if (response == null) {
        throw const LegacyHotspotProvisioningException(
          code: 'invalid_response',
          message: '设备没有回应它的身份',
        );
      }
      return CommissionableDevice.fromPlatform(response);
    } on PlatformException catch (error) {
      throw LegacyHotspotProvisioningException(
        code: error.code,
        message: _platformMessage(error),
      );
    }
  }

  @override
  Future<CommissionedDevice> commission({
    required DeviceOnboardingTarget target,
    DeviceWifiCredentials? credentials,
  }) async {
    try {
      final response = await _channel.invokeMapMethod<Object?, Object?>(
        'commissionDeviceOnHotspot',
        {
          'hubId': target.hubId,
          'hubCertificate': target.hubCertificate,
          if (credentials != null) 'ssid': credentials.ssid,
          if (credentials != null) 'password': credentials.password,
        },
      );
      if (response == null) {
        throw const LegacyHotspotProvisioningException(
          code: 'invalid_response',
          message: '设备没有确认这次设置',
        );
      }
      final commissioned = CommissionedDevice.fromPlatform(response);
      if (commissioned.hubId != target.hubId) {
        throw const LegacyHotspotProvisioningException(
          code: 'commissioned_other_hub',
          message: '设备确认的主机与本次设置不一致',
        );
      }
      return commissioned;
    } on PlatformException catch (error) {
      throw LegacyHotspotProvisioningException(
        code: error.code,
        message: _platformMessage(error),
      );
    }
  }

  @override
  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('closeLegacyHotspotProvisioning');
    } on PlatformException {
      // Android tears the request down with the Activity. Cleanup must not
      // obscure a completed configuration or navigation away from the page.
    }
  }

  DeviceWifiNetwork _parseNetwork(Object? value) {
    if (value is! Map) {
      throw const LegacyHotspotProvisioningException(
        code: 'invalid_response',
        message: '设备返回了无效的 Wi-Fi 条目',
      );
    }
    final ssid = value['ssid'];
    final signal = value['signalStrength'];
    final security = value['security'];
    if (ssid is! String ||
        ssid.trim().isEmpty ||
        signal is! int ||
        security is! String) {
      throw const LegacyHotspotProvisioningException(
        code: 'invalid_response',
        message: '设备返回了不兼容的 Wi-Fi 条目',
      );
    }
    return DeviceWifiNetwork(
      ssid: ssid,
      signalStrength: signal.clamp(0, 100),
      security: security,
    );
  }

  String _platformMessage(PlatformException error) => switch (error.code) {
        'WIFI_PERMISSION_DENIED' => '需要“附近的 Wi-Fi 设备”权限才能连接设备热点',
        'WIFI_UNSUPPORTED' => '当前 Android 版本不支持 App 内连接设备热点',
        'HOTSPOT_NOT_FOUND' => '未连接到设备配网热点：请在系统窗口选择设备；若热点未出现，请确认设备已进入配网模式',
        'HOTSPOT_CONNECTION_LOST' => '与设备配网热点的连接已断开',
        'HOTSPOT_PROTOCOL_ERROR' => '热点是可见的，但配网协议不兼容',
        'HOTSPOT_PLATFORM_ERROR' => 'Android 无法启动设备热点选择器，请重新打开 App 后再试',
        'WIFI_CONFIGURATION_UNKNOWN' => error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : '连接在结果确认前断开；设备可能已经加入 Wi-Fi，请先查看设备状态',
        'INVALID_WIFI_CREDENTIALS' => 'Wi-Fi 名称或密码超出设备支持的长度',
        'WIFI_CONFIGURATION_REJECTED' =>
          error.message?.trim().isNotEmpty == true
              ? error.message!.trim()
              : '设备未能加入该 Wi-Fi，请核对密码和网络兼容性',
        _ => error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : '设备配网失败（${error.code}）',
      };
}

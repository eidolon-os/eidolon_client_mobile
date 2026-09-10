import 'dart:async';

import '../host_setup/pinned_http_client.dart';
import '../../generated/management_v1.dart';
import '../host_setup/host_locator.dart';
import '../host_setup/local_api_discovery.dart';
import '../host_setup/local_api_candidate_sources.dart';
import '../host_setup/host_product_session.dart';
import 'host_registry.dart';
import 'commissioning_transport.dart';
import 'controller_key_bridge.dart';
import 'setup_models.dart';

class HostListInfo {
  const HostListInfo(this.host, this.status);
  final ManagedHost host;
  final String status;
}

typedef HostListInfoReader = Future<HostListInfo> Function(ManagedHost host);

HostMachineInfo machineInfoFromMonitor(HostMonitorWire monitor) =>
    HostMachineInfo(
      hostname: monitor.hostname,
      model: monitor.machineModel,
      cpuModel: monitor.cpu.model,
      operatingSystem: monitor.operatingSystem,
      cpuCores: monitor.cpu.cores?.length,
      memoryBytes: monitor.memory.totalBytes,
    );

/// Lists use the same LAN relocation and authentication as a connection.
/// BLE remains an explicit user action.
Future<HostListInfo> readHostListInfo(
  ManagedHost host, {
  LocalApiDiscovery? discovery,
  LocalApiClientFactory? clientFactory,
  ManagementClientFactory? managementClientFactory,
  ControllerKeyBridge? controllerKeys,
  void Function(HostProductSession)? onSession,
  HostConnectionProgress? onProgress,
}) async {
  if (host.tlsSpkiFingerprint == null) {
    return HostListInfo(host, '待连接确认');
  }
  final session = HostProductSession(
    host: host,
    transport: _NoBleTransport(),
    locator: HostLocator.standard(discovery ??
        platformLocalApiDiscovery(hostNames: hostNamesRemembered(host))),
    clientFactory: clientFactory,
    managementClientFactory: managementClientFactory,
    controllerKeys: controllerKeys,
  );
  try {
    onSession?.call(session);
    await session.connect(onProgress: onProgress);
    onProgress?.call('可连接 · 正在读取主机资料');
    try {
      final monitor = await session.executeManagement(
        (client, baseUri, token) =>
            client.fetchHostMonitor(baseUri, accessToken: token),
      );
      return HostListInfo(
        session.host.copyWith(machineInfo: machineInfoFromMonitor(monitor)),
        '可连接',
      );
    } catch (_) {
      return HostListInfo(session.host, '可连接 · 设备资料暂不可用');
    }
  } on HostControllerAuthorizationException {
    return HostListInfo(host, '需要恢复管理授权');
  } on HostLocationException catch (error) {
    return HostListInfo(host, error.message);
  } on TimeoutException {
    return HostListInfo(host, '主机连接验证超时 · 重新查找');
  } on PinnedHttpException catch (error) {
    return HostListInfo(
        host,
        error.kind == PinnedHttpFailureKind.timeout
            ? '主机连接验证超时 · 重新查找'
            : '安全连接未完成 · 重新查找');
  } catch (_) {
    return HostListInfo(host, '暂时无法确认连接 · 重新查找');
  } finally {
    await session.close();
  }
}

// A background list read must neither request BLE permission nor close a BLE
// link owned by a setup page that the user opened while this read was pending.
class _NoBleTransport implements CommissioningTransport {
  @override
  Future<void> close() async {}
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<List<NearbyEidolonHost>> scan(
          {required String serviceUuid,
          Duration timeout = const Duration(seconds: 10)}) async =>
      const [];
  @override
  Future<String> open(
          {required String address, required String serviceUuid}) async =>
      throw StateError('List reads do not use BLE');
  @override
  Future<void> secure({required String tlsSpkiFingerprint}) async =>
      throw StateError('List reads do not use BLE');
  @override
  Future<Map<String, dynamic>> request(
          String operation, Map<String, dynamic> payload) async =>
      throw StateError('List reads do not use BLE');
}

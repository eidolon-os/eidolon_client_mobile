import '../../generated/management_v1.dart';
import '../host_setup/host_locator.dart';
import '../host_setup/host_product_session.dart';
import 'host_registry.dart';
import 'commissioning_transport.dart';
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

/// A list checks saved addresses only. Discovery and BLE remain in the explicit
/// connection flow; all successful replies still pass Host identity and auth.
Future<HostListInfo> readHostListInfo(ManagedHost host) async {
  if (host.tlsSpkiFingerprint == null || host.lastKnownBaseUrl == null) {
    return HostListInfo(host, '待连接确认');
  }
  final session = HostProductSession(
    host: host,
    transport: _NoBleTransport(),
    locator: const HostLocator([RememberedAddressSource()]),
  );
  try {
    final connected =
        (await session.connect()).copyWith(lastConnectedAt: DateTime.now());
    try {
      final monitor = await session.executeManagement(
        (client, baseUri, token) =>
            client.fetchHostMonitor(baseUri, accessToken: token),
      );
      return HostListInfo(
        connected.copyWith(machineInfo: machineInfoFromMonitor(monitor)),
        '上次验证可连接',
      );
    } catch (_) {
      return HostListInfo(connected, '可连接 · 设备资料暂不可用');
    }
  } catch (_) {
    return HostListInfo(host, '原地址未能连接 · 点击重新查找');
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

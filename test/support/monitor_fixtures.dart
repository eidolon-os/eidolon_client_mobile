import 'package:eidolon_client_mobile/src/features/host_setup/host_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'setup_fixtures.dart';

ManagedHost monitorHost() => ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: '客厅主机',
      claimedAt: DateTime.utc(2026, 8, 5),
    );

HostProductConnection monitorConnection() => HostProductConnection(
      endpoint: const LocalApiEndpoint(
        instanceName: 'eidolon-local-api',
        baseUrl: 'https://192.168.1.26:9002',
        ipAddress: '192.168.1.26',
        contractVersion: '1',
      ),
      overview: HostOverview.fromJson({
        'contract_version': '1',
        'status': 'running',
        'mode': 'production',
        'descriptor': {
          'contract_version': '1',
          'host_id': validHostId,
          'host_public_key': validHostPublicKey,
          'host_public_key_fingerprint': validHostPublicKeyFingerprint,
          'ble_service_uuid': validBleServiceUuid,
        },
        'state': {
          'reset_epoch': 2,
          'claim_state': 'claimed',
          'network_state': 'connected',
          'updated_at': '2026-08-11T00:00:00Z',
        },
      }),
      controllerId: 'ectrl-0123456789abcdefabcd',
      sessionExpiresAt: DateTime.utc(2026, 8, 11, 1),
    );

HostMonitorWire monitorSnapshot(
        {double cpu = 30, String observedAt = '2026-09-09T03:00:00Z'}) =>
    HostMonitorWire(
      hostname: 'test-host',
      observedAt: observedAt,
      uptimeSeconds: 3600,
      cpu: MonitorProcessor(
          deviceId: 'cpu',
          model: 'RK3588',
          usagePercent: cpu,
          cores: [
            MonitorCore(coreId: '0', model: 'Cortex-A55', usagePercent: cpu),
            const MonitorCore(
                coreId: '1', model: 'Cortex-A76', usagePercent: 0),
          ]),
      npus: const [
        MonitorProcessor(deviceId: 'npu0', model: 'RK3588 NPU', cores: [
          MonitorCore(coreId: '0', model: 'RK3588 NPU', usagePercent: 55),
          MonitorCore(
              coreId: '1', model: 'RK3588 NPU', unavailableReason: '驱动未提供'),
        ])
      ],
      memory: const MonitorMemory(
          totalBytes: 16000000000, availableBytes: 8000000000),
      disks: const [
        MonitorDisk(
            path: '/', totalBytes: 2000000000, availableBytes: 1000000000)
      ],
      services: const [
        MonitorService(
            serviceId: 'hub',
            state: 'active/running',
            cpuPercent: 10,
            memoryBytes: 1000000,
            configurationPath: '/etc/systemd/eidolon-hub.service',
            processes: [
              MonitorProcess(
                  pid: 100,
                  parentPid: 1,
                  name: 'python',
                  state: 'S',
                  cpuPercent: 10,
                  executable: '/opt/python',
                  sourcePath: '/opt/eidolon/hub/server.py',
                  workingDirectory: '/opt/eidolon/hub',
                  command: 'python server.py --token [redacted]',
                  user: 'eidolon',
                  startedAt: '2026-09-09T02:00:00Z',
                  uptimeSeconds: 3600),
            ])
      ],
    );

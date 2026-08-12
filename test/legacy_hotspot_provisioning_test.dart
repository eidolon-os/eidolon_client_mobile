import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/legacy_hotspot_provisioning.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/legacy_hotspot_provisioning_page.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/setup_fixtures.dart';

final _host = ManagedHost(
  hostId: validHostId,
  hostPublicKey: validHostPublicKey,
  hostFingerprint: validHostPublicKeyFingerprint,
  bleServiceUuid: validBleServiceUuid,
  controllerId: 'ectrl-0123456789abcdefabcd',
  displayName: 'Eidolon-4c0285',
  claimedAt: DateTime.parse('2026-08-05T00:20:00Z'),
);

final _target = DeviceOnboardingTarget(
  hubId: 'eidolon-hub-abc',
  descriptorUri: Uri.parse(
    'https://eidolon-hub-abc.local:8443/api/device-onboarding/v1/descriptor',
  ),
  tlsSpkiFingerprint: 'sha256:${'A' * 43}',
  hubCertificate: '-----BEGIN CERTIFICATE-----\nMIIBdummy\n-----END CERTIFICATE-----\n',
);

class _FakeLegacyHotspotProvisioning implements LegacyHotspotProvisioningPort {
  var permissionGranted = true;
  var openCalls = 0;
  var closeCalls = 0;
  DeviceWifiCredentials? configured;
  DeviceOnboardingTarget? commissionedTarget;
  LegacyHotspotProvisioningException? configurationFailure;

  @override
  Future<void> close() async => closeCalls += 1;

  @override
  Future<CommissionableDevice> identify() async => const CommissionableDevice(
        deviceId: '24:ec:4a:52:f3:54',
        board: 'esp-box-3',
        deviceKind: 'esp-box-3',
      );

  @override
  Future<CommissionedDevice> commission({
    required DeviceOnboardingTarget target,
    DeviceWifiCredentials? credentials,
  }) async {
    final failure = configurationFailure;
    if (failure != null) throw failure;
    commissionedTarget = target;
    configured = credentials;
    return CommissionedDevice(
      deviceId: '24:ec:4a:52:f3:54',
      hubId: target.hubId,
    );
  }

  @override
  Future<List<DeviceWifiNetwork>> openAndScan() async {
    openCalls += 1;
    return const [
      DeviceWifiNetwork(
        ssid: 'Home WiFi',
        signalStrength: 86,
        security: 'secured',
      ),
      DeviceWifiNetwork(
        ssid: 'Guest',
        signalStrength: 42,
        security: 'open',
      ),
    ];
  }

  @override
  Future<bool> requestPermission() async => permissionGranted;
}

void main() {
  testWidgets(
      'setup hands the device its network and its Host, then claims it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final claimed = <String>[];
    final provisioning = _FakeLegacyHotspotProvisioning();
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyHotspotProvisioningPage(
          host: _host,
          loadTarget: () async => _target,
          onCommissioned: (deviceId) async => claimed.add(deviceId),
          provisioning: provisioning,
        ),
      ),
    );

    expect(find.text('添加设备'), findsOneWidget);
    expect(find.textContaining('设备之后只信任这台主机'), findsOneWidget);

    await tester.tap(find.byKey(const Key('connect-device-hotspot')));
    await tester.pumpAndSettle();

    expect(provisioning.openCalls, 1);
    expect(find.text('以下网络由设备扫描，不是手机的扫描结果。'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('device-wifi-password')),
      'not-persisted',
    );
    await tester.tap(find.byKey(const Key('configure-device-wifi')));
    await tester.pumpAndSettle();

    expect(provisioning.configured?.ssid, 'Home WiFi');
    expect(provisioning.configured?.password, 'not-persisted');
    // Trust travelled with the network, and the claim followed without asking
    // the person to confirm the same device a second time.
    expect(provisioning.commissionedTarget?.hubId, 'eidolon-hub-abc');
    expect(claimed, ['24:ec:4a:52:f3:54']);
    expect(find.text('设备已添加'), findsOneWidget);
    expect(provisioning.closeCalls, 1);
  });

  testWidgets('firmware rejection remains retryable on the credential step',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final claimed = <String>[];
    final provisioning = _FakeLegacyHotspotProvisioning()
      ..configurationFailure = const LegacyHotspotProvisioningException(
        code: 'WIFI_CONFIGURATION_REJECTED',
        message: '设备未能加入该 Wi-Fi，请核对密码、频段和网络兼容性',
      );
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyHotspotProvisioningPage(
          host: _host,
          loadTarget: () async => _target,
          onCommissioned: (deviceId) async => claimed.add(deviceId),
          provisioning: provisioning,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('connect-device-hotspot')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('device-wifi-password')),
      'wrong-password',
    );
    await tester.tap(find.byKey(const Key('configure-device-wifi')));
    await tester.pumpAndSettle();

    expect(find.textContaining('请核对密码、频段和网络兼容性'), findsOneWidget);
    expect(find.byKey(const Key('configure-device-wifi')), findsOneWidget);
    expect(find.text('开发配网完成'), findsNothing);
  });
}

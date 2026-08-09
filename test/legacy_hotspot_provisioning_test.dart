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

class _FakeLegacyHotspotProvisioning implements LegacyHotspotProvisioningPort {
  var permissionGranted = true;
  var openCalls = 0;
  var closeCalls = 0;
  DeviceWifiCredentials? configured;
  LegacyHotspotProvisioningException? configurationFailure;

  @override
  Future<void> close() async => closeCalls += 1;

  @override
  Future<void> configureNetwork(DeviceWifiCredentials credentials) async {
    final failure = configurationFailure;
    if (failure != null) throw failure;
    configured = credentials;
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
      'legacy device flow configures Wi-Fi without claiming or admitting Device',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final provisioning = _FakeLegacyHotspotProvisioning();
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyHotspotProvisioningPage(
          host: _host,
          provisioning: provisioning,
        ),
      ),
    );

    expect(find.text('开发配网'), findsOneWidget);
    expect(find.textContaining('不会把设备认领'), findsOneWidget);

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
    expect(find.text('开发配网完成'), findsOneWidget);
    expect(find.textContaining('尚未被认领'), findsOneWidget);
    expect(find.text('设备已添加'), findsNothing);
    expect(provisioning.closeCalls, 1);
  });

  testWidgets('firmware rejection remains retryable on the credential step',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final provisioning = _FakeLegacyHotspotProvisioning()
      ..configurationFailure = const LegacyHotspotProvisioningException(
        code: 'WIFI_CONFIGURATION_REJECTED',
        message: '设备未能加入该 Wi-Fi，请核对密码、频段和网络兼容性',
      );
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyHotspotProvisioningPage(
          host: _host,
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

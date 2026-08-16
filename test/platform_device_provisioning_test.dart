import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/platform_device_provisioning.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('live.eidolon.mobile/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime.utc(2026, 8, 17, 1, 0, 0);

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  String descriptorJson({
    String contractVersion = '1',
    String trust = 'development-tofu',
    int expiresInSeconds = 600,
  }) =>
      jsonEncode({
        'contract_version': contractVersion,
        'device_id': '10:51:db:7e:24:44',
        'device_kind': 'atk-dnesp32s3',
        'display_name': 'atk-dnesp32s3',
        'identity_fingerprint': 'sha256:abc',
        'session_id': 'sess-1',
        'expires_in_seconds': expiresInSeconds,
        'trust': trust,
      });

  final target = DeviceOnboardingTarget(
    hubId: 'ehost-0123456789abcdef0123',
    descriptorUri: Uri.parse('https://hub.local:8443/api/device-onboarding/v1/descriptor'),
    tlsSpkiFingerprint: 'sha256:AAAA',
    hubCertificate: '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n',
  );

  PlatformDeviceProvisioning build({
    PendingEnrollmentLookup? loadPending,
    Duration timeout = const Duration(minutes: 3),
  }) =>
      PlatformDeviceProvisioning(
        loadPendingEnrollments:
            loadPending ?? () async => const <PendingDeviceEnrollment>[],
        enrollmentTimeout: timeout,
        enrollmentInterval: Duration.zero,
        clock: () => now,
      );

  test('turns the window a device reports into the expiry the contract carries',
      () async {
    // A device being set up has no clock, so it says how long rather than when.
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      return null;
    });

    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 'Eidolon-7e2444',
        displayName: 'Eidolon-7e2444',
        transportKind: 'softap',
        trust: DeviceProvisioningTrust.developmentTofu,
      ),
    );

    expect(session.descriptor.expiresAt, now.add(const Duration(seconds: 600)));
    expect(session.descriptor.deviceId, '10:51:db:7e:24:44');
    expect(session.descriptor.trust, DeviceProvisioningTrust.developmentTofu);
  });

  test('carries the declared trust level through rather than assuming one',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') {
        return descriptorJson(trust: 'manufacturer-bound');
      }
      return null;
    });
    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: DeviceProvisioningTrust.developmentTofu,
      ),
    );
    expect(session.descriptor.trust, DeviceProvisioningTrust.manufacturerBound);
  });

  test('refuses a descriptor from a contract or trust level it does not know',
      () async {
    for (final raw in [
      descriptorJson(contractVersion: '2'),
      descriptorJson(trust: 'something-new'),
      descriptorJson(expiresInSeconds: 0),
      'not json',
      '[]',
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openProvisioningSession') return raw;
        return null;
      });
      await expectLater(
        build().open(
          const DeviceProvisioningCandidate(
            transportId: 't',
            displayName: 'd',
            transportKind: 'softap',
            trust: DeviceProvisioningTrust.developmentTofu,
          ),
        ),
        throwsA(isA<DeviceProvisioningTransportException>()),
      );
    }
  });

  test('hands the Host over before the network, and only then the credentials',
      () async {
    final order = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningHandOverTrust') {
        final payload = jsonDecode(
          (call.arguments as Map)['payloadJson'] as String,
        ) as Map<String, dynamic>;
        expect(payload['contract_version'], '1');
        expect(payload['hub_id'], target.hubId);
        expect(payload['hub_certificate'], target.hubCertificate);
        return jsonEncode({
          'contract_version': '1',
          'device_id': '10:51:db:7e:24:44',
          'hub_id': target.hubId,
          'accepted': true,
        });
      }
      return null;
    });

    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: DeviceProvisioningTrust.developmentTofu,
      ),
    );
    await session.configureNetwork(
      credentials: const DeviceWifiCredentials(ssid: 'home', password: 'secret'),
      onboardingTarget: target,
    );

    expect(
      order,
      containsAllInOrder(
        ['provisioningHandOverTrust', 'provisioningConfigureNetwork'],
      ),
    );
  });

  test('does not configure a network when the device refused the Host',
      () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningHandOverTrust') {
        return jsonEncode({
          'contract_version': '1',
          'accepted': false,
          'error': 'handover is not supported',
        });
      }
      return null;
    });

    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: DeviceProvisioningTrust.developmentTofu,
      ),
    );
    await expectLater(
      session.configureNetwork(
        credentials: const DeviceWifiCredentials(ssid: 'home', password: 'pw'),
        onboardingTarget: target,
      ),
      throwsA(isA<DeviceProvisioningTransportException>()),
    );
    // Handing a device a network it has no Host for is the failure this order
    // exists to prevent.
    expect(methods.contains('provisioningConfigureNetwork'), isFalse);
  });

  test('refuses a device that confirmed a different Host', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningHandOverTrust') {
        return jsonEncode({
          'contract_version': '1',
          'hub_id': 'ehost-someone-else',
          'accepted': true,
        });
      }
      return null;
    });
    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: DeviceProvisioningTrust.developmentTofu,
      ),
    );
    await expectLater(
      session.configureNetwork(
        credentials: const DeviceWifiCredentials(ssid: 'home', password: 'pw'),
        onboardingTarget: target,
      ),
      throwsA(isA<DeviceProvisioningTransportException>()),
    );
  });

  test('asks the Host whether the device enrolled, not the device', () async {
    var asked = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      return null;
    });

    final provisioning = build(
      loadPending: () async {
        asked++;
        if (asked < 3) return const <PendingDeviceEnrollment>[];
        return [
          PendingDeviceEnrollment(
            deviceId: '10:51:db:7e:24:44',
            displayName: 'atk-dnesp32s3',
            deviceKind: 'atk-dnesp32s3',
            enrolledAt: now,
          ),
        ];
      },
    );
    final session = await provisioning.open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: DeviceProvisioningTrust.developmentTofu,
      ),
    );

    final receipt = await session.awaitEnrollment();
    expect(receipt.deviceId, '10:51:db:7e:24:44');
    expect(receipt.lifecycleState, 'pending-approval');
    expect(asked, 3);
  });

  test('gives up waiting rather than hanging when the device never enrolls',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      return null;
    });
    final session = await build(timeout: Duration.zero).open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: DeviceProvisioningTrust.developmentTofu,
      ),
    );
    await expectLater(
      session.awaitEnrollment(),
      throwsA(isA<DeviceProvisioningTransportException>()),
    );
  });

  test('refuses a discovered candidate it cannot identify', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'discoverProvisionableDevices') {
        return <Object?>[
          <Object?, Object?>{'transportId': '', 'displayName': 'x', 'transportKind': 'softap'},
        ];
      }
      return null;
    });
    await expectLater(
      build().discover(),
      throwsA(isA<DeviceProvisioningTransportException>()),
    );
  });
}

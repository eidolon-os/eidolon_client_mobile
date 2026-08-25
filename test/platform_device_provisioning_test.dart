import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/platform_device_provisioning.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/owner_domain_fixtures.dart';

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
    Object? expiresInSeconds = 600,
    bool declaresExpiry = true,
  }) =>
      jsonEncode({
        'contract_version': contractVersion,
        'device_id': '10:51:db:7e:24:44',
        'device_kind': 'atk-dnesp32s3',
        'display_name': 'atk-dnesp32s3',
        'identity_fingerprint':
            'p256:591d7c62d0bc738376935f77ff2acd5472bbee64207a765df03af6d6240c07dc',
        'session_id': 'setup_session_01',
        if (declaresExpiry) 'expires_in_seconds': expiresInSeconds,
        'trust': trust,
      });

  final target = deviceOnboardingTargetFixture();

  Map<String, Object?> committedEvidence() => {
        'contract': 'eidolon.device-foundation.commissioning-status',
        'contract_version': '1.0',
        'profile_id': 'eidolon-trust-p256-hpke-v1',
        'session_id': 'setup_session_01',
        'setup_generation': 7,
        'state_revision': 5,
        'state': 'committed',
        'conditions': {
          'wifi_connected': true,
          'owner_route_validated': true,
          'trust_committed': true,
          'network_committed': true,
        },
        'failure_code': null,
      };

  PlatformDeviceProvisioning build() => PlatformDeviceProvisioning(
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
        transportId: 'eidolon-7e2444',
        displayName: 'eidolon-7e2444',
        transportKind: 'softap',
        trust: SetupDescriptorTrustV1.developmentTofu,
      ),
    );

    expect(session.descriptor.expiresAt, now.add(const Duration(seconds: 600)));
    expect(session.descriptor.deviceId, '10:51:db:7e:24:44');
    expect(session.descriptor.trust, SetupDescriptorTrustV1.developmentTofu);
  });

  test('accepts an offer that names no duration as one with no deadline',
      () async {
    // A device nobody has claimed keeps its setup offer open until it is
    // claimed, cancelled or powered off, so its descriptor names no duration at
    // all. Insisting on one refused every device out of the box: the Owner's
    // tablet found the body, then reported its descriptor as breaking the
    // contract the moment they tapped connect.
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') {
        return descriptorJson(declaresExpiry: false);
      }
      return null;
    });

    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 'eidolon-7e2444',
        displayName: 'eidolon-7e2444',
        transportKind: 'softap',
        trust: SetupDescriptorTrustV1.developmentTofu,
      ),
    );

    // No deadline is its own answer, not a deadline of zero: nothing downstream
    // may compute an instant out of an offer that does not end.
    expect(session.descriptor.expiresAt, isNull);
    expect(session.descriptor.sessionId, 'setup_session_01');
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
        trust: SetupDescriptorTrustV1.developmentTofu,
      ),
    );
    expect(session.descriptor.trust, SetupDescriptorTrustV1.manufacturerBound);
  });

  test('refuses a descriptor from a contract or trust level it does not know',
      () async {
    for (final raw in [
      descriptorJson(contractVersion: '2'),
      descriptorJson(trust: 'something-new'),
      // A duration that is present but not a usable one stays a refusal. Only
      // its absence means "no deadline"; a device that names a number must name
      // one it can honour, and 0 or a negative one is a device reporting a
      // window that shut before it spoke.
      descriptorJson(expiresInSeconds: 0),
      descriptorJson(expiresInSeconds: -60),
      descriptorJson(expiresInSeconds: '600'),
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
            trust: SetupDescriptorTrustV1.developmentTofu,
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
        expect(payload['owner_domain_id'], target.ownerDomainId);
        expect(
          payload['owner_domain_descriptor'],
          target.ownerDomainDescriptor.toJson(),
        );
        expect(
          payload['owner_root_certificate'],
          target.ownerRootCertificate,
        );
        expect(
          payload['authority_signing_certificate'],
          target.authoritySigningCertificate,
        );
        expect(payload['admission_command_ids'], {
          'create': 'create-01',
          'collect': 'collect-01',
          'ack': 'ack-01',
        });
        return jsonEncode({
          'contract_version': '1',
          'device_id': '10:51:db:7e:24:44',
          'owner_domain_id': target.ownerDomainId,
          'staged': true,
        });
      }
      if (call.method == 'provisioningConfigureNetwork') {
        return committedEvidence();
      }
      return null;
    });

    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: SetupDescriptorTrustV1.developmentTofu,
      ),
    );
    await session.configureNetwork(
      credentials:
          const DeviceWifiCredentials(ssid: 'home', password: 'secret'),
      onboardingTarget: target,
      createCommandId: 'create-01',
      collectCommandId: 'collect-01',
      ackCommandId: 'ack-01',
    );

    expect(
      order,
      containsAllInOrder(
        ['provisioningHandOverTrust', 'provisioningConfigureNetwork'],
      ),
    );
  });

  test('credential delivery without terminal device evidence is not success',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningHandOverTrust') {
        return jsonEncode({
          'contract_version': '1',
          'device_id': '10:51:db:7e:24:44',
          'owner_domain_id': target.ownerDomainId,
          'staged': true,
        });
      }
      // Models wifiConfigApplied followed by a lost/unknown terminal callback:
      // no device-confirmed evidence crosses the platform boundary.
      if (call.method == 'provisioningConfigureNetwork') return null;
      return null;
    });
    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: SetupDescriptorTrustV1.developmentTofu,
      ),
    );

    await expectLater(
      session.configureNetwork(
        credentials: const DeviceWifiCredentials(ssid: 'home', password: 'pw'),
        onboardingTarget: target,
        createCommandId: 'create-01',
        collectCommandId: 'collect-01',
        ackCommandId: 'ack-01',
      ),
      throwsA(
        isA<DeviceProvisioningTransportException>().having(
          (error) => error.code,
          'code',
          'network_terminal_missing',
        ),
      ),
    );
  });

  test('Wi-Fi connectivity without Owner validation and commit is not terminal',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningHandOverTrust') {
        return jsonEncode({
          'contract_version': '1',
          'device_id': '10:51:db:7e:24:44',
          'owner_domain_id': target.ownerDomainId,
          'staged': true,
        });
      }
      if (call.method == 'provisioningConfigureNetwork') {
        final incomplete = committedEvidence();
        incomplete['conditions'] = {
          'wifi_connected': true,
          'owner_route_validated': false,
          'trust_committed': false,
          'network_committed': false,
        };
        return incomplete;
      }
      return null;
    });
    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: SetupDescriptorTrustV1.developmentTofu,
      ),
    );
    await expectLater(
      session.configureNetwork(
        credentials: const DeviceWifiCredentials(ssid: 'home', password: 'pw'),
        onboardingTarget: target,
        createCommandId: 'create-01',
        collectCommandId: 'collect-01',
        ackCommandId: 'ack-01',
      ),
      throwsA(
        isA<DeviceProvisioningTransportException>().having(
          (error) => error.code,
          'code',
          'network_terminal_invalid',
        ),
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
          'staged': false,
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
        trust: SetupDescriptorTrustV1.developmentTofu,
      ),
    );
    await expectLater(
      session.configureNetwork(
        credentials: const DeviceWifiCredentials(ssid: 'home', password: 'pw'),
        onboardingTarget: target,
        createCommandId: 'create-01',
        collectCommandId: 'collect-01',
        ackCommandId: 'ack-01',
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
          'owner_domain_id': 'ehost-someone-else',
          'staged': true,
        });
      }
      return null;
    });
    final session = await build().open(
      const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: SetupDescriptorTrustV1.developmentTofu,
      ),
    );
    await expectLater(
      session.configureNetwork(
        credentials: const DeviceWifiCredentials(ssid: 'home', password: 'pw'),
        onboardingTarget: target,
        createCommandId: 'create-01',
        collectCommandId: 'collect-01',
        ackCommandId: 'ack-01',
      ),
      throwsA(isA<DeviceProvisioningTransportException>()),
    );
  });

  test('refuses a discovered candidate it cannot identify', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'discoverProvisionableDevices') {
        return <Object?>[
          <Object?, Object?>{
            'transportId': '',
            'displayName': 'x',
            'transportKind': 'softap'
          },
        ];
      }
      return null;
    });
    await expectLater(
      build().discover(),
      throwsA(isA<DeviceProvisioningTransportException>()),
    );
  });

  group('what the phone said, said to a person', () {
    test('a refused scan is not reported as an empty room', () async {
      final transport = PlatformDeviceProvisioning(
        channel: _failing('DEVICE_SCAN_STALE', 'The phone did not scan'),
      );

      await expectLater(
        transport.discover(),
        throwsA(
          isA<DeviceProvisioningTransportException>()
              // "Nothing is there" and "nobody looked" are the same empty
              // list underneath, and only one of them should send a person
              // back to check the device.
              .having((e) => e.message, 'message', contains('没能重新扫描')),
        ),
      );
    });

    test('Wi-Fi being off is said plainly', () async {
      final transport = PlatformDeviceProvisioning(
        channel: _failing('WIFI_DISABLED', 'Wi-Fi is switched off'),
      );

      await expectLater(
        transport.discover(),
        throwsA(
          isA<DeviceProvisioningTransportException>()
              .having((e) => e.message, 'message', contains('打开手机的 Wi-Fi')),
        ),
      );
    });

    test('a platform failure never reaches the screen as a class name',
        () async {
      final transport = PlatformDeviceProvisioning(
        channel: _failing('SOMETHING_NEW', '设备暂时不可用'),
      );

      await expectLater(
        transport.discover(),
        throwsA(
          isA<DeviceProvisioningTransportException>()
              .having((e) => e.toString(), 'toString', '设备暂时不可用'),
        ),
      );
    });
  });
}

MethodChannel _failing(String code, String message) {
  const channel = MethodChannel('live.eidolon.mobile/platform');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    throw PlatformException(code: code, message: message);
  });
  return channel;
}

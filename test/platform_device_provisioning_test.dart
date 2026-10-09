import 'dart:convert';
import 'dart:async';

import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/platform_device_provisioning.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';

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
        'device_id': namedDeviceInstanceId('waveshare-2-06'),
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

  test(
      'cancel during open rejects a late descriptor and closes only that visit',
      () async {
    final response = Completer<String>();
    final entered = Completer<void>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'openProvisioningSession') {
        entered.complete();
        return response.future;
      }
      return null;
    });
    final transport = build();
    final opening = transport.open(const DeviceProvisioningCandidate(
      transportId: 'eidolon-test',
      displayName: 'test',
      transportKind: 'softap',
      trust: SetupDescriptorTrustV1.developmentTofu,
    ));
    final rejected = expectLater(
        opening,
        throwsA(isA<DeviceProvisioningTransportException>()
            .having((e) => e.code, 'code', 'provisioning_closed')));
    await entered.future;
    await transport.close();
    response.complete(descriptorJson());
    await rejected;
    final visit = (calls.first.arguments as Map)['sessionId'];
    expect(
        calls.skip(1).every((c) =>
            c.method == 'closeProvisioningSession' &&
            (c.arguments as Map)['sessionId'] == visit),
        isTrue);
  });

  test('native busy refusal retains the preceding visit for close', () async {
    final calls = <MethodCall>[];
    var opens = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'openProvisioningSession') {
        if (++opens == 2) throw PlatformException(code: 'PROVISIONING_BUSY');
        return descriptorJson();
      }
      return null;
    });
    const candidate = DeviceProvisioningCandidate(
      transportId: 'eidolon-test',
      displayName: 'test',
      transportKind: 'softap',
      trust: SetupDescriptorTrustV1.developmentTofu,
    );
    final transport = build();
    await transport.open(candidate);
    final previous = (calls.first.arguments as Map)['sessionId'];
    await expectLater(transport.open(candidate),
        throwsA(isA<DeviceProvisioningTransportException>()));
    await transport.close();
    expect(calls.last.method, 'closeProvisioningSession');
    expect((calls.last.arguments as Map)['sessionId'], previous);
    expect((calls[calls.length - 2].arguments as Map)['sessionId'],
        isNot(previous));
  });

  test('invalid descriptor releases the native visit immediately', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'openProvisioningSession') return '{}';
      return null;
    });
    final transport = build();
    await expectLater(
        transport.open(const DeviceProvisioningCandidate(
          transportId: 'eidolon-test',
          displayName: 'test',
          transportKind: 'softap',
          trust: SetupDescriptorTrustV1.developmentTofu,
        )),
        throwsA(isA<DeviceProvisioningTransportException>()));
    expect(calls.map((c) => c.method),
        ['openProvisioningSession', 'closeProvisioningSession']);
    expect(calls.first.arguments,
        containsPair('sessionId', (calls.last.arguments as Map)['sessionId']));
    await transport.close();
    expect(calls.length, 2);
  });

  test('concurrent open cannot replace a pending visit', () async {
    final response = Completer<String>();
    final entered = Completer<void>();
    var opens = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') {
        opens++;
        entered.complete();
        return response.future;
      }
      return null;
    });
    const candidate = DeviceProvisioningCandidate(
      transportId: 'eidolon-test',
      displayName: 'test',
      transportKind: 'softap',
      trust: SetupDescriptorTrustV1.developmentTofu,
    );
    final transport = build();
    final first = transport.open(candidate);
    await entered.future;
    await expectLater(
        transport.open(candidate),
        throwsA(isA<DeviceProvisioningTransportException>()
            .having((e) => e.code, 'code', 'provisioning_busy')));
    response.complete(descriptorJson());
    final session = await first;
    expect(opens, 1);
    await session.close();
  });

  test(
      'old visit close and requests retain their own scope after a new visit opens',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningScanNetworks') return <Object>[];
      return null;
    });
    final transport = build();
    const candidate = DeviceProvisioningCandidate(
      transportId: 'eidolon-test',
      displayName: 'test',
      transportKind: 'softap',
      trust: SetupDescriptorTrustV1.developmentTofu,
    );
    final first = await transport.open(candidate);
    final second = await transport.open(candidate);
    final firstId = (calls[0].arguments as Map)['sessionId'];
    final secondId = (calls[1].arguments as Map)['sessionId'];
    expect(firstId, isNot(secondId));
    await first.close();
    await second.scanNetworks();
    await transport.close();
    expect((calls[2].arguments as Map)['sessionId'], firstId);
    expect((calls[3].arguments as Map)['sessionId'], secondId);
    expect((calls[4].arguments as Map)['sessionId'], secondId);
  });

  test('configuration failures use the same typed error boundary as discovery',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningHandOverTrust') {
        return jsonEncode({
          'contract_version': '1',
          'staged': true,
          'owner_domain_id': target.ownerDomainId
        });
      }
      if (call.method == 'provisioningConfigureNetwork') {
        throw PlatformException(
            code: 'OWNER_ROUTE_UNAVAILABLE',
            message: '设备未能连接本次选择的主机，本次配置已撤回，原有归属未变。');
      }
      return null;
    });
    final session = await build().open(const DeviceProvisioningCandidate(
        transportId: 't',
        displayName: 'd',
        transportKind: 'softap',
        trust: SetupDescriptorTrustV1.developmentTofu));
    await expectLater(
        session.configureNetwork(
            credentials:
                const DeviceWifiCredentials(ssid: 'home', password: 'secret'),
            onboardingTarget: target,
            createCommandId: 'create-01',
            collectCommandId: 'collect-01',
            ackCommandId: 'ack-01'),
        throwsA(isA<DeviceProvisioningTransportException>()
            .having((e) => e.code, 'code', 'owner_route_unavailable')
            .having((e) => e.message, 'message', contains('原有归属未变'))));
  });

  test('prepares the selected Owner before obtaining a key-bound voucher',
      () async {
    final digest = 'a' * 64;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningHandOverTrust') {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        final payload = jsonDecode(arguments['payloadJson'] as String) as Map;
        expect(payload['prepare_only'], isTrue);
        expect(payload['owner_domain_id'], target.ownerDomainId);
        expect(payload.containsKey('commissioning_voucher'), isFalse);
        return jsonEncode({
          'contract_version': '1',
          'prepared': true,
          'owner_domain_id': target.ownerDomainId,
          'device_id': 'device-instance-$digest',
          'identity_fingerprint': 'sha256:$digest',
        });
      }
      return null;
    });
    final session = await build().open(const DeviceProvisioningCandidate(
      transportId: 'eidolon-7e2444',
      displayName: 'eidolon-7e2444',
      transportKind: 'softap',
      trust: SetupDescriptorTrustV1.developmentTofu,
    ));
    final prepared = await session.prepareOwner(target);
    expect(prepared.deviceId, 'device-instance-$digest');
    expect(prepared.identityFingerprint, 'p256:$digest');
    expect(session.descriptor, same(prepared));
    expect(prepared.sessionId, 'setup_session_01');
  });
  test('carries revoked identity replacement in authenticated preparation',
      () async {
    final digest = 'a' * 64;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningHandOverTrust') {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        final payload = jsonDecode(arguments['payloadJson'] as String) as Map;
        expect(payload['prepare_only'], isTrue);
        expect(payload['replace_revoked_identity'], isTrue);
        expect(payload['owner_domain_id'], target.ownerDomainId);
        expect(payload.containsKey('commissioning_voucher'), isFalse);
        return jsonEncode({
          'contract_version': '1',
          'prepared': true,
          'owner_domain_id': target.ownerDomainId,
          'device_id': 'device-instance-$digest',
          'identity_fingerprint': 'sha256:$digest',
        });
      }
      return null;
    });
    final session = await build().open(const DeviceProvisioningCandidate(
      transportId: 'eidolon-7e2444',
      displayName: 'eidolon-7e2444',
      transportKind: 'softap',
      trust: SetupDescriptorTrustV1.developmentTofu,
    ));
    final prepared =
        await session.prepareOwner(target.withRevokedIdentityReplacement(true));
    expect(prepared.deviceId, 'device-instance-$digest');
    expect(prepared.identityFingerprint, 'p256:$digest');
    expect(session.descriptor, same(prepared));
    expect(prepared.sessionId, 'setup_session_01');
  });

  test('authenticated preparation explicitly permits voucher-free maintenance',
      () async {
    final digest = 'a' * 64;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      return jsonEncode({
        'contract_version': '1',
        'prepared': true,
        'owner_domain_id': target.ownerDomainId,
        'device_id': 'device-instance-$digest',
        'identity_fingerprint': 'sha256:$digest',
        'requires_voucher': false,
      });
    });
    final session = await build().open(const DeviceProvisioningCandidate(
      transportId: 'eidolon-test',
      displayName: 'eidolon-test',
      transportKind: 'softap',
      trust: SetupDescriptorTrustV1.developmentTofu,
    ));
    expect(session.descriptor.requiresVoucher, isTrue);
    expect((await session.prepareOwner(target)).requiresVoucher, isFalse);
  });

  test('refuses preparation responses from a different Owner or key', () async {
    for (final wrongOwner in [true, false]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openProvisioningSession') return descriptorJson();
        return jsonEncode({
          'contract_version': '1',
          'prepared': true,
          'owner_domain_id': wrongOwner ? 'owner-other' : target.ownerDomainId,
          'device_id': 'device-instance-${'b' * 64}',
          'identity_fingerprint': 'sha256:${'a' * 64}',
        });
      });
      final session = await build().open(const DeviceProvisioningCandidate(
        transportId: 'eidolon-7e2444',
        displayName: 'eidolon-7e2444',
        transportKind: 'softap',
        trust: SetupDescriptorTrustV1.developmentTofu,
      ));
      final before = session.descriptor;
      await expectLater(session.prepareOwner(target),
          throwsA(isA<DeviceProvisioningTransportException>()));
      expect(session.descriptor, same(before));
    }
  });

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
    expect(
        session.descriptor.deviceId, namedDeviceInstanceId('waveshare-2-06'));
    expect(session.descriptor.trust, SetupDescriptorTrustV1.developmentTofu);
  });

  test('a ten minute phone clock skew cannot change a relative setup window',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      return null;
    });

    for (final skew in const [Duration(minutes: -10), Duration(minutes: 10)]) {
      final phoneNow = now.add(skew);
      final session =
          await PlatformDeviceProvisioning(clock: () => phoneNow).open(
        const DeviceProvisioningCandidate(
          transportId: 'eidolon-7e2444',
          displayName: 'eidolon-7e2444',
          transportKind: 'softap',
          trust: SetupDescriptorTrustV1.developmentTofu,
        ),
      );

      expect(
        session.descriptor.expiresAt?.difference(phoneNow),
        const Duration(minutes: 10),
      );
    }
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
          'device_id': namedDeviceInstanceId('waveshare-2-06'),
          'owner_domain_id': target.ownerDomainId,
          'staged': true,
        });
      }
      if (call.method == 'provisioningConfigureNetwork') {
        return committedEvidence();
      }
      if (call.method == 'closeProvisioningSession') {
        throw PlatformException(code: 'CLOSE_FAILED');
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
    final evidence = await session.configureNetwork(
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
    expect(evidence.isCommittedTerminal, isTrue);
    await expectLater(session.close(), throwsA(isA<PlatformException>()));
  });

  for (final failure in [
    ('provisioningConfigureNetwork', 'COMMISSIONING_TERMINAL_TIMEOUT', true),
    ('provisioningConfigureNetwork', 'NETWORK_APPLY_UNAVAILABLE', true),
    ('provisioningConfigureNetwork', 'DEVICE_DISCONNECTED', true),
    ('provisioningHandOverTrust', 'DEVICE_DISCONNECTED', false),
    ('provisioningConfigureNetwork', 'NETWORK_APPLY_REJECTED', false),
    ('provisioningConfigureNetwork', 'COMMISSIONING_STATUS_INVALID', false),
    ('provisioningConfigureNetwork', 'WIFI_AUTH_FAILED', false),
  ]) {
    test('network outcome classification: $failure', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openProvisioningSession') return descriptorJson();
        if (call.method == failure.$1) {
          throw PlatformException(code: failure.$2);
        }
        if (call.method == 'provisioningHandOverTrust') {
          return jsonEncode({
            'contract_version': '1',
            'device_id': namedDeviceInstanceId('waveshare-2-06'),
            'owner_domain_id': target.ownerDomainId,
            'staged': true
          });
        }
        return null;
      });
      final session = await build().open(const DeviceProvisioningCandidate(
          transportId: 't',
          displayName: 'd',
          transportKind: 'softap',
          trust: SetupDescriptorTrustV1.developmentTofu));
      await expectLater(
          session.configureNetwork(
              credentials:
                  const DeviceWifiCredentials(ssid: 'home', password: 'pw'),
              onboardingTarget: target,
              createCommandId: 'create-01',
              collectCommandId: 'collect-01',
              ackCommandId: 'ack-01'),
          throwsA(isA<DeviceProvisioningTransportException>().having(
              (error) => error.outcomeUnknown, 'outcomeUnknown', failure.$3)));
    });
  }

  test('credential delivery without terminal device evidence is not success',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openProvisioningSession') return descriptorJson();
      if (call.method == 'provisioningHandOverTrust') {
        return jsonEncode({
          'contract_version': '1',
          'device_id': namedDeviceInstanceId('waveshare-2-06'),
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
          'device_id': namedDeviceInstanceId('waveshare-2-06'),
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

  test(
    'B-005 rejects a transport profile this Mobile version does not support',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'discoverProvisionableDevices') {
          return <Object?>[
            <Object?, Object?>{
              'transportId': 'future-transport-1',
              'displayName': 'Future device',
              'transportKind': 'future-radio-v2',
            },
          ];
        }
        return null;
      });

      await expectLater(
        build().discover(),
        throwsA(
          isA<DeviceProvisioningTransportException>().having(
            (error) => error.code,
            'code',
            'unsupported_profile',
          ),
        ),
      );
    },
    skip:
        'B-005 product gap: candidate parsing currently accepts any non-empty transportKind',
  );

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

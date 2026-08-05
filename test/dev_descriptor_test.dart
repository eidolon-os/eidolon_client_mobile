import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/dev_descriptor.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/setup_fixtures.dart';

void main() {
  DateTime validClock() => DateTime.parse('2026-08-05T00:10:00Z');

  test('verifies the descriptor signed by Admin canonical JSON', () async {
    final descriptor = await DevelopmentCommissioningDescriptor.parseAndVerify(
      validDevDescriptorJson,
      clock: validClock,
    );

    expect(descriptor.hostId, 'ehost-56475aa75463474c0285');
    expect(descriptor.commissioningId, '123e4567-e89b-42d3-a456-426614174000');
    expect(
        descriptor.toString(), isNot(contains(descriptor.commissioningSecret)));
    expect(
      () => descriptor.requireNotExpired(
        clock: () => DateTime.parse('2026-08-05T00:30:00Z'),
      ),
      throwsA(isA<SetupTrustException>()),
    );
  });

  test('rejects a descriptor whose signed data was changed', () async {
    final changed = Map<String, dynamic>.from(validDevDescriptor)
      ..['commissioning_secret'] =
          'changed-commissioning-secret-0123456789abcdef';

    await expectLater(
      DevelopmentCommissioningDescriptor.parseAndVerify(
        jsonEncode(changed),
        clock: validClock,
      ),
      throwsA(
        isA<SetupTrustException>().having(
          (error) => error.message,
          'message',
          contains('签名验证失败'),
        ),
      ),
    );
  });

  test('rejects expired and non-contract descriptors', () async {
    await expectLater(
      DevelopmentCommissioningDescriptor.parseAndVerify(
        validDevDescriptorJson,
        clock: () => DateTime.parse('2026-08-05T00:30:00Z'),
      ),
      throwsA(
        isA<SetupTrustException>().having(
          (error) => error.message,
          'message',
          contains('已过期'),
        ),
      ),
    );

    final extraField = Map<String, dynamic>.from(validDevDescriptor)
      ..['unsupported'] = true;
    await expectLater(
      DevelopmentCommissioningDescriptor.parseAndVerify(
        jsonEncode(extraField),
        clock: validClock,
      ),
      throwsA(
        isA<SetupTrustException>().having(
          (error) => error.message,
          'message',
          contains('字段与 v1 契约不一致'),
        ),
      ),
    );
  });

  test('matches only the Local API snapshot for the selected Host', () async {
    final descriptor = await DevelopmentCommissioningDescriptor.parseAndVerify(
      validDevDescriptorJson,
      clock: validClock,
    );
    descriptor.requireHostMatch(HostOverview.fromJson(matchingHostOverview));

    final wrongOverview = Map<String, dynamic>.from(matchingHostOverview);
    final wrongHostDescriptor = Map<String, dynamic>.from(
      matchingHostOverview['descriptor']! as Map<String, dynamic>,
    )..['host_id'] = 'ehost-0123456789abcdefabcd';
    wrongOverview['descriptor'] = wrongHostDescriptor;

    expect(
      () => descriptor.requireHostMatch(HostOverview.fromJson(wrongOverview)),
      throwsA(
        isA<SetupTrustException>().having(
          (error) => error.message,
          'message',
          contains('不匹配'),
        ),
      ),
    );
  });

  test('verifies a nonce-bound Local API Host proof', () async {
    final descriptor = await DevelopmentCommissioningDescriptor.parseAndVerify(
      validDevDescriptorJson,
      clock: validClock,
    );
    await descriptor.verifyHostProof(
      HostProof.fromJson(validHostProof),
      expectedChallenge: validHostChallenge,
    );

    await expectLater(
      descriptor.verifyHostProof(
        HostProof.fromJson(validHostProof),
        expectedChallenge: 'AAEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8',
      ),
      throwsA(
        isA<SetupTrustException>().having(
          (error) => error.message,
          'message',
          contains('challenge 不匹配'),
        ),
      ),
    );

    final tamperedProof = Map<String, dynamic>.from(validHostProof)
      ..['signature'] =
          'AF3KrfUegMPsqmrjfbBpDy-2xhay3RdqRFslSH_oEDepS3vabevWP9haxt5w1xdW5QeSVKek2HCMwiaasj8yCQ';
    await expectLater(
      descriptor.verifyHostProof(
        HostProof.fromJson(tamperedProof),
        expectedChallenge: validHostChallenge,
      ),
      throwsA(
        isA<SetupTrustException>().having(
          (error) => error.message,
          'message',
          contains('私钥持有权'),
        ),
      ),
    );
  });
}

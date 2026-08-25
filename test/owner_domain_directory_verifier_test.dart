import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_setup/owner_domain_directory_verifier.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/owner_domain_fixtures.dart';

void main() {
  test('descriptor signing document is deterministic and excludes signature',
      () {
    // Byte-exactness against the canonical contract is asserted in
    // owner_domain_canonical_golden_test.dart, against the SDK golden vector.
    // Restating the expected bytes here too would make this file a second
    // authority for them, and the two copies drift the moment the descriptor
    // gains a field.
    final target = deviceOnboardingTargetFixture();
    final canonical = canonicalOwnerDomainDescriptorSigningJson(target);

    expect(canonical, canonicalOwnerDomainDescriptorSigningJson(target));
    expect(canonical, isNot(contains('"signature"')));
    expect(canonical, contains('"descriptor_uri"'));
    final decoded = jsonDecode(canonical) as Map<String, dynamic>;
    final keys = decoded.keys.toList();
    expect(keys, equals(List<String>.from(keys)..sort()));
    expect(
      decoded['descriptor_uri'],
      target.ownerDomainDescriptor.descriptorUri,
    );
  });

  test('accepts A to B and durably rejects an older signed revision', () async {
    final preferences = InMemoryAppPreferences();
    final verifier = PlatformOwnerDomainDirectoryVerifier(
      preferences: preferences,
      signatureVerifier: const _AcceptingSignatureVerifier(),
    );
    final a = deviceOnboardingTargetFixture();
    final b = _target(revision: 8, host: 'owner-b.local', signature: 'B');

    await verifier.verify(a);
    await verifier.verify(b);
    await expectLater(verifier.verify(a), throwsFormatException);

    final restored = PlatformOwnerDomainDirectoryVerifier(
      preferences: preferences,
      signatureVerifier: const _AcceptingSignatureVerifier(),
    );
    await expectLater(restored.verify(a), throwsFormatException);
  });

  test('same revision with different signed content fails closed', () async {
    final verifier = PlatformOwnerDomainDirectoryVerifier(
      preferences: InMemoryAppPreferences(),
      signatureVerifier: const _AcceptingSignatureVerifier(),
    );
    await verifier.verify(deviceOnboardingTargetFixture());

    await expectLater(
      verifier
          .verify(_target(revision: 7, host: 'other.local', signature: 'C')),
      throwsFormatException,
    );
  });

  test('higher Owner generation resets revision and fences the old lineage',
      () async {
    final verifier = PlatformOwnerDomainDirectoryVerifier(
      preferences: InMemoryAppPreferences(),
      signatureVerifier: const _AcceptingSignatureVerifier(),
    );
    final generationOne = _target(
      generation: 1,
      revision: 8,
      host: 'owner-a.local',
      signature: 'A',
    );
    final generationTwo = _target(
      generation: 2,
      revision: 1,
      host: 'owner-b.local',
      signature: 'B',
    );

    await verifier.verify(generationOne);
    await verifier.verify(generationTwo);
    await expectLater(verifier.verify(generationOne), throwsFormatException);
  });
}

DeviceOnboardingTarget _target({
  int generation = 1,
  required int revision,
  required String host,
  required String signature,
}) {
  final endpoints = ownerDomainDescriptorJsonFixture['endpoints']! as List;
  final value = Map<String, dynamic>.from(ownerDomainDescriptorJsonFixture)
    ..['owner_domain_generation'] = generation
    ..['directory_revision'] = revision
    ..['signature'] = signature * 86
    ..['endpoints'] = [
      {
        ...endpoints[0] as Map<String, dynamic>,
        'uri': 'https://$host/api/admission/v1',
      },
      endpoints[1],
    ];
  return DeviceOnboardingTarget(
    ownerDomainId: ownerDomainIdFixture,
    ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson(value),
    ownerRootCertificate: ownerRootCertificateFixture,
    authoritySigningCertificate: authoritySigningCertificateFixture,
  );
}

class _AcceptingSignatureVerifier implements OwnerDomainSignatureVerifierPort {
  const _AcceptingSignatureVerifier();

  @override
  Future<void> verify({
    required DeviceOnboardingTarget target,
    required String canonicalSigningDocument,
  }) async {}
}

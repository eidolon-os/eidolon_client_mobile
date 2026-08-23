import 'package:eidolon_client_mobile/src/features/device_setup/owner_domain_directory_verifier.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/owner_domain_fixtures.dart';

void main() {
  test('descriptor signing document is deterministic and excludes signature',
      () {
    final canonical = canonicalOwnerDomainDescriptorSigningJson(
      deviceOnboardingTargetFixture(),
    );

    expect(canonical, isNot(contains('"signature"')));
    expect(
      canonical,
      '{"directory_revision":7,"endpoints":[{"authority":"admission",'
      '"logical_audience":"owner-local:admission","priority":10,'
      '"transport_profile":"https-json","uri":"https://owner-a.local/'
      'api/device-onboarding/v1"},{"authority":"device-control",'
      '"logical_audience":"owner-local:device-control","priority":10,'
      '"transport_profile":"https-json","uri":"https://owner-a.local/'
      'api/device-control/v1"}],"expires_at":"2036-08-18T00:00:00Z",'
      '"issued_at":"2026-08-18T00:00:00Z","owner_domain_id":"owner-local",'
      '"signing_key_id":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      'bbbbbbbbbbbbbbbbbbbbbbbb","trust_root_refs":["sha256:aaaaaaaaaaaa'
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}',
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
}

DeviceOnboardingTarget _target({
  required int revision,
  required String host,
  required String signature,
}) {
  final endpoints = ownerDomainDescriptorJsonFixture['endpoints']! as List;
  final value = Map<String, dynamic>.from(ownerDomainDescriptorJsonFixture)
    ..['directory_revision'] = revision
    ..['signature'] = signature * 86
    ..['endpoints'] = [
      {
        ...endpoints[0] as Map<String, dynamic>,
        'uri': 'https://$host/api/device-onboarding/v1',
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

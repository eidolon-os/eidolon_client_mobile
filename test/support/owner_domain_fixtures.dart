import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';

const ownerDomainIdFixture = 'owner-local';
const ownerRootCertificateFixture = '''-----BEGIN CERTIFICATE-----
TEST-OWNER-ROOT
-----END CERTIFICATE-----''';
const authoritySigningCertificateFixture = '''-----BEGIN CERTIFICATE-----
TEST-AUTHORITY-SIGNER
-----END CERTIFICATE-----''';

const ownerDomainDescriptorJsonFixture = <String, dynamic>{
  'owner_domain_id': ownerDomainIdFixture,
  'owner_domain_generation': 1,
  'directory_revision': 7,
  'trust_root_refs': [
    'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ],
  'endpoints': [
    {
      'authority': 'admission',
      'logical_audience': '$ownerDomainIdFixture:admission',
      'uri': 'https://owner-a.local/api/device-onboarding/v1',
      'transport_profile': 'https-json',
      'priority': 10,
    },
    {
      'authority': 'device-control',
      'logical_audience': '$ownerDomainIdFixture:device-control',
      'uri': 'https://owner-a.local/api/device-control/v1',
      'transport_profile': 'https-json',
      'priority': 10,
    },
  ],
  'issued_at': '2026-08-18T00:00:00Z',
  'expires_at': '2036-08-18T00:00:00Z',
  'signing_key_id':
      'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'signature':
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
};

OwnerDomainDescriptorV1 ownerDomainDescriptorFixture() =>
    OwnerDomainDescriptorV1.fromJson(ownerDomainDescriptorJsonFixture);

DeviceOnboardingTarget deviceOnboardingTargetFixture({String? hostAddress}) =>
    DeviceOnboardingTarget(
      ownerDomainId: ownerDomainIdFixture,
      ownerDomainDescriptor: ownerDomainDescriptorFixture(),
      ownerRootCertificate: ownerRootCertificateFixture,
      authoritySigningCertificate: authoritySigningCertificateFixture,
      hostAddress: hostAddress,
    );

class AcceptingOwnerDomainDirectoryVerifier
    implements OwnerDomainDirectoryVerifier {
  const AcceptingOwnerDomainDirectoryVerifier();

  @override
  Future<void> verify(DeviceOnboardingTarget target) async {}
}

class RejectingOwnerDomainDirectoryVerifier
    implements OwnerDomainDirectoryVerifier {
  const RejectingOwnerDomainDirectoryVerifier();

  @override
  Future<void> verify(DeviceOnboardingTarget target) async {
    throw const FormatException('signature invalid');
  }
}

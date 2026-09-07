import 'dart:convert';
import 'dart:io';

import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/owner_domain_directory_verifier.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/owner_domain_fixtures.dart';

/// The canonical signing bytes of an Owner Domain descriptor exist in three
/// independent implementations: the Python SDK, ESP32 C++ and this Dart file.
/// Only the golden vector is authoritative, and it is synced byte-for-byte from
/// the SDK by tool/sync_device_foundation_v1.py. Asserting against a string
/// written out here instead would make this repo a second authority, which is
/// how a descriptor field can be added in the SDK and silently break signature
/// verification on this client with every test still green.
void main() {
  test('canonical signing document is byte-identical to the golden vector', () {
    final vector = jsonDecode(
      File('test/fixtures/device_foundation/owner-domain-descriptor.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final descriptor = Map<String, dynamic>.from(
      vector['descriptor']! as Map,
    );

    final canonical = canonicalOwnerDomainDescriptorSigningJson(
      DeviceOnboardingTarget(
        ownerDomainId: descriptor['owner_domain_id']! as String,
        ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson(descriptor),
        ownerRootCertificate: ownerRootCertificateFixture,
        authoritySigningCertificate: authoritySigningCertificateFixture,
      ),
    );

    expect(canonical, vector['canonical_signing_utf8']);
  });
}

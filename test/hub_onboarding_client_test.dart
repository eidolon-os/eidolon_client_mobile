import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/conversation/hub_onboarding_client.dart';
import 'package:eidolon_client_mobile/src/features/conversation/hub_onboarding_models.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_security.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/owner_domain_fixtures.dart';

const _retrievalToken = 'device-generated-random-token-000001';

void main() {
  test('canonical manifest revision matches the Hub and ESP32 vector',
      () async {
    expect(
      await canonicalManifestRevision(_manifest),
      'sha256:61fbd6624779ccded820c200cb9f289dde23860ec6952a52e5068824758d0175',
    );
  });

  test('uses signed logical Admission route and portable Owner root', () async {
    final security = _Security();
    final requests = <http.Request>[];
    final target = _target(ownerDomainDescriptorFixture());
    final client = HubOnboardingClient(
      security: security,
      clientFactory: (ownerRootCertificate) {
        expect(ownerRootCertificate, ownerRootCertificateFixture);
        return MockClient((request) async {
          requests.add(request);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['operation'] == 'device.enrollment') {
            return http.Response(
              jsonEncode({
                'operation': 'device.enrollment-received',
                'request_id': 'mobile-enroll-1',
                'enrollment_id': 'enrollment_1',
                'device_id': 'aa:bb',
                'lifecycle_state': 'pending-approval',
                'retrieval_expires_at_ms': 1786000000000,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'operation': 'device.handoff-outcome',
              'request_id': 'mobile-handoff-1',
              'enrollment_id': 'enrollment_1',
              'device_id': 'aa:bb',
              'manifest_revision':
                  'sha256:61fbd6624779ccded820c200cb9f289dde23860ec6952a52e5068824758d0175',
              'lifecycle_state': 'pending-approval',
              'channels': <Object>[],
            }),
            202,
          );
        });
      },
    );

    final descriptor = await client.fetchDescriptor(target);
    expect(requests, isEmpty, reason: 'discovery is not a trust fetch');
    final material = await security.loadOrCreateMaterial(target.ownerDomainId);
    final receipt = await client.enroll(
      target: target,
      descriptor: descriptor,
      material: material,
      deviceId: 'aa:bb',
      displayName: 'Eidolon Body',
      deviceKind: 'esp32-s3',
      manifest: _manifest,
    );
    await client.handoff(
      target: target,
      descriptor: descriptor,
      material: material,
      deviceId: 'aa:bb',
      enrollmentId: receipt.enrollmentId,
    );

    expect(requests[0].url.host, 'owner-a.local');
    expect(requests[0].url.path, '/api/device-onboarding/v1/enrollments');
    expect(requests[1].url.path,
        '/api/device-onboarding/v1/enrollments/enrollment_1/handoff');
    expect(security.savedEnrollmentId, 'enrollment_1');
  });

  test('Host A to B changes only the signed route', () async {
    final descriptorA = ownerDomainDescriptorFixture();
    final endpoints = ownerDomainDescriptorJsonFixture['endpoints']! as List;
    final jsonB = Map<String, dynamic>.from(ownerDomainDescriptorJsonFixture)
      ..['directory_revision'] = 8
      ..['signature'] =
          'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
      ..['endpoints'] = [
        {
          ...endpoints[0] as Map<String, dynamic>,
          'uri': 'https://owner-b.local/api/device-onboarding/v1',
        },
        endpoints[1],
      ];
    final descriptorB = OwnerDomainDescriptorV1.fromJson(jsonB);

    expect(_target(descriptorA).admissionEndpoint().uri.host, 'owner-a.local');
    expect(_target(descriptorB).admissionEndpoint().uri.host, 'owner-b.local');
    expect(descriptorB.ownerDomainId, descriptorA.ownerDomainId);
  });

  test('a descriptor from another Owner Domain is rejected', () {
    final wrong = Map<String, dynamic>.from(ownerDomainDescriptorJsonFixture)
      ..['owner_domain_id'] = 'owner-attacker';
    final target = VerifiedOwnerDomainTarget(
      ownerDomainId: ownerDomainIdFixture,
      descriptor: OwnerDomainDescriptorV1.fromJson(wrong),
      ownerRootCertificate: ownerRootCertificateFixture,
    );

    expect(target.admissionEndpoint, throwsFormatException);
  });
}

VerifiedOwnerDomainTarget _target(OwnerDomainDescriptorV1 descriptor) =>
    VerifiedOwnerDomainTarget(
      ownerDomainId: ownerDomainIdFixture,
      descriptor: descriptor,
      ownerRootCertificate: ownerRootCertificateFixture,
    );

const _manifest = <String, dynamic>{
  'schema_version': 1,
  'title': 'esp32-s3-touch-amoled-2.06',
  'properties': <Object>[],
  'actions': <Object>[],
  'events': <Object>[],
  'media': [
    {
      'kind': 'audio',
      'direction': 'bidirectional',
      'codecs': ['opus'],
    },
  ],
};

class _Security implements MobileBodySecurity {
  String? savedEnrollmentId;

  @override
  Future<DeviceEnrollmentMaterial> loadOrCreateMaterial(
          String ownerDomainId) async =>
      const DeviceEnrollmentMaterial(
        enrollmentRequestId: 'mobile-enroll-1',
        handoffRequestId: 'mobile-handoff-1',
        retrievalToken: _retrievalToken,
      );

  @override
  Future<void> saveEnrollmentReceipt({
    required String ownerDomainId,
    required String enrollmentId,
    required DateTime retrievalExpiresAt,
  }) async {
    savedEnrollmentId = enrollmentId;
  }

  @override
  Future<void> clearMaterial(String ownerDomainId) async {}
}

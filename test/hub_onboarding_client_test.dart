import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/conversation/hub_onboarding_client.dart';
import 'package:eidolon_client_mobile/src/features/conversation/hub_onboarding_models.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _fingerprint = 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';
const _retrievalToken = 'device-generated-random-token-000001';

void main() {
  test('canonical manifest revision matches the Hub and ESP32 vector',
      () async {
    expect(
      await canonicalManifestRevision(_manifest),
      'sha256:61fbd6624779ccded820c200cb9f289dde23860ec6952a52e5068824758d0175',
    );
  });

  test('screen-independent enrollment and pending handoff use the Hub contract',
      () async {
    final security = _Security();
    final requests = <http.Request>[];
    final client = HubOnboardingClient(
      security: security,
      clientFactory: (fingerprint) {
        expect(fingerprint, _fingerprint);
        return MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode(_descriptorJson),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
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
          expect(body['operation'], 'device.handoff');
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
    final descriptor = await client.fetchDescriptor(_target);
    final material = await security.loadOrCreateMaterial(_target.hubId);
    final receipt = await client.enroll(
      target: _target,
      descriptor: descriptor,
      material: material,
      deviceId: 'aa:bb',
      displayName: 'esp32-s3-touch-amoled-2.06',
      deviceKind: 'esp32-s3-touch-amoled-2.06',
      manifest: _manifest,
    );
    final handoff = await client.handoff(
      target: _target,
      descriptor: descriptor,
      material: material,
      deviceId: 'aa:bb',
      enrollmentId: receipt.enrollmentId,
    );

    expect(receipt.enrollmentId, 'enrollment_1');
    expect(handoff.isPending, isTrue);
    expect(security.savedEnrollmentId, 'enrollment_1');
    final enrollmentBody = jsonDecode(requests[1].body) as Map<String, dynamic>;
    expect(enrollmentBody['operation'], 'device.enrollment');
    expect(enrollmentBody, isNot(contains('identity_proof')));
    expect(enrollmentBody, isNot(contains('pairing_proof')));
    expect(
      requests[2].url.path,
      '/api/device-onboarding/v1/enrollments/enrollment_1/handoff',
    );
  });

  test('descriptor identity cannot switch Hub origin', () async {
    final client = HubOnboardingClient(
      security: _Security(),
      clientFactory: (_) => MockClient(
        (_) async => http.Response(
          jsonEncode({
            ..._descriptorJson,
            'enrollment_uri':
                'https://attacker.invalid/api/device-onboarding/v1/enrollments',
          }),
          200,
        ),
      ),
    );

    await expectLater(
      client.fetchDescriptor(_target),
      throwsA(
        isA<HubOnboardingRequestException>().having(
          (error) => error.message,
          'message',
          contains('身份不一致'),
        ),
      ),
    );
  });
}

final _target = VerifiedHubTarget(
  hubId: 'hub-local',
  descriptorUri: Uri(
      scheme: 'https',
      host: 'eidolon-hub.local',
      path: '/api/device-onboarding/v1/descriptor'),
  tlsSpkiFingerprint: _fingerprint,
);

const _descriptorJson = {
  'schema_version': 1,
  'hub_id': 'hub-local',
  'descriptor_uri':
      'https://eidolon-hub.local/api/device-onboarding/v1/descriptor',
  'device_onboarding_uri': 'https://eidolon-hub.local/api/device-onboarding/v1',
  'enrollment_uri':
      'https://eidolon-hub.local/api/device-onboarding/v1/enrollments',
  'protocol_versions': [1],
};

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
  Future<DeviceEnrollmentMaterial> loadOrCreateMaterial(String hubId) async =>
      const DeviceEnrollmentMaterial(
        enrollmentRequestId: 'mobile-enroll-1',
        handoffRequestId: 'mobile-handoff-1',
        retrievalToken: _retrievalToken,
      );

  @override
  Future<void> saveEnrollmentReceipt({
    required String hubId,
    required String enrollmentId,
    required DateTime retrievalExpiresAt,
  }) async {
    savedEnrollmentId = enrollmentId;
  }

  @override
  Future<void> clearMaterial(String hubId) async {}
}

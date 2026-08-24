import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/admission_fixtures.dart';

void main() {
  test('uses canonical Admission recovery routes, bearer and cursor', () async {
    final requests = <http.Request>[];
    final projection = canonicalProjection(state: 'grant_delivered');
    final cursor = canonicalAdmissionCursor();
    final client = LocalApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        expect(request.headers['authorization'], 'Bearer token');
        if (request.url.path.endsWith('/enrollment_01')) {
          return http.Response(jsonEncode(projection.toJson()), 200);
        }
        return http.Response(
          jsonEncode(
            canonicalRecoveryPage(
              [projection],
              nextCursor: cursor,
            ).toJson(),
          ),
          200,
        );
      }),
    );

    final page = await client.fetchEnrollmentRecoveryPage(
      'https://hub.example',
      accessToken: 'token',
      ownerDomainId: 'owner-domain_01',
      after: cursor,
    );
    final recovered = await client.fetchEnrollmentRecovery(
      'https://hub.example',
      accessToken: 'token',
      enrollmentId: 'enrollment_01',
    );

    expect(page.json['items'], hasLength(1));
    expect(recovered.toJson(), projection.toJson());
    expect(requests.first.url.path, '/api/admission/v1/enrollments');
    expect(requests.first.url.queryParameters, containsPair('limit', '50'));
    expect(
      requests.first.url.queryParameters,
      containsPair('after_resource_id', 'enrollment_01'),
    );
    expect(
      requests.last.url.path,
      '/api/admission/v1/enrollments/enrollment_01',
    );
  });

  test('stable Decision ID keeps an immutable canonical payload', () async {
    final bodies = <String>[];
    final result = canonicalAdmissionValue('DF-ADMISSION-DECIDE-RESULT-VALID');
    final client = LocalApiClient(
      httpClient: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(jsonEncode(result), 200);
      }),
    );
    final command = DecideEnrollmentV1.fromJson(
      canonicalAdmissionValue('DF-ADMISSION-DECIDE-VALID'),
    );

    for (var attempt = 0; attempt < 2; attempt++) {
      await client.decideEnrollment(
        'https://hub.example',
        accessToken: 'token',
        commandId: 'mobile-decision-01',
        correlationId: 'setup-01',
        command: command,
      );
    }

    expect(bodies, hasLength(2));
    expect(bodies[1], bodies[0]);
    final body = jsonDecode(bodies.first) as Map<String, dynamic>;
    expect(body['command_id'], 'mobile-decision-01');
    expect(body['decision'], 'approve');
    expect(body['expected_proposal_revision'], 1);
    expect(body['target_owner_domain_id'], 'owner-domain_01');
    expect(body['target_business_owner_id'], 'owner_01');
  });

  test('different payload conflict is a canonical DeviceProblem', () async {
    var attempt = 0;
    final bodies = <String>[];
    final client = LocalApiClient(
      httpClient: MockClient((request) async {
        bodies.add(request.body);
        attempt += 1;
        if (attempt == 1) {
          return http.Response(
            jsonEncode(
              canonicalAdmissionValue('DF-ADMISSION-DECIDE-RESULT-VALID'),
            ),
            200,
          );
        }
        return http.Response(
          jsonEncode(_problem(
            code: 'idempotency_payload_mismatch',
            retryable: false,
            commandId: 'mobile-decision-01',
          )),
          409,
        );
      }),
    );
    final command = DecideEnrollmentV1.fromJson(
      canonicalAdmissionValue('DF-ADMISSION-DECIDE-VALID'),
    );
    await client.decideEnrollment(
      'https://hub.example',
      accessToken: 'token',
      commandId: 'mobile-decision-01',
      correlationId: 'setup-01',
      command: command,
    );
    final changed = DecideEnrollmentV1.fromJson({
      ...command.toJson(),
      'initial_assignment_intent': {'companion_id': 'companion_other'},
    });

    await expectLater(
      client.decideEnrollment(
        'https://hub.example',
        accessToken: 'token',
        commandId: 'mobile-decision-01',
        correlationId: 'setup-01',
        command: changed,
      ),
      throwsA(
        isA<AdmissionRequestException>()
            .having(
                (error) => error.code, 'code', 'idempotency_payload_mismatch')
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
    expect(bodies[1], isNot(bodies[0]));
  });

  test('consumes SDK Claim event golden with five-field DeviceRef', () {
    final golden = canonicalAdmissionGolden();
    final event = ClaimRevokedEventV1.fromJson(
      Map<String, dynamic>.from(golden['event'] as Map),
    );
    final data = ClaimRevokedDataV1.fromJson(
      Map<String, dynamic>.from(event.json['data'] as Map),
    );
    final refJson = Map<String, dynamic>.from(data.json['device_ref'] as Map);
    final ref = DeviceRefV1.fromJson(refJson);

    expect(refJson.keys, {
      'device_instance_id',
      'owner_domain_id',
      'owner_domain_generation',
      'claim_generation',
      'trust_epoch',
    });
    expect(ref.ownerDomainId.value, 'owner-domain_01');
    expect(golden['semantics']['duplicate'], contains('one business fact'));
  });

  test('Hub unavailable stays retryable and malformed errors never infer state',
      () async {
    final unavailable = LocalApiClient(
      httpClient: MockClient((request) async => http.Response(
            jsonEncode(_problem(
              code: 'authority_unavailable',
              retryable: true,
            )),
            503,
          )),
    );
    await expectLater(
      unavailable.fetchEnrollmentRecovery(
        'https://hub.example',
        accessToken: 'token',
        enrollmentId: 'enrollment_01',
      ),
      throwsA(
        isA<AdmissionRequestException>()
            .having((error) => error.code, 'code', 'authority_unavailable')
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );

    final malformed = LocalApiClient(
      httpClient: MockClient(
        (request) async =>
            http.Response(jsonEncode({'detail': 'missing'}), 404),
      ),
    );
    await expectLater(
      malformed.fetchEnrollmentRecovery(
        'https://hub.example',
        accessToken: 'token',
        enrollmentId: 'enrollment_01',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

Map<String, dynamic> _problem({
  required String code,
  required bool retryable,
  String? commandId,
}) =>
    {
      'code': code,
      'category': 'conflict',
      'retryable': retryable,
      'authority': 'admission',
      'command_id': commandId,
      'resource_ref': 'enrollments/enrollment_01',
      'current_revision': 2,
      'current_generation': null,
      'retry_after_ms': retryable ? 1000 : null,
      'detail': code,
      'incident_id': 'incident_01',
    };

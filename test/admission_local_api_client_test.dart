import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_setup/admission_projection.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/admission_fixtures.dart';

/// This phone reads and decides Admission through one origin: the Host's own
/// Local API. Hub remains the Admission Authority and the Host presents a
/// short-lived, exactly-scoped credential on this Controller's behalf, so the
/// canonical `/api/admission/v1` path is never spoken here — a request sent to
/// it reached an origin that does not own it, and its 404 says nothing about
/// the Enrollment.
void main() {
  test('reads Enrollment recovery through the Host workflow surface', () async {
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
            canonicalRecoveryPage([projection], nextCursor: cursor).toJson(),
          ),
          200,
        );
      }),
    );

    final page = await client.fetchEnrollmentRecoveryPage(
      'https://host.example',
      accessToken: 'token',
      ownerDomainId: 'owner-domain_01',
      after: cursor,
    );
    final recovered = await client.fetchEnrollmentRecovery(
      'https://host.example',
      accessToken: 'token',
      enrollmentId: 'enrollment_01',
    );

    expect(page.json['items'], hasLength(1));
    expect(recovered.toJson(), projection.toJson());
    expect(requests.first.url.path, '/api/local/v1/device-enrollments');
    expect(requests.first.url.queryParameters, containsPair('limit', '50'));
    expect(
      requests.first.url.queryParametersAll['states'],
      containsAll(<String>['pending_review', 'grant_acknowledged']),
    );
    expect(
      requests.first.url.queryParameters,
      containsPair('after_resource_id', 'enrollment_01'),
    );
    expect(
      requests.last.url.path,
      '/api/local/v1/device-enrollments/enrollment_01',
    );
    for (final request in requests) {
      expect(request.url.path, isNot(contains('/api/admission/')));
    }
  });

  test('one request ID submits one Decision intent, byte for byte', () async {
    final bodies = <String>[];
    final urls = <Uri>[];
    final client = LocalApiClient(
      httpClient: MockClient((request) async {
        urls.add(request.url);
        bodies.add(request.body);
        expect(request.method, 'PUT');
        return http.Response(jsonEncode(_workflowResult()), 200);
      }),
    );

    for (var attempt = 0; attempt < 2; attempt++) {
      final outcome = await client.decideEnrollment(
        'https://host.example',
        accessToken: 'token',
        requestId: 'mobile-decision-setup-01',
        enrollmentId: 'enrollment_01',
        expectedProposalRevision: 2,
        reviewedManifestRef: _manifestRef(),
        expectedOwnerDomainId: 'owner-domain_01',
        expectedBusinessOwnerId: 'owner_01',
        initialCompanionId: 'companion_01',
      );
      expect(outcome.isCommitted, isTrue);
      expect(outcome.decisionId, 'decision_01');
      expect(outcome.recovery.proposal.json['enrollment_id'], 'enrollment_01');
    }

    expect(bodies, hasLength(2));
    expect(bodies[1], bodies[0]);
    expect(
      urls.first.path,
      '/api/local/v1/device-enrollments/enrollment_01/decision',
    );
    final body = jsonDecode(bodies.first) as Map<String, dynamic>;
    expect(body['request_id'], 'mobile-decision-setup-01');
    expect(body['decision'], 'approve');
    expect(body['expected_proposal_revision'], 2);
    // The confirming screen's Owner travels with the Decision; the Host refuses
    // it if the session it authenticates no longer holds that Owner.
    expect(body['expected_owner_domain_id'], 'owner-domain_01');
    expect(body['expected_business_owner_id'], 'owner_01');
    expect(body['initial_assignment_intent'], {'companion_id': 'companion_01'});
    expect(body.containsKey('command_id'), isFalse);
  });

  test('a Host refusal is the Host\'s refusal, with its own words', () async {
    final client = LocalApiClient(
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'detail': {'reason': '主机不接受这台设备当前的状态。请刷新列表后重试。'},
            }),
          ),
          409,
        ),
      ),
    );

    await expectLater(
      client.decideEnrollment(
        'https://host.example',
        accessToken: 'token',
        requestId: 'mobile-decision-setup-01',
        enrollmentId: 'enrollment_01',
        expectedProposalRevision: 2,
        reviewedManifestRef: _manifestRef(),
        expectedOwnerDomainId: 'owner-domain_01',
        expectedBusinessOwnerId: 'owner_01',
      ),
      throwsA(
        isA<LocalApiRequestException>()
            .having((error) => error.statusCode, 'statusCode', 409)
            .having((error) => error.reason, 'reason', contains('刷新列表')),
      ),
    );
  });

  test('a Decision that answered another request is not an outcome', () async {
    final client = LocalApiClient(
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({..._workflowResult(), 'request_id': 'someone-else'}),
          200,
        ),
      ),
    );

    await expectLater(
      client.decideEnrollment(
        'https://host.example',
        accessToken: 'token',
        requestId: 'mobile-decision-setup-01',
        enrollmentId: 'enrollment_01',
        expectedProposalRevision: 2,
        reviewedManifestRef: _manifestRef(),
        expectedOwnerDomainId: 'owner-domain_01',
        expectedBusinessOwnerId: 'owner_01',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('an uncommitted intent is reported as one, not as approval', () async {
    final result = _workflowResult();
    result['checkpoint'] = 'intent_recorded';
    result['decision_result'] = null;
    result['recovery'] = canonicalProjection().toJson();
    final client = LocalApiClient(
      httpClient: MockClient(
        (request) async => http.Response(jsonEncode(result), 200),
      ),
    );

    final outcome = await client.decideEnrollment(
      'https://host.example',
      accessToken: 'token',
      requestId: 'mobile-decision-setup-01',
      enrollmentId: 'enrollment_01',
      expectedProposalRevision: 2,
      reviewedManifestRef: _manifestRef(),
      expectedOwnerDomainId: 'owner-domain_01',
      expectedBusinessOwnerId: 'owner_01',
    );

    expect(outcome.isCommitted, isFalse);
    expect(outcome.decisionId, isNull);
    expect(
      outcome.recovery.proposal.json['state'],
      'pending_review',
    );
  });

  test('a checkpoint that disagrees with its result is refused', () async {
    final result = _workflowResult();
    result['checkpoint'] = 'intent_recorded';
    final client = LocalApiClient(
      httpClient: MockClient(
        (request) async => http.Response(jsonEncode(result), 200),
      ),
    );

    await expectLater(
      client.decideEnrollment(
        'https://host.example',
        accessToken: 'token',
        requestId: 'mobile-decision-setup-01',
        enrollmentId: 'enrollment_01',
        expectedProposalRevision: 2,
        reviewedManifestRef: _manifestRef(),
        expectedOwnerDomainId: 'owner-domain_01',
        expectedBusinessOwnerId: 'owner_01',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('reads Claims through the Host workflow surface', () async {
    final requests = <http.Request>[];
    final client = LocalApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(
            canonicalContractValue('DF-PH2B0-CLAIM-PAGE-VALID'),
          ),
          200,
        );
      }),
    );

    await client.fetchClaimPage(
      'https://host.example',
      accessToken: 'token',
      ownerDomainId: 'owner-domain_01',
    );

    expect(requests.single.url.path, '/api/local/v1/device-claims');
    expect(
      requests.single.url.queryParametersAll['states'],
      containsAll(<String>['active', 'suspended', 'revoked']),
    );
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

  test('an unavailable Host never becomes an Enrollment state', () async {
    final unavailable = LocalApiClient(
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'detail': 'Admin Device admission control plane is unavailable'
          }),
          503,
        ),
      ),
    );
    await expectLater(
      unavailable.fetchEnrollmentRecovery(
        'https://host.example',
        accessToken: 'token',
        enrollmentId: 'enrollment_01',
      ),
      throwsA(
        isA<LocalApiRequestException>()
            .having((error) => error.statusCode, 'statusCode', 503),
      ),
    );

    final malformed = LocalApiClient(
      httpClient: MockClient(
        (request) async =>
            http.Response(jsonEncode({'proposal': 'nonsense'}), 200),
      ),
    );
    await expectLater(
      malformed.fetchEnrollmentRecovery(
        'https://host.example',
        accessToken: 'token',
        enrollmentId: 'enrollment_01',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('the outcome model refuses a document that is not one', () {
    expect(
      () => AdmissionDecisionOutcome.fromJson({'operation': 'something.else'}),
      throwsA(isA<FormatException>()),
    );
  });
}

Map<String, dynamic> _manifestRef() => Map<String, dynamic>.from(
      canonicalProposal()['manifest_ref'] as Map,
    );

Map<String, dynamic> _workflowResult() => {
      'operation': 'admin.admission-decision-intent',
      'request_id': 'mobile-decision-setup-01',
      'intent_id': 'admission-intent-${'a' * 32}',
      'command_id': 'decide-enrollment-${'b' * 32}',
      'checkpoint': 'decision_committed',
      'decision_result': {
        'decision_id': 'decision_01',
        'decision': 'approve',
        'decided_by': Map<String, dynamic>.from(
          canonicalDecision()['actor'] as Map,
        ),
        'decided_at': '2026-08-25T00:00:00Z',
        'proposal_revision': 2,
      },
      'recovery': canonicalProjection(
        state: 'approved_awaiting_handoff',
        withDecision: true,
      ).toJson(),
    };

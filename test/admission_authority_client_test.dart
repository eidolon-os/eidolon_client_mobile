import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_setup/admission_authority_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/admission_fixtures.dart';

/// The device half of Admission, driven with the contract's own examples.
///
/// Every request this client sends has a canonical example in
/// `admission.json`, so nothing here is a payload someone typed. What is being
/// checked is the part the examples cannot state: which route each command goes
/// to, that the envelope carries exactly the two extra members the Authority's
/// strict check allows, and that a refusal arrives as the Authority's own
/// vocabulary rather than as an HTTP status.
///
/// The last one matters most. `hub/admission/http.py` refuses a wrong field set
/// with `INVALID_ARGUMENT`, a stale revision with `REVISION_CONFLICT` and a
/// missing approval with `DECISION_REQUIRED`, and those three want three
/// different things from a person. A client that flattens them into "failed"
/// is how a retry button ends up in front of an approval nobody has given.
void main() {
  final authority = Uri.parse('https://hub.owner-domain.invalid');

  http.Response ok(Object? body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: const {
        'content-type': 'application/json',
      });

  test('a proposal is posted with exactly the envelope the Authority allows',
      () async {
    final example = canonicalContractValue('DF-ADMISSION-CREATE-VALID');
    late http.Request sent;
    final client = AdmissionAuthorityClient(
      authority: authority,
      transport: MockClient((request) async {
        sent = request;
        return ok(
          canonicalContractValue('DF-ADMISSION-CREATE-RESULT-VALID'),
          201,
        );
      }),
    );

    final result = await client.createEnrollment(
      commandId: 'command_01',
      correlationId: 'intent_01',
      deviceInstanceCandidateId:
          example['device_instance_candidate_id']! as String,
      requestedOwnerDomainId: example['requested_owner_domain_id']! as String,
      hardwareIdentityEvidence:
          Map<String, Object?>.from(example['hardware_identity_evidence']! as Map),
      commissioningProof:
          Map<String, Object?>.from(example['commissioning_proof']! as Map),
      manifest: Map<String, Object?>.from(example['manifest']! as Map),
      handoffPublicKey:
          (example['handoff_key']! as Map)['public_key']! as String,
      operationalPublicKey:
          (example['operational_key']! as Map)['public_key']! as String,
    );

    expect(sent.url.path, '/api/admission/v1/enrollments');
    expect(sent.method, 'POST');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    // `_strict` in the Authority refuses both unknown and missing members, so
    // the envelope is the command plus exactly two.
    expect(body.keys.toSet(), {...example.keys, 'command_id', 'correlation_id'});
    for (final entry in example.entries) {
      expect(body[entry.key], entry.value, reason: entry.key);
    }
    expect(result.json['collection_challenge'], isNotEmpty);
  });

  test('collection goes to the enrollment it names', () async {
    final example = canonicalContractValue('DF-ADMISSION-COLLECT-VALID');
    late http.Request sent;
    final client = AdmissionAuthorityClient(
      authority: authority,
      transport: MockClient((request) async {
        sent = request;
        return ok(canonicalContractValue('DF-ADMISSION-COLLECT-RESULT-VALID'));
      }),
    );

    final result = await client.collectClaimGrant(
      commandId: 'command_02',
      correlationId: 'intent_01',
      enrollmentId: example['enrollment_id']! as String,
      proposalRevision: example['proposal_revision']! as int,
      collectionChallenge: example['collection_challenge']! as String,
      handoffKeyProof: example['handoff_key_proof']! as String,
    );

    expect(
      sent.url.path,
      '/api/admission/v1/enrollments/enrollment_01/claim-grants:collect',
    );
    expect(
      (jsonDecode(sent.body) as Map<String, dynamic>).keys.toSet(),
      {...example.keys, 'command_id', 'correlation_id'},
    );
    // The generated binding cross-checks the envelope's AAD against the grant
    // id on the way in, so parsing this is already an assertion.
    expect(result.json['grant_id'], isNotEmpty);
  });

  test('acknowledgement names both the enrollment and the grant', () async {
    final example = canonicalContractValue('DF-ADMISSION-ACK-VALID');
    late http.Request sent;
    final client = AdmissionAuthorityClient(
      authority: authority,
      transport: MockClient((request) async {
        sent = request;
        return ok(canonicalContractValue('DF-ADMISSION-ACK-RESULT-VALID'));
      }),
    );

    final result = await client.ackClaimGrant(
      commandId: 'command_03',
      correlationId: 'intent_01',
      enrollmentId: example['enrollment_id']! as String,
      grantId: example['grant_id']! as String,
      operationalKeyProof: example['operational_key_proof']! as String,
      storedClaimGeneration: example['stored_claim_generation']! as int,
      storedTrustEpoch: example['stored_trust_epoch']! as int,
    );

    expect(
      sent.url.path,
      '/api/admission/v1/enrollments/enrollment_01'
      '/claim-grants/grant_01:ack',
    );
    expect(result.json['claim_state'], 'active');
  });

  test('cancelling is available, because it is the way out', () async {
    late http.Request sent;
    final client = AdmissionAuthorityClient(
      authority: authority,
      transport: MockClient((request) async {
        sent = request;
        return ok(
          canonicalContractValue('DF-PH2B0-CANCEL-ENROLLMENT-RESULT-VALID'),
        );
      }),
    );
    final example =
        canonicalContractValue('DF-PH2B0-CANCEL-ENROLLMENT-VALID');

    await client.cancelEnrollment(
      commandId: 'command_04',
      correlationId: 'intent_01',
      enrollmentId: example['enrollment_id']! as String,
      reason: example['reason']! as String,
    );

    // The only forward move for a proposal whose handoff key is gone. Without
    // it the enrollment stays approved and unopenable for good.
    expect(sent.url.path, endsWith(':cancel'));
  });

  test('a refusal arrives as the Authority stated it', () async {
    final client = AdmissionAuthorityClient(
      authority: authority,
      transport: MockClient((_) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'code': 'DECISION_REQUIRED',
            'category': 'conflict',
            'retryable': false,
            'authority': 'admission',
            'command_id': 'command_02',
            'resource_ref': null,
            'current_revision': null,
            'current_generation': null,
            'retry_after_ms': null,
            'detail': 'approved Decision is required',
            'incident_id': 'incident_abc',
          }),
          409,
          headers: const {'content-type': 'application/problem+json'},
        );
      }),
    );

    await expectLater(
      client.collectClaimGrant(
        commandId: 'command_02',
        correlationId: 'intent_01',
        enrollmentId: 'enrollment_01',
        proposalRevision: 1,
        collectionChallenge: 'Y29sbGVjdGlvbi1jaGFsbGVuZ2U',
        handoffKeyProof: 'aGFuZG9mZi1rZXktcHJvb2Y',
      ),
      throwsA(
        isA<AdmissionRefusal>()
            .having((e) => e.code, 'code', 'DECISION_REQUIRED')
            // The bit a screen has to have: nobody is coming unless a person
            // acts, so nothing here should offer to try again.
            .having((e) => e.advancesOnItsOwn, 'advancesOnItsOwn', false)
            .having((e) => e.incidentId, 'incidentId', 'incident_abc'),
      ),
    );
  });

  test('a body that is not JSON is not treated as a busy Authority', () async {
    // Retrying an endpoint that answers HTML is a client spinning on a
    // misconfiguration. Named as unreadable, and not retryable.
    final client = AdmissionAuthorityClient(
      authority: authority,
      transport: MockClient((_) async => http.Response('<html>502</html>', 502)),
    );

    await expectLater(
      client.cancelEnrollment(
        commandId: 'command_05',
        correlationId: 'intent_01',
        enrollmentId: 'enrollment_01',
        reason: 'device_replaced',
      ),
      throwsA(
        isA<AdmissionRefusal>()
            .having((e) => e.code, 'code', 'INVALID_AUTHORITY_RESPONSE')
            .having((e) => e.advancesOnItsOwn, 'advancesOnItsOwn', false),
      ),
    );
  });

  test('a malformed command is refused before it reaches the network',
      () async {
    var reached = false;
    final client = AdmissionAuthorityClient(
      authority: authority,
      transport: MockClient((_) async {
        reached = true;
        return ok(const <String, Object?>{});
      }),
    );

    // `device_instance_candidate_id` must be `device-instance-<64 hex>`; the
    // generated binding knows that, so the round trip is not spent learning it.
    await expectLater(
      client.createEnrollment(
        commandId: 'command_01',
        correlationId: 'intent_01',
        deviceInstanceCandidateId: 'mobile-android-whatever',
        requestedOwnerDomainId: 'owner-domain_01',
        hardwareIdentityEvidence: const <String, Object?>{},
        commissioningProof: const <String, Object?>{},
        manifest: const <String, Object?>{},
        handoffPublicKey: 'p256-spki:AAAA',
        operationalPublicKey: 'p256-spki:AAAA',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(reached, isFalse);
  });

  test('a command without an idempotency key is refused', () async {
    var reached = false;
    final client = AdmissionAuthorityClient(
      authority: authority,
      transport: MockClient((_) async {
        reached = true;
        return ok(const <String, Object?>{});
      }),
    );

    // Without it a retry after a lost reply is a second proposal, and the
    // first one is orphaned with a handoff key nobody will ever collect for.
    await expectLater(
      client.cancelEnrollment(
        commandId: '  ',
        correlationId: 'intent_01',
        enrollmentId: 'enrollment_01',
        reason: 'device_replaced',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(reached, isFalse);
  });
}

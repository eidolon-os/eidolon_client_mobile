import 'dart:convert';
import 'dart:typed_data';

import 'package:eidolon_client_mobile/src/features/device_setup/admission_authority_client.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/admission_evidence.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/admission_proofs.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_claim_store.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_manifest.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

/// The admission chain as this phone runs it.
///
/// The cryptography is not re-tested here — it is held to RFC 9180 and the
/// ES256 vectors on the platform side, where it lives. What this covers is the
/// orchestration, which is where the failures are ones a person has to read: a
/// Grant addressed to another proposal, a key minted for a proposal that was
/// never made, a generation reported from expectation rather than from the
/// Grant that was actually opened.
const _handoffKeyId =
    'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _FakePlatform extends FakePhonePlatform {
  int issued = 0;
  int discarded = 0;
  final List<String> signedWithOperationalKey = <String>[];
  final List<String> signedWithHandoffKey = <String>[];
  Map<String, Object?>? openedWith;
  Object? grantPlaintext;

  @override
  Future<PlatformHandoffKey> issueHandoffKey() async {
    issued += 1;
    return PlatformHandoffKey(
      handle: 'handle-$issued',
      publicKey: 'p256-spki:AAAA',
      keyId: _handoffKeyId,
    );
  }

  @override
  Future<String> signDeviceCanonicalDocument(String document) async {
    signedWithOperationalKey.add(document);
    // 64 bytes, because the evidence assembler refuses anything else.
    return base64Url.encode(List<int>.filled(64, 7)).replaceAll('=', '');
  }

  @override
  Future<String> signHandoffCanonicalDocument({
    required String handle,
    required String document,
  }) async {
    signedWithHandoffKey.add(document);
    return base64Url.encode(List<int>.filled(64, 9)).replaceAll('=', '');
  }

  @override
  Future<Uint8List> openClaimGrant({
    required String handle,
    required String encapsulatedKey,
    required String aad,
    required String ciphertext,
  }) async {
    openedWith = <String, Object?>{
      'handle': handle,
      'encapsulatedKey': encapsulatedKey,
      'aad': aad,
      'ciphertext': ciphertext,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(grantPlaintext)));
  }

  @override
  Future<void> discardHandoffKey() async {
    discarded += 1;
  }
}

class _FakeController implements DeviceAdmissionPort {
  _FakeController({this.refuse = false});

  final bool refuse;
  String? askedFor;

  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
  }) async {
    askedFor = operationalSpkiSha256;
    if (refuse) throw StateError('no Workspace yet');
    return CommissioningVoucher(
      voucher: 'header.claims.signature',
      jti: 'jti-0f3a91c4d25b47e8a6031f7c8b9d2e50',
      deviceBaseId: 'software-body-${'a' * 40}',
      expiresAt: DateTime.utc(2026, 9, 6, 1),
    );
  }

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) =>
      throw UnimplementedError();

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) =>
      throw UnimplementedError();

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) =>
      throw UnimplementedError();
}

void main() {
  final target = deviceOnboardingTargetFixture();

  Map<String, dynamic> grantExample() {
    final grant = canonicalContractValue('DF-ADMISSION-CLAIM-GRANT-VALID');
    (grant['device_ref'] as Map)['device_instance_id'] = phoneDeviceInstanceId;
    return grant;
  }

  Map<String, dynamic> envelopeFor(String keyId) {
    final envelope =
        canonicalContractValue('DF-PH2B0-GRANT-WIRE-ENVELOPE-VALID');
    return <String, dynamic>{...envelope, 'recipient_handoff_key_id': keyId};
  }

  http.Response ok(Object? body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: const {
        'content-type': 'application/json',
      });

  MobileBodyAdmission admission({
    required _FakePlatform platform,
    required _FakeController controller,
    required MockClient transport,
    MobileBodyClaimStore? claims,
  }) =>
      MobileBodyAdmission(
        issueVoucher: controller.issueCommissioningVoucher,
        authority: AdmissionAuthorityClient(
          authority: Uri.parse('https://hub.owner-domain.invalid'),
          transport: transport,
        ),
        claims: claims ?? InMemoryMobileBodyClaimStore(),
        platform: platform,
        clock: () => DateTime.utc(2026, 9, 6, 12),
      );

  test('a proposal presents the standing the Host signed', () async {
    final platform = _FakePlatform();
    final controller = _FakeController();
    late Map<String, dynamic> sent;
    final flow = admission(
      platform: platform,
      controller: controller,
      transport: MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return ok(
          canonicalContractValue('DF-ADMISSION-CREATE-RESULT-VALID'),
          201,
        );
      }),
    );

    final proposal = await flow.propose(
      target: target,
      title: 'Eidolon Mobile',
      commandId: 'command_01',
      correlationId: 'intent_01',
    );

    // The Host is asked with this key's own fingerprint, in the shape the
    // hardware path already uses.
    expect(controller.askedFor, phoneFingerprint);
    // The base identity is the Host's, threaded through untouched. A Body that
    // named its own would be choosing its own lineage.
    final evidence = sent['hardware_identity_evidence']! as Map;
    expect(
      evidence['evidence'],
      contains('software-body-${'a' * 40}'),
    );
    expect(evidence['scheme'], admissionEvidenceScheme);
    expect(sent['device_instance_candidate_id'], phoneDeviceInstanceId);
    expect(
      (sent['manifest']! as Map)['manifest_id'],
      mobileBodyManifestId,
    );
    expect(proposal.handoffKeyId, _handoffKeyId);
    // What was signed is what was sent, not a re-encoding of it.
    expect(
      '${platform.signedWithOperationalKey.single}.'
      '${base64Url.encode(List<int>.filled(64, 7)).replaceAll('=', '')}',
      evidence['evidence'],
    );
  });

  test('a proposal that never got made does not leave a key behind', () async {
    // A handoff key minted for a proposal the Authority refused is a secret
    // nobody is watching — and worse, it would have replaced the key of a
    // proposal still in flight.
    final platform = _FakePlatform();
    final flow = admission(
      platform: platform,
      controller: _FakeController(),
      transport: MockClient((_) async => ok(<String, Object?>{
            'code': 'INVALID_ARGUMENT',
            'category': 'invalid',
            'retryable': false,
            'authority': 'admission',
            'command_id': 'command_01',
            'resource_ref': null,
            'current_revision': null,
            'current_generation': null,
            'retry_after_ms': null,
            'detail': 'manifest digest does not match',
            'incident_id': 'incident_1',
          }, 422)),
    );

    await expectLater(
      flow.propose(
        target: target,
        title: 'Eidolon Mobile',
        commandId: 'command_01',
        correlationId: 'intent_01',
      ),
      throwsA(isA<AdmissionRefusal>()),
    );
    expect(platform.discarded, 1);
  });

  test('no key is minted when the Host will not sign a standing', () async {
    // Order matters: the Host refuses first, and nothing else should have
    // happened yet.
    final platform = _FakePlatform();
    final flow = admission(
      platform: platform,
      controller: _FakeController(refuse: true),
      transport: MockClient((_) async => ok(const <String, Object?>{})),
    );

    await expectLater(
      flow.propose(
        target: target,
        title: 'Eidolon Mobile',
        commandId: 'command_01',
        correlationId: 'intent_01',
      ),
      throwsA(isA<StateError>()),
    );
    expect(platform.issued, 0);
  });

  test('completion opens the Grant and acknowledges what it actually holds',
      () async {
    final platform = _FakePlatform()..grantPlaintext = grantExample();
    final requests = <Map<String, dynamic>>[];
    final flow = admission(
      platform: platform,
      controller: _FakeController(),
      transport: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (request.url.path.endsWith(':ack')) {
          return ok(canonicalContractValue('DF-ADMISSION-ACK-RESULT-VALID'));
        }
        return ok(<String, Object?>{
          ...canonicalContractValue('DF-ADMISSION-COLLECT-RESULT-VALID'),
          'grant_id': grantExample()['grant_id'],
          'wire_envelope': envelopeFor(_handoffKeyId),
        });
      }),
    );

    final claim = await flow.completeAdmission(
      proposal: MobileBodyProposal(
        ownerDomainId:
            grantExample()['device_ref']['owner_domain_id'] as String,
        enrollmentId: 'enrollment_01',
        proposalRevision: 1,
        collectionChallenge: 'Y29sbGVjdGlvbi1jaGFsbGVuZ2U',
        handoffHandle: 'handle-1',
        handoffKeyId: _handoffKeyId,
        deviceInstanceId: phoneDeviceInstanceId,
        expiresAt: '2026-08-18T00:15:00Z',
      ),
      collectCommandId: 'command_02',
      ackCommandId: 'command_03',
      correlationId: 'intent_01',
    );

    // The collection proof is made with the handoff key, over the document the
    // Authority recomputes.
    expect(
      platform.signedWithHandoffKey.single,
      claimGrantCollectionProof(
        enrollmentId: 'enrollment_01',
        proposalRevision: 1,
        collectionChallenge: 'Y29sbGVjdGlvbi1jaGFsbGVuZ2U',
      ),
    );
    // The generation acknowledged is the one inside the Grant that was opened,
    // never the one this side expected to be given.
    final ack = requests.last;
    final deviceRef = grantExample()['device_ref']! as Map<String, dynamic>;
    expect(ack['stored_claim_generation'], deviceRef['claim_generation']);
    expect(ack['stored_trust_epoch'], deviceRef['trust_epoch']);
    expect(claim.claimState, 'active');
    // One shot, spent.
    expect(platform.discarded, 1);
  });

  test('the Claim is remembered, with the ref the Grant carried', () async {
    // A phone that did not persist would propose itself again on every launch,
    // and the Authority would be right to keep saying yes.
    final platform = _FakePlatform()..grantPlaintext = grantExample();
    final claims = InMemoryMobileBodyClaimStore();
    final flow = admission(
      platform: platform,
      controller: _FakeController(),
      claims: claims,
      transport: MockClient((request) async {
        if (request.url.path.endsWith(':ack')) {
          return ok(canonicalContractValue('DF-ADMISSION-ACK-RESULT-VALID'));
        }
        return ok(<String, Object?>{
          ...canonicalContractValue('DF-ADMISSION-COLLECT-RESULT-VALID'),
          'grant_id': grantExample()['grant_id'],
          'wire_envelope': envelopeFor(_handoffKeyId),
        });
      }),
    );

    await flow.completeAdmission(
      proposal: MobileBodyProposal(
        ownerDomainId:
            grantExample()['device_ref']['owner_domain_id'] as String,
        enrollmentId: 'enrollment_01',
        proposalRevision: 1,
        collectionChallenge: 'Y29sbGVjdGlvbi1jaGFsbGVuZ2U',
        handoffHandle: 'handle-1',
        handoffKeyId: _handoffKeyId,
        deviceInstanceId: phoneDeviceInstanceId,
        expiresAt: '2026-08-18T00:15:00Z',
      ),
      collectCommandId: 'command_02',
      ackCommandId: 'command_03',
      correlationId: 'intent_01',
    );

    final saved = await claims.load();
    // Carried whole, not rebuilt: the ref is what `configuration:pull` and the
    // acknowledgement proof are stated over.
    expect(saved!.deviceRef, grantExample()['device_ref']);
    expect(saved.grantId, grantExample()['grant_id']);
    expect(saved.claimGeneration, 2);
    expect(saved.trustEpoch, 1);
  });

  test('nothing is remembered when the Grant was never opened', () async {
    // The refusal path: a Grant addressed elsewhere must not leave a record
    // saying this phone holds a Claim it never received.
    final platform = _FakePlatform()..grantPlaintext = grantExample();
    final claims = InMemoryMobileBodyClaimStore();
    final flow = admission(
      platform: platform,
      controller: _FakeController(),
      claims: claims,
      transport: MockClient((_) async => ok(<String, Object?>{
            ...canonicalContractValue('DF-ADMISSION-COLLECT-RESULT-VALID'),
            'grant_id': grantExample()['grant_id'],
            'wire_envelope': envelopeFor('sha256:${'b' * 64}'),
          })),
    );

    await expectLater(
      flow.completeAdmission(
        proposal: MobileBodyProposal(
          ownerDomainId:
              grantExample()['device_ref']['owner_domain_id'] as String,
          enrollmentId: 'enrollment_01',
          proposalRevision: 1,
          collectionChallenge: 'Y29sbGVjdGlvbi1jaGFsbGVuZ2U',
          handoffHandle: 'handle-1',
          handoffKeyId: _handoffKeyId,
          deviceInstanceId: phoneDeviceInstanceId,
          expiresAt: '2026-08-18T00:15:00Z',
        ),
        collectCommandId: 'command_02',
        ackCommandId: 'command_03',
        correlationId: 'intent_01',
      ),
      throwsA(isA<AdmissionRefusal>()),
    );
    expect(await claims.load(), isNull);
  });

  test('a Grant addressed to another proposal is refused before opening',
      () async {
    // Attempting it would produce a bad AEAD tag, which reads as "this Grant
    // is corrupt" when what happened is that it belongs to somebody else.
    final platform = _FakePlatform()..grantPlaintext = grantExample();
    final flow = admission(
      platform: platform,
      controller: _FakeController(),
      transport: MockClient((_) async => ok(<String, Object?>{
            ...canonicalContractValue('DF-ADMISSION-COLLECT-RESULT-VALID'),
            'grant_id': grantExample()['grant_id'],
            'wire_envelope': envelopeFor('sha256:${'b' * 64}'),
          })),
    );

    await expectLater(
      flow.completeAdmission(
        proposal: MobileBodyProposal(
          ownerDomainId:
              grantExample()['device_ref']['owner_domain_id'] as String,
          enrollmentId: 'enrollment_01',
          proposalRevision: 1,
          collectionChallenge: 'Y29sbGVjdGlvbi1jaGFsbGVuZ2U',
          handoffHandle: 'handle-1',
          handoffKeyId: _handoffKeyId,
          deviceInstanceId: phoneDeviceInstanceId,
          expiresAt: '2026-08-18T00:15:00Z',
        ),
        collectCommandId: 'command_02',
        ackCommandId: 'command_03',
        correlationId: 'intent_01',
      ),
      throwsA(
        isA<AdmissionRefusal>()
            .having((e) => e.code, 'code', 'GRANT_ADDRESSED_ELSEWHERE')
            .having((e) => e.advancesOnItsOwn, 'advancesOnItsOwn', false),
      ),
    );
    expect(platform.openedWith, isNull);
  });

  test('lost ACK reply resumes after restart with the saved command and proof',
      () async {
    final platform = _FakePlatform()..grantPlaintext = grantExample();
    final claims = InMemoryMobileBodyClaimStore();
    final acks = <Map<String, dynamic>>[];
    final transport = MockClient((request) async {
      if (request.url.path.endsWith(':ack')) {
        final saved = await claims.load();
        expect(saved?.ackPending, true);
        expect(saved?.deviceRef, grantExample()['device_ref']);
        acks.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (acks.length == 1) {
          throw http.ClientException('reply lost after commit');
        }
        return ok(canonicalContractValue('DF-ADMISSION-ACK-RESULT-VALID'));
      }
      return ok({
        ...canonicalContractValue('DF-ADMISSION-COLLECT-RESULT-VALID'),
        'grant_id': grantExample()['grant_id'],
        'wire_envelope': envelopeFor(_handoffKeyId)
      });
    });
    final first = admission(
        platform: platform,
        controller: _FakeController(),
        transport: transport,
        claims: claims);
    await expectLater(
        first.completeAdmission(
            proposal: MobileBodyProposal(
                ownerDomainId:
                    grantExample()['device_ref']['owner_domain_id'] as String,
                enrollmentId: 'enrollment_01',
                proposalRevision: 1,
                collectionChallenge: 'Y29sbGVjdGlvbi1jaGFsbGVuZ2U',
                handoffHandle: 'handle-1',
                handoffKeyId: _handoffKeyId,
                deviceInstanceId: phoneDeviceInstanceId,
                expiresAt: '2026-08-18T00:15:00Z'),
            collectCommandId: 'command_02',
            ackCommandId: 'command_03',
            correlationId: 'intent_01'),
        throwsException);
    final signedBefore = platform.signedWithOperationalKey.length;
    final restarted = admission(
        platform: platform,
        controller: _FakeController(refuse: true),
        transport: transport,
        claims: claims);
    expect(await restarted.resumeAcknowledgement(correlationId: 'intent_02'),
        'active');
    expect(acks[0]['command_id'], acks[1]['command_id']);
    expect(acks[0]['operational_key_proof'], acks[1]['operational_key_proof']);
    expect(platform.signedWithOperationalKey.length, signedBefore);
    expect((await claims.load())!.ackPending, false);
  });

  test(
      'a lost proposal reply retries identical evidence without replacing its key',
      () async {
    final platform = _FakePlatform();
    final sent = <Map<String, dynamic>>[];
    final flow = admission(
        platform: platform,
        controller: _FakeController(),
        transport: MockClient((request) async {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          if (sent.length == 1) throw http.ClientException('reply lost');
          return ok(
              canonicalContractValue('DF-ADMISSION-CREATE-RESULT-VALID'), 201);
        }));
    Future<MobileBodyProposal> send() => flow.propose(
        target: target,
        title: 'Mobile',
        commandId: 'command_01',
        correlationId: 'intent_01');
    await expectLater(send(), throwsException);
    await send();
    expect(sent[0], sent[1]);
    expect(platform.issued, 1);
    expect(platform.discarded, 0);
  });

  test('abandoning a proposal cancels it and forgets the key', () async {
    final platform = _FakePlatform();
    late String path;
    final flow = admission(
      platform: platform,
      controller: _FakeController(),
      transport: MockClient((request) async {
        path = request.url.path;
        return ok(
          canonicalContractValue('DF-PH2B0-CANCEL-ENROLLMENT-RESULT-VALID'),
        );
      }),
    );

    await flow.abandon(
      enrollmentId: 'enrollment_01',
      commandId: 'command_04',
      correlationId: 'intent_01',
      reason: 'device_replaced',
    );

    expect(path, endsWith(':cancel'));
    expect(platform.discarded, 1);
  });
}

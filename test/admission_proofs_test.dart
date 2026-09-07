import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/admission_proofs.dart';
import 'package:flutter_test/flutter_test.dart';

/// The collection and acknowledgement proof documents, against their vectors.
///
/// For a while these were the two documents on the admission chain that the
/// contracts repository did not describe: the Authority built them as Python
/// dicts, the firmware concatenated the same bytes by hand, this file built
/// them a third way, and nothing compared the three. The member set was
/// asserted here as a literal — better than nothing, and no more than that,
/// because a literal beside the code it checks agrees with the code by
/// construction.
///
/// `DF-CLAIM-GRANT-COLLECTION-PROOF-001` and `DF-CLAIM-GRANT-ACK-PROOF-001`
/// ended that. Both the inputs and the expected bytes below come out of the
/// vector, which matters more than it looks: taking the inputs from a local
/// helper and only the expectation from the vector is how a test named for a
/// golden ends up never disagreeing with one.
///
/// Ordering and escaping are not re-asserted here; they belong to
/// `canonicalJsonEncode`, pinned by RFC 8785's own vector in
/// `canonical_json_golden_test.dart`.
Map<String, dynamic> _vector(String name) => jsonDecode(
      File('test/fixtures/device_foundation/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  test('the collection proof is the bytes the vector pins', () {
    final vector = _vector('claim-grant-collection-proof.json');
    final document = vector['document']! as Map<String, dynamic>;

    final proof = claimGrantCollectionProof(
      enrollmentId: document['enrollment_id']! as String,
      proposalRevision: document['proposal_revision']! as int,
      collectionChallenge: document['collection_challenge']! as String,
    );

    // Byte for byte: this is the exact form `hub/admission/application.py`
    // recomputes before verifying, and the form
    // `esp_idf_claim_grant_crypto.cc` concatenates by hand.
    expect(proof, vector['canonical_utf8']);
    expect(
      'sha256:${sha256.convert(utf8.encode(proof))}',
      vector['canonical_sha256'],
    );
    // The vector names which key signs it. Getting this wrong is not a
    // canonicalisation bug and would not show up above: collecting with the
    // operational key instead of the handoff key is a proof the Authority
    // refuses, because the Grant is sealed to the handoff key's HPKE peer.
    expect(vector['signing_key'], 'handoff');
  });

  test('the acknowledgement proof is the bytes the vector pins', () {
    final vector = _vector('claim-grant-ack-proof.json');
    final document = vector['document']! as Map<String, dynamic>;

    final proof = claimGrantAckProof(
      enrollmentId: document['enrollment_id']! as String,
      grantId: document['grant_id']! as String,
      // Passed through rather than rebuilt from parts, which is the whole
      // point of the member: the ref is a signed statement about which Claim
      // generation and trust epoch this Body is acknowledging.
      deviceRef: Map<String, Object?>.from(
        document['device_ref']! as Map,
      ),
    );

    expect(proof, vector['canonical_utf8']);
    expect(
      'sha256:${sha256.convert(utf8.encode(proof))}',
      vector['canonical_sha256'],
    );
    // The other key. The acknowledgement is this device speaking about itself,
    // and `device_instance_id` is derived from the very key that signs it — so
    // a proof by any other key activates a Claim it is not the subject of.
    expect(vector['signing_key'], 'operational');
  });

  test('every member the vector says must not move is in the signed bytes',
      () {
    // `mutate_each_field_must_fail` is the contract's list of members whose
    // change must break verification. A producer that silently dropped one
    // would still match nothing here unless the list is read: the digest
    // assertions above pass for the vector's own values, and a dropped member
    // is only visible as an absence.
    for (final vector in <Map<String, dynamic>>[
      _vector('claim-grant-collection-proof.json'),
      _vector('claim-grant-ack-proof.json'),
    ]) {
      final signed = jsonDecode(vector['canonical_utf8']! as String);
      for (final path
          in (vector['mutate_each_field_must_fail']! as List<Object?>)
              .cast<String>()) {
        Object? value = signed;
        for (final segment in path.split('.')) {
          expect(
            value,
            isA<Map<String, dynamic>>(),
            reason: '$path does not resolve in ${vector['vector_id']}',
          );
          final map = value! as Map<String, dynamic>;
          expect(
            map.containsKey(segment),
            isTrue,
            reason: '$path is absent from ${vector['vector_id']}',
          );
          value = map[segment];
        }
      }
    }
  });

  test('nested device ref members are ordered too', () {
    // The ref arrives from the Grant in whatever order the Authority wrote it;
    // what gets signed has to be canonical at every depth.
    final proof = claimGrantAckProof(
      enrollmentId: 'e',
      grantId: 'g',
      deviceRef: <String, Object?>{'z': 1, 'a': 2},
    );

    expect(
      proof,
      '{"contract":"eidolon.device-foundation.claim-grant-ack",'
      '"device_ref":{"a":2,"z":1},'
      '"enrollment_id":"e",'
      '"grant_id":"g"}',
    );
  });

  test('the contract names match the ones the Authority checks', () {
    // Two constants, and both are the whole of what tells these documents
    // apart. A collection proof accepted as an acknowledgement would be a
    // signature reused across two different statements.
    expect(
      claimGrantCollectionContract,
      'eidolon.device-foundation.claim-grant-collection',
    );
    expect(claimGrantAckContract, 'eidolon.device-foundation.claim-grant-ack');
    expect(claimGrantCollectionContract, isNot(claimGrantAckContract));
  });

  test('a base64url challenge is signed verbatim', () {
    // The contract allows `^[A-Za-z0-9_-]{22,128}$`, so nothing in a valid
    // challenge needs escaping and the signed bytes contain it as sent. The
    // Authority compares a digest of what it issued against a digest of what
    // arrives, so a challenge that changed shape in transit fails before the
    // signature is even looked at.
    const challenge = 'aZ0_-aZ0_-aZ0_-aZ0_-aZ';

    final proof = claimGrantCollectionProof(
      enrollmentId: 'enrollment_01',
      proposalRevision: 1,
      collectionChallenge: challenge,
    );

    expect(proof, contains('"collection_challenge":"$challenge"'));
  });

  test('incomplete proofs are refused rather than signed', () {
    // Signing an incomplete document produces a proof the Authority rejects
    // with a code that names the proof, not the missing field — so the refusal
    // has to happen here, where the missing field is known.
    expect(
      () => claimGrantCollectionProof(
        enrollmentId: '',
        proposalRevision: 1,
        collectionChallenge: 'c' * 22,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => claimGrantCollectionProof(
        enrollmentId: 'e',
        proposalRevision: 0,
        collectionChallenge: 'c' * 22,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => claimGrantAckProof(
        enrollmentId: 'e',
        grantId: 'g',
        deviceRef: const <String, Object?>{},
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

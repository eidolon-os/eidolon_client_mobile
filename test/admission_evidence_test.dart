import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:eidolon_client_mobile/src/features/device_setup/admission_evidence.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_instance_identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// The evidence a Body presents, replayed against the SDK's own vector.
///
/// The vector carries the whole chain — the four fields, their canonical bytes,
/// the signature over them, the composed wire string and its digest — so every
/// step here is compared against a number rather than against a reading of the
/// contract. That matters most for the digest: it covers the wire form, and a
/// digest over the canonical document instead is well-formed, plausible, and
/// produces a ClaimGrant that fails to open with nothing to say about why.
Map<String, dynamic> _voucherGolden() => jsonDecode(
      File('test/fixtures/device_foundation/commissioning-voucher.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  test('the evidence document is the four fields the vector states', () {
    final vector = _voucherGolden();

    final document = admissionEvidenceDocument(
      deviceBaseId: vector['device_base_id']! as String,
      deviceInstanceId: vector['device_instance_id']! as String,
      operationalPublicKey: vector['operational_public_key']! as String,
    );

    expect(document, vector['evidence_document']);
  });

  test('a software Body presents the same shape with its own base id', () {
    // The only difference between a board and this phone in all of Admission:
    // which base id the Host put in the voucher. Asserted so that a future
    // change which adds a software-only field to the evidence has to come
    // through this test.
    final vector = _voucherGolden();

    final document = admissionEvidenceDocument(
      deviceBaseId: vector['software_body_device_base_id']! as String,
      deviceInstanceId: vector['device_instance_id']! as String,
      operationalPublicKey: vector['operational_public_key']! as String,
    );

    expect(document.keys.toSet(), <String>{
      'device_base_id',
      'device_instance_id',
      'operational_public_key',
      'profile_id',
    });
    expect(document['device_base_id'], startsWith('software-body-'));
    expect(document['profile_id'], admissionProfileId);
  });

  test('canonical bytes match the vector', () {
    final vector = _voucherGolden();

    final canonical = admissionEvidenceCanonicalJson(
      Map<String, Object?>.from(vector['evidence_document']! as Map),
    );

    expect(canonical, vector['evidence_canonical_utf8']);
  });

  test('the instance id in the vector is the one this app would derive', () {
    // Ties the evidence to the identity rule rather than letting the document
    // carry whatever it was handed. If these ever disagree, the phone is
    // attesting to a key it is not using.
    final vector = _voucherGolden();

    expect(
      deriveDeviceInstanceId(vector['operational_public_key']! as String),
      vector['device_instance_id'],
    );
  });

  test('wire form and digest match the vector', () {
    final vector = _voucherGolden();

    final evidence = signedAdmissionEvidence(
      canonical: vector['evidence_canonical_utf8']! as String,
      signature: vector['evidence_signature']! as String,
    );

    expect(evidence.wire, vector['wire_evidence']);
    expect(evidence.digest, vector['evidence_digest']);
  });

  test('the digest covers the wire form, not the canonical document', () {
    // Stated as its own case because both are plausible and only one is right.
    final vector = _voucherGolden();
    final canonical = vector['evidence_canonical_utf8']! as String;

    final evidence = signedAdmissionEvidence(
      canonical: canonical,
      signature: vector['evidence_signature']! as String,
    );

    expect(evidence.digest, isNot(_digestOf(canonical)));
    expect(evidence.digest, _digestOf(evidence.wire));
  });

  test('the presented evidence member carries the V1 scheme', () {
    final vector = _voucherGolden();

    final json = signedAdmissionEvidence(
      canonical: vector['evidence_canonical_utf8']! as String,
      signature: vector['evidence_signature']! as String,
    ).toJson();

    expect(json['scheme'], vector['evidence_scheme']);
    expect(json['evidence'], vector['wire_evidence']);
    expect(json['evidence_digest'], vector['evidence_digest']);
  });

  test('a DER signature is refused rather than presented', () {
    // The failure this guards is specific: `Signature.sign()` returns DER, and
    // a DER signature is a well-formed base64url string of the wrong length.
    // Presented, it costs a round trip to an Authority that can only say the
    // evidence did not verify.
    final der = base64Url.encode(<int>[
      0x30, 0x44, 0x02, 0x20, ...List<int>.filled(32, 0x11), //
      0x02, 0x20, ...List<int>.filled(32, 0x22),
    ]);

    expect(
      () => signedAdmissionEvidence(canonical: '{}', signature: der),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('DER'),
        ),
      ),
    );
  });

  test('the commissioning proof uses the voucher jti as its nonce', () {
    // Not a fresh random value: the Hub's one-shot ledger is keyed by the
    // voucher's own jti, so any other nonce presents a proof whose single-use
    // record cannot be found.
    final vector = _voucherGolden();
    final voucher = vector['voucher']! as Map<String, dynamic>;
    final claims = voucher['claims']! as Map<String, dynamic>;

    final proof = commissioningProof(
      voucher: 'header.claims.signature',
      jti: claims['jti']! as String,
    );

    expect(proof['scheme'], voucher['scheme']);
    expect(proof['nonce'], claims['jti']);
  });

  test('empty evidence fields are refused', () {
    expect(
      () => admissionEvidenceDocument(
        deviceBaseId: '',
        deviceInstanceId: 'device-instance-x',
        operationalPublicKey: 'p256-spki:x',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => commissioningProof(voucher: 'v', jti: ''),
      throwsA(isA<FormatException>()),
    );
  });
}

/// The digest computed here rather than read from the implementation under
/// test, so the assertion about which half is covered is independent of it.
String _digestOf(String value) =>
    'sha256:${sha256.convert(utf8.encode(value))}';

/// What a Body signs to propose itself, and the form that signature travels in.
///
/// Every Body — a board or this phone — presents the same evidence: four fields
/// saying which base identity it was issued, which instance identity its
/// operational key derives, what that key is, and under which trust profile.
/// The document is canonicalised, signed by the operational key it names, and
/// sent as `<canonical>.<signature>` with a digest over that whole string.
///
/// The digest is the part worth stating twice: it covers the **wire** form, not
/// the canonical document. It ends up inside a signed ClaimGrant AAD
/// (`hardware_evidence_digest`), so a digest computed over the wrong half
/// produces a Grant that cannot be opened, and the only symptom is a bad AEAD
/// tag. `golden/commissioning-voucher.json` settles which half, and
/// `test/admission_evidence_test.dart` holds this file to it.
///
/// No signing here, and no key. The signature comes from the platform, because
/// the operational private key is in the Android Keystore and never leaves it;
/// what this file owns is the bytes that get signed and the shape they are sent
/// in — which is exactly the part that can be silently wrong.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../protocol/canonical_json.dart';

/// The trust profile every V1 Body is admitted under.
///
/// Named once here rather than at each use. The generated binding validates it
/// on construction (`CreateEnrollmentV1`, `ClaimGrantAADV1` and two others all
/// refuse any other value), so a wrong constant cannot travel — but a wrong
/// constant repeated at three call sites can still be tedious to correct, and
/// the vector in `commissioning-voucher.json` pins this one.
const admissionProfileId = 'eidolon-trust-p256-hpke-v1';

/// The evidence scheme for a base identity the Hub issued at commissioning.
///
/// The whole of V1: since 2026-08-31 no device carries factory identity
/// material, so hardware and software Bodies present the same scheme and differ
/// only in how the Host derived the base id it put in the voucher.
const admissionEvidenceScheme = 'hub-issued-base-p256';

/// The commissioning proof scheme for a first admission.
const commissioningVoucherScheme = 'hub-issued-commissioning-voucher-v1';

/// A signed evidence document, ready to be presented.
class AdmissionEvidence {
  const AdmissionEvidence({
    required this.canonical,
    required this.signature,
    required this.wire,
    required this.digest,
  });

  /// `JCS(evidence_document)` — the bytes the operational key signed.
  final String canonical;

  /// ES256 `r || s`, base64url without padding.
  final String signature;

  /// `<canonical>.<signature>`, as `hardware_identity_evidence.evidence`.
  final String wire;

  /// `sha256:<hex>` over [wire].
  final String digest;

  /// The `hardware_identity_evidence` member of a CreateEnrollment.
  Map<String, Object?> toJson() => <String, Object?>{
        'scheme': admissionEvidenceScheme,
        'evidence': wire,
        'evidence_digest': digest,
      };
}

/// The four fields a Body attests to, before canonicalisation.
///
/// [deviceBaseId] is never chosen here. It is whatever the Host put in the
/// commissioning voucher — minted for a board, derived from the Controller for
/// a software Body — and a Body that could name its own base identity could
/// choose its own lineage, which is the anchor the anti-rollback fence hangs
/// from. It is threaded through from the voucher for that reason and no other.
Map<String, Object?> admissionEvidenceDocument({
  required String deviceBaseId,
  required String deviceInstanceId,
  required String operationalPublicKey,
}) {
  if (deviceBaseId.isEmpty ||
      deviceInstanceId.isEmpty ||
      operationalPublicKey.isEmpty) {
    throw const FormatException('Admission evidence fields cannot be empty');
  }
  return <String, Object?>{
    'device_base_id': deviceBaseId,
    'device_instance_id': deviceInstanceId,
    'operational_public_key': operationalPublicKey,
    'profile_id': admissionProfileId,
  };
}

/// The canonical bytes of [document], which are what gets signed.
String admissionEvidenceCanonicalJson(Map<String, Object?> document) =>
    canonicalJsonEncode(document);

/// Assemble a signed evidence document from its canonical bytes and signature.
///
/// [signature] must already be ES256 `r || s` base64url — what
/// `PlatformBridge.signDeviceCanonicalDocument` returns. A DER signature would
/// be accepted here and rejected by the Authority, so the one thing this can
/// check cheaply, it checks: the encoding's fixed length.
AdmissionEvidence signedAdmissionEvidence({
  required String canonical,
  required String signature,
}) {
  if (canonical.isEmpty) {
    throw const FormatException('Admission evidence document is empty');
  }
  _requireEs256P1363(signature);
  final wire = '$canonical.$signature';
  return AdmissionEvidence(
    canonical: canonical,
    signature: signature,
    wire: wire,
    // Over the wire form. See this library's note: the Authority binds this
    // digest into the ClaimGrant AAD, so the wrong half fails as a bad tag.
    digest: 'sha256:${sha256.convert(utf8.encode(wire))}',
  );
}

/// The `commissioning_proof` member of a CreateEnrollment.
Map<String, Object?> commissioningProof({
  required String voucher,
  required String jti,
}) {
  if (voucher.isEmpty || jti.isEmpty) {
    throw const FormatException('Commissioning proof is incomplete');
  }
  return <String, Object?>{
    'scheme': commissioningVoucherScheme,
    'proof': voucher,
    // The voucher's own jti. It is the nonce because the Hub's one-shot ledger
    // is keyed by it: sending anything else would present a proof whose
    // single-use record nobody can find.
    'nonce': jti,
  };
}

/// 64 raw bytes of `r || s`, base64url without padding, and nothing else.
void _requireEs256P1363(String signature) {
  if (signature.isEmpty) {
    throw const FormatException('Admission evidence signature is empty');
  }
  final List<int> raw;
  try {
    raw = base64Url.decode(
      signature.padRight(signature.length + (-signature.length % 4), '='),
    );
  } on FormatException {
    throw const FormatException(
      'Admission evidence signature is not base64url',
    );
  }
  if (raw.length != 64) {
    throw FormatException(
      'Admission evidence signature must be 64-byte ES256 r||s, '
      'got ${raw.length} bytes — a DER signature is the likely cause',
    );
  }
}

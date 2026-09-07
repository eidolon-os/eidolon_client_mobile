/// The two documents a Body signs after its proposal has been approved.
///
/// Collection proves possession of the key the Grant will be sealed to;
/// acknowledgement proves possession of the operational key and states which
/// generation the device stored. Different keys, different contracts, one
/// canonicaliser.
///
/// ## This is the third implementation, and now there is a vector
///
/// The Authority builds these dictionaries in `hub/admission/application.py`
/// and verifies the signature over `rfc8785.dumps(...)`; the firmware builds
/// the same bytes by string concatenation in
/// `eidolon-client-esp32/main/eidolon/esp_idf_claim_grant_crypto.cc`, with the
/// members pre-sorted by hand. For a while none of the three was written down
/// in `eidolon_sdk/contracts`, so nothing turned red when one drifted — and
/// these are documents **neither end sends**: both build them from the
/// Proposal they hold, and a member set that disagrees surfaces as a rejected
/// signature, which reads like a key fault.
///
/// `DF-CLAIM-GRANT-COLLECTION-PROOF-001` and `DF-CLAIM-GRANT-ACK-PROOF-001`
/// now pin both documents, and `test/admission_proofs_test.dart` asserts this
/// file's output against their `canonical_utf8` byte for byte. The member set
/// is no longer stated by a test agreeing with the code beside it; it is
/// stated by the contract.
library;

import '../../generated/device_foundation_v1.dart';
import '../../protocol/canonical_json.dart';

/// The contract name in a collection proof document.
const claimGrantCollectionContract =
    'eidolon.device-foundation.claim-grant-collection';

/// The contract name in an acknowledgement proof document.
const claimGrantAckContract = 'eidolon.device-foundation.claim-grant-ack';

/// The canonical bytes a device signs with its **handoff** key to collect.
///
/// [collectionChallenge] is the one the Authority issued with the proposal
/// result and holds only a digest of; presenting a different one is refused as
/// an invalid challenge before the signature is even checked.
String claimGrantCollectionProof({
  required String enrollmentId,
  required int proposalRevision,
  required String collectionChallenge,
}) {
  if (enrollmentId.isEmpty || collectionChallenge.isEmpty) {
    throw const FormatException('Collection proof is missing an identifier');
  }
  if (proposalRevision < 1) {
    throw const FormatException('Proposal revision must be positive');
  }
  return canonicalJsonEncode(<String, Object?>{
    'contract': claimGrantCollectionContract,
    'enrollment_id': enrollmentId,
    'proposal_revision': proposalRevision,
    'collection_challenge': collectionChallenge,
  });
}

/// The canonical bytes a device signs with its **operational** key to ack.
///
/// [deviceRef] is the reference carried inside the opened Grant, passed through
/// whole. It is not rebuilt from parts here: it is a signed statement about
/// which generation this Claim belongs to, and a reconstruction that dropped or
/// renamed a member would be a proof over a different document than the one the
/// Authority is holding.
String claimGrantAckProof({
  required String enrollmentId,
  required String grantId,
  required Map<String, Object?> deviceRef,
}) {
  if (enrollmentId.isEmpty || grantId.isEmpty) {
    throw const FormatException('Acknowledgement proof is missing an identifier');
  }
  if (deviceRef.isEmpty) {
    throw const FormatException('Acknowledgement proof is missing a device ref');
  }
  return canonicalJsonEncode(<String, Object?>{
    'contract': claimGrantAckContract,
    'enrollment_id': enrollmentId,
    'grant_id': grantId,
    'device_ref': deviceRef,
  });
}

/// The canonical bytes a ClaimGrant is authenticated under.
///
/// Recomputed from the envelope's own members rather than carried alongside
/// them: the AAD is authenticated, not transmitted, so if any member says
/// something other than what the Authority sealed, the Grant simply does not
/// open. Those bytes are pinned by two vectors in
/// `test/canonical_json_golden_test.dart`.
///
/// The strict field check happens first, and it is not ceremony. A member the
/// Authority added and this build does not know would otherwise be dropped by a
/// tolerant reader and produce different bytes — which surfaces as a bad tag,
/// with nothing to say about the version skew that caused it.
String claimGrantAadCanonicalJson(Object? aad) {
  if (aad is! Map) {
    throw const FormatException('ClaimGrant AAD is not an object');
  }
  final members = Map<String, dynamic>.from(aad);
  ClaimGrantAADV1.fromJson(members);
  return canonicalJsonEncode(members);
}

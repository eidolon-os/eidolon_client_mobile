/// This phone proposing itself as a Body, and finishing once it is approved.
///
/// ## Why this is two calls and not one
///
/// Approval stays a separate, deliberate act. On the hardware path "propose"
/// and "approve" are two physical objects — the board in the box and the phone
/// in your hand — and on this path they are the same phone and the same person.
/// `docs/设备与Body/纯软件Body准入身份裁决.md` W1 accepts that weakening on one
/// condition: that it is made visible rather than compensated for. An
/// orchestrator that proposed and approved in one call would be exactly the
/// compensation it refused — the Owner would never see the moment.
///
/// So [MobileBodyAdmission.propose] stops at a pending proposal, the existing
/// approval surface does what it already does for a board, and
/// [MobileBodyAdmission.completeAdmission] runs the two steps after it. What
/// happens in between is a person's.
///
/// ## What crosses which boundary
///
/// Neither private key leaves the platform. The operational key signs the
/// evidence and the acknowledgement; the one-shot handoff key signs the
/// collection proof and opens the Grant. This layer moves canonical bytes down
/// and reads contract objects back, and owns no cryptography of its own.
library;

import 'dart:convert';

import '../../generated/device_foundation_v1.dart';
import '../../models/hub_models.dart';
import '../../platform/platform_bridge.dart';
import 'admission_authority_client.dart';
import 'admission_evidence.dart';
import 'admission_proofs.dart';
import 'device_setup_models.dart';
import 'mobile_body_claim_store.dart';
import 'mobile_body_manifest.dart';

/// A proposal this phone has made and can still finish.
///
/// Holds the handle to the handoff key on the platform. The key itself lives
/// only in memory, so a proposal that outlives the process can no longer be
/// completed by anyone — see [MobileBodyAdmission.completeAdmission], which
/// says so rather than retrying.
class MobileBodyProposal {
  const MobileBodyProposal({
    required this.enrollmentId,
    required this.proposalRevision,
    required this.collectionChallenge,
    required this.handoffHandle,
    required this.handoffKeyId,
    required this.deviceInstanceId,
    required this.expiresAt,
    required this.ownerDomainId,
  });

  final String enrollmentId;
  final int proposalRevision;
  final String collectionChallenge;
  final String handoffHandle;
  final String handoffKeyId;
  final String deviceInstanceId;
  final String expiresAt;
  final String ownerDomainId;
}

/// A Claim this phone now holds, as the Grant it opened describes it.
class MobileBodyClaim {
  const MobileBodyClaim({
    required this.grant,
    required this.claimState,
  });

  final ClaimGrantV1 grant;
  final String claimState;

  Map<String, Object?> get deviceRef =>
      Map<String, Object?>.from(grant.json['device_ref']! as Map);
}

/// The admission chain, from this phone's side.
class MobileBodyAdmission {
  MobileBodyAdmission({
    required Future<CommissioningVoucher> Function(
            {required String operationalSpkiSha256})
        issueVoucher,
    required AdmissionAuthorityClient authority,
    required MobileBodyClaimStore claims,
    PlatformBridge platform = const PlatformBridge(),
    DateTime Function() clock = DateTime.now,
  })  : _issueVoucher = issueVoucher,
        _authority = authority,
        _claims = claims,
        _platform = platform,
        _clock = clock;

  /// The Controller surface, for the one thing only an Owner can do here:
  /// have the Host sign this device's standing.
  final Future<CommissioningVoucher> Function(
      {required String operationalSpkiSha256}) _issueVoucher;
  _PreparedProposal? _prepared;
  bool get hasPreparedProposal => _prepared != null;
  final Map<String, String> _collectionProofs = {};

  AdmissionAuthorityClient _authority;

  void useAuthority(AdmissionAuthorityClient authority) {
    _authority.close();
    _authority = authority;
  }

  /// Where the Claim is remembered. Required rather than optional: a phone that
  /// forgot to persist would propose itself again on every launch, and the
  /// Authority would be right to keep saying yes.
  final MobileBodyClaimStore _claims;

  final PlatformBridge _platform;
  final DateTime Function() _clock;

  /// Propose this phone, and stop.
  ///
  /// [commandId] is the idempotency key over the proposal. Reuse it to resume
  /// after a lost reply; a fresh one makes a second proposal and orphans the
  /// first — along with the handoff key it was made with.
  Future<MobileBodyProposal> propose({
    required DeviceOnboardingTarget target,
    required String title,
    required String commandId,
    required String correlationId,
  }) async {
    var prepared = _prepared;
    if (prepared == null || prepared.commandId != commandId) {
      final identity = await _platform.getDeviceIdentity();
      final voucher =
          await _issueVoucher(operationalSpkiSha256: identity.fingerprint);
      final handoff = await _platform.issueHandoffKey();
      final canonical =
          admissionEvidenceCanonicalJson(admissionEvidenceDocument(
        deviceBaseId: voucher.deviceBaseId,
        deviceInstanceId: identity.deviceInstanceId,
        operationalPublicKey: identity.operationalPublicKey,
      ));
      prepared = _PreparedProposal(
        commandId: commandId,
        identity: identity,
        handoff: handoff,
        evidence: signedAdmissionEvidence(
                canonical: canonical,
                signature:
                    await _platform.signDeviceCanonicalDocument(canonical))
            .toJson(),
        proof: commissioningProof(voucher: voucher.voucher, jti: voucher.jti),
      );
      _prepared = prepared;
    }
    // Retain the exact proof and key across an uncertain response. A retry is
    // the same command, not a new proposal under a replacement handoff key.
    late CreateEnrollmentResultV1 result;
    try {
      result = await _authority.createEnrollment(
        commandId: commandId,
        correlationId: correlationId,
        deviceInstanceCandidateId: prepared.identity.deviceInstanceId,
        requestedOwnerDomainId: target.ownerDomainId,
        hardwareIdentityEvidence: prepared.evidence,
        commissioningProof: prepared.proof,
        manifest: mobileBodyManifestRef(title: title),
        handoffPublicKey: prepared.handoff.publicKey,
        operationalPublicKey: prepared.identity.operationalPublicKey,
      );
    } on AdmissionRefusal catch (e) {
      if (!e.retryable &&
          e.status >= 400 &&
          e.status < 500 &&
          e.code == "INVALID_ARGUMENT") {
        await _platform.discardHandoffKey();
        _prepared = null;
      }
      rethrow;
    }
    return MobileBodyProposal(
      ownerDomainId: target.ownerDomainId,
      enrollmentId: result.json['enrollment_id']! as String,
      proposalRevision: result.json['proposal_revision']! as int,
      collectionChallenge: result.json['collection_challenge']! as String,
      handoffHandle: prepared.handoff.handle,
      handoffKeyId: prepared.handoff.keyId,
      deviceInstanceId: prepared.identity.deviceInstanceId,
      expiresAt: result.json['expires_at']! as String,
    );
  }

  /// Collect the Grant, open it, and acknowledge it.
  ///
  /// Runs only after the Owner has approved [proposal]. The Authority refuses
  /// collection before that with `DECISION_REQUIRED`, which is a refusal that
  /// names a person rather than a delay — nothing here should retry it.
  Future<MobileBodyClaim> completeAdmission({
    required MobileBodyProposal proposal,
    required String collectCommandId,
    required String ackCommandId,
    required String correlationId,
  }) async {
    final collected = await _authority.collectClaimGrant(
      commandId: collectCommandId,
      correlationId: correlationId,
      enrollmentId: proposal.enrollmentId,
      proposalRevision: proposal.proposalRevision,
      collectionChallenge: proposal.collectionChallenge,
      handoffKeyProof: _collectionProofs[proposal.enrollmentId] ??=
          await _platform.signHandoffCanonicalDocument(
        handle: proposal.handoffHandle,
        document: claimGrantCollectionProof(
          enrollmentId: proposal.enrollmentId,
          proposalRevision: proposal.proposalRevision,
          collectionChallenge: proposal.collectionChallenge,
        ),
      ),
    );

    final envelope = Map<String, dynamic>.from(
      collected.json['wire_envelope']! as Map,
    );
    final addressedTo = envelope['recipient_handoff_key_id'];
    if (addressedTo != proposal.handoffKeyId) {
      // Checked before opening, so the failure names the cause. Attempting it
      // anyway would produce a bad AEAD tag, which reads as "this Grant is
      // corrupt" when what happened is that it belongs to another proposal.
      throw AdmissionRefusal(
        code: 'GRANT_ADDRESSED_ELSEWHERE',
        category: 'conflict',
        retryable: false,
        detail: 'the Grant names handoff key $addressedTo, and this proposal '
            'was made with ${proposal.handoffKeyId}',
        status: 409,
      );
    }

    final plaintext = await _platform.openClaimGrant(
      handle: proposal.handoffHandle,
      encapsulatedKey: envelope['encapsulated_key']! as String,
      // The AAD is authenticated, not carried: it is recomputed from the
      // envelope's own members through this app's one canonicaliser, and a
      // Grant whose members say something else simply will not open.
      aad: claimGrantAadCanonicalJson(envelope['aad']),
      ciphertext: envelope['ciphertext']! as String,
    );

    final grant = ClaimGrantV1.fromJson(
      Map<String, dynamic>.from(jsonDecode(utf8.decode(plaintext)) as Map),
    );
    final deviceRef = Map<String, Object?>.from(
      grant.json['device_ref']! as Map,
    );

    final identity = await _platform.getDeviceIdentity();
    if (deviceRef['device_instance_id'] != identity.deviceInstanceId ||
        deviceRef['device_instance_id'] != proposal.deviceInstanceId) {
      throw const FormatException('ClaimGrant names another device');
    }
    if (deviceRef['owner_domain_id'] != proposal.ownerDomainId) {
      throw const FormatException('ClaimGrant names another Owner');
    }
    if (grant.json['grant_id'] != collected.json['grant_id']) {
      throw const FormatException(
          'ClaimGrant does not match the collected grant');
    }
    final stored = await _claims.loadFor(identity.operationalPublicKey);
    if (stored?.ackPending == true) {
      if (stored!.grantId != grant.json['grant_id'] ||
          stored.enrollmentId != proposal.enrollmentId) {
        throw const FormatException('Another grant acknowledgement is pending');
      }
      final state = await resumeAcknowledgement(correlationId: correlationId);
      return MobileBodyClaim(grant: grant, claimState: state!);
    }
    // ACK attests to durable storage, so commit the reference before sending.
    // This checkpoint contains no sealed secret and can resume without the
    // one-shot handoff key if the process dies after the Host accepts ACK.
    await _claims.save(MobileBodyClaimRecord(
      deviceRef: deviceRef,
      grantId: grant.json['grant_id']! as String,
      ownerDomainId: deviceRef['owner_domain_id']! as String,
      deviceInstanceId: proposal.deviceInstanceId,
      acknowledgedAt: _clock().toUtc(),
      enrollmentId: proposal.enrollmentId,
      ackCommandId: ackCommandId,
      ackPending: true,
      ackProof: await _platform.signDeviceCanonicalDocument(claimGrantAckProof(
          enrollmentId: proposal.enrollmentId,
          grantId: grant.json['grant_id']! as String,
          deviceRef: deviceRef)),
    ));
    final state = await resumeAcknowledgement(correlationId: correlationId);
    return MobileBodyClaim(grant: grant, claimState: state!);
  }

  Future<String?> resumeAcknowledgement({required String correlationId}) async {
    final identity = await _platform.getDeviceIdentity();
    final record = await _claims.loadFor(identity.operationalPublicKey);
    if (record == null || !record.ackPending) return null;
    final enrollmentId = record.enrollmentId;
    final commandId = record.ackCommandId;
    if (enrollmentId == null || commandId == null || record.ackProof == null) {
      throw const FormatException('Stored grant acknowledgement is incomplete');
    }
    final answer = await _authority.ackClaimGrant(
      commandId: commandId,
      correlationId: correlationId,
      enrollmentId: enrollmentId,
      grantId: record.grantId,
      operationalKeyProof: record.ackProof!,
      storedClaimGeneration: record.claimGeneration,
      storedTrustEpoch: record.trustEpoch,
    );
    await _claims.save(record.acknowledged(_clock().toUtc()));
    await _platform.discardHandoffKey();
    return answer.json['claim_state']! as String;
  }

  /// Abandon a proposal this phone can no longer finish.
  ///
  /// The way out when the handoff key is gone — the app restarted, or a second
  /// proposal replaced it — because the Grant it would be sealed to can never
  /// be opened by anybody. Without this the enrollment stays approved forever
  /// and the only honest thing a screen could offer is waiting.
  Future<void> abandon({
    required String enrollmentId,
    required String commandId,
    required String correlationId,
    required String reason,
  }) async {
    await _authority.cancelEnrollment(
      commandId: commandId,
      correlationId: correlationId,
      enrollmentId: enrollmentId,
      reason: reason,
    );
    await _platform.discardHandoffKey();
  }
}

class _PreparedProposal {
  const _PreparedProposal(
      {required this.commandId,
      required this.identity,
      required this.handoff,
      required this.evidence,
      required this.proof});
  final String commandId;
  final DeviceIdentity identity;
  final PlatformHandoffKey handoff;
  final Map<String, Object?> evidence;
  final Map<String, Object?> proof;
}

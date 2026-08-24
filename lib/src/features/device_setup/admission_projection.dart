import '../../generated/device_foundation_v1.dart';

enum AdmissionProjectionStage {
  pendingReview,
  approvedAwaitingHandoff,
  grantDelivered,
  claimActive,
  rejected,
  expired,
  canceled,
  claimRevoked,
}

extension EnrollmentRecoveryProjectionAccess on EnrollmentRecoveryProjectionV1 {
  EnrollmentProposalV1 get proposal => EnrollmentProposalV1.fromJson(
        _object(json, 'proposal'),
      );

  ApprovalDecisionV1? get approvalDecision {
    final value = json['approval_decision'];
    return value == null
        ? null
        : ApprovalDecisionV1.fromJson(_object(json, 'approval_decision'));
  }

  GrantDeliveryRecordV1? get grantDelivery {
    final value = json['grant_delivery'];
    return value == null
        ? null
        : GrantDeliveryRecordV1.fromJson(_object(json, 'grant_delivery'));
  }

  ClaimRecordV1? get claim {
    final value = json['claim'];
    return value == null
        ? null
        : ClaimRecordV1.fromJson(_object(json, 'claim'));
  }

  /// The revision of the projection: it advances as facts are added to this
  /// Enrollment — a Decision, a delivered Grant — and is what a reader uses to
  /// tell a fresher read from a staler one.
  int get sourceRevision {
    final value = json['source_revision'];
    if (value is! int || value < 1) {
      throw const FormatException('Invalid Enrollment recovery revision');
    }
    return value;
  }

  /// The revision of the Proposal's own content: what a Decision reviews, and
  /// what it stays pinned to once decided.
  ///
  /// Deliberately not the same number as [sourceRevision], and the difference
  /// is the whole reason both exist. They are equal only until something
  /// happens to the Enrollment; reading one as the other approved a device and
  /// then rejected the Authority's own account of having approved it.
  int get proposalRevision {
    final value = proposal.json['proposal_revision'];
    if (value is! int || value < 1) {
      throw const FormatException('Invalid Enrollment proposal revision');
    }
    return value;
  }

  AdmissionProjectionStage validateForOwner(
    String ownerDomainId, {
    int? ownerDomainGeneration,
  }) {
    final expectedOwner = OwnerDomainIdV1.parse(ownerDomainId).value;
    final proposalValue = proposal;
    if (proposalValue.json['requested_owner_domain_id'] != expectedOwner ||
        sourceRevision < proposalRevision) {
      throw const FormatException(
          'Enrollment recovery Owner/revision mismatch');
    }

    final decision = approvalDecision;
    if (decision != null) {
      if (decision.json['enrollment_id'] !=
              proposalValue.json['enrollment_id'] ||
          decision.json['target_owner_domain_id'] != expectedOwner) {
        throw const FormatException('ApprovalDecision identity mismatch');
      }
      // What was approved must be what is recorded as approved. The Proposal's
      // content revision is pinned to the reviewed one once a Decision exists,
      // so a disagreement here means the Decision on file reviewed something
      // other than what this screen is showing.
      if (decision.json['expected_proposal_revision'] !=
          proposalValue.json['proposal_revision']) {
        throw const FormatException(
            'ApprovalDecision reviewed another revision');
      }
    }

    final delivery = grantDelivery;
    if (delivery != null &&
        decision != null &&
        delivery.json['approval_decision_id'] != decision.json['decision_id']) {
      throw const FormatException('Grant delivery Decision mismatch');
    }

    final claimValue = claim;
    if (claimValue != null) {
      final deviceRef = DeviceRefV1.fromJson(
        _object(claimValue.json, 'device_ref'),
      );
      if (deviceRef.ownerDomainId.value != expectedOwner ||
          (ownerDomainGeneration != null &&
              deviceRef.ownerDomainGeneration != ownerDomainGeneration) ||
          deviceRef.deviceInstanceId !=
              proposalValue.json['device_instance_candidate_id']) {
        throw const FormatException('Claim identity mismatch');
      }
      final claimState = claimValue.json['state'];
      if (claimState == ClaimStateV1.active.wireValue) {
        return AdmissionProjectionStage.claimActive;
      }
      if (claimState == ClaimStateV1.revoked.wireValue) {
        return AdmissionProjectionStage.claimRevoked;
      }
    }

    return switch (proposalValue.json['state']) {
      'pending_review' => AdmissionProjectionStage.pendingReview,
      'approved_awaiting_handoff' =>
        AdmissionProjectionStage.approvedAwaitingHandoff,
      'grant_delivered' ||
      'grant_acknowledged' =>
        AdmissionProjectionStage.grantDelivered,
      'rejected' => AdmissionProjectionStage.rejected,
      'expired' => AdmissionProjectionStage.expired,
      'canceled' => AdmissionProjectionStage.canceled,
      'claim_revoked' => AdmissionProjectionStage.claimRevoked,
      _ => throw const FormatException('Unknown Enrollment recovery state'),
    };
  }
}

extension EnrollmentProposalPageAccess on EnrollmentProposalPageV1 {
  List<EnrollmentRecoveryProjectionV1> get projections {
    final values = json['items'];
    if (values is! List || values.length > 50) {
      throw const FormatException('Invalid Enrollment recovery page');
    }
    return List<EnrollmentRecoveryProjectionV1>.unmodifiable(
      values.map(
        (value) => value is Map
            ? EnrollmentRecoveryProjectionV1.fromJson(
                Map<String, dynamic>.from(value),
              )
            : throw const FormatException(
                'Invalid Enrollment recovery projection',
              ),
      ),
    );
  }

  AdmissionListCursorV1? get nextCursor {
    final value = json['next_cursor'];
    return value == null
        ? null
        : AdmissionListCursorV1.fromJson(
            Map<String, dynamic>.from(value as Map),
          );
  }
}

extension ClaimPageAccess on ClaimPageV1 {
  List<ClaimRecordV1> get claims {
    final values = json['items'];
    if (values is! List || values.length > 50) {
      throw const FormatException('Invalid Claim page');
    }
    return List<ClaimRecordV1>.unmodifiable(
      values.map(
        (value) => value is Map
            ? ClaimRecordV1.fromJson(Map<String, dynamic>.from(value))
            : throw const FormatException('Invalid Claim record'),
      ),
    );
  }
}

Map<String, dynamic> _object(Map<String, dynamic> value, String key) {
  final result = value[key];
  if (result is! Map) {
    throw FormatException('Invalid canonical Admission $key');
  }
  return Map<String, dynamic>.from(result);
}

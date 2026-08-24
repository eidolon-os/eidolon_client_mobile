import 'dart:convert';
import 'dart:io';

import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';

Map<String, dynamic> canonicalAdmissionValue(String caseId) {
  for (final path in const [
    'test/fixtures/device_foundation/admission.json',
    'test/fixtures/device_foundation/admission-consumer-surface.json',
  ]) {
    final document = jsonDecode(File(path).readAsStringSync());
    for (final item in document['cases'] as List<dynamic>) {
      final entry = Map<String, dynamic>.from(item as Map);
      if (entry['case_id'] == caseId) {
        return Map<String, dynamic>.from(entry['value'] as Map);
      }
    }
  }
  throw StateError('Missing canonical SDK fixture $caseId');
}

Map<String, dynamic> canonicalAdmissionGolden() => Map<String, dynamic>.from(
      jsonDecode(
        File('test/fixtures/device_foundation/admission-event-stream.json')
            .readAsStringSync(),
      ) as Map,
    );

Map<String, dynamic> canonicalProposal({
  String state = 'pending_review',
  String ownerDomainId = 'owner-domain_01',
  String deviceId = 'device_01',
  int revision = 2,
}) {
  final value = canonicalAdmissionValue('DF-ADMISSION-PROPOSAL-VALID');
  return {
    ...value,
    'state': state,
    'requested_owner_domain_id': ownerDomainId,
    'device_instance_candidate_id': deviceId,
    'proposal_revision': revision,
  };
}

Map<String, dynamic> canonicalDecision({
  String ownerDomainId = 'owner-domain_01',
  int revision = 2,
}) {
  final value = canonicalAdmissionValue('DF-ADMISSION-DECISION-RECORD-VALID');
  final actor = Map<String, dynamic>.from(value['actor'] as Map);
  return {
    ...value,
    'target_owner_domain_id': ownerDomainId,
    'expected_proposal_revision': revision,
    'actor': {...actor, 'owner_domain_id': ownerDomainId},
  };
}

EnrollmentRecoveryProjectionV1 canonicalProjection({
  String state = 'pending_review',
  String ownerDomainId = 'owner-domain_01',
  String deviceId = 'device_01',
  int revision = 2,
  bool withDecision = false,
  bool withDelivery = false,
  String? claimState,
  int claimOwnerDomainGeneration = 3,
}) {
  final projection = canonicalAdmissionValue(
    'DF-PH2B0-RECOVERY-PROJECTION-VALID',
  );
  projection['proposal'] = canonicalProposal(
    state: state,
    ownerDomainId: ownerDomainId,
    deviceId: deviceId,
    revision: revision,
  );
  projection['source_revision'] = revision;
  projection['approval_decision'] = withDecision
      ? canonicalDecision(ownerDomainId: ownerDomainId, revision: revision)
      : null;
  projection['grant_delivery'] = withDelivery
      ? canonicalAdmissionValue('DF-PH2B0-GRANT-DELIVERY-VALID')
      : null;
  if (claimState == null) {
    projection['claim'] = null;
  } else {
    final claim = canonicalAdmissionValue('DF-ADMISSION-CLAIM-RECORD-VALID');
    final ref = Map<String, dynamic>.from(claim['device_ref'] as Map);
    projection['claim'] = {
      ...claim,
      'state': claimState,
      'device_ref': {
        ...ref,
        'device_instance_id': deviceId,
        'owner_domain_id': ownerDomainId,
        'owner_domain_generation': claimOwnerDomainGeneration,
      },
    };
  }
  return EnrollmentRecoveryProjectionV1.fromJson(projection);
}

EnrollmentProposalPageV1 canonicalRecoveryPage(
  List<EnrollmentRecoveryProjectionV1> projections, {
  String ownerDomainId = 'owner-domain_01',
  AdmissionListCursorV1? nextCursor,
}) {
  final value = canonicalAdmissionValue('DF-PH2B0-PROPOSAL-PAGE-VALID');
  return EnrollmentProposalPageV1.fromJson({
    ...value,
    'owner_domain_id': ownerDomainId,
    'items': projections.map((item) => item.toJson()).toList(growable: false),
    'next_cursor': nextCursor?.toJson(),
  });
}

AdmissionListCursorV1 canonicalAdmissionCursor({
  String ownerDomainId = 'owner-domain_01',
}) {
  final value = canonicalAdmissionValue('DF-PH2B0-ADMISSION-CURSOR-VALID');
  return AdmissionListCursorV1.fromJson({
    ...value,
    'owner_domain_id': ownerDomainId,
  });
}

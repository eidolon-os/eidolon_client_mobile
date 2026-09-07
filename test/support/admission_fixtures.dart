import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';

/// One canonical example case from the SDK's own vectors, by id.
///
/// Reads every vendored example file rather than a caller-chosen one, so a case
/// that moves between them — as the Manifest documents did when they gained a
/// schema — does not silently stop being found.
///
/// Throws when the id matches nothing, and that is the point. A fixture that
/// answers "nothing" for an id nobody typed correctly leaves the producer with
/// no check at all while the test stays green, which is how an inlined copy
/// drifts from the vector it was supposed to be held to.
Map<String, dynamic> canonicalContractValue(String caseId) {
  for (final path in const [
    'test/fixtures/device_foundation/admission.json',
    'test/fixtures/device_foundation/admission-consumer-surface.json',
    'test/fixtures/device_foundation/common.valid.json',
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
  String? deviceId,
  int revision = 2,
}) {
  final value = canonicalContractValue('DF-ADMISSION-PROPOSAL-VALID');
  return {
    ...value,
    'state': state,
    'requested_owner_domain_id': ownerDomainId,
    'device_instance_candidate_id': deviceId ?? namedDeviceInstanceId('device-01'),
    'proposal_revision': revision,
  };
}

Map<String, dynamic> canonicalDecision({
  String ownerDomainId = 'owner-domain_01',
  int revision = 2,
}) {
  final value = canonicalContractValue('DF-ADMISSION-DECISION-RECORD-VALID');
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
  String? deviceId,
  int revision = 2,

  /// The projection's own revision, which advances past the Proposal's content
  /// revision as facts are added. Defaults to equal, which is only true before
  /// anything has happened to the Enrollment.
  int? sourceRevision,
  bool withDecision = false,
  bool withDelivery = false,
  String? claimState,
  int claimOwnerDomainGeneration = 3,
}) {
  final projection = canonicalContractValue(
    'DF-PH2B0-RECOVERY-PROJECTION-VALID',
  );
  projection['proposal'] = canonicalProposal(
    state: state,
    ownerDomainId: ownerDomainId,
    deviceId: deviceId,
    revision: revision,
  );
  projection['source_revision'] = sourceRevision ?? revision;
  projection['approval_decision'] = withDecision
      ? canonicalDecision(ownerDomainId: ownerDomainId, revision: revision)
      : null;
  projection['grant_delivery'] = withDelivery
      ? canonicalContractValue('DF-PH2B0-GRANT-DELIVERY-VALID')
      : null;
  if (claimState == null) {
    projection['claim'] = null;
  } else {
    final claim = canonicalContractValue('DF-ADMISSION-CLAIM-RECORD-VALID');
    final ref = Map<String, dynamic>.from(claim['device_ref'] as Map);
    projection['claim'] = {
      ...claim,
      'state': claimState,
      'device_ref': {
        ...ref,
        'device_instance_id': deviceId ?? namedDeviceInstanceId('device-01'),
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
  final value = canonicalContractValue('DF-PH2B0-PROPOSAL-PAGE-VALID');
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
  final value = canonicalContractValue('DF-PH2B0-ADMISSION-CURSOR-VALID');
  return AdmissionListCursorV1.fromJson({
    ...value,
    'owner_domain_id': ownerDomainId,
  });
}

/// Rewrites one field of an otherwise canonical projection, so a test can pin
/// what happens when the Authority's two revisions disagree.
extension EnrollmentRecoveryProjectionV1Mutation
    on EnrollmentRecoveryProjectionV1 {
  static EnrollmentRecoveryProjectionV1 withDecisionRevision(
    EnrollmentRecoveryProjectionV1 projection,
    int expectedProposalRevision,
  ) {
    final document = Map<String, dynamic>.from(projection.toJson());
    final decision = Map<String, dynamic>.from(
      document['approval_decision']! as Map,
    );
    decision['expected_proposal_revision'] = expectedProposalRevision;
    document['approval_decision'] = decision;
    return EnrollmentRecoveryProjectionV1.fromJson(document);
  }
}

/// A valid device instance id for the device a test calls [label].
///
/// A device instance id is the digest of that device's operational key, so the
/// names these fixtures used — `device_01`, `mobile-android-test`, and in one
/// case a MAC address — described devices that cannot exist. Tests still want
/// to say which device they mean, so the name becomes a real id here, by the
/// same rule Hub applies: SHA-256 over the bytes the name stands for.
String namedDeviceInstanceId(String label) {
  final digest = sha256.convert(utf8.encode(label));
  return DeviceInstanceIdV1.parse('device-instance-${digest.toString()}').value;
}

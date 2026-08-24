import 'package:eidolon_client_mobile/src/features/device_setup/admission_projection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';

/// An Enrollment carries two revisions and they are not the same fact.
///
/// `proposal_revision` is the content a Decision reviews, pinned to the
/// reviewed value once one exists. `source_revision` is the projection's own,
/// and it advances the moment anything happens — a Decision, a delivered Grant.
/// They are equal only until something does, which is why reading one as the
/// other survived every test and then, on a real Host, approved a device and
/// rejected the Authority's own account of having approved it.
void main() {
  test('a projection that advanced past its Proposal is not a mismatch', () {
    final projection = canonicalProjection(
      state: 'grant_delivered',
      revision: 1,
      sourceRevision: 3,
      withDecision: true,
      withDelivery: true,
    );

    expect(projection.proposalRevision, 1);
    expect(projection.sourceRevision, 3);
    expect(
      projection.validateForOwner('owner-domain_01', ownerDomainGeneration: 3),
      AdmissionProjectionStage.grantDelivered,
    );
  });

  test('a projection older than the Proposal it carries is refused', () {
    final projection = canonicalProjection(revision: 3, sourceRevision: 1);
    expect(
      () => projection.validateForOwner('owner-domain_01'),
      throwsFormatException,
    );
  });

  test('a Decision that reviewed another revision is refused', () {
    // What was approved must be what is recorded as approved. The Proposal's
    // content revision is pinned once a Decision exists, so a disagreement
    // means the Decision on file reviewed something else.
    final projection = canonicalProjection(
      state: 'approved_awaiting_handoff',
      revision: 2,
      sourceRevision: 4,
      withDecision: true,
    );
    final decided = EnrollmentRecoveryProjectionV1Mutation.withDecisionRevision(
      projection,
      7,
    );
    expect(
      () => decided.validateForOwner('owner-domain_01'),
      throwsFormatException,
    );
  });

  test('an undecided Proposal is pending review at any projection revision',
      () {
    final projection = canonicalProjection(revision: 1, sourceRevision: 5);
    expect(
      projection.validateForOwner('owner-domain_01'),
      AdmissionProjectionStage.pendingReview,
    );
  });
}

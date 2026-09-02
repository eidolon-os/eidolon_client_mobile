import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

void main() {
  test('network/pending review never implies approval or active Channel',
      () async {
    final admission = _Admission([
      _projection(state: 'pending_review', deviceId: phoneDeviceInstanceId),
    ]);
    final config = await _provisioner(admission).provision();

    expect(config.status, HubConfigStatus.pendingApproval);
    expect(config.bodyStanding, MobileBodyStanding.pendingReview);
    expect(config.session.usable, isFalse);
    expect(admission.decisions, 0);
  });

  test('this phone finds its own record by the id derived from its own key',
      () async {
    // The comparison used to be against an ANDROID_ID-derived
    // `mobile-android-<hash>`, while the field it was compared to is one Hub
    // only ever writes as `device-instance-<sha256(spki)>`. It was false by
    // construction, so this phone could not have recognised its own record
    // even once one existed.
    final admission = _Admission([
      _projection(state: 'pending_review', deviceId: phoneDeviceInstanceId),
    ]);

    final config = await _provisioner(admission).provision();

    expect(config.bodyStanding, MobileBodyStanding.pendingReview);
  });

  test('a record under this phone\'s old invented id is not this phone',
      () async {
    final admission = _Admission([
      _projection(
        state: 'pending_review',
        deviceId: namedDeviceInstanceId(phoneInstallId),
      ),
    ]);

    final config = await _provisioner(admission).provision();

    expect(config.bodyStanding, MobileBodyStanding.notEnrolled);
  });

  test('the three stages after approval are three answers, not one', () async {
    // They were folded into one `waitingBinding` that said 「正在关联 Companion」.
    // Two of them are a few seconds of work this phone is doing; the third is
    // where this version stops. Saying all three the same way used progress to
    // cover an unimplemented edge.
    final cases = <MobileBodyStanding, EnrollmentRecoveryProjectionV1>{
      MobileBodyStanding.approvedAwaitingHandoff: _projection(
        state: 'approved_awaiting_handoff',
        deviceId: phoneDeviceInstanceId,
        withDecision: true,
      ),
      MobileBodyStanding.grantDelivered: _projection(
        state: 'grant_delivered',
        deviceId: phoneDeviceInstanceId,
        withDecision: true,
        withDelivery: true,
      ),
      MobileBodyStanding.claimActiveWithoutChannel: _projection(
        state: 'grant_acknowledged',
        deviceId: phoneDeviceInstanceId,
        withDecision: true,
        withDelivery: true,
        claimState: 'active',
      ),
    };

    for (final entry in cases.entries) {
      final config =
          await _provisioner(_Admission([entry.value])).provision();
      expect(config.status, HubConfigStatus.waitingBinding);
      expect(config.bodyStanding, entry.key);
      expect(config.session.usable, isFalse);
    }
  });

  test('no Enrollment is not a claim in progress', () async {
    // The whole bug in one assertion. An empty recovery list used to be
    // reported as `pendingApproval`, which the screen rendered as 「主机正在认领
    // Mobile / 认领请求会自动向前推进」 — a claim no party was making, could
    // make, or would ever make, since only a device may propose itself and this
    // app cannot yet do it.
    final config = await _provisioner(_Admission(const [])).provision();

    expect(config.bodyStanding, MobileBodyStanding.notEnrolled);
    expect(config.status, isNot(HubConfigStatus.pendingApproval));
    expect(config.bodyStanding!.advances, isFalse);
  });

  test('a revoked Claim and an ended Enrollment are told apart', () async {
    final revoked = await _provisioner(
      _Admission([
        _projection(
          state: 'grant_acknowledged',
          deviceId: phoneDeviceInstanceId,
          withDecision: true,
          withDelivery: true,
          claimState: 'revoked',
        ),
      ]),
    ).provision();
    expect(revoked.bodyStanding, MobileBodyStanding.claimRevoked);
    expect(revoked.status, HubConfigStatus.revoked);

    final ended = await _provisioner(
      _Admission([
        _projection(state: 'rejected', deviceId: phoneDeviceInstanceId),
      ]),
    ).provision();
    expect(ended.bodyStanding, MobileBodyStanding.admissionEnded);
  });

  test('Owner Domain mismatch is rejected instead of cross-domain adoption',
      () async {
    final admission = _Admission([
      _projection(
        ownerDomainId: 'owner-domain_other',
        deviceId: phoneDeviceInstanceId,
      ),
    ]);
    await expectLater(
      _provisioner(admission).provision(),
      throwsA(isA<FormatException>()),
    );
  });

  test(
      'another device this Owner holds cannot take down this phone\'s conversation',
      () async {
    // The list is the whole Owner Domain. Validating every record on the way
    // past made this phone's conversation depend on the health of every other
    // device: one unrelated projection the phone disagreed with threw
    // FormatException out of provision() and the flow died, over a record that
    // was never this device's business.
    final admission = _Admission([
      _projection(
        state: 'pending_review',
        deviceId: namedDeviceInstanceId('someone-else'),
        ownerDomainId: 'owner-domain_99',
      ),
      _projection(state: 'pending_review', deviceId: phoneDeviceInstanceId),
    ]);

    final config = await _provisioner(admission).provision();

    expect(config.status, HubConfigStatus.pendingApproval);
  });

  test('a record that is ours but belongs to another Owner is still refused',
      () async {
    // Skipping other devices must not skip the check that matters: the record
    // this phone accepts has to be this Owner's.
    final admission = _Admission([
      _projection(
        state: 'pending_review',
        deviceId: phoneDeviceInstanceId,
        ownerDomainId: 'owner-domain_99',
      ),
    ]);

    expect(
      () => _provisioner(admission).provision(),
      throwsA(isA<FormatException>()),
    );
  });
}

MobileConversationProvisioner _provisioner(DeviceAdmissionPort admission) =>
    MobileConversationProvisioner(
      loadTarget: () async => deviceOnboardingTargetFixture(),
      admission: admission,
      platform: FakePhonePlatform(),
    );

EnrollmentRecoveryProjectionV1 _projection({
  String state = 'pending_review',
  String ownerDomainId = ownerDomainIdFixture,
  String? deviceId,
  bool withDecision = false,
  bool withDelivery = false,
  String? claimState,
}) =>
    canonicalProjection(
      state: state,
      ownerDomainId: ownerDomainId,
      deviceId: deviceId,
      withDecision: withDecision,
      withDelivery: withDelivery,
      claimState: claimState,
      claimOwnerDomainGeneration: 1,
    );

class _Admission implements DeviceAdmissionPort {
  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
  }) async {
    voucherRequests.add(operationalSpkiSha256);
    return CommissioningVoucher(
      voucher: 'header.payload.signature',
      jti: 'jti-${voucherRequests.length}',
      deviceBaseId: 'device-base-${'a' * 64}',
      expiresAt: DateTime.utc(2027),
    );
  }

  final List<String> voucherRequests = [];

  _Admission(this.items);

  final List<EnrollmentRecoveryProjectionV1> items;
  int decisions = 0;

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) async =>
      canonicalRecoveryPage(items);

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) async =>
      items.single;

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) async {
    decisions += 1;
    return projection;
  }
}

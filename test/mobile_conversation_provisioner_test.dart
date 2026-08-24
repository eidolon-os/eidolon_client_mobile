import 'package:eidolon_client_mobile/src/features/conversation/mobile_conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';

void main() {
  test('network/pending review never implies approval or active Channel',
      () async {
    final admission = _Admission([
      _projection(
        state: 'pending_review',
        deviceId: 'mobile-android-test',
      ),
    ]);
    final config = await _provisioner(admission).provision();

    expect(config.status, HubConfigStatus.pendingApproval);
    expect(config.session.usable, isFalse);
    expect(admission.decisions, 0);
  });

  test('approved, GrantDelivered and ClaimActive remain honestly visible',
      () async {
    final cases = <EnrollmentRecoveryProjectionV1>[
      _projection(
        state: 'approved_awaiting_handoff',
        deviceId: 'mobile-android-test',
        withDecision: true,
      ),
      _projection(
        state: 'grant_delivered',
        deviceId: 'mobile-android-test',
        withDecision: true,
        withDelivery: true,
      ),
      _projection(
        state: 'grant_acknowledged',
        deviceId: 'mobile-android-test',
        withDecision: true,
        withDelivery: true,
        claimState: 'active',
      ),
    ];

    for (final projection in cases) {
      final config = await _provisioner(_Admission([projection])).provision();
      expect(config.status, HubConfigStatus.waitingBinding);
      expect(config.session.usable, isFalse);
    }
  });

  test('empty recovery does not mean ClaimActive', () async {
    final config = await _provisioner(_Admission(const [])).provision();
    expect(config.status, HubConfigStatus.pendingApproval);
  });

  test('Owner Domain mismatch is rejected instead of cross-domain adoption',
      () async {
    final admission = _Admission([
      _projection(
        ownerDomainId: 'owner-domain_other',
        deviceId: 'mobile-android-test',
      ),
    ]);
    await expectLater(
      _provisioner(admission).provision(),
      throwsA(isA<FormatException>()),
    );
  });
}

MobileConversationProvisioner _provisioner(DeviceAdmissionPort admission) =>
    MobileConversationProvisioner(
      loadTarget: () async => deviceOnboardingTargetFixture(),
      admission: admission,
      platform: _Platform(),
    );

EnrollmentRecoveryProjectionV1 _projection({
  String state = 'pending_review',
  String ownerDomainId = ownerDomainIdFixture,
  String deviceId = 'device_01',
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

class _Platform extends PlatformBridge {
  @override
  Future<DeviceIdentity> getDeviceIdentity() async => const DeviceIdentity(
        deviceId: 'mobile-android-test',
        fingerprint: 'p256:mobile-test',
      );
}

class _Admission implements DeviceAdmissionPort {
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
    required String commandId,
    required String correlationId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) async {
    decisions += 1;
    return projection;
  }
}

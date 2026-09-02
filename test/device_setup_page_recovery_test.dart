import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';

void main() {
  testWidgets('page startup and foreground recover before declaring completion',
      (tester) async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint());
    final admission = _Admission(
      _projection(state: 'approved_awaiting_handoff', withDecision: true),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceSetupPage(
          transport: _Transport(),
          admission: admission,
          checkpoints: store,
          loadTarget: () async => deviceOnboardingTargetFixture(),
        ),
      ),
    );
    await _pumpUntil(tester, () => admission.recoverCalls == 1);

    expect(admission.recoverCalls, 1);
    expect(find.textContaining('尚未 ClaimActive'), findsOneWidget);
    expect(find.text('设备已设置完成'), findsNothing);

    admission.current = _projection(
      state: 'grant_acknowledged',
      withDecision: true,
      withDelivery: true,
      claimState: 'active',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpUntil(tester, () => admission.recoverCalls == 2);

    expect(admission.recoverCalls, 2);
    expect(find.text('设备已设置完成'), findsOneWidget);
    expect(admission.decideCalls, 0);
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 20 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.pump();
}

DeviceSetupCheckpoint _checkpoint() => DeviceSetupCheckpoint(
      contractVersion: DeviceSetupCheckpoint.currentContractVersion,
      setupId: 'setup-page-recovery',
      requestId: 'intent-page-recovery',
      createCommandId: 'mobile-create-setup-page-recovery',
      decisionRequestId: 'mobile-decision-setup-page-recovery',
      collectCommandId: 'mobile-collect-setup-page-recovery',
      ackCommandId: 'mobile-ack-setup-page-recovery',
      provisioningState: DeviceProvisioningState.networkConfigured,
      admissionState: DeviceAdmissionState.approvedAwaitingHandoff,
      updatedAt: DateTime.utc(2026, 8, 18),
      onboardingTarget: deviceOnboardingTargetFixture(),
      deviceId: namedDeviceInstanceId('device_01'),
      enrollmentId: 'enrollment_01',
      expectedProposalRevision: 2,
    );

EnrollmentRecoveryProjectionV1 _projection({
  required String state,
  bool withDecision = false,
  bool withDelivery = false,
  String? claimState,
}) =>
    canonicalProjection(
      state: state,
      ownerDomainId: ownerDomainIdFixture,
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

  _Admission(this.current);

  EnrollmentRecoveryProjectionV1 current;
  int recoverCalls = 0;
  int decideCalls = 0;

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) async =>
      canonicalRecoveryPage([current], ownerDomainId: ownerDomainIdFixture);

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) async {
    recoverCalls += 1;
    return current;
  }

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) async {
    decideCalls += 1;
    return current;
  }
}

class _Transport implements DeviceProvisioningTransport {
  @override
  Future<void> close() async {}

  @override
  Future<List<DeviceProvisioningCandidate>> discover() async => const [];

  @override
  Future<DeviceProvisioningSession> open(
    DeviceProvisioningCandidate candidate,
  ) =>
      throw UnimplementedError();

  @override
  Future<bool> requestPermission() async => true;
}

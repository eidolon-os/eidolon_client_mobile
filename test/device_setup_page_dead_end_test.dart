import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/host_controller_device_admission.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';

/// A setup the Host has finished refusing must not hold the entrance shut.
///
/// This is the shape a real device produced: the Owner removed the device, the
/// Claim was revoked, and the checkpoint became `rejected`. Because the resume
/// scan adopts every non-ready checkpoint for this Owner Domain, that one
/// refused setup made "配置新设备网络" unusable forever — restarting the app
/// re-adopted it, and the screen it drew offered only "从主机恢复状态", which
/// can never move a terminal Enrollment.
void main() {
  _adapterGrading();
  testWidgets('a refused setup offers a way out instead of only a retry',
      (tester) async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint());
    final admission = _Admission(_projection('rejected'));

    await tester.pumpWidget(_page(store, admission));
    await _pumpUntil(tester, () => admission.recoverCalls == 1);

    expect(find.text('这次接入进行不下去了'), findsOneWidget);
    expect(find.byKey(const Key('restart-device-setup')), findsOneWidget);
    expect(find.byKey(const Key('resume-device-admission')), findsNothing);
  });

  testWidgets('starting over forgets the refused setup and frees the entrance',
      (tester) async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint());
    final admission = _Admission(_projection('rejected'));

    await tester.pumpWidget(_page(store, admission));
    await _pumpUntil(tester, () => admission.recoverCalls == 1);

    await tester.tap(find.byKey(const Key('restart-device-setup')));
    await tester.pumpAndSettle();

    expect(find.text('准备设备'), findsOneWidget);
    expect(await store.list(), isEmpty);

    // Coming back from the background must not drag the person into the
    // checkpoint they just dismissed.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('准备设备'), findsOneWidget);
    expect(admission.recoverCalls, 1);
  });

  testWidgets('a setup still in flight keeps its retry and its way out',
      (tester) async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint());
    final admission = _Admission(
      _projection('approved_awaiting_handoff', withDecision: true),
    );

    await tester.pumpWidget(_page(store, admission));
    await _pumpUntil(tester, () => admission.recoverCalls == 1);

    expect(find.byKey(const Key('resume-device-admission')), findsOneWidget);
    expect(find.byKey(const Key('restart-device-setup')), findsOneWidget);
  });

  testWidgets('a device that never created an Enrollment is not a dead end',
      (tester) async {
    // The shape a reflashed board produces: network committed, no Enrollment,
    // and a failure the coordinator grades retryable. Retrying is the right
    // default — the device usually just has not got there yet — but this one
    // never will, so the entrance has to stay openable.
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint(enrollmentId: null));
    final admission = _GoneAdmission();

    await tester.pumpWidget(_page(store, admission));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('restart-device-setup')).evaluate().isNotEmpty,
    );

    expect(admission.recoverCalls, 0, reason: 'no Enrollment id to recover');
    expect(find.textContaining('Device has not created an Enrollment yet'),
        findsOneWidget);
    expect(find.byKey(const Key('resume-device-admission')), findsOneWidget);
    expect(find.byKey(const Key('restart-device-setup')), findsOneWidget);

    await tester.tap(find.byKey(const Key('restart-device-setup')));
    await tester.pumpAndSettle();

    expect(find.text('准备设备'), findsOneWidget);
    expect(await store.list(), isEmpty);
  });

  testWidgets('a Host that no longer has this Enrollment is a dead end too',
      (tester) async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint());
    final admission = _GoneAdmission();

    await tester.pumpWidget(_page(store, admission));
    await _pumpUntil(tester, () => admission.recoverCalls == 1);

    // The Host's own sentence, and no retry above it.
    expect(find.text('这次接入进行不下去了'), findsOneWidget);
    expect(find.byKey(const Key('restart-device-setup')), findsOneWidget);
    expect(find.byKey(const Key('resume-device-admission')), findsNothing);
    expect(find.textContaining('主机上已经没有这台设备了'), findsOneWidget);
    expect(find.textContaining('可安全重试'), findsNothing);
  });
}

Widget _page(
  DeviceSetupCheckpointStore store,
  DeviceAdmissionPort admission,
) =>
    MaterialApp(
      home: DeviceSetupPage(
        transport: _Transport(),
        admission: admission,
        checkpoints: store,
        loadTarget: () async => deviceOnboardingTargetFixture(),
      ),
    );

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 20 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.pump();
}

DeviceSetupCheckpoint _checkpoint({
  String? enrollmentId = 'enrollment_01',
}) =>
    DeviceSetupCheckpoint(
      contractVersion: DeviceSetupCheckpoint.currentContractVersion,
      setupId: 'setup-dead-end',
      requestId: 'intent-dead-end',
      createCommandId: 'mobile-create-setup-dead-end',
      decisionRequestId: 'mobile-decision-setup-dead-end',
      collectCommandId: 'mobile-collect-setup-dead-end',
      ackCommandId: 'mobile-ack-setup-dead-end',
      provisioningState: DeviceProvisioningState.networkConfigured,
      admissionState: DeviceAdmissionState.pendingReview,
      updatedAt: DateTime.utc(2026, 8, 27),
      onboardingTarget: deviceOnboardingTargetFixture(),
      deviceId: namedDeviceInstanceId('device_01'),
      enrollmentId: enrollmentId,
      expectedProposalRevision: 2,
    );

EnrollmentRecoveryProjectionV1 _projection(
  String state, {
  bool withDecision = false,
}) =>
    canonicalProjection(
      state: state,
      ownerDomainId: ownerDomainIdFixture,
      withDecision: withDecision,
    );

class _Admission implements DeviceAdmissionPort {
  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
    String? presentedDeviceBaseId,
  }) async {
    voucherRequests.add(
      (
        operationalSpkiSha256: operationalSpkiSha256,
        presentedDeviceBaseId: presentedDeviceBaseId,
      ),
    );
    return CommissioningVoucher(
      voucher: 'header.payload.signature',
      jti: 'jti-${voucherRequests.length}',
      deviceBaseId: presentedDeviceBaseId ?? 'device-base-${'a' * 64}',
      expiresAt: DateTime.utc(2027),
    );
  }

  final List<({String operationalSpkiSha256, String? presentedDeviceBaseId})>
      voucherRequests = [];

  _Admission(this.current);

  EnrollmentRecoveryProjectionV1 current;
  int recoverCalls = 0;

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
  }) async =>
      current;
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


/// A Host that answers 404 for this Enrollment, as one does after a reinstall.
class _GoneAdmission implements DeviceAdmissionPort {
  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
    String? presentedDeviceBaseId,
  }) async {
    voucherRequests.add(
      (
        operationalSpkiSha256: operationalSpkiSha256,
        presentedDeviceBaseId: presentedDeviceBaseId,
      ),
    );
    return CommissioningVoucher(
      voucher: 'header.payload.signature',
      jti: 'jti-${voucherRequests.length}',
      deviceBaseId: presentedDeviceBaseId ?? 'device-base-${'a' * 64}',
      expiresAt: DateTime.utc(2027),
    );
  }

  final List<({String operationalSpkiSha256, String? presentedDeviceBaseId})>
      voucherRequests = [];

  int recoverCalls = 0;

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) async =>
      canonicalRecoveryPage(const [], ownerDomainId: ownerDomainIdFixture);

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) async {
    recoverCalls += 1;
    throw enrollmentRecoveryRefusal(
      const LocalApiRequestException(
        'Enrollment recovery 返回 HTTP 404',
        statusCode: 404,
        reason: '主机上已经没有这台设备了。',
      ),
    )!;
  }

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) =>
      throw UnimplementedError();
}


void _adapterGrading() {
  test('only a 404 is graded terminal', () {
    final gone = enrollmentRecoveryRefusal(
      const LocalApiRequestException('x', statusCode: 404, reason: 'y'),
    );
    expect(gone, isNotNull);
    expect(gone!.code, 'enrollment_gone');
    expect(gone.retryable, isFalse);
    expect(
      enrollmentRecoveryRefusal(
        const LocalApiRequestException('x', statusCode: 503),
      ),
      isNull,
    );
    expect(
      enrollmentRecoveryRefusal(const LocalApiRequestException('x')),
      isNull,
    );
  });
}

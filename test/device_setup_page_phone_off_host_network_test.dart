import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';

/// After the device has taken its Wi-Fi, the phone has to be back on the
/// Host's network for the setup to be seen through.
///
/// Measured on a tablet that never went back (Android 10, 2026-11-15): the
/// device was online and admitted, and the screen showed 「3. 接入主机 · 进行中」
/// and a spinner for as long as anyone watched. Each read spent five seconds
/// looking for the Host and was drawn as a command — spinner, every button
/// gone — so even the one sentence it had flashed for three seconds in eight.
void main() {
  /// How long one read spends looking for a Host that is not there.
  const search = Duration(seconds: 5);

  testWidgets('says the phone is off the Host network and carries on by itself',
      (tester) async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint());
    final admission = _Admission()..offline = true;
    final transport = _Transport();
    await tester.pumpWidget(_page(store, admission, transport));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续接入'));
    await tester.pump();
    await tester.pump(search);
    await tester.pump();

    expect(find.byKey(const Key('phone-off-host-network')), findsOneWidget);
    expect(find.text('3. 接入主机 · 等手机回到主机网络'), findsOneWidget);
    expect(find.textContaining('还没有连回主机所在的 Wi-Fi'), findsOneWidget);
    expect(find.text('设备这边不用再操作。'), findsOneWidget);
    // Not an error, and no retry to offer: the next read is already coming.
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.byKey(const Key('resume-device-admission')), findsNothing);
    expect(find.byKey(const Key('restart-device-setup')), findsOneWidget);
    expect(admission.recoverCalls, 1);

    // The next read starts on its own and is as slow; while it runs the
    // screen keeps its sentence and its way out.
    await tester.pump(const Duration(seconds: 4));
    expect(admission.recoverCalls, 2);
    expect(find.byKey(const Key('phone-off-host-network')), findsOneWidget);
    expect(find.byKey(const Key('restart-device-setup')), findsOneWidget);
    expect(find.text('正在从主机恢复设备接入状态'), findsNothing);

    await tester.tap(find.byKey(const Key('open-wifi-settings')));
    await tester.pump();
    expect(transport.wifiSettingsOpened, 1);

    // The phone is back: the screen goes on without being asked.
    admission.offline = false;
    await tester.pumpAndSettle();
    expect(find.text('设备已接入这台主机'), findsOneWidget);
    expect(find.byKey(const Key('phone-off-host-network')), findsNothing);
  });

  testWidgets(
      'a Host that answered is still the Host\'s failure, not the phone',
      (tester) async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint());
    final admission = _Admission()
      ..failure = const LocalApiRequestException('busy', statusCode: 503);
    await tester.pumpWidget(_page(store, admission, _Transport()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续接入'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('phone-off-host-network')), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byKey(const Key('resume-device-admission')), findsOneWidget);
    expect(find.text('3. 接入主机 · 进行中'), findsOneWidget);
  });

  testWidgets('starting over during a read forgets the setup for good',
      (tester) async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint());
    final admission = _Admission()..offline = true;
    await tester.pumpWidget(_page(store, admission, _Transport()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续接入'));
    await tester.pump();
    await tester.pump(search);
    await tester.pump(const Duration(seconds: 4));
    expect(admission.recoverCalls, 2, reason: 'a read is under way');

    await tester.tap(find.byKey(const Key('restart-device-setup')));
    await tester.pumpAndSettle();

    // The read that was under way finished after the tap; it must not have
    // written the attempt back, nor drawn it again.
    expect(find.text('准备设备'), findsOneWidget);
    expect(await store.list(), isEmpty);
  });
}

Widget _page(
  DeviceSetupCheckpointStore store,
  DeviceAdmissionPort admission,
  _Transport transport,
) =>
    MaterialApp(
      home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: store,
        loadTarget: () async => deviceOnboardingTargetFixture(),
      ),
    );

DeviceSetupCheckpoint _checkpoint() => DeviceSetupCheckpoint(
      commissioningProofDigest:
          'sha256:256d04db4e5e4ac308751ed0885b722b758630567c53a7125ed9fbd068e5c3f6',
      contractVersion: DeviceSetupCheckpoint.currentContractVersion,
      setupId: 'setup-off-network',
      requestId: 'intent-off-network',
      createCommandId: 'mobile-create-setup-off-network',
      decisionRequestId: 'mobile-decision-setup-off-network',
      collectCommandId: 'mobile-collect-setup-off-network',
      ackCommandId: 'mobile-ack-setup-off-network',
      provisioningState: DeviceProvisioningState.networkConfigured,
      admissionState: DeviceAdmissionState.pendingReview,
      updatedAt: DateTime.utc(2026, 11, 15),
      onboardingTarget: deviceOnboardingTargetFixture(),
      deviceId: namedDeviceInstanceId('device_01'),
      enrollmentId: 'enrollment_01',
      expectedProposalRevision: 2,
    );

/// A Host the phone can reach or not. Unreachable, a read fails the way the
/// pinned transport does after looking for the Host for [_search]; reachable,
/// the device is already admitted.
class _Admission implements DeviceAdmissionPort {
  bool offline = false;
  Object? failure;
  int recoverCalls = 0;

  static const _search = Duration(seconds: 5);

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) async {
    recoverCalls += 1;
    if (offline) {
      await Future<void>.delayed(_search);
      throw PinnedHttpException(
        kind: PinnedHttpFailureKind.unreachable,
        message: 'Failed to connect to /192.168.100.12:9002',
      );
    }
    if (failure case final error?) throw error;
    return canonicalProjection(
      state: 'grant_acknowledged',
      ownerDomainId: ownerDomainIdFixture,
      deviceId: namedDeviceInstanceId('device_01'),
      withDecision: true,
      withDelivery: true,
      claimState: 'active',
      claimOwnerDomainGeneration: 1,
    );
  }

  @override
  Future<ClaimPageV1> listClaims({AdmissionListCursorV1? after}) async =>
      currentClaimPage([], ownerDomainId: ownerDomainIdFixture);

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) =>
      throw UnimplementedError();

  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
  }) =>
      throw UnimplementedError();

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) =>
      throw UnimplementedError();
}

class _Transport implements DeviceProvisioningTransport, PhoneWifiSource {
  int wifiSettingsOpened = 0;

  @override
  Future<String?> currentWifiSsid() async => 'home-wifi';

  @override
  Future<bool> openWifiSettings() async {
    wifiSettingsOpened += 1;
    return true;
  }

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

import 'dart:async';

import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/owner_domain_fixtures.dart';
import 'support/admission_fixtures.dart';

/// Setting up a device is two visits to it, and the Host is asked between them.
///
/// Not a preference about ordering. A phone joins a device's access point with
/// the same radio it reaches the Host on, and while it is there the platform
/// reports that access point as the only network the phone has — measured on
/// real hardware, where a request meant for the Host sat for 26 seconds and
/// then failed. So the session must be closed before the Host is asked, and
/// re-opened afterwards to hand over what the Host said.
void main() {
  for (final restart in [false, true]) {
    testWidgets(
        'duplicate confirmation converges without replay (restart: $restart)',
        (tester) async {
      const channel = MethodChannel('live.eidolon.mobile/platform');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async =>
              call.method == 'verifyOwnerDomainDescriptor' ? true : null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final transport = _Transport();
      final admission = _Admission(transport);
      final store = InMemoryDeviceSetupCheckpointStore();
      if (restart) {
        admission.current = canonicalProjection(
            state: 'rejected',
            ownerDomainId: ownerDomainIdFixture,
            deviceId: 'device-instance-${'a' * 64}');
        await store.save(DeviceSetupCheckpoint(
          contractVersion: DeviceSetupCheckpoint.currentContractVersion,
          setupId: 'previous',
          requestId: 'previous-intent',
          createCommandId: 'previous-create',
          decisionRequestId: 'previous-decision',
          collectCommandId: 'previous-collect',
          ackCommandId: 'previous-ack',
          provisioningState: DeviceProvisioningState.networkConfigured,
          admissionState: DeviceAdmissionState.pendingReview,
          updatedAt: DateTime.now().toUtc(),
          onboardingTarget: deviceOnboardingTargetFixture(),
          deviceId: 'device-instance-${'a' * 64}',
          enrollmentId: 'enrollment_01',
        ));
      }
      final gate = Completer<void>();
      transport.configurationGate = gate.future;
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: store,
        loadTarget: () async => deviceOnboardingTargetFixture(),
      )));
      await tester.pumpAndSettle();
      if (restart) {
        await tester.tap(find.text('继续接入'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('restart-device-setup')));
        await tester.pumpAndSettle();
        admission.current = canonicalProjection(
            state: 'pending_review',
            ownerDomainId: ownerDomainIdFixture,
            deviceId: 'device-instance-${'a' * 64}');
      }
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network-owner-wifi')));
      await tester.pump();
      final confirm = tester
          .widget<FilledButton>(find.byKey(const Key('confirm-device-setup')))
          .onPressed!;
      // Two callbacks can arrive before Flutter rebuilds the disabled button.
      confirm();
      confirm();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(transport.opened, 2);
      expect(find.text('选择家庭 Wi-Fi'), findsNothing);
      expect(find.text('Wi-Fi 已配置，正在接入主机'), findsNothing);
      admission.publishEnrollment = false;
      gate.complete();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      // A committed network is visible even when device enrollment is late.
      // Waiting must not reopen SoftAP or need a refresh/approval tap.
      expect(find.text('Wi-Fi 已配置，正在接入主机'), findsOneWidget);
      expect(find.text('等待设备向主机登记，状态会自动更新'), findsOneWidget);
      expect(find.text('设备已设置完成'), findsNothing);
      expect(admission.decisions, 0);
      await tester.pump(const Duration(seconds: 30));
      expect(transport.opened, 2);
      admission.publishEnrollment = true;
      await tester.pump(const Duration(seconds: 3));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(admission.decisions, 1);
      expect(find.text('选择家庭 Wi-Fi'), findsNothing);
      admission.current = canonicalProjection(
        state: 'grant_acknowledged',
        ownerDomainId: ownerDomainIdFixture,
        deviceId: 'device-instance-${'a' * 64}',
        withDecision: true,
        withDelivery: true,
        claimState: 'active',
        claimOwnerDomainGeneration: 1,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('设备已设置完成'), findsOneWidget);
      expect(transport.opened, 2);
      expect(transport.sessions.fold<int>(0, (sum, s) => sum + s.writes), 1);
      expect(admission.decisions, 1);
    });
  }

  testWidgets('the Host is asked only while no session is held',
      (tester) async {
    final transport = _Transport();
    final admission = _Admission(transport);

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceSetupPage(
          transport: transport,
          admission: admission,
          checkpoints: InMemoryDeviceSetupCheckpointStore(),
          loadTarget: () async => deviceOnboardingTargetFixture(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();

    expect(admission.sessionsOpenWhenAsked, [0]);
    expect(admission.requestedKey, 'p256:${'a' * 64}');
    expect(transport.sessions.single.prepared, isTrue);
    expect(transport.opened, 1);
    expect(transport.sessions.single.closed, isTrue);
  });
}

class _Admission implements DeviceAdmissionPort {
  _Admission(this._transport);

  final _Transport _transport;
  final List<int> sessionsOpenWhenAsked = [];
  String? requestedKey;
  int decisions = 0;
  bool publishEnrollment = true;
  EnrollmentRecoveryProjectionV1 current = canonicalProjection(
    state: 'pending_review',
    ownerDomainId: ownerDomainIdFixture,
    deviceId: 'device-instance-${'a' * 64}',
  );

  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
  }) async {
    sessionsOpenWhenAsked.add(_transport.openSessions);
    requestedKey = operationalSpkiSha256;
    return CommissioningVoucher(
      voucher: 'header.payload.signature',
      jti: 'jti-01',
      deviceBaseId: 'device-base-${'a' * 64}',
      expiresAt: DateTime.utc(2027),
    );
  }

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) async =>
      canonicalRecoveryPage(publishEnrollment ? [current] : [],
          ownerDomainId: ownerDomainIdFixture);

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) async =>
      current;

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) async {
    decisions += 1;
    return current = canonicalProjection(
      state: 'approved_awaiting_handoff',
      ownerDomainId: ownerDomainIdFixture,
      deviceId: 'device-instance-${'a' * 64}',
      withDecision: true,
    );
  }
}

class _Transport implements DeviceProvisioningTransport {
  final List<_Session> sessions = [];
  int opened = 0;
  Future<void>? configurationGate;

  int get openSessions => sessions.where((session) => !session.closed).length;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<DeviceProvisioningCandidate>> discover() async => const [
        DeviceProvisioningCandidate(
          transportId: 'eidolon-52f354',
          displayName: 'Eidolon Body 1',
          transportKind: 'softap',
          trust: SetupDescriptorTrustV1.manufacturerBound,
        ),
      ];

  @override
  Future<DeviceProvisioningSession> open(
    DeviceProvisioningCandidate candidate,
  ) async {
    opened += 1;
    final session = _Session()..configurationGate = configurationGate;
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {}
}

class _Session implements DeviceProvisioningSession {
  Future<void>? configurationGate;
  int writes = 0;
  bool prepared = false;
  @override
  Future<DeviceProvisioningDescriptor> prepareOwner(
      DeviceOnboardingTarget target) async {
    prepared = true;
    return DeviceProvisioningDescriptor(
      setup: SetupDescriptorV1.fromJson({
        ...descriptor.setup.toJson(),
        'device_id': 'device-instance-${'a' * 64}',
        'identity_fingerprint': 'p256:${'a' * 64}',
      }),
      expiresAt: descriptor.expiresAt,
    );
  }

  bool closed = false;

  @override
  DeviceProvisioningDescriptor get descriptor => DeviceProvisioningDescriptor(
        setup: SetupDescriptorV1.fromJson({
          'contract_version': '1',
          'device_id': 'device-instance-${'a' * 64}',
          'device_kind': 'esp32-display',
          'display_name': 'Eidolon Body 1',
          'identity_fingerprint': 'p256:${'5' * 64}',
          'session_id': 'setup_session_01',
          'expires_in_seconds': 600,
          'trust': 'manufacturer-bound',
        }),
        expiresAt: DateTime.utc(2036),
      );

  @override
  Future<List<DeviceWifiNetwork>> scanNetworks() async => const [
        DeviceWifiNetwork(
          ssid: 'owner-wifi',
          signalStrength: -40,
          security: 'wpa2',
        ),
      ];

  @override
  Future<CommissioningStatusEvidenceV1> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
    required String createCommandId,
    required String collectCommandId,
    required String ackCommandId,
  }) async {
    writes += 1;
    await configurationGate;
    return const CommissioningStatusEvidenceV1(
      sessionId: 'setup_session_01',
      setupGeneration: 1,
      stateRevision: 5,
      state: CommissioningStatusStateV1.committed,
      conditions: CommissioningConditionsV1(
          wifiConnected: true,
          ownerRouteValidated: true,
          trustCommitted: true,
          networkCommitted: true),
      failureCode: null,
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

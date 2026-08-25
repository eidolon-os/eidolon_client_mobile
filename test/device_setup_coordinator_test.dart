import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_coordinator.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';

final _now = DateTime.parse('2026-08-18T10:00:00Z');

const _candidate = DeviceProvisioningCandidate(
  transportId: 'nearby-1',
  displayName: 'Eidolon Body 1',
  transportKind: 'test',
  trust: DeviceProvisioningTrust.manufacturerBound,
);

final _descriptor = DeviceProvisioningDescriptor(
  contractVersion: '1',
  deviceId: 'device_01',
  deviceKind: 'esp32-display',
  displayName: 'Eidolon Body 1',
  identityFingerprint: 'sha256:device-1',
  sessionId: 'session-1',
  expiresAt: _now.add(const Duration(minutes: 10)),
  trust: DeviceProvisioningTrust.manufacturerBound,
);

// A device that has never been commissioned keeps its offer open, so there is
// no instant to carry here at all.
final _descriptorWithoutExpiry = DeviceProvisioningDescriptor(
  contractVersion: '1',
  deviceId: 'device_01',
  deviceKind: 'esp32-display',
  displayName: 'Eidolon Body 1',
  identityFingerprint: 'sha256:device-1',
  sessionId: 'session-1',
  expiresAt: null,
  trust: DeviceProvisioningTrust.manufacturerBound,
);

DeviceProvisioningDescriptor _descriptorExpiringAt(DateTime expiresAt) =>
    DeviceProvisioningDescriptor(
      contractVersion: '1',
      deviceId: 'device_01',
      deviceKind: 'esp32-display',
      displayName: 'Eidolon Body 1',
      identityFingerprint: 'sha256:device-1',
      sessionId: 'session-1',
      expiresAt: expiresAt,
      trust: DeviceProvisioningTrust.manufacturerBound,
    );

void main() {
  test('network commit persists stable command IDs before explicit Decision',
      () async {
    final session = _Session(_descriptor);
    final admission = _Admission(
      _projection(state: 'pending_review'),
    );
    final store = InMemoryDeviceSetupCheckpointStore();
    final coordinator = _coordinator(session, admission, store);

    final result = await coordinator.provisionAndAdmit(
      setupId: 'setup-1',
      requestId: 'intent-1',
      candidate: _candidate,
      credentials: const DeviceWifiCredentials(
        ssid: 'Home WiFi',
        password: 'not-persisted',
      ),
      onboardingTarget: deviceOnboardingTargetFixture(),
      companionId: 'companion-1',
    );

    expect(result.provisioningState, DeviceProvisioningState.networkConfigured);
    expect(
      result.admissionState,
      DeviceAdmissionState.approvedAwaitingHandoff,
    );
    expect(result.isReady, isFalse);
    expect(session.commandIds, {
      'create': 'mobile-create-setup-1',
      'collect': 'mobile-collect-setup-1',
      'ack': 'mobile-ack-setup-1',
    });
    expect(admission.decisionRequestIds, ['mobile-decision-setup-1']);
    expect(result.expectedProposalRevision, 2);
    expect(result.encode(), isNot(contains('not-persisted')));
  });

  test('reply loss and coordinator restart recover before any replay',
      () async {
    final session = _Session(_descriptor);
    final admission = _Admission(
      _projection(state: 'pending_review'),
      loseDecisionReply: true,
    );
    final store = InMemoryDeviceSetupCheckpointStore();

    final failed =
        await _coordinator(session, admission, store).provisionAndAdmit(
      setupId: 'setup-reply-loss',
      requestId: 'intent-reply-loss',
      candidate: _candidate,
      credentials: const DeviceWifiCredentials(ssid: 'Home', password: 'pw'),
      onboardingTarget: deviceOnboardingTargetFixture(),
    );
    expect(failed.admissionState, DeviceAdmissionState.failed);
    expect(failed.enrollmentId, 'enrollment_01');
    expect(failed.decisionRequestId, 'mobile-decision-setup-reply-loss');

    final restarted = _coordinator(_Session(_descriptor), admission, store);
    final recovered = await restarted.resumeAdmission('setup-reply-loss');

    expect(
      recovered.admissionState,
      DeviceAdmissionState.approvedAwaitingHandoff,
    );
    expect(admission.recoverCalls, 1);
    expect(admission.decisionRequestIds, ['mobile-decision-setup-reply-loss']);
  });

  test('duplicate resume reuses immutable Decision command and payload',
      () async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint('setup-duplicate'));
    final admission = _Admission(_projection(state: 'pending_review'));
    final coordinator = _coordinator(_Session(_descriptor), admission, store);

    await coordinator.resumeAdmission('setup-duplicate');
    admission.current = _projection(state: 'pending_review');
    await store.save(_checkpoint('setup-duplicate'));
    await coordinator.resumeAdmission('setup-duplicate');

    expect(admission.decisionRequestIds, [
      'mobile-decision-setup-duplicate',
      'mobile-decision-setup-duplicate',
    ]);
    expect(admission.payloads[1], admission.payloads[0]);
  });

  test('Hub unavailable is recoverable and never becomes completion', () async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint('setup-offline'));
    final admission = _Admission(_projection())..unavailable = true;

    final result = await _coordinator(
      _Session(_descriptor),
      admission,
      store,
    ).resumeAdmission('setup-offline');

    expect(result.admissionState, DeviceAdmissionState.failed);
    expect(result.failure?.code, 'admission_unavailable');
    expect(result.failure?.retryable, isTrue);
    expect(result.isReady, isFalse);
    expect(admission.decisionRequestIds, isEmpty);
  });

  test('Owner mismatch and old Owner generation are contract failures',
      () async {
    for (final projection in [
      _projection(ownerDomainId: 'owner-domain_other'),
      _projection(
        state: 'grant_acknowledged',
        withDecision: true,
        withDelivery: true,
        claimState: 'active',
        claimOwnerDomainGeneration: 2,
      ),
    ]) {
      final store = InMemoryDeviceSetupCheckpointStore();
      await store.save(_checkpoint('setup-mismatch'));
      final result = await _coordinator(
        _Session(_descriptor),
        _Admission(projection),
        store,
      ).resumeAdmission('setup-mismatch');
      expect(result.admissionState, DeviceAdmissionState.failed);
      expect(result.failure?.code, 'admission_unavailable');
    }
  });

  test('an offer with no deadline is never treated as an expired one',
      () async {
    // A device that has never been commissioned advertises no duration, so its
    // descriptor carries no expiry. Reading that absence as a deadline already
    // past would refuse exactly the devices setup exists for.
    final session = _Session(_descriptorWithoutExpiry);
    final store = InMemoryDeviceSetupCheckpointStore();
    final coordinator = _coordinator(
      session,
      _Admission(_projection(state: 'pending_review')),
      store,
    );

    final result = await coordinator.provisionAndAdmit(
      setupId: 'setup-open-ended',
      requestId: 'intent-open-ended',
      candidate: _candidate,
      credentials: const DeviceWifiCredentials(
        ssid: 'Home WiFi',
        password: 'not-persisted',
      ),
      onboardingTarget: deviceOnboardingTargetFixture(),
      companionId: 'companion-1',
    );

    expect(result.provisioningState, DeviceProvisioningState.networkConfigured);
    expect(result.failure, isNull);
  });

  test('a deadline that has already passed still stops the setup', () async {
    final coordinator = _coordinator(
      _Session(
          _descriptorExpiringAt(_now.subtract(const Duration(minutes: 1)))),
      _Admission(_projection(state: 'pending_review')),
      InMemoryDeviceSetupCheckpointStore(),
    );

    final result = await coordinator.provisionAndAdmit(
      setupId: 'setup-expired',
      requestId: 'intent-expired',
      candidate: _candidate,
      credentials: const DeviceWifiCredentials(
        ssid: 'Home WiFi',
        password: 'not-persisted',
      ),
      onboardingTarget: deviceOnboardingTargetFixture(),
      companionId: 'companion-1',
    );

    expect(result.provisioningState, DeviceProvisioningState.failed);
    expect(result.failure?.code, 'provisioning_session_expired');
  });

  test('ClaimActive alone makes the recovered workflow ready', () async {
    final store = InMemoryDeviceSetupCheckpointStore();
    await store.save(_checkpoint('setup-active'));
    final projection = _projection(
      state: 'grant_acknowledged',
      withDecision: true,
      withDelivery: true,
      claimState: 'active',
    );

    final result = await _coordinator(
      _Session(_descriptor),
      _Admission(projection),
      store,
    ).resumeAdmission('setup-active');

    expect(result.admissionState, DeviceAdmissionState.claimActive);
    expect(result.isReady, isTrue);
  });
}

DeviceSetupCoordinator _coordinator(
  _Session session,
  DeviceAdmissionPort admission,
  DeviceSetupCheckpointStore store,
) =>
    DeviceSetupCoordinator(
      transport: _Transport(session),
      admission: admission,
      checkpoints: store,
      ownerDirectoryVerifier: const AcceptingOwnerDomainDirectoryVerifier(),
      clock: () => _now,
      sleep: (_) async {},
      enrollmentInterval: Duration.zero,
    );

EnrollmentRecoveryProjectionV1 _projection({
  String state = 'pending_review',
  String ownerDomainId = ownerDomainIdFixture,
  bool withDecision = false,
  bool withDelivery = false,
  String? claimState,
  int claimOwnerDomainGeneration = 1,
}) =>
    canonicalProjection(
      state: state,
      ownerDomainId: ownerDomainId,
      withDecision: withDecision,
      withDelivery: withDelivery,
      claimState: claimState,
      claimOwnerDomainGeneration: claimOwnerDomainGeneration,
    );

DeviceSetupCheckpoint _checkpoint(String setupId) => DeviceSetupCheckpoint(
      contractVersion: DeviceSetupCheckpoint.currentContractVersion,
      setupId: setupId,
      requestId: 'intent-$setupId',
      createCommandId: 'mobile-create-$setupId',
      decisionRequestId: 'mobile-decision-$setupId',
      collectCommandId: 'mobile-collect-$setupId',
      ackCommandId: 'mobile-ack-$setupId',
      provisioningState: DeviceProvisioningState.networkConfigured,
      admissionState: DeviceAdmissionState.pendingReview,
      updatedAt: _now,
      onboardingTarget: deviceOnboardingTargetFixture(),
      deviceId: 'device_01',
      enrollmentId: 'enrollment_01',
      expectedProposalRevision: 2,
    );

class _Session implements DeviceProvisioningSession {
  _Session(this.descriptor);

  @override
  final DeviceProvisioningDescriptor descriptor;
  Map<String, String>? commandIds;

  @override
  Future<void> close() async {}

  @override
  Future<CommissioningStatusEvidenceV1> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
    required String createCommandId,
    required String collectCommandId,
    required String ackCommandId,
  }) async {
    commandIds = {
      'create': createCommandId,
      'collect': collectCommandId,
      'ack': ackCommandId,
    };
    return const CommissioningStatusEvidenceV1(
      sessionId: 'session-1',
      setupGeneration: 1,
      stateRevision: 5,
      state: CommissioningStatusStateV1.committed,
      conditions: CommissioningConditionsV1(
        wifiConnected: true,
        ownerRouteValidated: true,
        trustCommitted: true,
        networkCommitted: true,
      ),
      failureCode: null,
    );
  }

  @override
  Future<List<DeviceWifiNetwork>> scanNetworks() async => const [];
}

class _Transport implements DeviceProvisioningTransport {
  _Transport(this.session);
  final _Session session;

  @override
  Future<void> close() async {}

  @override
  Future<List<DeviceProvisioningCandidate>> discover() async => [_candidate];

  @override
  Future<DeviceProvisioningSession> open(
    DeviceProvisioningCandidate candidate,
  ) async =>
      session;

  @override
  Future<bool> requestPermission() async => true;
}

class _Admission implements DeviceAdmissionPort {
  _Admission(this.current, {this.loseDecisionReply = false});

  EnrollmentRecoveryProjectionV1 current;
  final bool loseDecisionReply;
  bool unavailable = false;
  int recoverCalls = 0;
  final List<String> decisionRequestIds = [];
  final List<Map<String, dynamic>> payloads = [];

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) async {
    if (unavailable) throw StateError('Hub unavailable');
    return canonicalRecoveryPage([current]);
  }

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) async {
    recoverCalls += 1;
    if (unavailable) throw StateError('Hub unavailable');
    return current;
  }

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) async {
    decisionRequestIds.add(requestId);
    payloads.add({
      'enrollment_id': projection.json['proposal']['enrollment_id'],
      'revision': projection.json['source_revision'],
      'companion_id': initialCompanionId,
    });
    current = _projection(
      state: 'approved_awaiting_handoff',
      withDecision: true,
    );
    if (loseDecisionReply && decisionRequestIds.length == 1) {
      throw StateError('reply lost');
    }
    return current;
  }
}

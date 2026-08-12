import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_coordinator.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.parse('2026-08-07T10:00:00Z');

const _candidate = DeviceProvisioningCandidate(
  transportId: 'nearby-1',
  displayName: 'Eidolon Body 1',
  transportKind: 'test',
  trust: DeviceProvisioningTrust.manufacturerBound,
);

final _descriptor = DeviceProvisioningDescriptor(
  contractVersion: '1',
  deviceId: 'device-1',
  deviceKind: 'esp32-display',
  displayName: 'Eidolon Body 1',
  identityFingerprint: 'sha256:device-1',
  sessionId: 'session-1',
  expiresAt: _now.add(const Duration(minutes: 10)),
  trust: DeviceProvisioningTrust.manufacturerBound,
);

class _FakeSession implements DeviceProvisioningSession {
  _FakeSession(this.descriptor);

  @override
  final DeviceProvisioningDescriptor descriptor;
  bool configured = false;
  bool closed = false;
  DeviceWifiCredentials? receivedCredentials;

  @override
  Future<DeviceEnrollmentReceipt> awaitEnrollment() async =>
      const DeviceEnrollmentReceipt(
        deviceId: 'device-1',
        enrollmentId: 'enrollment-1',
        lifecycleState: 'pending-approval',
      );

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
  }) async {
    configured = true;
    receivedCredentials = credentials;
  }

  @override
  Future<List<DeviceWifiNetwork>> scanNetworks() async => const [];
}

class _FakeTransport implements DeviceProvisioningTransport {
  _FakeTransport(this.session);

  final _FakeSession session;
  bool closed = false;

  @override
  Future<void> close() async => closed = true;

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

class _FakeAdmission implements DeviceAdmissionPort {
  int calls = 0;
  bool fail = false;
  final List<String> requestIds = [];

  @override
  Future<DeviceAdmissionProgress> approve({
    required String requestId,
    required String deviceId,
    String? companionId,
  }) async {
    calls += 1;
    requestIds.add(requestId);
    if (fail) throw StateError('Hub is unavailable');
    return DeviceAdmissionProgress(
      requestId: requestId,
      deviceId: deviceId,
      ownerId: 'owner-1',
      state: DeviceAdmissionState.ready,
      completedStage: 'companion-attached',
      companionId: companionId,
    );
  }

  @override
  Future<List<PendingDeviceEnrollment>> listPending() async => const [];
}

void main() {
  test('keeps provisioning and admission as separately checkpointed stages',
      () async {
    final session = _FakeSession(_descriptor);
    final transport = _FakeTransport(session);
    final admission = _FakeAdmission();
    final store = InMemoryDeviceSetupCheckpointStore();
    final coordinator = DeviceSetupCoordinator(
      transport: transport,
      admission: admission,
      checkpoints: store,
      clock: () => _now,
    );

    final result = await coordinator.provisionAndAdmit(
      setupId: 'setup-1',
      requestId: 'device-setup-1',
      candidate: _candidate,
      credentials: const DeviceWifiCredentials(
        ssid: 'Home WiFi',
        password: 'secret-not-persisted',
      ),
      onboardingTarget: DeviceOnboardingTarget(
        hubId: 'hub-1',
        descriptorUri: Uri.parse('https://hub.local/onboarding'),
        tlsSpkiFingerprint:
            'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8',
  hubCertificate: '-----BEGIN CERTIFICATE-----\\nMIIBdummy\\n-----END CERTIFICATE-----\\n',
),
      companionId: 'companion-1',
    );

    expect(result.provisioningState, DeviceProvisioningState.networkConfigured);
    expect(result.admissionState, DeviceAdmissionState.ready);
    expect(result.isReady, isTrue);
    expect(result.deviceId, 'device-1');
    expect(result.enrollmentId, 'enrollment-1');
    expect(session.configured, isTrue);
    expect(session.closed, isTrue);
    expect(transport.closed, isTrue);
    expect(admission.requestIds, ['device-setup-1']);
    expect(result.encode(), isNot(contains('secret-not-persisted')));
  });

  test('retries admission forward without configuring Wi-Fi again', () async {
    final session = _FakeSession(_descriptor);
    final transport = _FakeTransport(session);
    final admission = _FakeAdmission()..fail = true;
    final store = InMemoryDeviceSetupCheckpointStore();
    final coordinator = DeviceSetupCoordinator(
      transport: transport,
      admission: admission,
      checkpoints: store,
      clock: () => _now,
    );

    final failed = await coordinator.provisionAndAdmit(
      setupId: 'setup-1',
      requestId: 'stable-request-1',
      candidate: _candidate,
      credentials: const DeviceWifiCredentials(ssid: 'Home', password: 'pw'),
      onboardingTarget: DeviceOnboardingTarget(
        hubId: 'hub-1',
        descriptorUri: Uri.parse('https://hub.local/onboarding'),
        tlsSpkiFingerprint:
            'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8',
  hubCertificate: '-----BEGIN CERTIFICATE-----\\nMIIBdummy\\n-----END CERTIFICATE-----\\n',
),
    );
    expect(failed.provisioningState, DeviceProvisioningState.networkConfigured);
    expect(failed.admissionState, DeviceAdmissionState.failed);
    expect(failed.failure?.retryable, isTrue);

    admission.fail = false;
    final resumed = await coordinator.resumeAdmission('setup-1');

    expect(resumed.isReady, isTrue);
    expect(admission.requestIds, ['stable-request-1', 'stable-request-1']);
    expect(session.configured, isTrue);
  });

  test('product coordinator rejects development TOFU provisioning', () async {
    final descriptor = DeviceProvisioningDescriptor(
      contractVersion: '1',
      deviceId: 'device-dev',
      deviceKind: 'esp32-display',
      displayName: 'Xiaozhi-1234',
      identityFingerprint: '',
      sessionId: 'dev-session',
      expiresAt: _now.add(const Duration(minutes: 10)),
      trust: DeviceProvisioningTrust.developmentTofu,
    );
    final session = _FakeSession(descriptor);
    final store = InMemoryDeviceSetupCheckpointStore();
    final coordinator = DeviceSetupCoordinator(
      transport: _FakeTransport(session),
      admission: _FakeAdmission(),
      checkpoints: store,
      clock: () => _now,
    );
    const candidate = DeviceProvisioningCandidate(
      transportId: 'open-ap',
      displayName: 'Xiaozhi-1234',
      transportKind: 'hotspot',
      trust: DeviceProvisioningTrust.developmentTofu,
    );

    final result = await coordinator.provisionAndAdmit(
      setupId: 'setup-dev',
      requestId: 'request-dev',
      candidate: candidate,
      credentials: const DeviceWifiCredentials(ssid: 'Home', password: 'pw'),
      onboardingTarget: DeviceOnboardingTarget(
        hubId: 'hub-1',
        descriptorUri: Uri.parse('https://hub.local/onboarding'),
        tlsSpkiFingerprint:
            'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8',
  hubCertificate: '-----BEGIN CERTIFICATE-----\\nMIIBdummy\\n-----END CERTIFICATE-----\\n',
),
    );

    expect(result.provisioningState, DeviceProvisioningState.failed);
    expect(result.failure?.code, 'untrusted_device_provisioning');
    expect(session.configured, isFalse);
  });
}

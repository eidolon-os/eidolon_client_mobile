import 'device_setup_models.dart';

abstract interface class DeviceProvisioningTransport {
  Future<bool> requestPermission();

  Future<List<DeviceProvisioningCandidate>> discover();

  Future<DeviceProvisioningSession> open(
    DeviceProvisioningCandidate candidate,
  );

  Future<void> close();
}

abstract interface class DeviceProvisioningSession {
  DeviceProvisioningDescriptor get descriptor;

  Future<List<DeviceWifiNetwork>> scanNetworks();

  /// Configures only the device's network and onboarding destination.
  /// Host Setup codes and Controller credentials never cross this port.
  Future<void> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
  });

  /// Returns the enrollment created by the Device using its own identity.
  Future<DeviceEnrollmentReceipt> awaitEnrollment();

  Future<void> close();
}

abstract interface class DeviceAdmissionPort {
  /// Continues an Owner-scoped, forward-only approval/mount workflow.
  /// Owner scope is derived by Local API from the Controller session.
  Future<DeviceAdmissionProgress> continueAdmission({
    required String deviceId,
    required String enrollmentId,
    required String requestId,
    String? companionId,
  });

  Future<DeviceAdmissionProgress> readProgress({
    required String deviceId,
    required String enrollmentId,
  });
}

abstract interface class DeviceSetupCheckpointStore {
  Future<void> save(DeviceSetupCheckpoint checkpoint);

  Future<DeviceSetupCheckpoint?> load(String setupId);

  Future<void> remove(String setupId);
}

/// Temporary adapter boundary for the current ESP32 captive-portal contract.
///
/// This port is intentionally narrower than [DeviceProvisioningTransport]: the
/// legacy hotspot has no verifiable Device identity, onboarding destination or
/// enrollment receipt. A successful call therefore means only that Wi-Fi was
/// configured; it must never be promoted to Device admission/claim completion.
abstract interface class LegacyHotspotProvisioningPort {
  Future<bool> requestPermission();

  /// Opens an OS-scoped connection to a nearby `Xiaozhi-*` configuration AP
  /// and returns the networks scanned by that device.
  Future<List<DeviceWifiNetwork>> openAndScan();

  /// Sends credentials only over the already-open local hotspot session.
  /// Implementations must not persist [credentials].
  Future<void> configureNetwork(DeviceWifiCredentials credentials);

  Future<void> close();
}

class InMemoryDeviceSetupCheckpointStore implements DeviceSetupCheckpointStore {
  final Map<String, DeviceSetupCheckpoint> _values = {};

  @override
  Future<DeviceSetupCheckpoint?> load(String setupId) async => _values[setupId];

  @override
  Future<void> remove(String setupId) async {
    _values.remove(setupId);
  }

  @override
  Future<void> save(DeviceSetupCheckpoint checkpoint) async {
    _values[checkpoint.setupId] = checkpoint;
  }
}

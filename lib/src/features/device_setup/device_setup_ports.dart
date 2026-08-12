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
  Future<List<PendingDeviceEnrollment>> listPending();

  /// Records explicit Controller approval and continues the Owner-scoped,
  /// forward-only Hub approval, Kernel mount and Companion attachment.
  Future<DeviceAdmissionProgress> approve({
    required String requestId,
    required String deviceId,
    String? companionId,
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

  /// Which device is on the other end of the open hotspot session.
  Future<CommissionableDevice> identify();

  /// Hands the device the Host it belongs to, and optionally the network to
  /// reach it on, over the already-open local hotspot session. Implementations
  /// must not persist [credentials].
  ///
  /// Trust and network travel together because a device that joined a network
  /// without knowing its Host has nothing it can safely talk to there.
  Future<CommissionedDevice> commission({
    required DeviceOnboardingTarget target,
    DeviceWifiCredentials? credentials,
  });

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

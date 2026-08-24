import 'device_setup_models.dart';
import '../../generated/device_foundation_v1.dart';

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
  Future<CommissioningStatusEvidenceV1> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
    required String createCommandId,
    required String collectCommandId,
    required String ackCommandId,
  });

  Future<void> close();
}

abstract interface class DeviceAdmissionPort {
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  });

  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  });

  /// Records one immutable, explicit Decision then re-reads recovery.
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String commandId,
    required String correlationId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  });
}

abstract interface class OwnerDomainDirectoryVerifier {
  /// Verifies Owner identity, delegated P-256 signer and descriptor signature.
  /// A transport-reachable endpoint or Host TLS leaf is never sufficient.
  Future<void> verify(DeviceOnboardingTarget target);
}

abstract interface class DeviceSetupCheckpointStore {
  Future<void> save(DeviceSetupCheckpoint checkpoint);

  Future<DeviceSetupCheckpoint?> load(String setupId);

  Future<List<DeviceSetupCheckpoint>> list();

  Future<void> remove(String setupId);
}

class InMemoryDeviceSetupCheckpointStore implements DeviceSetupCheckpointStore {
  final Map<String, DeviceSetupCheckpoint> _values = {};

  @override
  Future<DeviceSetupCheckpoint?> load(String setupId) async => _values[setupId];

  @override
  Future<List<DeviceSetupCheckpoint>> list() async {
    final values = _values.values.toList(growable: false)
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return values;
  }

  @override
  Future<void> remove(String setupId) async {
    _values.remove(setupId);
  }

  @override
  Future<void> save(DeviceSetupCheckpoint checkpoint) async {
    _values[checkpoint.setupId] = checkpoint;
  }
}

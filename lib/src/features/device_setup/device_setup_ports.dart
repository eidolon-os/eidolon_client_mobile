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
  /// Ask the Host to sign the standing this device needs to be admitted.
  ///
  /// [operationalSpkiSha256] is the fingerprint the device stated in its own
  /// setup descriptor; [presentedDeviceBaseId] is the identity it says it
  /// already holds, forwarded and not vouched for. Which of the two the Host
  /// signs — that identity, or a newly minted one — is Hub's answer, not this
  /// controller's: a device that could name itself would be choosing the anchor
  /// its whole Claim history hangs from.
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
    String? presentedDeviceBaseId,
  });

  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  });

  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  });

  /// Records one immutable, explicit Decision and returns what became of it.
  ///
  /// [requestId] is an idempotency key over the Host's durable intent, so a
  /// lost reply is resumed rather than decided again.
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
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

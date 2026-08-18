import 'device_setup_models.dart';
import 'device_setup_ports.dart';

class DeviceSetupException implements Exception {
  const DeviceSetupException({
    required this.code,
    required this.message,
    this.retryable = false,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

typedef DeviceSetupClock = DateTime Function();

/// Coordinates local provisioning and Owner admission without merging their
/// completion semantics or attempting destructive compensation.
class DeviceSetupCoordinator {
  DeviceSetupCoordinator({
    required this.transport,
    required this.admission,
    required this.checkpoints,
    this.allowDevelopmentTrust = false,
    DeviceSetupClock? clock,
  }) : _clock = clock ?? DateTime.now;

  final DeviceProvisioningTransport transport;
  final DeviceAdmissionPort admission;
  final DeviceSetupCheckpointStore checkpoints;
  final bool allowDevelopmentTrust;
  final DeviceSetupClock _clock;

  Future<DeviceSetupCheckpoint> provisionAndAdmit({
    required String setupId,
    required String requestId,
    required DeviceProvisioningCandidate candidate,
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
    String? companionId,
  }) async {
    var checkpoint = DeviceSetupCheckpoint(
      contractVersion: DeviceSetupCheckpoint.currentContractVersion,
      setupId: setupId,
      requestId: requestId,
      provisioningState: DeviceProvisioningState.selected,
      admissionState: DeviceAdmissionState.notStarted,
      updatedAt: _now(),
      onboardingTarget: onboardingTarget,
      companionId: companionId,
    );
    await checkpoints.save(checkpoint);

    DeviceProvisioningSession? session;
    try {
      session = await transport.open(candidate);
      _validateTrust(candidate, session.descriptor);
      checkpoint = checkpoint.copyWith(
        provisioningState: DeviceProvisioningState.configuringNetwork,
        deviceId: session.descriptor.deviceId,
        updatedAt: _now(),
        clearFailure: true,
      );
      await checkpoints.save(checkpoint);
      await session.configureNetwork(
        credentials: credentials,
        onboardingTarget: onboardingTarget,
      );
      checkpoint = checkpoint.copyWith(
        provisioningState: DeviceProvisioningState.networkConfigured,
        admissionState: DeviceAdmissionState.awaitingEnrollment,
        updatedAt: _now(),
      );
      await checkpoints.save(checkpoint);

      final receipt = await session.awaitEnrollment();
      if (receipt.deviceId != session.descriptor.deviceId) {
        throw const DeviceSetupException(
          code: 'enrollment_identity_mismatch',
          message: 'Enrollment does not belong to the provisioned Device',
        );
      }
      if (receipt.lifecycleState != 'pending-approval' &&
          receipt.lifecycleState != 'approved') {
        throw const DeviceSetupException(
          code: 'invalid_enrollment_state',
          message: 'Device enrollment is not awaiting approval',
        );
      }
      checkpoint = checkpoint.copyWith(
        admissionState: DeviceAdmissionState.pendingApproval,
        enrollmentId: receipt.enrollmentId,
        updatedAt: _now(),
      );
      await checkpoints.save(checkpoint);
    } on DeviceSetupException catch (error) {
      return _fail(
        checkpoint,
        error,
        admissionStage: checkpoint.provisioningState ==
            DeviceProvisioningState.networkConfigured,
      );
    } catch (error) {
      return _fail(
        checkpoint,
        DeviceSetupException(
          code: 'provisioning_failed',
          message: error.toString(),
          retryable: true,
        ),
        admissionStage: checkpoint.provisioningState ==
            DeviceProvisioningState.networkConfigured,
      );
    } finally {
      await _closeProvisioning(session);
    }
    return _continueAdmission(checkpoint);
  }

  Future<DeviceSetupCheckpoint> resumeAdmission(String setupId) async {
    final checkpoint = await checkpoints.load(setupId);
    if (checkpoint == null) {
      throw const DeviceSetupException(
        code: 'checkpoint_not_found',
        message: 'Device Setup checkpoint does not exist',
      );
    }
    if (checkpoint.provisioningState !=
            DeviceProvisioningState.networkConfigured ||
        checkpoint.deviceId == null ||
        checkpoint.enrollmentId == null) {
      throw const DeviceSetupException(
        code: 'admission_not_resumable',
        message: 'Device enrollment has not completed',
      );
    }
    return _continueAdmission(checkpoint);
  }

  Future<DeviceSetupCheckpoint> _continueAdmission(
    DeviceSetupCheckpoint checkpoint,
  ) async {
    try {
      final progress = await admission.approve(
        requestId: checkpoint.requestId,
        deviceId: checkpoint.deviceId!,
        companionId: checkpoint.companionId,
      );
      if (progress.requestId != checkpoint.requestId ||
          progress.deviceId != checkpoint.deviceId) {
        throw const DeviceSetupException(
          code: 'admission_identity_mismatch',
          message: 'Local API returned another Device admission',
        );
      }
      final updated = checkpoint.copyWith(
        admissionState: switch (progress.outcome) {
          ActOutcome.done => DeviceAdmissionState.ready,
          // Partway is partway: the checkpoint records that it is still
          // binding, which is what makes the next attempt a continuation
          // rather than a fresh start.
          ActOutcome.unfinished => DeviceAdmissionState.binding,
          ActOutcome.refused => DeviceAdmissionState.failed,
        },
        updatedAt: _now(),
        clearFailure: true,
      );
      await checkpoints.save(updated);
      return updated;
    } on DeviceSetupException catch (error) {
      return _fail(checkpoint, error, admissionStage: true);
    } catch (error) {
      return _fail(
        checkpoint,
        DeviceSetupException(
          code: 'admission_unavailable',
          message: error.toString(),
          retryable: true,
        ),
        admissionStage: true,
      );
    }
  }

  void _validateTrust(
    DeviceProvisioningCandidate candidate,
    DeviceProvisioningDescriptor descriptor,
  ) {
    if (candidate.trust != descriptor.trust) {
      throw const DeviceSetupException(
        code: 'provisioning_trust_mismatch',
        message: 'Device provisioning trust changed after connection',
      );
    }
    if (!allowDevelopmentTrust &&
        descriptor.trust == DeviceProvisioningTrust.developmentTofu) {
      throw const DeviceSetupException(
        code: 'untrusted_device_provisioning',
        message: 'Device provisioning is not bound to a product identity',
      );
    }
    if (descriptor.expiresAt.isBefore(_now())) {
      throw const DeviceSetupException(
        code: 'provisioning_session_expired',
        message: 'Device provisioning session has expired',
        retryable: true,
      );
    }
  }

  Future<DeviceSetupCheckpoint> _fail(
    DeviceSetupCheckpoint checkpoint,
    DeviceSetupException error, {
    bool admissionStage = false,
  }) async {
    final failed = checkpoint.copyWith(
      provisioningState: admissionStage
          ? checkpoint.provisioningState
          : DeviceProvisioningState.failed,
      admissionState: admissionStage
          ? DeviceAdmissionState.failed
          : checkpoint.admissionState,
      updatedAt: _now(),
      failure: DeviceSetupFailure(
        stage: admissionStage ? 'admission' : 'provisioning',
        code: error.code,
        message: error.message,
        retryable: error.retryable,
      ),
    );
    await checkpoints.save(failed);
    return failed;
  }

  DateTime _now() => _clock().toUtc();

  Future<void> _closeProvisioning(DeviceProvisioningSession? session) async {
    try {
      await session?.close();
    } catch (_) {
      // The durable workflow state is authoritative; cleanup cannot roll back
      // network configuration or obscure the primary setup outcome.
    }
    try {
      await transport.close();
    } catch (_) {
      // A stale platform link is cleaned up by the next adapter open/OS cycle.
    }
  }
}

import '../../generated/device_foundation_v1.dart';
import 'admission_projection.dart';
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

/// Coordinates network commissioning and Admission as separate committed facts.
///
/// A successful network terminal only advances [DeviceProvisioningState].
/// Admission is recovered from the Authority before any Decision is sent or
/// replayed.
class DeviceSetupCoordinator {
  DeviceSetupCoordinator({
    required this.transport,
    required this.admission,
    required this.checkpoints,
    required this.ownerDirectoryVerifier,
    this.allowDevelopmentTrust = false,
    this.enrollmentTimeout = const Duration(minutes: 3),
    this.enrollmentInterval = const Duration(seconds: 3),
    DeviceSetupClock? clock,
    Future<void> Function(Duration)? sleep,
  })  : _clock = clock ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed;

  final DeviceProvisioningTransport transport;
  final DeviceAdmissionPort admission;
  final DeviceSetupCheckpointStore checkpoints;
  final OwnerDomainDirectoryVerifier ownerDirectoryVerifier;
  final bool allowDevelopmentTrust;
  final Duration enrollmentTimeout;
  final Duration enrollmentInterval;
  final DeviceSetupClock _clock;
  final Future<void> Function(Duration) _sleep;

  Future<DeviceSetupCheckpoint> provisionAndAdmit({
    required String setupId,
    required String requestId,
    required DeviceProvisioningCandidate candidate,
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
    String? companionId,
  }) async {
    try {
      await ownerDirectoryVerifier.verify(onboardingTarget);
    } catch (error) {
      throw DeviceSetupException(
        code: 'owner_directory_rejected',
        message: 'Owner Domain directory could not be authenticated: $error',
      );
    }
    var checkpoint = DeviceSetupCheckpoint(
      contractVersion: DeviceSetupCheckpoint.currentContractVersion,
      setupId: setupId,
      requestId: requestId,
      createCommandId: _commandId('create', setupId),
      decisionRequestId: _commandId('decision', setupId),
      collectCommandId: _commandId('collect', setupId),
      ackCommandId: _commandId('ack', setupId),
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
      final evidence = await session.configureNetwork(
        credentials: credentials,
        onboardingTarget: onboardingTarget,
        createCommandId: checkpoint.createCommandId,
        collectCommandId: checkpoint.collectCommandId,
        ackCommandId: checkpoint.ackCommandId,
      );
      if (!evidence.isCommittedTerminal ||
          evidence.sessionId != session.descriptor.sessionId) {
        throw const DeviceSetupException(
          code: 'network_terminal_missing',
          message: 'Device did not confirm the network connection',
          retryable: true,
        );
      }
      checkpoint = checkpoint.copyWith(
        provisioningState: DeviceProvisioningState.networkConfigured,
        admissionState: DeviceAdmissionState.awaitingEnrollment,
        updatedAt: _now(),
      );
      await checkpoints.save(checkpoint);
    } on DeviceSetupException catch (error) {
      return _fail(checkpoint, error);
    } catch (error) {
      return _fail(
        checkpoint,
        DeviceSetupException(
          code: 'provisioning_failed',
          message: error.toString(),
          retryable: true,
        ),
      );
    } finally {
      await _closeProvisioning(session);
    }
    return _resume(checkpoint, waitForEnrollment: true);
  }

  /// Startup/foreground entry point. Recovery is always queried before replay.
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
        checkpoint.deviceId == null) {
      throw const DeviceSetupException(
        code: 'admission_not_resumable',
        message: 'Device network commissioning has not committed',
      );
    }
    return _resume(checkpoint, waitForEnrollment: false);
  }

  Future<DeviceSetupCheckpoint> _resume(
    DeviceSetupCheckpoint checkpoint, {
    required bool waitForEnrollment,
  }) async {
    var current = checkpoint;
    try {
      var projection = current.enrollmentId == null
          ? null
          : await admission.recover(enrollmentId: current.enrollmentId!);
      if (projection == null) {
        final found = await _findEnrollment(
          current,
          wait: waitForEnrollment,
        );
        if (found == null) {
          return _fail(
            current,
            const DeviceSetupException(
              code: 'enrollment_not_seen',
              message: 'Device has not created an Enrollment yet',
              retryable: true,
            ),
            admissionStage: true,
          );
        }
        projection = found.$1;
        current = found.$2;
      }

      final stage = projection.validateForOwner(
        current.onboardingTarget.ownerDomainId,
        ownerDomainGeneration: current
            .onboardingTarget.ownerDomainDescriptor.ownerDomainGeneration,
      );
      current = await _saveProjection(current, projection, stage);
      if (stage == AdmissionProjectionStage.pendingReview) {
        // The immutable Decision payload is derived from the recovered Proposal.
        // Reply loss is recovered on the next entry before this ID is reused.
        projection = await admission.decide(
          requestId: current.decisionRequestId,
          projection: projection,
          initialCompanionId: current.companionId,
        );
        final decidedStage = projection.validateForOwner(
          current.onboardingTarget.ownerDomainId,
          ownerDomainGeneration: current
              .onboardingTarget.ownerDomainDescriptor.ownerDomainGeneration,
        );
        return _saveProjection(current, projection, decidedStage);
      }
      return current;
    } on DeviceSetupException catch (error) {
      return _fail(current, error, admissionStage: true);
    } catch (error) {
      return _fail(
        current,
        DeviceSetupException(
          code: 'admission_unavailable',
          message: error.toString(),
          retryable: true,
        ),
        admissionStage: true,
      );
    }
  }

  Future<(EnrollmentRecoveryProjectionV1, DeviceSetupCheckpoint)?>
      _findEnrollment(
    DeviceSetupCheckpoint checkpoint, {
    required bool wait,
  }) async {
    final deadline = _now().add(enrollmentTimeout);
    var cursor = checkpoint.recoveryCursor;
    while (true) {
      final page = await admission.listRecovery(after: cursor);
      for (final projection in page.projections) {
        projection.validateForOwner(
          checkpoint.onboardingTarget.ownerDomainId,
          ownerDomainGeneration: checkpoint
              .onboardingTarget.ownerDomainDescriptor.ownerDomainGeneration,
        );
        if (projection.proposal.json['device_instance_candidate_id'] ==
            checkpoint.deviceId) {
          final updated = checkpoint.copyWith(
            enrollmentId: projection.proposal.json['enrollment_id']! as String,
            expectedProposalRevision: projection.proposalRevision,
            recoveryCursor: page.nextCursor,
            updatedAt: _now(),
          );
          await checkpoints.save(updated);
          return (projection, updated);
        }
      }
      cursor = page.nextCursor;
      checkpoint = checkpoint.copyWith(
        recoveryCursor: cursor,
        clearRecoveryCursor: cursor == null,
        updatedAt: _now(),
      );
      await checkpoints.save(checkpoint);
      if (cursor != null) continue;
      if (!wait || !_now().isBefore(deadline)) return null;
      await _sleep(enrollmentInterval);
    }
  }

  Future<DeviceSetupCheckpoint> _saveProjection(
    DeviceSetupCheckpoint checkpoint,
    EnrollmentRecoveryProjectionV1 projection,
    AdmissionProjectionStage stage,
  ) async {
    final updated = checkpoint.copyWith(
      enrollmentId: projection.proposal.json['enrollment_id']! as String,
      expectedProposalRevision: projection.proposalRevision,
      admissionState: switch (stage) {
        AdmissionProjectionStage.pendingReview =>
          DeviceAdmissionState.pendingReview,
        AdmissionProjectionStage.approvedAwaitingHandoff =>
          DeviceAdmissionState.approvedAwaitingHandoff,
        AdmissionProjectionStage.grantDelivered =>
          DeviceAdmissionState.grantDelivered,
        AdmissionProjectionStage.claimActive =>
          DeviceAdmissionState.claimActive,
        AdmissionProjectionStage.rejected ||
        AdmissionProjectionStage.expired ||
        AdmissionProjectionStage.canceled ||
        AdmissionProjectionStage.claimRevoked =>
          DeviceAdmissionState.rejected,
      },
      updatedAt: _now(),
      clearFailure: true,
    );
    await checkpoints.save(updated);
    return updated;
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
        descriptor.trust == SetupDescriptorTrustV1.developmentTofu) {
      throw const DeviceSetupException(
        code: 'untrusted_device_provisioning',
        message: 'Device provisioning is not bound to a product identity',
      );
    }
    // Only an offer that has a deadline can be past it. An offer with none is
    // the ordinary state of a device nobody has claimed yet, which is exactly
    // the device this whole flow exists to set up.
    final expiresAt = descriptor.expiresAt;
    if (expiresAt != null && expiresAt.isBefore(_now())) {
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

  String _commandId(String operation, String setupId) {
    final value = 'mobile-$operation-$setupId';
    if (value.length > 128) {
      throw const DeviceSetupException(
        code: 'setup_identity_invalid',
        message: 'Device Setup ID is too long for stable Admission commands',
      );
    }
    return value;
  }

  Future<void> _closeProvisioning(DeviceProvisioningSession? session) async {
    try {
      await session?.close();
    } catch (_) {
      // Durable workflow state is authoritative.
    }
    try {
      await transport.close();
    } catch (_) {
      // The next platform open/OS cycle cleans a stale link.
    }
  }
}

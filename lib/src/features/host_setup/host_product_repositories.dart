import 'dart:typed_data';

import '../device_management/mounted_device_models.dart';
import '../device_setup/device_setup_models.dart';
import '../../generated/device_foundation_v1.dart';
import 'activity_models.dart';
import 'companion_face_models.dart';
import 'controller_grant_models.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import 'host_product_session.dart';
import 'host_service_models.dart';
import 'host_vitals_models.dart';
import 'workspace_models.dart';
import 'workspace_runtime_models.dart';

class HostWorkspaceRepository {
  const HostWorkspaceRepository(this._session);

  final HostProductSession _session;

  Future<WorkspaceStatus> fetchStatus() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchWorkspace(
          baseUrl,
          accessToken: accessToken,
        ),
      );

  Future<WorkspaceStatus> initialize({
    required String ownerDisplayName,
    required String companionDisplayName,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.initializeWorkspace(
          baseUrl,
          accessToken: accessToken,
          ownerDisplayName: ownerDisplayName,
          companionDisplayName: companionDisplayName,
        ),
      );

  Future<WorkspaceRuntime> fetchRuntime() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchWorkspaceRuntime(
          baseUrl,
          accessToken: accessToken,
        ),
      );
}

class HostDeviceNamingRepository {
  HostDeviceNamingRepository(this._session);

  final HostProductSession _session;

  Future<MountedDevice> rename({
    required String deviceId,
    required String displayName,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.renameDevice(
          baseUrl,
          accessToken: accessToken,
          deviceId: deviceId,
          displayName: displayName,
        ),
      );
}

class HostDevicesRepository {
  const HostDevicesRepository(this._session);

  final HostProductSession _session;

  Future<MountedDeviceInventory> fetchMountedDevices() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchMountedDevices(
          baseUrl,
          accessToken: accessToken,
        ),
      );

  Future<DeviceRemovalProgress> remove({
    required String requestId,
    required String deviceId,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.removeDevice(
          baseUrl,
          accessToken: accessToken,
          requestId: requestId,
          deviceId: deviceId,
        ),
      );
}

class HostCompanionRepository {
  HostCompanionRepository(this._session);

  final HostProductSession _session;

  Future<CompanionFaceState> faceState({required String companionId}) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.fetchCompanionFaceState(
          baseUrl,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  Future<Uint8List?> face({required String companionId}) => _session.execute(
        (client, baseUrl, accessToken) => client.fetchCompanionFace(
          baseUrl,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  Future<CompanionFaceState> setFace({
    required String companionId,
    required Uint8List face,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.setCompanionFace(
          baseUrl,
          accessToken: accessToken,
          companionId: companionId,
          face: face,
        ),
      );

  Future<CompanionFaceState> clearFace({required String companionId}) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.clearCompanionFace(
          baseUrl,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  Future<String> rename({
    required String companionId,
    required String displayName,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.renameCompanion(
          baseUrl,
          accessToken: accessToken,
          companionId: companionId,
          displayName: displayName,
        ),
      );
}

/// What this Eidolon remembers.
/// Every Eidolon this Owner has, and what the Host says it can do.
///
/// The one repository here that speaks the management contract rather than
/// `/api/local/v1`. Kept apart for that reason: everything it returns is a
/// generated type, so nothing in this app hand-maintains a copy of that wire.
class HostManagementRepository {
  HostManagementRepository(this._session);

  final HostProductSession _session;

  Future<ManagementContextView> context() => _session.executeManagement(
        (client, baseUri, accessToken) =>
            client.fetchContext(baseUri, accessToken: accessToken),
      );

  Future<CompanionDetailView> companion({required String companionId}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchCompanion(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  /// Add another Eidolon. [operationId] must be stable across retries.
  Future<CreatedCompanion> createCompanion({
    required String operationId,
    required String displayName,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.createCompanion(
          baseUri,
          accessToken: accessToken,
          operationId: operationId,
          displayName: displayName,
        ),
      );

  /// What is remembered, by category. [companionId] selects an audience.
  Future<MemoryLibraryView> memoryLibrary({String? companionId}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchMemoryLibrary(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  /// What it wrote down since [since]. The window is the caller's.
  Future<MemoryDayView> memoryEntries({
    required DateTime since,
    int? limit,
    String? companionId,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchMemoryEntries(
          baseUri,
          accessToken: accessToken,
          since: since,
          limit: limit,
          companionId: companionId,
        ),
      );

  /// End every runtime session this Owner has.
  Future<RevokedSessionsView> revokeRuntimeSessions() =>
      _session.executeManagement(
        (client, baseUri, accessToken) =>
            client.revokeRuntimeSessions(baseUri, accessToken: accessToken),
      );

  /// When this Eidolon and I talked.
  Future<ConversationPageView> conversations({
    required String companionId,
    int? limit,
    String? cursor,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchConversations(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          limit: limit,
          cursor: cursor,
        ),
      );

  /// What was said in one conversation.
  Future<TranscriptView> transcript({
    required String companionId,
    required String conversationId,
    int? limit,
    String? cursor,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchTranscript(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          conversationId: conversationId,
          limit: limit,
          cursor: cursor,
        ),
      );

  /// What it was asked to do, and how far it has got.
  Future<TaskPageView> tasks({
    required String companionId,
    int? limit,
    String? status,
    String? cursor,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchTasks(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          limit: limit,
          status: status,
          cursor: cursor,
        ),
      );

  /// Stop a task. The Host answers with what it became.
  Future<TaskView> cancelTask({
    required String companionId,
    required String taskId,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.cancelTask(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          taskId: taskId,
        ),
      );

  /// Ask for a task again. The Host decides whether it can.
  Future<TaskView> retryTask({
    required String companionId,
    required String taskId,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.retryTask(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          taskId: taskId,
        ),
      );

  /// What this Eidolon has been.
  Future<PersonaHistoryView> personaHistory({required String companionId}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchPersonaHistory(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  /// Make it the way it was then. Idempotent: the chapter it already is
  /// succeeds rather than conflicting.
  Future<PersonaHistoryView> restorePersona({
    required String companionId,
    required String chapterId,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.restorePersona(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          chapterId: chapterId,
        ),
      );

  /// What it remembers about [query]. A sentence and a time, nothing about how
  /// it was found.
  Future<RecollectionsView> recollections({
    required String query,
    int limit = 10,
    String? companionId,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchRecollections(
          baseUri,
          accessToken: accessToken,
          query: query,
          limit: limit,
          companionId: companionId,
        ),
      );

  /// A copy of the whole visible memory. [companionId] selects an audience.
  Future<MemoryCopyView> memoryCopy({String? companionId}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchMemoryCopy(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  /// Keep one memory between the Owner and one Companion, or give it back.
  Future<MemoryAudienceView> assignMemoryAudience({
    required String entryId,
    String? companionId,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.assignMemoryAudience(
          baseUri,
          accessToken: accessToken,
          entryId: entryId,
          companionId: companionId,
        ),
      );

  /// What forgetting [target] would remove. Nothing changes.
  Future<ForgetProposalView> previewForget({
    required String target,
    String? action,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.previewForget(
          baseUri,
          accessToken: accessToken,
          target: target,
          action: action,
        ),
      );

  /// Forget exactly what a preview showed. The token is passed back unread.
  Future<ForgetResultView> confirmForget({required String confirmationToken}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.confirmForget(
          baseUri,
          accessToken: accessToken,
          confirmationToken: confirmationToken,
        ),
      );

  /// Make one of them the default. Returns where the pointer ended up.
  Future<CompanionDetailOutcome> setDefaultCompanion({
    required String companionId,
    required int expectedRevision,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.setDefaultCompanion(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          expectedRevision: expectedRevision,
        ),
      );

  /// One page. [cursor] is a value a previous page handed back, forwarded as-is.
  Future<CompanionRosterView> roster({String? cursor}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchRoster(
          baseUri,
          accessToken: accessToken,
          cursor: cursor,
        ),
      );
}

/// The person this Host answers to.
class HostOwnerRepository {
  HostOwnerRepository(this._session);

  final HostProductSession _session;

  Future<String> rename({required String displayName}) => _session.execute(
        (client, baseUrl, accessToken) => client.renameOwner(
          baseUrl,
          accessToken: accessToken,
          displayName: displayName,
        ),
      );
}

class HostControllerGrantRepository {
  HostControllerGrantRepository(this._session);

  final HostProductSession _session;

  Future<List<ControllerGrant>> list() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchControllers(
          baseUrl,
          accessToken: accessToken,
        ),
      );

  Future<ControllerInvitation> invite({required Duration ttl}) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.inviteController(
          baseUrl,
          accessToken: accessToken,
          ttl: ttl,
        ),
      );

  Future<void> revoke({required String controllerId}) => _session.execute(
        (client, baseUrl, accessToken) => client.revokeController(
          baseUrl,
          accessToken: accessToken,
          controllerId: controllerId,
        ),
      );
}

/// What has happened on this Host lately.
class HostActivityRepository {
  const HostActivityRepository(this._session);

  final HostProductSession _session;

  Future<HostActivity> list({int limit = 50}) => _session.execute(
        (client, baseUrl, accessToken) => client.fetchActivity(
          baseUrl,
          accessToken: accessToken,
          limit: limit,
        ),
      );
}

class HostServicesRepository {
  const HostServicesRepository(this._session);

  final HostProductSession _session;

  Future<HostVitals> vitals() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchHostVitals(
          baseUrl,
          accessToken: accessToken,
        ),
      );

  Future<HostServiceInventory> list() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchHostServices(
          baseUrl,
          accessToken: accessToken,
        ),
      );

  /// [expectedRevision] is the revision the screen displayed, not a re-read.
  Future<HostServiceChange> change({
    required String serviceId,
    required String operation,
    required int expectedRevision,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.changeHostService(
          baseUrl,
          accessToken: accessToken,
          serviceId: serviceId,
          operation: operation,
          expectedRevision: expectedRevision,
        ),
      );
}

class HostDeviceAdmissionRepository {
  const HostDeviceAdmissionRepository(this._session);

  final HostProductSession _session;

  Future<DeviceOnboardingTarget> fetchTarget() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchDeviceOnboardingTarget(
          baseUrl,
          accessToken: accessToken,
        ),
      );

  Future<EnrollmentProposalPageV1> listRecovery({
    required String ownerDomainId,
    AdmissionListCursorV1? after,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.fetchEnrollmentRecoveryPage(
          baseUrl,
          accessToken: accessToken,
          ownerDomainId: ownerDomainId,
          after: after,
        ),
      );

  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.fetchEnrollmentRecovery(
          baseUrl,
          accessToken: accessToken,
          enrollmentId: enrollmentId,
        ),
      );

  Future<AdmissionDecisionOutcome> decide({
    required String requestId,
    required String enrollmentId,
    required int expectedProposalRevision,
    required Map<String, dynamic> reviewedManifestRef,
    required String expectedOwnerDomainId,
    required String expectedBusinessOwnerId,
    String? initialCompanionId,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.decideEnrollment(
          baseUrl,
          accessToken: accessToken,
          requestId: requestId,
          enrollmentId: enrollmentId,
          expectedProposalRevision: expectedProposalRevision,
          reviewedManifestRef: reviewedManifestRef,
          expectedOwnerDomainId: expectedOwnerDomainId,
          expectedBusinessOwnerId: expectedBusinessOwnerId,
          initialCompanionId: initialCompanionId,
        ),
      );

  Future<ClaimPageV1> listClaims({
    required String ownerDomainId,
    AdmissionListCursorV1? after,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.fetchClaimPage(
          baseUrl,
          accessToken: accessToken,
          ownerDomainId: ownerDomainId,
          after: after,
        ),
      );
}

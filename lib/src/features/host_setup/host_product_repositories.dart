import 'dart:typed_data';

import '../device_management/mounted_device_models.dart';
import '../device_setup/device_setup_models.dart';
import '../../generated/device_foundation_v1.dart';
import 'activity_models.dart';
import 'home_models.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import 'host_product_session.dart';
import 'host_service_models.dart';
import 'host_vitals_models.dart';
import 'workspace_models.dart';

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

}

class HostDevicesRepository {
  const HostDevicesRepository(this._session);

  final HostProductSession _session;

  Future<MountedDeviceInventory> fetchMountedDevices() async =>
      MountedDeviceInventory.fromView(
        await _session.executeManagement(
          (client, baseUri, accessToken) => client.fetchDevices(
            baseUri,
            accessToken: accessToken,
          ),
        ),
      );

  Future<DeviceRemovalView> remove({
    required String requestId,
    required String deviceId,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.removeDevice(
          baseUri,
          accessToken: accessToken,
          requestId: requestId,
          deviceId: deviceId,
        ),
      );
}

class HostCompanionRepository {
  HostCompanionRepository(this._session);

  final HostProductSession _session;

  /// What it looks like, and which picture that is.
  ///
  /// One call: the answer carries the digest, so nothing has to ask a second
  /// time which face it just received. Passing [held] lets the Host answer
  /// "still that one" without sending a photograph again.
  Future<CompanionFacePicture> face({
    required String companionId,
    CompanionFacePicture? held,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchCompanionFace(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          held: held,
        ),
      );

  Future<CompanionFaceView> setFace({
    required String companionId,
    required Uint8List face,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.setCompanionFace(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          face: face,
        ),
      );

  Future<CompanionFaceView> clearFace({required String companionId}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.clearCompanionFace(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  /// Call it something else.
  ///
  /// Over the management contract, like everything else a person does to a
  /// Companion. The `/api/local/v1` route this used to call is deleted: two
  /// surfaces for one write is how the two come to disagree about what a name
  /// may be.
  Future<String> rename({
    required String companionId,
    required String displayName,
  }) async {
    final named = await _session.executeManagement(
      (client, baseUri, accessToken) => client.renameCompanion(
        baseUri,
        accessToken: accessToken,
        companionId: companionId,
        displayName: displayName,
      ),
    );
    return named.displayName ?? displayName;
  }
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
    PersonaAuthoring? persona,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.createCompanion(
          baseUri,
          accessToken: accessToken,
          operationId: operationId,
          displayName: displayName,
          persona: persona,
        ),
      );

  /// Who this Eidolon is now, in the words somebody wrote.
  Future<PersonaAuthoring> persona({required String companionId}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.fetchPersona(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  /// Say who this Eidolon is now. Appends a chapter; never edits one.
  Future<PersonaAuthoring> setPersona({
    required String companionId,
    required PersonaAuthoring persona,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.setPersona(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          persona: persona,
        ),
      );

  /// What the Host would write if the authoring form came back untouched.
  Future<PersonaAuthoring> personaAuthoringTemplate() =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.personaAuthoringTemplate(
          baseUri,
          accessToken: accessToken,
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

  /// Put one away, or bring it back.
  ///
  /// [replacementCompanionId] is only sent once the Host has asked for one: the
  /// rule about who must answer lives there, and a client that pre-empted it
  /// would be keeping a second copy of it.
  Future<CompanionLifecycleView> setCompanionLifecycle({
    required String companionId,
    required String lifecycleState,
    String? replacementCompanionId,
    int? expectedRevision,
  }) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.setCompanionLifecycle(
          baseUri,
          accessToken: accessToken,
          companionId: companionId,
          lifecycleState: lifecycleState,
          replacementCompanionId: replacementCompanionId,
          expectedRevision: expectedRevision,
        ),
      );

  /// What is mine, right now — the one read a screen makes when it opens.
  Future<HostHome> home() async => HostHome.fromView(
        await _session.executeManagement(
          (client, baseUri, accessToken) => client.fetchHome(
            baseUri,
            accessToken: accessToken,
          ),
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

  Future<String> rename({required String displayName}) async {
    final named = await _session.executeManagement(
      (client, baseUri, accessToken) => client.renameOwner(
        baseUri,
        accessToken: accessToken,
        displayName: displayName,
      ),
    );
    return named.displayName ?? displayName;
  }
}

class HostControllerGrantRepository {
  HostControllerGrantRepository(this._session);

  final HostProductSession _session;

  Future<List<ControllerView>> list() async {
    final answer = await _session.executeManagement(
      (client, baseUri, accessToken) => client.fetchControllers(
        baseUri,
        accessToken: accessToken,
      ),
    );
    return answer.controllers;
  }

  Future<ControllerInvitationView> invite({required Duration ttl}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.inviteController(
          baseUri,
          accessToken: accessToken,
          ttl: ttl,
        ),
      );

  Future<void> revoke({required String controllerId}) =>
      _session.executeManagement(
        (client, baseUri, accessToken) => client.revokeController(
          baseUri,
          accessToken: accessToken,
          controllerId: controllerId,
        ),
      );
}

/// What has happened on this Host lately.
class HostActivityRepository {
  const HostActivityRepository(this._session);

  final HostProductSession _session;

  Future<HostActivity> list({int limit = 50, String? cursor}) async =>
      HostActivity.fromView(
        await _session.executeManagement(
          (client, baseUri, accessToken) => client.fetchActivity(
            baseUri,
            accessToken: accessToken,
            limit: limit,
            cursor: cursor,
          ),
        ),
      );
}

class HostServicesRepository {
  const HostServicesRepository(this._session);

  final HostProductSession _session;

  /// The Host's own answers, turned into this app's domain on the way in.
  ///
  /// The shape comes from the generated views; the enums and labels are this
  /// app's, because "degraded" is a word the wire uses and 降级 is the word a
  /// person reads.
  Future<HostVitals> vitals() async => HostVitals.fromView(
        await _session.executeManagement(
          (client, baseUri, accessToken) => client.fetchHostVitals(
            baseUri,
            accessToken: accessToken,
          ),
        ),
      );

  Future<HostServiceInventory> list() async => HostServiceInventory.fromView(
        await _session.executeManagement(
          (client, baseUri, accessToken) => client.fetchHostServices(
            baseUri,
            accessToken: accessToken,
          ),
        ),
      );

  /// [expectedRevision] is the revision the screen displayed, not a re-read.
  Future<HostServiceChange> change({
    required String serviceId,
    required String operation,
    required int expectedRevision,
  }) async =>
      HostServiceChange.fromView(
        await _session.executeManagement(
          (client, baseUri, accessToken) => client.changeHostService(
            baseUri,
            accessToken: accessToken,
            serviceId: serviceId,
            operation: operation,
            expectedRevision: expectedRevision,
          ),
        ),
      );
}

class HostDeviceCompanionRepository {
  const HostDeviceCompanionRepository(this._session);

  final HostProductSession _session;

  Future<MountedDevice> set({
    required String deviceId,
    required String requestId,
    required String? companionId,
    required int expectedRevision,
  }) async =>
      MountedDevice.fromView(
        await _session.executeManagement(
          (client, baseUri, accessToken) => client.setDeviceCompanion(
            baseUri,
            accessToken: accessToken,
            deviceId: deviceId,
            requestId: requestId,
            companionId: companionId,
            expectedRevision: expectedRevision,
          ),
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

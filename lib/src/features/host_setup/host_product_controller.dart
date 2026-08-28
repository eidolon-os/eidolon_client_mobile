import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../device_management/mounted_device_models.dart';
import '../device_setup/device_setup_models.dart';
import '../device_setup/admission_projection.dart';
import '../setup/commissioning_transport.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/host_registry.dart';
import '../setup/setup_models.dart';
import '../setup/setup_trust.dart';
import 'activity_models.dart';
import 'home_models.dart';
import 'host_product_repositories.dart';
import 'host_product_session.dart';
import 'host_service_models.dart';
import 'host_vitals_models.dart';
import '../../generated/management_v1.dart';
import '../../generated/device_foundation_v1.dart';
import '../../management/management_client.dart';
import 'local_api_client.dart';
import 'local_api_discovery.dart';
import 'pinned_http_client.dart';
import 'workspace_models.dart';
import 'network_changes.dart';

typedef ManagedHostUpdater = Future<void> Function(ManagedHost host);

/// What is actually left to do about a connection that failed.
///
/// Almost every failure here is a network that will come back, and 「重新连接」
/// is the whole answer. One is not: when the Host's cryptographic identity no
/// longer matches what this phone saved, no amount of retrying can change it
/// back — a reinstalled Host issues a new key and keeps it. Offering only a
/// retry there is a promise the Host cannot keep, so the failure has to carry
/// which of the two it is.
enum HostConnectionRecovery {
  /// Try again.
  retry,

  /// This is not the Host this phone remembers. The ways forward are to stop
  /// managing it, or to reclaim it through a window opened at the Host.
  identityChanged,

  /// The Host is the right one and has revoked this phone's Grant. Connecting
  /// is precisely what fails, so the way back is to be claimed again — which
  /// somebody standing at the Host has to open the window for first.
  reclaimRequired,
}

class HostProductController extends ChangeNotifier {
  HostProductController({
    required ManagedHost host,
    required ManagedHostUpdater onHostUpdated,
    CommissioningTransport? transport,
    ControllerKeyBridge? controllerKeys,
    LocalApiDiscovery? discovery,
    LocalApiClientFactory? localApiClientFactory,
    ManagementClientFactory? managementClientFactory,
    NetworkChanges? networkChanges,
  })  : _host = host,
        _onHostUpdated = onHostUpdated,
        _networkChanges = networkChanges ?? PlatformNetworkChanges(),
        _session = HostProductSession(
          host: host,
          transport: transport,
          controllerKeys: controllerKeys,
          discovery: discovery,
          clientFactory: localApiClientFactory,
          managementClientFactory: managementClientFactory,
        ) {
    _workspaceRepository = HostWorkspaceRepository(_session);
    _devicesRepository = HostDevicesRepository(_session);
    _deviceAdmissionRepository = HostDeviceAdmissionRepository(_session);
    _deviceCompanionRepository = HostDeviceCompanionRepository(_session);
    _hostServicesRepository = HostServicesRepository(_session);
    _controllerGrantRepository = HostControllerGrantRepository(_session);
    _companionRepository = HostCompanionRepository(_session);
    _ownerRepository = HostOwnerRepository(_session);
    _activityRepository = HostActivityRepository(_session);
    _managementRepository = HostManagementRepository(_session);
    // Where the Host was is only true for as long as this phone is on the
    // network it learned it from. Watching for that keeps the recovery the
    // session already does from costing a timeout first.
    _networkSubscription =
        _networkChanges.changes.listen((_) => _session.invalidateLocation());
  }

  ManagedHost _host;
  final ManagedHostUpdater _onHostUpdated;
  final HostProductSession _session;
  final NetworkChanges _networkChanges;
  StreamSubscription<void>? _networkSubscription;
  late final HostWorkspaceRepository _workspaceRepository;
  late final HostDevicesRepository _devicesRepository;
  late final HostDeviceAdmissionRepository _deviceAdmissionRepository;
  late final HostDeviceCompanionRepository _deviceCompanionRepository;
  late final HostServicesRepository _hostServicesRepository;
  late final HostControllerGrantRepository _controllerGrantRepository;
  late final HostCompanionRepository _companionRepository;
  late final HostOwnerRepository _ownerRepository;
  late final HostActivityRepository _activityRepository;
  late final HostManagementRepository _managementRepository;

  bool _connecting = false;
  bool _workspaceBusy = false;
  bool _devicesBusy = false;
  bool _disposed = false;
  String? _progress;
  String? _connectionError;
  HostConnectionRecovery _connectionRecovery = HostConnectionRecovery.retry;
  HostProductConnection? _connection;
  WorkspaceStatus? _workspace;
  String? _workspaceError;
  HostHome? _home;

  /// What this Host says it can do at all, read once per connected session.
  ///
  /// Cached beside the other Host facts rather than fetched by each screen,
  /// because it is the same kind of fact: it changes when the Host changes, not
  /// while somebody is looking at a page. A screen that read it on open would
  /// make controls appear and disappear under a thumb; a screen that never read
  /// it is why a Host missing a credential still offered four features that
  /// could not work.
  ///
  /// Null means "not read yet", which is treated as no objection: a Host that
  /// has not answered must not make every feature look withdrawn.
  ManagementContextView? _managementContext;
  String? _homeError;
  MountedDeviceInventory? _devices;
  String? _devicesError;

  ManagedHost get host => _host;
  bool get connecting => _connecting;
  bool get workspaceBusy => _workspaceBusy;
  bool get devicesBusy => _devicesBusy;
  String? get progress => _progress;
  String? get connectionError => _connectionError;

  /// What [connectionError] leaves a person able to do. Meaningless while
  /// [connectionError] is null.
  HostConnectionRecovery get connectionRecovery => _connectionRecovery;
  HostProductConnection? get connection => _connection;
  WorkspaceStatus? get workspace => _workspace;
  String? get workspaceError => _workspaceError;

  /// What is mine, right now. Null while it has not been read, or when the
  /// Host refused — and [homeError] says which.
  HostHome? get home => _home;

  ManagementContextView? get managementCapabilities => _managementContext;
  String? get homeError => _homeError;
  MountedDeviceInventory? get devices => _devices;
  String? get devicesError => _devicesError;

  Future<void> connect() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    _progress = '正在连接';
    _connectionError = null;
    _connectionRecovery = HostConnectionRecovery.retry;
    _connection = null;
    _clearProductState();
    _notify();
    try {
      final previous = _host;
      final connectedHost = await _session.connect(
        onProgress: (message) {
          _progress = message;
          _notify();
        },
      );
      // The address it answered on is worth keeping for the same reason the
      // fingerprint is: next time, it is one less thing that has to be found.
      if (connectedHost.tlsSpkiFingerprint != previous.tlsSpkiFingerprint ||
          connectedHost.lastKnownBaseUrl != previous.lastKnownBaseUrl) {
        await _onHostUpdated(connectedHost);
      }
      _host = connectedHost;
      _connection = _session.connection;
      _progress = null;
      await _loadProductState();
    } on SetupTrustException catch (error) {
      // The Host answered and named itself as someone else. Same dead end as a
      // failed pin, reached one layer earlier.
      _failConnection(
        error.message,
        recovery: HostConnectionRecovery.identityChanged,
      );
    } on CommissioningRequestException catch (error) {
      _failConnection(error.message);
    } on HostControllerAuthorizationException catch (error) {
      _failAuthorization(error);
    } on LocalApiRequestException catch (error) {
      _failConnection(error.message);
    } on PinnedHttpException catch (error) {
      _failConnection(
        _pinnedHttpFailure(error),
        recovery: error.kind == PinnedHttpFailureKind.secureChannel
            ? HostConnectionRecovery.identityChanged
            : HostConnectionRecovery.retry,
      );
    } on PlatformException catch (error) {
      _failConnection(_platformError(error));
    } on FormatException catch (error) {
      _failConnection(error.message);
    } catch (_) {
      _failConnection('无法安全连接主机。请确认当前设备和主机连接同一 Wi-Fi 后重试。');
    } finally {
      _connecting = false;
      _notify();
    }
  }

  Future<void> refreshWorkspace() async {
    if (_workspaceBusy || _connection == null || _disposed) return;
    _workspaceBusy = true;
    _workspace = null;
    _workspaceError = null;
    _home = null;
    _homeError = null;
    _devices = null;
    _devicesError = null;
    _notify();
    try {
      await _loadProductState();
      _connection = _session.connection;
    } on HostControllerAuthorizationException catch (error) {
      _failAuthorization(error);
    } finally {
      _workspaceBusy = false;
      _notify();
    }
  }

  Future<void> initializeWorkspace({
    required String ownerDisplayName,
    required String companionDisplayName,
  }) async {
    if (_workspaceBusy || _connection == null || _disposed) return;
    final ownerName = ownerDisplayName.trim();
    final companionName = companionDisplayName.trim();
    if (ownerName.isEmpty || ownerName.length > 128) {
      _workspaceError = '请填写 1–128 个字符的称呼。';
      _notify();
      return;
    }
    if (companionName.isEmpty || companionName.length > 128) {
      _workspaceError = '请填写 1–128 个字符的 Eidolon 名称。';
      _notify();
      return;
    }

    _workspaceBusy = true;
    _workspaceError = null;
    _homeError = null;
    _notify();
    try {
      final workspace = await _workspaceRepository.initialize(
        ownerDisplayName: ownerName,
        companionDisplayName: companionName,
      );
      if (!workspace.isReady) {
        throw const FormatException('Workspace 初始化没有返回 ready');
      }
      _workspace = workspace;
      await _loadReadyWorkspaceResources(workspace);
      _connection = _session.connection;
    } on HostControllerAuthorizationException catch (error) {
      _failAuthorization(error);
    } on LocalApiRequestException catch (error) {
      _workspaceError = _workspaceFailure(error);
    } on PinnedHttpException catch (error) {
      _workspaceError = _pinnedHttpFailure(
        error,
        workspaceIsOptional: true,
      );
    } on FormatException {
      _workspaceError = '主机没有返回完整的 Workspace 结果，请重试。';
    } catch (_) {
      _workspaceError = 'Workspace 暂时未能完成；主机认领和 Wi-Fi 不会回滚。';
    } finally {
      _workspaceBusy = false;
      _notify();
    }
  }

  Future<void> refreshDevices() async {
    if (_devicesBusy || _connection == null || _disposed) return;
    _devicesBusy = true;
    _devicesError = null;
    _notify();
    try {
      await _loadDevices();
      _connection = _session.connection;
    } on HostControllerAuthorizationException catch (error) {
      _failAuthorization(error);
    } finally {
      _devicesBusy = false;
      _notify();
    }
  }

  Future<HostServiceInventory> listHostServices() =>
      _hostServicesRepository.list();

  /// How the machine is doing. Read when someone opens the page that shows
  /// it, not held here: a temperature from five minutes ago is not a
  /// temperature, and nothing else on this controller needs it.
  Future<HostVitals> hostVitals() => _hostServicesRepository.vitals();

  /// What has happened to this Owner's devices lately.
  ///
  /// Asked for when someone opens the screen that shows it, and never cached
  /// here: a history read once and held would keep answering with the moment
  /// this app last looked, which is the question nobody asked.
  Future<HostActivity> activity({int limit = 50}) =>
      _activityRepository.list(limit: limit);

  /// Name one of this Owner's devices.
  ///
  /// The inventory is re-read afterwards for the same reason the Companion's
  /// is: the Host is what a thing is called, and a screen editing its own copy
  /// would show a name the Host might not have accepted.
  /// Name this Owner's Eidolon.
  ///
  /// The runtime view is re-read afterwards rather than patched here: the Host
  /// is what a Companion is called, and a screen that edited its own copy
  /// would show a name the Host might not have accepted.
  Future<void> renameCompanion({
    required String companionId,
    required String displayName,
  }) async {
    await _companionRepository.rename(
      companionId: companionId,
      displayName: displayName,
    );
    await refreshWorkspace();
  }

  /// What this Eidolon looks like, as the Host last answered.
  ///
  /// The picture is held here rather than fetched by whoever is drawing it: a
  /// screen that re-read a photograph on every rebuild would spend a
  /// megabyte to show what it already had. It is re-read when the Host says
  /// the face changed — which is what the hash beside it is for.
  Uint8List? get companionFace => _face?.bytes;
  CompanionFacePicture? _face;

  /// Read the face, sending back the one already held.
  ///
  /// The Host answers "still that one" without spending a photograph on it, so
  /// this is cheap enough to call whenever the screen opens — which is the
  /// point: a picture that is only fetched once goes stale the first time the
  /// person changes it somewhere else.
  Future<void> loadCompanionFace({required String companionId}) async {
    final picture = await _companionRepository.face(
      companionId: companionId,
      held: _face,
    );
    if (_disposed) return;
    _face = picture;
    _notify();
  }

  Future<void> setCompanionFace({
    required String companionId,
    required Uint8List face,
  }) async {
    final state = await _companionRepository.setFace(
      companionId: companionId,
      face: face,
    );
    if (_disposed) return;
    // Shown from what was sent, and only because the Host accepted it and said
    // so with the same hash.
    _face = state.hasFace
        ? CompanionFacePicture(bytes: face, sha256: state.sha256)
        : const CompanionFacePicture.none();
    _notify();
  }

  Future<void> clearCompanionFace({required String companionId}) async {
    await _companionRepository.clearFace(companionId: companionId);
    if (_disposed) return;
    _face = const CompanionFacePicture.none();
    _notify();
  }

  /// Name the person this Host answers to.
  ///
  /// Nothing identifies them in the request: the session does. As with the
  /// Companion, the runtime view is re-read rather than patched here.
  Future<void> renameOwner({required String displayName}) async {
    await _ownerRepository.rename(displayName: displayName);
    await refreshWorkspace();
  }

  /// Ask it what it remembers about something.
  ///
  /// Not held on this controller: unlike the face or the name, an answer here
  /// belongs to one question someone just asked, and keeping the last one
  /// would show it again beside the next question.
  Future<RecollectionsView> recollections({
    required String companionId,
    required String query,
  }) =>
      _managementRepository.recollections(
        query: query,
        companionId: companionId,
      );

  /// Every Eidolon this Owner has.
  ///
  /// Not cached on this controller. The roster is what the Host says right now,
  /// and a stale copy held here would be a second answer to "what do I have" —
  /// the page asks when it opens and when a person asks for more.
  Future<CompanionRosterView> roster({String? cursor}) =>
      _managementRepository.roster(cursor: cursor);

  /// What is happening on this Host right now, lane by lane.
  Future<Map<String, Object?>> missionControlSnapshot() =>
      _managementRepository.missionControlSnapshot();

  /// One page of what has happened here, newest first.
  Future<Map<String, Object?>> activityHistory({String? cursor}) =>
      _managementRepository.activityHistory(cursor: cursor);

  /// One of them, opened.
  Future<CompanionDetailView> companion({required String companionId}) =>
      _managementRepository.companion(companionId: companionId);

  /// Add another Eidolon.
  ///
  /// The operation id comes from the screen that asked, not from here: it has
  /// to survive a retry, and a controller minting one per call would make every
  /// retry a new operation.
  Future<CreatedCompanion> createCompanion({
    required String operationId,
    required String displayName,
    PersonaAuthoring? persona,
  }) =>
      _managementRepository.createCompanion(
        operationId: operationId,
        displayName: displayName,
        persona: persona,
      );

  /// Who this Eidolon is now, in the words somebody wrote.
  Future<PersonaAuthoring> persona({required String companionId}) =>
      _managementRepository.persona(companionId: companionId);

  /// Say who this Eidolon is now.
  Future<PersonaAuthoring> setPersona({
    required String companionId,
    required PersonaAuthoring persona,
  }) =>
      _managementRepository.setPersona(
        companionId: companionId,
        persona: persona,
      );

  /// Who a new Eidolon would be if nobody said anything.
  Future<PersonaAuthoring> personaAuthoringTemplate() =>
      _managementRepository.personaAuthoringTemplate();

  /// Make one of them the one that answers when nothing named an Eidolon.
  ///
  /// [expectedRevision] comes from the context this app last read. Passing it
  /// through rather than looking it up here keeps "which version am I changing"
  /// a decision of the screen that showed the person that version.
  Future<CompanionDetailOutcome> setDefaultCompanion({
    required String companionId,
    required int expectedRevision,
  }) =>
      _managementRepository.setDefaultCompanion(
        companionId: companionId,
        expectedRevision: expectedRevision,
      );

  /// Put one of them away, or bring it back.
  Future<CompanionLifecycleView> setCompanionLifecycle({
    required String companionId,
    required String lifecycleState,
    String? replacementCompanionId,
  }) =>
      _managementRepository.setCompanionLifecycle(
        companionId: companionId,
        lifecycleState: lifecycleState,
        replacementCompanionId: replacementCompanionId,
      );

  /// What one of this Owner's Eidolons looks like.
  ///
  /// Not the cached face above: that one belongs to the Companion this Host
  /// runs by default, and holding a second Eidolon's picture in the same field
  /// would make the connection page show whichever was opened last.
  Future<CompanionFacePicture> companionFacePicture({
    required String companionId,
  }) =>
      _companionRepository.face(companionId: companionId);

  /// Call one of them something else, and answer with what the Host accepted.
  Future<String> renameOneCompanion({
    required String companionId,
    required String displayName,
  }) =>
      _companionRepository.rename(
        companionId: companionId,
        displayName: displayName,
      );

  /// What is remembered, by category.
  Future<MemoryLibraryView> memoryLibrary({String? companionId}) =>
      _managementRepository.memoryLibrary(companionId: companionId);

  Future<MemoryGraphView> memoryGraph({String? companionId}) =>
      _managementRepository.memoryGraph(companionId: companionId);

  /// What it wrote down since [since].
  Future<MemoryDayView> memoryEntries({
    required DateTime since,
    int? limit,
    String? companionId,
  }) =>
      _managementRepository.memoryEntries(
        since: since,
        limit: limit,
        companionId: companionId,
      );

  /// A copy of everything remembered that this Owner can see.
  Future<MemoryCopyView> memoryCopy({String? companionId}) =>
      _managementRepository.memoryCopy(companionId: companionId);

  /// Keep one memory between me and one of my Eidolons, or give it back.
  Future<MemoryAudienceView> assignMemoryAudience({
    required String entryId,
    String? companionId,
  }) =>
      _managementRepository.assignMemoryAudience(
        entryId: entryId,
        companionId: companionId,
      );

  /// What forgetting [target] would remove. Nothing changes.
  Future<ForgetProposalView> previewForget({
    required String target,
    String? action,
  }) =>
      _managementRepository.previewForget(target: target, action: action);

  /// Forget exactly what a preview showed.
  Future<ForgetResultView> confirmForget({required String confirmationToken}) =>
      _managementRepository.confirmForget(confirmationToken: confirmationToken);

  /// What this Host says it can do at all, for the authenticated Owner.
  Future<ManagementContextView> managementContext() =>
      _managementRepository.context();

  /// End every runtime session, so every device has to sign in again.
  Future<RevokedSessionsView> revokeRuntimeSessions() =>
      _managementRepository.revokeRuntimeSessions();

  /// When this Eidolon and I talked.
  Future<ConversationPageView> conversations({
    required String companionId,
    String? cursor,
  }) =>
      _managementRepository.conversations(
        companionId: companionId,
        cursor: cursor,
      );

  /// What was said in one conversation.
  Future<TranscriptView> transcript({
    required String companionId,
    required String conversationId,
    String? cursor,
  }) =>
      _managementRepository.transcript(
        companionId: companionId,
        conversationId: conversationId,
        cursor: cursor,
      );

  /// What it was asked to do, and how far it has got.
  Future<TaskPageView> tasks({required String companionId, String? cursor}) =>
      _managementRepository.tasks(companionId: companionId, cursor: cursor);

  /// Stop a task, or ask for it again. Either way the Host says what it became.
  Future<TaskView> cancelTask({
    required String companionId,
    required String taskId,
  }) =>
      _managementRepository.cancelTask(
          companionId: companionId, taskId: taskId);

  Future<TaskView> retryTask({
    required String companionId,
    required String taskId,
  }) =>
      _managementRepository.retryTask(companionId: companionId, taskId: taskId);

  /// Which phones hold this Host, as the Host says.
  Future<List<ControllerView>> listControllers() =>
      _controllerGrantRepository.list();

  /// Open a window in which one more phone may claim this Host.
  ///
  /// Asked for by a phone that already holds it, so the Host is never left
  /// deciding on its own who may join.
  Future<ControllerInvitationView> inviteController({
    Duration ttl = const Duration(minutes: 10),
  }) =>
      _controllerGrantRepository.invite(ttl: ttl);

  /// Withdraw one phone's authority over this Host.
  Future<void> revokeController({required String controllerId}) =>
      _controllerGrantRepository.revoke(controllerId: controllerId);

  /// The phone this App is running on, as this Host knows it.
  String get controllerId => _host.controllerId;

  /// [expectedRevision] must be the revision the caller displayed, so that a
  /// screen showing stale state loses the race instead of silently winning it.
  Future<HostServiceChange> changeHostService({
    required String serviceId,
    required String operation,
    required int expectedRevision,
  }) =>
      _hostServicesRepository.change(
        serviceId: serviceId,
        operation: operation,
        expectedRevision: expectedRevision,
      );

  Future<DeviceOnboardingTarget> fetchDeviceOnboardingTarget() {
    if (!(_workspace?.isReady ?? false)) {
      throw const HostControllerAuthorizationException(
        '请先完成 Owner Workspace，再添加设备',
      );
    }
    return _deviceAdmissionRepository.fetchTarget();
  }

  Future<EnrollmentProposalPageV1> listEnrollmentRecovery({
    AdmissionListCursorV1? after,
  }) async {
    if (!(_workspace?.isReady ?? false)) {
      throw const HostControllerAuthorizationException(
        '请先完成 Owner Workspace，再添加设备',
      );
    }
    final target = await _deviceAdmissionRepository.fetchTarget();
    return _deviceAdmissionRepository.listRecovery(
      ownerDomainId: target.ownerDomainId,
      after: after,
    );
  }

  /// The Host this Owner's devices are being set up for.
  Future<DeviceOnboardingTarget> deviceOnboardingTarget() =>
      _deviceAdmissionRepository.fetchTarget();

  Future<EnrollmentRecoveryProjectionV1> recoverEnrollment({
    required String enrollmentId,
  }) async {
    if (!(_workspace?.isReady ?? false)) {
      throw const HostControllerAuthorizationException(
        '请先完成 Owner Workspace，再读取设备接入状态',
      );
    }
    final projection = await _deviceAdmissionRepository.recover(
      enrollmentId: enrollmentId,
    );
    final target = await _deviceAdmissionRepository.fetchTarget();
    projection.validateForOwner(
      target.ownerDomainId,
      ownerDomainGeneration: target.ownerDomainDescriptor.ownerDomainGeneration,
    );
    return projection;
  }

  /// Records the Owner's one explicit approval for this Enrollment.
  ///
  /// The Host owns the Decision as a durable intent and re-reads the Authority
  /// afterwards, so this returns that projection rather than a second read of
  /// its own. [requestId] is the idempotency key: the same value resumes one
  /// intent, and a lost reply never becomes two Decisions.
  Future<EnrollmentRecoveryProjectionV1> decideEnrollment({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) async {
    final workspace = _workspace;
    final businessOwnerId = workspace?.owner?.ownerId;
    if (workspace == null || !workspace.isReady || businessOwnerId == null) {
      throw const HostControllerAuthorizationException(
        '请先完成 Owner Workspace，再认领设备',
      );
    }
    final target = await _deviceAdmissionRepository.fetchTarget();
    final ownerDomainGeneration =
        target.ownerDomainDescriptor.ownerDomainGeneration;
    final stage = projection.validateForOwner(
      target.ownerDomainId,
      ownerDomainGeneration: ownerDomainGeneration,
    );
    if (stage != AdmissionProjectionStage.pendingReview) {
      return projection;
    }
    final proposal = projection.proposal;
    final manifestRef = proposal.json['manifest_ref'];
    if (manifestRef is! Map) {
      throw const FormatException('Enrollment proposal has no Manifest');
    }
    final outcome = await _deviceAdmissionRepository.decide(
      requestId: requestId,
      enrollmentId: proposal.json['enrollment_id']! as String,
      expectedProposalRevision: projection.proposalRevision,
      reviewedManifestRef: Map<String, dynamic>.from(manifestRef),
      expectedOwnerDomainId: target.ownerDomainId,
      expectedBusinessOwnerId: businessOwnerId,
      initialCompanionId: initialCompanionId,
    );
    final recovered = outcome.recovery;
    recovered.validateForOwner(
      target.ownerDomainId,
      ownerDomainGeneration: ownerDomainGeneration,
    );
    final decision = recovered.approvalDecision;
    if (!outcome.isCommitted ||
        decision == null ||
        decision.json['decision_id'] != outcome.decisionId) {
      throw const FormatException('Committed Decision is absent from recovery');
    }
    if (decision.json['decision'] != 'approve') {
      throw const FormatException('Host recorded another Decision');
    }
    return recovered;
  }

  /// Bind a device to one Companion, or release it from the one it has.
  ///
  /// The device list is re-read afterwards rather than patched here: the mount
  /// is the Host's, and a screen that edited its own copy would show a binding
  /// the Host might have refused.
  Future<void> setDeviceCompanion({
    required String deviceId,
    required String requestId,
    required String? companionId,
    required int expectedRevision,
  }) async {
    if (_connection == null) {
      throw const HostControllerAuthorizationException(
        '请先安全连接主机，再关联 Companion',
      );
    }
    await _deviceCompanionRepository.set(
      deviceId: deviceId,
      requestId: requestId,
      companionId: companionId,
      expectedRevision: expectedRevision,
    );
    await refreshDevices();
  }

  /// Take a device off this Host at the Owner's request.
  ///
  /// A device the Host still holds cannot enroll again, so this is also the
  /// way back for a phone that lost its own credential — reinstalled, or
  /// restored onto different storage.
  Future<DeviceRemovalProgress> removeDevice({
    required String deviceId,
    required String requestId,
  }) async {
    if (_connection == null) {
      throw const HostControllerAuthorizationException('请先安全连接主机，再移除设备');
    }
    final progress = DeviceRemovalProgress.fromView(
      await _devicesRepository.remove(
        requestId: requestId,
        deviceId: deviceId,
      ),
    );
    await refreshDevices();
    return progress;
  }

  Future<void> _loadProductState() async {
    WorkspaceStatus workspace;
    try {
      workspace = await _workspaceRepository.fetchStatus();
    } on HostControllerAuthorizationException {
      rethrow;
    } on LocalApiRequestException catch (error) {
      _workspaceError = _workspaceFailure(error);
      return;
    } on PinnedHttpException catch (error) {
      _workspaceError = _pinnedHttpFailure(
        error,
        workspaceIsOptional: true,
      );
      return;
    } on FormatException {
      _workspaceError = '主机已安全连接，但 Workspace 返回了不兼容的数据。';
      return;
    } catch (_) {
      _workspaceError = '主机已安全接入，但 Workspace 服务暂时不可用。';
      return;
    }
    _workspace = workspace;
    if (!workspace.isReady) {
      _home = null;
      _homeError = null;
      _devices = null;
      _devicesError = null;
      return;
    }
    await _loadReadyWorkspaceResources(workspace);
  }

  Future<void> _loadReadyWorkspaceResources(WorkspaceStatus workspace) async {
    await _loadHome(workspace);
    await _loadCapabilities();
    await _loadDevices();
  }

  /// Ask once what this Host can do, and never let the answer be a failure.
  ///
  /// Swallowed on purpose: capabilities decide whether a *row* is offered, and
  /// a Host that could not answer must leave the rows alone rather than
  /// withdraw all of them. The features themselves still refuse per action, and
  /// those refusals now say which refusal they are.
  Future<void> _loadCapabilities() async {
    try {
      _managementContext = await _managementRepository.context();
    } on HostControllerAuthorizationException {
      rethrow;
    } catch (_) {
      _managementContext = null;
    }
  }

  String _homeFailure(ManagementRequestException error) =>
      switch (error.statusCode) {
        // The Host has no Owner yet: there is nothing for a home screen to be
        // about, which is a state of setup rather than a failure.
        409 => '这台主机还没有主人。',
        401 => '需要重新连接这台主机。',
        _ => '这台主机的概览暂时读不到。',
      };

  Future<void> _loadHome(WorkspaceStatus workspace) async {
    try {
      final home = await _managementRepository.home();
      if (!home.answersFor(workspace.workspace?.primaryCompanionId)) {
        // The Eidolon this device just helped create is not the one the Host
        // says answers. Showing it anyway would put somebody else's Companion
        // behind this person's name.
        _home = null;
        _homeError = '主机说的伙伴与刚刚建好的不是同一个，已拒绝展示。';
        return;
      }
      _home = home;
      _homeError = null;
    } on HostControllerAuthorizationException {
      rethrow;
    } on ManagementRequestException catch (error) {
      _home = null;
      _homeError = _homeFailure(error);
    } on PinnedHttpException catch (error) {
      _home = null;
      _homeError = '${_pinnedHttpFailure(error)} Workspace 已就绪，可稍后刷新。';
    } catch (_) {
      _home = null;
      _homeError = '这台主机的概览暂时读不到。';
    }
  }

  /// The Owner's bodies, read on the plane that actually serves them.
  ///
  /// This chain named `LocalApiRequestException` long after the read moved to
  /// the management plane, where a refusal arrives as
  /// `ManagementRequestException`. So every refusal the Host gave — a session
  /// that expired, a Workspace that does not exist yet, a Host too old to
  /// publish devices — fell through to the bare `catch` below and became
  /// 「设备列表暂时不可用。」 with no reason in it. On the star map that showed
  /// up as every Eidolon's 身体 moon reading 读不到, which is true and useless:
  /// the one thing the reader needed was *why*.
  Future<void> _loadDevices() async {
    try {
      _devices = await _devicesRepository.fetchMountedDevices();
      _devicesError = null;
    } on HostControllerAuthorizationException {
      rethrow;
    } on ManagementRequestException catch (error) {
      _devices = null;
      _devicesError = _managedDeviceFailure(error);
    } on PinnedHttpException catch (error) {
      _devices = null;
      _devicesError = _pinnedHttpFailure(error);
    } on FormatException {
      _devices = null;
      _devicesError = '主机返回了不兼容的设备列表。';
    } catch (error) {
      // Named, not swallowed. A failure this app has no word for is still a
      // failure somebody has to act on, and a sentence that erases its cause is
      // how 读不到 becomes the answer to every question.
      _devices = null;
      _devicesError = '设备列表暂时不可用：$error';
    }
  }

  void _clearProductState() {
    _workspace = null;
    _workspaceError = null;
    _home = null;
    _homeError = null;
    _devices = null;
    _devicesError = null;
  }

  /// A Grant refusal, told to the screen with what is actually left to do.
  ///
  /// Every path that can meet this refusal goes through here, because the
  /// distinction it carries is worthless if three of the four callers drop it.
  void _failAuthorization(HostControllerAuthorizationException error) =>
      _failConnection(
        error.message,
        recovery: error.reclaimRequired
            ? HostConnectionRecovery.reclaimRequired
            : HostConnectionRecovery.retry,
      );

  void _failConnection(
    String message, {
    HostConnectionRecovery recovery = HostConnectionRecovery.retry,
  }) {
    _connection = null;
    _connectionError = message;
    _connectionRecovery = recovery;
    _progress = null;
    _clearProductState();
  }

  String _platformError(PlatformException error) => switch (error.code) {
        'NOT_FOUND' => '局域网中没有发现主机。请确认当前设备和主机连接同一 Wi-Fi。',
        'DISCOVERY_FAILED' => 'Android 无法启动局域网发现，请稍后重试。',
        'BLUETOOTH_OFF' => '请先打开蓝牙，以确认已保存主机的本地连接身份。',
        'PERMISSION_DENIED' => '需要“附近设备”权限来确认主机身份。',
        _ => error.message ?? '当前设备无法完成本地主机连接',
      };

  String _pinnedHttpFailure(
    PinnedHttpException error, {
    bool workspaceIsOptional = false,
  }) {
    final message = switch (error.kind) {
      PinnedHttpFailureKind.invalidRequest =>
        'App 无法构造有效的本地管理请求，请更新或重新安装当前开发版本。',
      PinnedHttpFailureKind.unsupportedPlatform => '当前平台尚未实现安全的本地主机连接。',
      PinnedHttpFailureKind.secureChannel => '主机的加密身份与已保存身份不一致，已拒绝连接。',
      PinnedHttpFailureKind.timeout => '主机已找到，但本地管理请求超时。',
      PinnedHttpFailureKind.unreachable => '主机地址已找到，但当前网络无法到达该地址。',
      PinnedHttpFailureKind.io => '与主机的本地安全连接在传输过程中中断。',
      PinnedHttpFailureKind.platform => '当前设备的本地安全连接组件暂时不可用。',
    };
    if (!workspaceIsOptional) return message;
    return '$message 主机认领和 Wi-Fi 不会回滚，可稍后继续 Workspace。';
  }

  String _workspaceFailure(LocalApiRequestException error) =>
      switch (error.statusCode) {
        401 => '本次管理会话已失效，请重新连接主机。',
        409 => '主机的 Owner 绑定与 Workspace 不一致，已停止继续设置。',
        422 => 'Workspace 名称未被主机接受，请检查后重试。',
        _ => '主机已安全接入，但 Workspace 服务暂时不可用。认领和 Wi-Fi 不会回滚。',
      };

  /// Why the bodies could not be read, in the words of the plane that refused.
  ///
  /// The refusal envelope is already carried on the exception, so this only has
  /// to choose the sentence for the ones this app understands and hand the rest
  /// the Host's own — ten screens each inventing wording is the shape of the bug
  /// `ManagementRequestException` exists to end.
  String _managedDeviceFailure(ManagementRequestException error) =>
      switch (error.statusCode) {
        401 => '本次管理会话已失效，请重新连接主机。',
        403 => '这台主机没有把设备清单交给这台手机。',
        404 => '当前主机版本尚未提供设备列表。',
        409 => '主机尚未建立 Owner Workspace，不能读取设备。',
        503 => '主机连着，但设备清单的上游没有回应：${error.message}',
        _ => '读不到设备清单：${error.message}',
      };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_networkSubscription?.cancel());
    unawaited(_networkChanges.close());
    unawaited(_session.close());
    super.dispose();
  }
}

/// How long a just-commissioned device is given to finish arriving.
///
/// It has to leave the setup access point, join the network it was given (up to
/// 25s before the firmware gives up on it), find the Host and enroll — while
/// the phone is separately finding its own way back onto the home network. This
/// is the sum of two waits, neither of which this side controls, so it is set
/// well above what either takes rather than at the edge of what both do.

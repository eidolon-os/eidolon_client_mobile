import '../device_management/mounted_device_models.dart';
import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_ports.dart';
import 'controller_grant_models.dart';
import 'persona_history_models.dart';
import 'host_product_session.dart';
import 'host_service_models.dart';
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

  Future<PersonaHistory> personaHistory({required String companionId}) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.fetchPersonaHistory(
          baseUrl,
          accessToken: accessToken,
          companionId: companionId,
        ),
      );

  Future<PersonaHistory> restorePersona({
    required String companionId,
    required String chapterId,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.restorePersona(
          baseUrl,
          accessToken: accessToken,
          companionId: companionId,
          chapterId: chapterId,
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

class HostServicesRepository {
  const HostServicesRepository(this._session);

  final HostProductSession _session;

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

class HostDeviceAdmissionRepository implements DeviceAdmissionPort {
  const HostDeviceAdmissionRepository(this._session);

  final HostProductSession _session;

  Future<DeviceOnboardingTarget> fetchTarget() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchDeviceOnboardingTarget(
          baseUrl,
          accessToken: accessToken,
        ),
      );

  @override
  Future<List<PendingDeviceEnrollment>> listPending() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchPendingDeviceEnrollments(
          baseUrl,
          accessToken: accessToken,
        ),
      );

  @override
  Future<DeviceAdmissionProgress> approve({
    required String requestId,
    required String deviceId,
    String? companionId,
  }) =>
      _session.execute(
        (client, baseUrl, accessToken) => client.approveDeviceEnrollment(
          baseUrl,
          accessToken: accessToken,
          requestId: requestId,
          deviceId: deviceId,
          companionId: companionId,
        ),
      );
}

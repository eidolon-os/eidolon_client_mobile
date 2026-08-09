import '../device_management/mounted_device_models.dart';
import 'host_product_session.dart';
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

class HostDevicesRepository {
  const HostDevicesRepository(this._session);

  final HostProductSession _session;

  Future<MountedDeviceInventory> fetchMountedDevices() => _session.execute(
        (client, baseUrl, accessToken) => client.fetchMountedDevices(
          baseUrl,
          accessToken: accessToken,
        ),
      );
}

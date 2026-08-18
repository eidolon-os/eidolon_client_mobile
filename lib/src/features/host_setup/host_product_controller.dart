import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../device_management/mounted_device_models.dart';
import '../device_setup/device_setup_models.dart';
import '../setup/commissioning_transport.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/host_registry.dart';
import '../setup/setup_models.dart';
import '../setup/setup_trust.dart';
import 'activity_models.dart';
import 'controller_grant_models.dart';
import 'host_product_repositories.dart';
import 'host_product_session.dart';
import 'host_service_models.dart';
import 'host_vitals_models.dart';
import 'local_api_client.dart';
import 'local_api_discovery.dart';
import 'persona_history_models.dart';
import 'recollection_models.dart';
import 'pinned_http_client.dart';
import 'workspace_models.dart';
import 'network_changes.dart';
import 'workspace_runtime_models.dart';

typedef ManagedHostUpdater = Future<void> Function(ManagedHost host);

class HostProductController extends ChangeNotifier {
  HostProductController({
    required ManagedHost host,
    required ManagedHostUpdater onHostUpdated,
    CommissioningTransport? transport,
    ControllerKeyBridge? controllerKeys,
    LocalApiDiscovery? discovery,
    LocalApiClientFactory? localApiClientFactory,
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
        ) {
    _workspaceRepository = HostWorkspaceRepository(_session);
    _devicesRepository = HostDevicesRepository(_session);
    _deviceAdmissionRepository = HostDeviceAdmissionRepository(_session);
    _hostServicesRepository = HostServicesRepository(_session);
    _controllerGrantRepository = HostControllerGrantRepository(_session);
    _companionRepository = HostCompanionRepository(_session);
    _ownerRepository = HostOwnerRepository(_session);
    _recollectionsRepository = HostRecollectionsRepository(_session);
    _activityRepository = HostActivityRepository(_session);
    _deviceNamingRepository = HostDeviceNamingRepository(_session);
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
  late final HostServicesRepository _hostServicesRepository;
  late final HostControllerGrantRepository _controllerGrantRepository;
  late final HostCompanionRepository _companionRepository;
  late final HostOwnerRepository _ownerRepository;
  late final HostRecollectionsRepository _recollectionsRepository;
  late final HostActivityRepository _activityRepository;
  late final HostDeviceNamingRepository _deviceNamingRepository;

  bool _connecting = false;
  bool _workspaceBusy = false;
  bool _devicesBusy = false;
  bool _disposed = false;
  String? _progress;
  String? _connectionError;
  HostProductConnection? _connection;
  WorkspaceStatus? _workspace;
  String? _workspaceError;
  WorkspaceRuntime? _workspaceRuntime;
  String? _workspaceRuntimeError;
  MountedDeviceInventory? _devices;
  String? _devicesError;

  ManagedHost get host => _host;
  bool get connecting => _connecting;
  bool get workspaceBusy => _workspaceBusy;
  bool get devicesBusy => _devicesBusy;
  String? get progress => _progress;
  String? get connectionError => _connectionError;
  HostProductConnection? get connection => _connection;
  WorkspaceStatus? get workspace => _workspace;
  String? get workspaceError => _workspaceError;
  WorkspaceRuntime? get workspaceRuntime => _workspaceRuntime;
  String? get workspaceRuntimeError => _workspaceRuntimeError;
  MountedDeviceInventory? get devices => _devices;
  String? get devicesError => _devicesError;

  Future<void> connect() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    _progress = '正在连接';
    _connectionError = null;
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
      _failConnection(error.message);
    } on CommissioningRequestException catch (error) {
      _failConnection(error.message);
    } on HostControllerAuthorizationException catch (error) {
      _failConnection(error.message);
    } on LocalApiRequestException catch (error) {
      _failConnection(error.message);
    } on PinnedHttpException catch (error) {
      _failConnection(_pinnedHttpFailure(error));
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
    _workspaceRuntime = null;
    _workspaceRuntimeError = null;
    _devices = null;
    _devicesError = null;
    _notify();
    try {
      await _loadProductState();
      _connection = _session.connection;
    } on HostControllerAuthorizationException catch (error) {
      _failConnection(error.message);
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
    _workspaceRuntimeError = null;
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
      _failConnection(error.message);
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
      _failConnection(error.message);
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
  Future<void> renameDevice({
    required String deviceId,
    required String displayName,
  }) async {
    await _deviceNamingRepository.rename(
      deviceId: deviceId,
      displayName: displayName,
    );
    await refreshDevices();
  }

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
  Uint8List? get companionFace => _companionFace;
  Uint8List? _companionFace;
  String? _companionFaceSha256;

  Future<void> loadCompanionFace({required String companionId}) async {
    final state = await _companionRepository.faceState(
      companionId: companionId,
    );
    if (_disposed) return;
    if (!state.hasFace) {
      _companionFace = null;
      _companionFaceSha256 = null;
      _notify();
      return;
    }
    if (state.matches(_companionFaceSha256) && _companionFace != null) return;
    final face = await _companionRepository.face(companionId: companionId);
    if (_disposed) return;
    _companionFace = face;
    _companionFaceSha256 = state.sha256;
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
    // Shown from what was sent, and only because the Host accepted it and
    // said so with the same hash.
    _companionFace = state.hasFace ? face : null;
    _companionFaceSha256 = state.sha256;
    _notify();
  }

  Future<void> clearCompanionFace({required String companionId}) async {
    await _companionRepository.clearFace(companionId: companionId);
    if (_disposed) return;
    _companionFace = null;
    _companionFaceSha256 = null;
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
  Future<Recollections> recollections({required String query}) =>
      _recollectionsRepository.search(query: query);

  /// What this Eidolon has been.
  Future<PersonaHistory> personaHistory({required String companionId}) =>
      _companionRepository.personaHistory(companionId: companionId);

  /// Make it the way it was then, and re-read the workspace so what is shown
  /// afterwards is what the Host now says it is.
  Future<PersonaHistory> restorePersona({
    required String companionId,
    required String chapterId,
  }) async {
    final history = await _companionRepository.restorePersona(
      companionId: companionId,
      chapterId: chapterId,
    );
    await refreshWorkspace();
    return history;
  }

  /// Which phones hold this Host, as the Host says.
  Future<List<ControllerGrant>> listControllers() =>
      _controllerGrantRepository.list();

  /// Open a window in which one more phone may claim this Host.
  ///
  /// Asked for by a phone that already holds it, so the Host is never left
  /// deciding on its own who may join.
  Future<ControllerInvitation> inviteController({
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

  Future<List<PendingDeviceEnrollment>> listPendingDeviceEnrollments() {
    if (!(_workspace?.isReady ?? false)) {
      throw const HostControllerAuthorizationException(
        '请先完成 Owner Workspace，再添加设备',
      );
    }
    return _deviceAdmissionRepository.listPending();
  }

  /// The Host this Owner's devices are being set up for.
  Future<DeviceOnboardingTarget> deviceOnboardingTarget() =>
      _deviceAdmissionRepository.fetchTarget();

  /// Finish setting up a device that was just commissioned by this Controller.
  ///
  /// The person already confirmed this device when they handed it the Host, so
  /// they are not asked to approve it a second time. The device still has to
  /// boot, join the network and enroll, which is why this waits for it to
  /// appear rather than assuming it already has.
  Future<DeviceAdmissionProgress> claimCommissionedDevice({
    required String deviceId,
    Duration timeout = commissionedClaimTimeout,
    Duration interval = commissionedClaimInterval,
  }) =>
      claimWhenBothEndsAreBack(
        deviceId: deviceId,
        listPending: listPendingDeviceEnrollments,
        approve: () => approveDeviceEnrollment(
          requestId: 'device-commissioned-$deviceId',
          deviceId: deviceId,
        ),
        timeout: timeout,
        interval: interval,
      );

  Future<DeviceAdmissionProgress> approveDeviceEnrollment({
    required String requestId,
    required String deviceId,
  }) async {
    final workspace = _workspace;
    if (workspace == null || !workspace.isReady) {
      throw const HostControllerAuthorizationException(
        '请先完成 Owner Workspace，再认领设备',
      );
    }
    final progress = await _deviceAdmissionRepository.approve(
      requestId: requestId,
      deviceId: deviceId,
      companionId: workspace.workspace?.primaryCompanionId,
    );
    if (progress.outcome == ActOutcome.done) {
      await refreshDevices();
    }
    return progress;
  }

  /// Take a device off this Host at the Owner's request.
  ///
  /// A device the Host still holds cannot enroll again, so this is also the
  /// way back for a phone that lost its own credential — reinstalled, or
  /// restored onto different storage.
  Future<DeviceRemovalProgress> removeDevice({
    required String deviceId,
  }) async {
    if (_connection == null) {
      throw const HostControllerAuthorizationException('请先安全连接主机，再移除设备');
    }
    final progress = await _devicesRepository.remove(
      requestId: _removalRequestId(deviceId),
      deviceId: deviceId,
    );
    await refreshDevices();
    return progress;
  }

  /// Stable per device, so a retry after a dropped reply resumes the same
  /// removal instead of starting a second one. The tail of the device id is
  /// kept when it is too long to fit, because that is where its entropy is.
  static String _removalRequestId(String deviceId) {
    const room = 113;
    final tail = deviceId.length <= room
        ? deviceId
        : deviceId.substring(deviceId.length - room);
    return 'device-removal-$tail';
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
      _workspaceRuntime = null;
      _workspaceRuntimeError = null;
      _devices = null;
      _devicesError = null;
      return;
    }
    await _loadReadyWorkspaceResources(workspace);
  }

  Future<void> _loadReadyWorkspaceResources(WorkspaceStatus workspace) async {
    await _loadRuntime(workspace);
    await _loadDevices();
  }

  Future<void> _loadRuntime(WorkspaceStatus workspace) async {
    try {
      final runtime = await _workspaceRepository.fetchRuntime();
      if (!runtime.matchesWorkspace(workspace)) {
        _workspaceRuntime = null;
        _workspaceRuntimeError =
            'Workspace 与日常运行状态不一致，已拒绝展示跨 Owner 或 Companion 数据。';
        return;
      }
      _workspaceRuntime = runtime;
      _workspaceRuntimeError = null;
    } on HostControllerAuthorizationException {
      rethrow;
    } on LocalApiRequestException catch (error) {
      _workspaceRuntime = null;
      _workspaceRuntimeError = _workspaceRuntimeFailure(error);
    } on PinnedHttpException catch (error) {
      _workspaceRuntime = null;
      _workspaceRuntimeError =
          '${_pinnedHttpFailure(error)} Workspace 已就绪，可稍后刷新日常状态。';
    } on FormatException {
      _workspaceRuntime = null;
      _workspaceRuntimeError = '主机返回了不兼容的日常运行状态。';
    } catch (_) {
      _workspaceRuntime = null;
      _workspaceRuntimeError = 'Eidolon 日常运行状态暂时不可用。';
    }
  }

  Future<void> _loadDevices() async {
    try {
      _devices = await _devicesRepository.fetchMountedDevices();
      _devicesError = null;
    } on HostControllerAuthorizationException {
      rethrow;
    } on LocalApiRequestException catch (error) {
      _devices = null;
      _devicesError = _deviceFailure(error);
    } on PinnedHttpException catch (error) {
      _devices = null;
      _devicesError = _pinnedHttpFailure(error);
    } on FormatException {
      _devices = null;
      _devicesError = '主机返回了不兼容的设备列表。';
    } catch (_) {
      _devices = null;
      _devicesError = '设备列表暂时不可用。';
    }
  }

  void _clearProductState() {
    _workspace = null;
    _workspaceError = null;
    _workspaceRuntime = null;
    _workspaceRuntimeError = null;
    _devices = null;
    _devicesError = null;
  }

  void _failConnection(String message) {
    _connection = null;
    _connectionError = message;
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

  String _workspaceRuntimeFailure(LocalApiRequestException error) =>
      switch (error.statusCode) {
        401 => '本次管理会话已失效，请重新连接主机。',
        404 => '主机尚未提供日常运行状态接口；Workspace 本身已就绪。',
        409 => 'Workspace 已创建，但主 Companion 的运行资源尚未一致。',
        _ => 'Workspace 已就绪，但日常运行状态暂时不可用。',
      };

  String _deviceFailure(LocalApiRequestException error) =>
      switch (error.statusCode) {
        401 => '本次管理会话已失效，请重新连接主机。',
        409 => '主机尚未建立 Owner Workspace，不能读取设备。',
        404 => '当前主机版本尚未提供设备列表。',
        _ => '主机已连接，但设备列表暂时不可用。',
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
const commissionedClaimTimeout = Duration(seconds: 150);
const commissionedClaimInterval = Duration(seconds: 3);

/// Wait for a commissioned device to reach the Host, then claim it.
///
/// Both ends are still finding their way back when this starts. The phone has
/// just let go of the device's access point, and Android does not hand the home
/// network back in the same breath — the first call after that handover reaches
/// nothing at all. Treating that as a failed setup is what reported success as
/// failure: the device was already commissioned and about to enroll.
///
/// So an unreachable Host is one of the things being waited for, alongside a
/// device that has not enrolled yet. What is *not* waited on is a Host that
/// answered: a refusal is something it decided, and it gets to say so at once.
@visibleForTesting
Future<DeviceAdmissionProgress> claimWhenBothEndsAreBack({
  required String deviceId,
  required Future<List<PendingDeviceEnrollment>> Function() listPending,
  required Future<DeviceAdmissionProgress> Function() approve,
  Duration timeout = commissionedClaimTimeout,
  Duration interval = commissionedClaimInterval,
  DateTime Function() clock = DateTime.now,
  Future<void> Function(Duration) sleep = _sleep,
}) async {
  final deadline = clock().add(timeout);
  // Which of the two waits is still outstanding, because they are different
  // things to tell the person.
  var hostOutOfReach = false;
  while (true) {
    try {
      final pending = await listPending();
      hostOutOfReach = false;
      if (pending.any((enrollment) => enrollment.deviceId == deviceId)) {
        return approve();
      }
    } on PinnedHttpException catch (error) {
      if (!_hostMayNotBeBackYet(error)) rethrow;
      hostOutOfReach = true;
    }
    if (!clock().isBefore(deadline)) {
      throw HostControllerAuthorizationException(
        hostOutOfReach
            ? '手机还没有回到家庭 Wi-Fi，暂时联系不上主机；'
                '设备已经配好，回到设备页就能认领它'
            : '设备还没有连上主机；等它上线后可以在设备页认领它',
      );
    }
    await sleep(interval);
  }
}

Future<void> _sleep(Duration duration) => Future<void>.delayed(duration);

/// Whether this failure is the transport being absent rather than the Host
/// having an answer. A pinned channel that could not be opened, timed out, or
/// broke mid-flight never reached the Host; anything else did.
bool _hostMayNotBeBackYet(PinnedHttpException error) => switch (error.kind) {
      PinnedHttpFailureKind.unreachable ||
      PinnedHttpFailureKind.timeout ||
      PinnedHttpFailureKind.io =>
        true,
      _ => false,
    };

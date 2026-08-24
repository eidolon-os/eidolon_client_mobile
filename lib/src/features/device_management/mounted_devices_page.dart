import 'dart:math';

import 'package:flutter/material.dart';

import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_checkpoint_store.dart';
import '../naming/ask_for_a_name.dart';
import '../device_setup/device_setup_ports.dart';
import '../device_setup/device_admission_page.dart';
import '../device_setup/device_setup_page.dart';
import '../device_setup/host_controller_device_admission.dart';
import '../device_setup/platform_device_provisioning.dart';
import '../host_setup/host_product_controller.dart';
import 'mounted_device_models.dart';

class MountedDevicesPage extends StatefulWidget {
  const MountedDevicesPage({
    super.key,
    required this.controller,
    this.deviceProvisioning,
    this.checkpoints,
  });

  final HostProductController controller;

  /// Supplied by tests; production builds get the protocomm adapter, which is
  /// the only transport this app speaks to a device.
  final DeviceProvisioningTransport? deviceProvisioning;
  final DeviceSetupCheckpointStore? checkpoints;

  @override
  State<MountedDevicesPage> createState() => _MountedDevicesPageState();
}

class _MountedDevicesPageState extends State<MountedDevicesPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _openProvisioning() async {
    final admission = HostControllerDeviceAdmission(widget.controller);
    final transport = widget.deviceProvisioning ?? PlatformDeviceProvisioning();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DeviceSetupPage(
          transport: transport,
          admission: admission,
          checkpoints:
              widget.checkpoints ?? PersistentDeviceSetupCheckpointStore(),
          loadTarget: widget.controller.deviceOnboardingTarget,
        ),
      ),
    );
    if (mounted) await widget.controller.refreshDevices();
  }

  Future<void> _openAdmission() async {
    final target = await widget.controller.fetchDeviceOnboardingTarget();
    final owner = widget.controller.workspace?.owner;
    final connection = widget.controller.connection;
    if (!mounted || owner == null || connection == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DeviceAdmissionPage(
          ownerDomainId: target.ownerDomainId,
          ownerDomainGeneration:
              target.ownerDomainDescriptor.ownerDomainGeneration,
          businessOwnerId: owner.ownerId,
          controllerId: connection.controllerId,
          loadRecovery: widget.controller.listEnrollmentRecovery,
          onDecide: ({
            required commandId,
            required correlationId,
            required projection,
          }) =>
              widget.controller.decideEnrollment(
            commandId: commandId,
            correlationId: correlationId,
            projection: projection,
            initialCompanionId:
                widget.controller.workspace?.workspace?.primaryCompanionId,
          ),
        ),
      ),
    );
    if (mounted) await widget.controller.refreshDevices();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final inventory = controller.devices;
    return Scaffold(
      key: const Key('mounted-devices-page'),
      appBar: AppBar(
        title: const Text('设备'),
        actions: [
          IconButton(
            key: const Key('refresh-mounted-devices'),
            onPressed:
                controller.devicesBusy ? null : controller.refreshDevices,
            tooltip: '刷新设备',
            icon: controller.devicesBusy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _InventoryMeaningCard(),
          if (controller.devicesError case final error?) ...[
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(error, key: const Key('mounted-devices-error')),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed:
                  controller.devicesBusy ? null : controller.refreshDevices,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
          ] else if (inventory == null || inventory.devices.isEmpty) ...[
            const SizedBox(height: 24),
            const Center(
              child: Text(
                '还没有已接入的设备。',
                key: Key('mounted-devices-empty'),
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            ...inventory.devices.map(
              (device) => _MountedDeviceCard(
                device: device,
                onRemove: (deviceId, requestId) => controller.removeDevice(
                  deviceId: deviceId,
                  requestId: requestId,
                ),
                onRename: (deviceId, displayName) => controller.renameDevice(
                  deviceId: deviceId,
                  displayName: displayName,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('pair-device-from-product'),
            onPressed: controller.devicesBusy ? null : _openAdmission,
            icon: const Icon(Icons.playlist_add_check),
            label: const Text('认领待接入设备'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('provision-device-from-product'),
            onPressed: controller.devicesBusy ? null : _openProvisioning,
            icon: const Icon(Icons.add_link),
            label: const Text('配置新设备网络（开发）'),
          ),
          const SizedBox(height: 8),
          Text(
            '认领与 Wi-Fi 配网是两个独立步骤。兼容热点入口只配置网络；设备连接 Hub 并进入待认领状态后，再由你确认绑定。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _InventoryMeaningCard extends StatelessWidget {
  const _InventoryMeaningCard();

  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.verified_outlined),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  '这里仅显示由主机权威确认挂载到当前 Owner 的设备。配网完成但尚未安全认领的设备不会出现在这里。',
                ),
              ),
            ],
          ),
        ),
      );
}

class _MountedDeviceCard extends StatelessWidget {
  const _MountedDeviceCard({
    required this.device,
    required this.onRemove,
    required this.onRename,
  });

  final MountedDevice device;
  final Future<DeviceRemovalProgress> Function(
    String deviceId,
    String requestId,
  ) onRemove;
  final Future<void> Function(String deviceId, String displayName)? onRename;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (device.admissionState) {
      MountedDeviceAdmissionState.ready => (
          '已接入',
          Theme.of(context).colorScheme.primary,
        ),
      MountedDeviceAdmissionState.mounted => (
          '待关联 Companion',
          Theme.of(context).colorScheme.tertiary,
        ),
    };
    return Card(
      child: ListTile(
        key: Key('mounted-device-${device.deviceId}'),
        contentPadding: const EdgeInsets.all(16),
        leading: Icon(Icons.developer_board_outlined, color: color),
        title: Text(device.label),
        // What kind of thing it is. The revision is a fact about a mount
        // record, and nobody reading this list is asking about a mount record.
        subtitle: Text(device.detail),
        trailing: Chip(label: Text(label)),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => MountedDeviceDetailPage(
              device: device,
              onRemove: onRemove,
            ),
          ),
        ),
      ),
    );
  }
}

class MountedDeviceDetailPage extends StatefulWidget {
  const MountedDeviceDetailPage({
    super.key,
    required this.device,
    required this.onRemove,
    this.onRename,
  });

  final MountedDevice device;
  final Future<DeviceRemovalProgress> Function(
    String deviceId,
    String requestId,
  ) onRemove;

  /// Naming is done to the name, where the name is — the same rule the
  /// Eidolon's own page follows. A device arrives calling itself after its
  /// board, so two of the same one are indistinguishable until someone says
  /// which is which.
  final Future<void> Function(String deviceId, String displayName)? onRename;

  @override
  State<MountedDeviceDetailPage> createState() =>
      _MountedDeviceDetailPageState();
}

class _MountedDeviceDetailPageState extends State<MountedDeviceDetailPage> {
  final Random _random = Random.secure();
  bool _removing = false;
  bool _platformRemoved = false;
  String? _notice;
  String? _removalRequestId;

  Future<void> _renameDevice() async {
    final rename = widget.onRename;
    if (rename == null) return;
    final name = await askForAName(
      context,
      question: '这台设备叫什么？',
      hint: '比如「客厅的音箱」',
      current: widget.device.displayName,
      dialogKey: const Key('rename-device-dialog'),
      fieldKey: const Key('device-name-field'),
      confirmKey: const Key('confirm-device-name'),
    );
    if (name == null || !mounted) return;
    try {
      await rename(widget.device.deviceId, name);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _notice = '改名没有完成：$error');
    }
  }

  Future<void> _confirmRemoval() async {
    final device = widget.device;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('confirm-device-removal'),
        title: const Text('移除这台设备？'),
        content: const Text(
          '主机会先撤销它对当前 Owner 的访问授权，再让挂载和通道独立收敛。'
          '之后需要重新认领才能再次使用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-device-removal-action'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _removing = true;
      _notice = null;
    });
    try {
      final requestId = _removalRequestId ??= _newRemovalRequestId();
      final progress = await widget.onRemove(device.deviceId, requestId);
      if (!mounted) return;
      if (progress.outcome == ActOutcome.done) {
        setState(() {
          _platformRemoved = true;
          _notice = progress.deviceEraseAcknowledged
              ? '已从平台移除，设备也已确认清除本地状态。'
              : '已从平台移除；设备本地擦除尚未确认。离线设备再次出现时旧凭据会被拒绝，必要时请执行物理复位。';
        });
        return;
      }
      setState(() {
        if (progress.outcome == ActOutcome.refused) {
          _removalRequestId = null;
        }
        _notice = switch (progress) {
          _ when progress.platformAccessRevoked && !progress.mountRemoved =>
            '平台访问授权已撤销；主机挂载正在独立收敛。',
          _
              when progress.platformAccessRevoked &&
                  progress.mountRemoved &&
                  !progress.channelAccessRevoked =>
            '平台授权和主机挂载已移除；通道凭据正在独立收敛。',
          _ when progress.outcome == ActOutcome.unfinished =>
            '主机已受理移除，正在等待各权威状态收敛。设备本地擦除尚未确认。',
          // The Host decided. Offering "try again" here would be offering
          // something that can only fail the same way.
          _ => '主机拒绝了这次移除。',
        };
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _notice = '暂时无法确认主机是否已受理；再次确认会继续同一移除意图：$error',
      );
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  String _newRemovalRequestId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final uuid = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return 'device-removal-$uuid';
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final stateLabel = switch (device.admissionState) {
      MountedDeviceAdmissionState.ready => '已接入',
      MountedDeviceAdmissionState.mounted => '待关联 Companion',
    };
    return Scaffold(
      key: const Key('mounted-device-detail'),
      appBar: AppBar(
        title: Text(device.label),
        actions: [
          if (widget.onRename != null)
            IconButton(
              key: const Key('rename-device'),
              onPressed: _removing ? null : _renameDevice,
              tooltip: '改名',
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('设备身份', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: SelectableText(device.deviceId),
            ),
          ),
          const SizedBox(height: 16),
          Text('接入状态', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(title: const Text('状态'), trailing: Text(stateLabel)),
                ListTile(
                  title: const Text('挂载 revision'),
                  trailing: Text('${device.mount.revision}'),
                ),
                ListTile(
                  title: const Text('关联 Companion'),
                  subtitle: Text(
                    device.mount.attachedCompanionId == null ? '尚未关联' : '已关联',
                  ),
                ),
                ListTile(
                  title: const Text('最后更新'),
                  subtitle: Text(device.mount.updatedAt.toLocal().toString()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '这里展示主机权威确认的挂载关系，不代表设备当前在线。在线状态需要独立的运行时遥测投影。',
          ),
          const SizedBox(height: 24),
          if (_notice case final notice?) ...[
            Card(
              color: _platformRemoved
                  ? Theme.of(context).colorScheme.tertiaryContainer
                  : Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(notice, key: const Key('device-removal-notice')),
              ),
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            key: const Key('remove-mounted-device'),
            onPressed: _removing || _platformRemoved ? null : _confirmRemoval,
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: _removing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link_off),
            label: Text(_platformRemoved ? '已从平台移除' : '移除设备'),
          ),
          const SizedBox(height: 8),
          Text(
            '移除后这台设备立即失去访问。它也是设备重新添加的前提：主机不会为已经持有的设备重复登记。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

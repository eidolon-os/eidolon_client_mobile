import 'package:flutter/material.dart';

import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_ports.dart';
import '../device_setup/device_admission_page.dart';
import '../device_setup/legacy_hotspot_provisioning_page.dart';
import '../host_setup/host_product_controller.dart';
import 'mounted_device_models.dart';

class MountedDevicesPage extends StatefulWidget {
  const MountedDevicesPage({
    super.key,
    required this.controller,
    this.deviceProvisioning,
  });

  final HostProductController controller;
  final LegacyHotspotProvisioningPort? deviceProvisioning;

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
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LegacyHotspotProvisioningPage(
          host: widget.controller.host,
          loadTarget: widget.controller.deviceOnboardingTarget,
          onCommissioned: (deviceId) =>
              widget.controller.claimCommissionedDevice(deviceId: deviceId),
          provisioning: widget.deviceProvisioning,
        ),
      ),
    );
    if (mounted) await widget.controller.refreshDevices();
  }

  Future<void> _openAdmission() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DeviceAdmissionPage(
          hostId: widget.controller.host.hostId,
          loadPending: widget.controller.listPendingDeviceEnrollments,
          onApprove: widget.controller.approveDeviceEnrollment,
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
                onRemove: (deviceId) =>
                    controller.removeDevice(deviceId: deviceId),
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
  const _MountedDeviceCard({required this.device, required this.onRemove});

  final MountedDevice device;
  final Future<DeviceRemovalProgress> Function(String deviceId) onRemove;

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
        // What it is, then what it is to this household. The revision is a
        // fact about a mount record, and nobody reading this list is asking
        // about a mount record.
        subtitle: Text(
          device.deviceKind.isNotEmpty && device.displayName.isNotEmpty
              ? device.deviceKind
              : _shortId(device.deviceId),
        ),
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
  });

  final MountedDevice device;
  final Future<DeviceRemovalProgress> Function(String deviceId) onRemove;

  @override
  State<MountedDeviceDetailPage> createState() =>
      _MountedDeviceDetailPageState();
}

class _MountedDeviceDetailPageState extends State<MountedDeviceDetailPage> {
  bool _removing = false;
  String? _notice;

  Future<void> _confirmRemoval() async {
    final device = widget.device;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('confirm-device-removal'),
        title: const Text('移除这台设备？'),
        content: const Text(
          '主机会撤销它的授权并从当前 Owner 卸载。这台设备会立即失去访问，'
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
      final progress = await widget.onRemove(device.deviceId);
      if (!mounted) return;
      if (progress.state == DeviceRemovalState.removed) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _notice = progress.state == DeviceRemovalState.revoked
            ? '授权已撤销，设备已经无法访问；卸载尚未完成，可以再试一次。'
            : '移除未完成，可以再试一次。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _notice = '移除未完成：$error');
    } finally {
      if (mounted) setState(() => _removing = false);
    }
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
      appBar: AppBar(title: const Text('设备详情')),
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
                    device.mount.attachedCompanionId == null
                        ? '尚未关联'
                        : '已关联',
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
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(notice, key: const Key('device-removal-notice')),
              ),
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            key: const Key('remove-mounted-device'),
            onPressed: _removing ? null : _confirmRemoval,
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: _removing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link_off),
            label: const Text('移除设备'),
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

String _shortId(String value) {
  if (value.length <= 16) return value;
  return '…${value.substring(value.length - 12)}';
}

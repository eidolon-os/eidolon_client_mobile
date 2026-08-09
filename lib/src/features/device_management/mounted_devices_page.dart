import 'package:flutter/material.dart';

import '../device_setup/device_setup_ports.dart';
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
          provisioning: widget.deviceProvisioning,
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
              (device) => _MountedDeviceCard(device: device),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.tonalIcon(
            key: const Key('provision-device-from-product'),
            onPressed: controller.devicesBusy ? null : _openProvisioning,
            icon: const Icon(Icons.add_link),
            label: const Text('配置新设备网络（开发）'),
          ),
          const SizedBox(height: 8),
          Text(
            '当前兼容入口只配置设备 Wi-Fi，不表示设备已安全认领。产品认领入口将在设备身份与 Hub admission 契约完成后接入。',
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
  const _MountedDeviceCard({required this.device});

  final MountedDevice device;

  @override
  Widget build(BuildContext context) {
    final companionId = device.mount.attachedCompanionId;
    final (label, color) = switch (device.admissionState) {
      MountedDeviceAdmissionState.ready => (
          '已接入',
          Theme.of(context).colorScheme.primary,
        ),
      MountedDeviceAdmissionState.mounted => (
          '待关联 Companion',
          Theme.of(context).colorScheme.tertiary,
        ),
      MountedDeviceAdmissionState.inactive => (
          '已停用',
          Theme.of(context).colorScheme.outline,
        ),
    };
    return Card(
      child: ListTile(
        key: Key('mounted-device-${device.deviceId}'),
        contentPadding: const EdgeInsets.all(16),
        leading: Icon(Icons.developer_board_outlined, color: color),
        title: Text(_shortId(device.deviceId)),
        subtitle: Text(
          companionId != null
              ? 'Companion ${_shortId(companionId)} · revision ${device.mount.revision}'
              : 'revision ${device.mount.revision}',
        ),
        trailing: Chip(label: Text(label)),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => MountedDeviceDetailPage(device: device),
          ),
        ),
      ),
    );
  }
}

class MountedDeviceDetailPage extends StatelessWidget {
  const MountedDeviceDetailPage({super.key, required this.device});

  final MountedDevice device;

  @override
  Widget build(BuildContext context) {
    final stateLabel = switch (device.admissionState) {
      MountedDeviceAdmissionState.ready => '已接入',
      MountedDeviceAdmissionState.mounted => '待关联 Companion',
      MountedDeviceAdmissionState.inactive => '已停用',
    };
    final companionId = device.mount.attachedCompanionId;
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
                  subtitle: companionId == null
                      ? const Text('尚未关联')
                      : SelectableText(companionId),
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
        ],
      ),
    );
  }
}

String _shortId(String value) {
  if (value.length <= 16) return value;
  return '…${value.substring(value.length - 12)}';
}

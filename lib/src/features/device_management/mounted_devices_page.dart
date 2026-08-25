import 'dart:math';

import 'package:flutter/material.dart';

import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_checkpoint_store.dart';
import '../device_setup/device_setup_ports.dart';
import '../device_setup/device_admission_page.dart';
import '../device_setup/device_setup_page.dart';
import '../device_setup/host_controller_device_admission.dart';
import '../device_setup/platform_device_provisioning.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
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
          onDecide: ({required requestId, required projection}) =>
              widget.controller.decideEnrollment(
            requestId: requestId,
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
                loadCompanions: controller.roster,
                onBindCompanion: controller.setDeviceCompanion,
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
    this.loadCompanions,
    this.onBindCompanion,
  });

  final MountedDevice device;
  final Future<DeviceRemovalProgress> Function(
    String deviceId,
    String requestId,
  ) onRemove;
  final Future<CompanionRosterView> Function()? loadCompanions;
  final Future<void> Function({
    required String deviceId,
    required String requestId,
    required String? companionId,
    required int expectedRevision,
  })? onBindCompanion;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (device.state) {
      MountedDeviceState.ready => (
          '已接入',
          Theme.of(context).colorScheme.primary,
        ),
      MountedDeviceState.awaitingCompanion => (
          '待关联 Companion',
          Theme.of(context).colorScheme.tertiary,
        ),
      // Its access is already gone; what is left is the mount. Saying so is
      // the difference between "retry the removal" and "something is wrong".
      MountedDeviceState.accessRevoked => (
          '已停用，待移除',
          Theme.of(context).colorScheme.error,
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
              loadCompanions: loadCompanions,
              onBindCompanion: onBindCompanion,
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
    this.loadCompanions,
    this.onBindCompanion,
  });

  final MountedDevice device;
  final Future<DeviceRemovalProgress> Function(
    String deviceId,
    String requestId,
  ) onRemove;

  /// This Owner's Companions, read when the Owner asks to choose one. Not held
  /// on this screen: which Companions exist is the Host's to say, and it
  /// changes without this device changing.
  final Future<CompanionRosterView> Function()? loadCompanions;

  /// Which Companion answers through this device, or none. One call for both,
  /// carrying the mount revision this screen was showing.
  final Future<void> Function({
    required String deviceId,
    required String requestId,
    required String? companionId,
    required int expectedRevision,
  })? onBindCompanion;

  @override
  State<MountedDeviceDetailPage> createState() =>
      _MountedDeviceDetailPageState();
}

class _MountedDeviceDetailPageState extends State<MountedDeviceDetailPage> {
  final Random _random = Random.secure();
  bool _removing = false;
  bool _binding = false;
  bool _platformRemoved = false;

  /// Whether the device has already lost access, which is a different fact from
  /// [_platformRemoved].
  ///
  /// One flag used to carry both, and they are not the same question: losing
  /// access has happened the moment the Host revokes the Claim and nothing the
  /// device does can undo it, while "there is nothing left to ask the Host for"
  /// also waits on the mount. Reading a removal that had already taken the
  /// device's access away as a setback is what made the screen's own answer
  /// sound like the operation had failed.
  bool _accessRevoked = false;
  String? _notice;
  String? _removalRequestId;

  Future<void> _bindCompanion() async {
    final bind = widget.onBindCompanion;
    final load = widget.loadCompanions;
    if (bind == null || load == null || _binding || _removing) return;
    setState(() {
      _binding = true;
      _notice = null;
    });
    try {
      final roster = await load();
      if (!mounted) return;
      final chosen = await showModalBottomSheet<_CompanionChoice>(
        context: context,
        builder: (sheetContext) => _CompanionPicker(
          roster: roster,
          attachedCompanionId: widget.device.attachedCompanionId,
        ),
      );
      if (chosen == null || !mounted) return;
      await bind(
        deviceId: widget.device.deviceId,
        requestId: _requestId('device-companion'),
        companionId: chosen.companionId,
        expectedRevision: widget.device.revision,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _notice = '关联没有完成：$error');
    } finally {
      if (mounted) setState(() => _binding = false);
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
          _accessRevoked = true;
          _notice = progress.deviceEraseAcknowledged
              ? '这台设备已失去访问，移除已经生效；它也确认清除了本地数据。'
              : '这台设备已失去访问，移除已经生效。它本地的数据尚未确认擦除：'
                  '设备若再次上线，旧凭据会被拒绝并被要求擦除；若它已经坏了，'
                  '只能按物理处置。';
        });
        return;
      }
      setState(() {
        if (progress.outcome == ActOutcome.refused) {
          _removalRequestId = null;
        }
        _accessRevoked = progress.platformAccessRevoked;
        _notice = switch (progress) {
          // Two facts, in the order they settle. Access is gone already and no
          // longer depends on anything; the mount converges on the Host's own
          // schedule and the erase depends on whether the device ever returns.
          _ when progress.platformAccessRevoked && !progress.mountRemoved =>
            '这台设备已失去访问，移除已经生效；主机挂载正在独立收敛。'
                '它本地的数据尚未确认擦除。',
          _ when progress.platformAccessRevoked =>
            '这台设备已失去访问，移除已经生效。它本地的数据尚未确认擦除。',
          _ when progress.outcome == ActOutcome.unfinished =>
            '主机已受理移除，正在等待各权威状态收敛。设备本地擦除尚未确认。',
          // The Host decided. Offering "try again" here would be offering
          // something that can only fail the same way.
          _ => '主机拒绝了这次移除。',
        };
      });
    } catch (error) {
      if (!mounted) return;
      // A refusal envelope means the Host answered. Saying 「暂时无法确认主机是否
      // 已受理」 to a definite refusal reads as "nothing happened, try again"
      // about an answer that already arrived — and it was this path's wording
      // for every throw, refusals included.
      final refused =
          error is ManagementRequestException && error.refusal != null;
      setState(() {
        if (refused && !canRetry(error)) _removalRequestId = null;
        _notice = refused
            ? '主机拒绝了这次移除：${refusalText(error, subject: '这台设备')}'
            : '暂时无法确认主机是否已受理；再次确认会继续同一移除意图：$error';
      });
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  String _newRemovalRequestId() => _requestId('device-removal');

  String _requestId(String purpose) {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final uuid = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return '$purpose-$uuid';
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final stateLabel = switch (device.state) {
      MountedDeviceState.ready => '已接入',
      MountedDeviceState.awaitingCompanion => '待关联 Companion',
      MountedDeviceState.accessRevoked => '已停用，待移除',
    };
    return Scaffold(
      key: const Key('mounted-device-detail'),
      appBar: AppBar(
        title: Text(device.label),
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
                  trailing: Text('${device.revision}'),
                ),
                ListTile(
                  key: const Key('device-companion-binding'),
                  title: const Text('关联 Companion'),
                  subtitle: Text(
                    device.attachedCompanionId ?? '尚未关联',
                  ),
                  trailing: widget.onBindCompanion == null
                      ? null
                      : TextButton(
                          key: const Key('bind-device-companion'),
                          onPressed: _binding || _removing || _platformRemoved
                              ? null
                              : _bindCompanion,
                          child: Text(
                            device.attachedCompanionId == null
                                ? '关联'
                                : '更换或解除',
                          ),
                        ),
                ),
                ListTile(
                  title: const Text('最后更新'),
                  subtitle: Text(
                    // The Host may not say when: an absent moment is left unsaid
                    // rather than shown as an epoch nobody means.
                    device.updatedAt?.toLocal().toString() ?? '主机没有说',
                  ),
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
              // Access already gone is not a setback, whatever is still
              // converging behind it.
              color: _accessRevoked
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

/// What the Owner chose in the picker: a Companion, or none.
class _CompanionChoice {
  const _CompanionChoice(this.companionId);

  final String? companionId;
}

class _CompanionPicker extends StatelessWidget {
  const _CompanionPicker({
    required this.roster,
    required this.attachedCompanionId,
  });

  final CompanionRosterView roster;
  final String? attachedCompanionId;

  @override
  Widget build(BuildContext context) {
    final active = roster.companions
        .where((item) => item.lifecycleState == 'active')
        .toList(growable: false);
    return SafeArea(
      child: ListView(
        key: const Key('device-companion-picker'),
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('谁通过这台设备说话？'),
            subtitle: Text('换一个 Companion 不会重新配网，也不会动它的记忆。'),
          ),
          const Divider(height: 1),
          if (active.isEmpty)
            const ListTile(
              key: Key('device-companion-picker-empty'),
              title: Text('这台主机上还没有可用的 Eidolon。'),
            ),
          ...active.map(
            (companion) => ListTile(
              key: Key('companion-choice-${companion.companionId}'),
              title: Text(
                (companion.displayName ?? '').trim().isEmpty
                    ? companion.companionId
                    : companion.displayName!.trim(),
              ),
              subtitle: Text(companion.kind),
              trailing: companion.companionId == attachedCompanionId
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.of(context).pop(
                _CompanionChoice(companion.companionId),
              ),
            ),
          ),
          if (attachedCompanionId != null) ...[
            const Divider(height: 1),
            ListTile(
              key: const Key('companion-choice-none'),
              title: const Text('解除关联'),
              subtitle: const Text('设备留在这台主机上，只是暂时没有谁通过它说话。'),
              onTap: () =>
                  Navigator.of(context).pop(const _CompanionChoice(null)),
            ),
          ],
        ],
      ),
    );
  }
}

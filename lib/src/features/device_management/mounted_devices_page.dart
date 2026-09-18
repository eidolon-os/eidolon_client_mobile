import 'dart:math';

import 'package:flutter/material.dart';

import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_checkpoint_store.dart';
import '../device_setup/device_setup_ports.dart';
import '../device_setup/device_admission_queue.dart';
import '../device_setup/device_setup_page.dart';
import '../device_setup/host_controller_device_admission.dart';
import '../device_setup/platform_device_provisioning.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../host_setup/host_product_controller.dart';
import 'mounted_device_models.dart';

/// Whether to draw the control that points a device at an Eidolon.
///
/// A named rule rather than a condition inside a build method, because it has
/// two halves worth stating separately and a test can only reach one of them
/// through a whole page otherwise.
///
/// `body.assign` is its own capability, read apart from `device.manage`: one is
/// about which devices are on this Host at all, and a Host could reasonably let
/// somebody point a speaker somewhere without letting them take it off.
///
/// A context that has not been read yet is no objection. Treating "not asked"
/// as "refused" would make every control disappear for the moment between
/// connecting to a Host and reading `/context`, which looks like a Host with
/// nothing on it rather than one nobody has questioned yet.
bool hostOffersBodyAssignment(ManagementContextView? context) =>
    context == null || hostCan(context, 'body.assign');

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

  bool get _hostOffersAssignment =>
      hostOffersBodyAssignment(widget.controller.managementCapabilities);

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
    if (mounted) await _refreshThenFinish();
  }

  Future<void> _openAdmission() async {
    await openDeviceAdmissionQueue(context, widget.controller);
    if (mounted) await _refreshThenFinish();
  }

  /// Take whoever just added a device to the decision that device is waiting on.
  ///
  /// Provisioning and claiming are the two steps a person set out to do, and
  /// neither of them makes the device usable. Landing back on a list and
  /// expecting someone to notice a chip, open the device, and know which of two
  /// controls unblocks it is how this ended with a board that said "service is
  /// not ready" and an Owner with nowhere to go. Nothing is invented here: the
  /// Host already says which devices are waiting and on what.
  Future<void> _refreshThenFinish() async {
    await widget.controller.refreshDevices();
    if (!mounted) return;
    final inventory = widget.controller.devices;
    if (inventory == null) return;
    final waiting = devicesAwaitingOwner(inventory.devices);
    if (waiting.isEmpty) return;
    await _openDevice(waiting.first);
  }

  Future<void> _openDevice(MountedDevice device) async {
    final controller = widget.controller;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MountedDeviceDetailPage(
          device: device,
          onRemove: (deviceId, requestId) =>
              controller.removeDevice(deviceId: deviceId, requestId: requestId),
          loadCompanions: controller.roster,
          onBindCompanion:
              _hostOffersAssignment ? controller.setDeviceCompanion : null,
          onSetOutputs: controller.setDeviceOutputs,
        ),
      ),
    );
    if (mounted) await controller.refreshDevices();
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
                // Its own capability, read separately from taking a device off
                // the Host: a Host could reasonably offer one and not the
                // other. Null means the control is not drawn at all rather
                // than drawn greyed, which is this app's rule for a thing the
                // Host is not offering.
                //
                // Not read yet counts as no objection: making every control
                // vanish for the moment between connecting and reading
                // /context would look like a Host with nothing on it.
                onBindCompanion: _hostOffersAssignment
                    ? controller.setDeviceCompanion
                    : null,
                onSetOutputs: controller.setDeviceOutputs,
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
    this.onSetOutputs,
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
  final Future<void> Function({
    required String deviceId,
    required OutputSelection allowed,
    required int expectedRevision,
  })? onSetOutputs;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (device.state) {
      MountedDeviceState.ready => (
          '已接入',
          Theme.of(context).colorScheme.primary,
        ),
      MountedDeviceState.awaitingCompanion => (
          '没有谁应答',
          Theme.of(context).colorScheme.tertiary,
        ),
      // It has an Eidolon and still cannot be served. Saying 已接入 here is
      // what left someone looking at a device whose own screen said the
      // service was not ready.
      MountedDeviceState.awaitingOutputs => (
          '还没定它怎么表达',
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
              onSetOutputs: onSetOutputs,
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
    this.onSetOutputs,
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

  /// What this device may present. Carries the outputs revision this screen
  /// was showing, which is a different number from the mount's.
  final Future<void> Function({
    required String deviceId,
    required OutputSelection allowed,
    required int expectedRevision,
  })? onSetOutputs;

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

  Future<void> _decideOutputs() async {
    final decide = widget.onSetOutputs;
    if (decide == null || _binding || _removing) return;
    final device = widget.device;
    final chosen = await showModalBottomSheet<OutputSelection>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _OutputsPicker(outputs: device.outputs),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _binding = true;
      _notice = null;
    });
    try {
      await decide(
        deviceId: device.deviceId,
        allowed: chosen,
        expectedRevision: device.outputs.revision,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _notice = '没有保存成功：$error');
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

  /// What to say where a name would go when nobody answers.
  ///
  /// Three sentences rather than one, because the three ways a device ends up
  /// quiet are not the same event and only one of them is something the person
  /// did to this device. A single "尚未关联" would tell someone whose Eidolon was
  /// put away that they had never set the speaker up.
  static String _quietText(MountedDevice device) => switch (device.quietBecause) {
        DeviceQuietBecause.ownerCleared => '你把它设成了不由谁应答',
        DeviceQuietBecause.companionPutAway => '原本应答的 Eidolon 被收起来了',
        DeviceQuietBecause.hostReleased => '主机把它放开了',
        DeviceQuietBecause.unstated => '还没有指定',
      };

  /// What it may present, in the words a person can act on.
  ///
  /// "Nobody has decided" and "decided on nothing" are different sentences on
  /// purpose: the first is a device waiting for its Owner, and the second is a
  /// device its Owner deliberately silenced.
  static String _outputsText(DeviceOutputs outputs) {
    final allowed = outputs.allowed;
    if (allowed == null) return '还没有决定 —— 在定下来之前，主机不会让它开始对话';
    final named = _outputNames(allowed);
    return named.isEmpty ? '你把它设成了什么都不表达' : named.join('、');
  }

  static List<String> _outputNames(OutputSelection outputs) => [
        if (outputs.speech ?? false) '说话',
        if (outputs.dialogueText ?? false) '显示对话文字',
        if (outputs.expression ?? false) '表情',
        if (outputs.audioCue ?? false) '提示音',
        if (outputs.motion ?? false) '动作',
      ];

  Widget _companionTile(MountedDevice device) => ListTile(
        key: const Key('device-companion-binding'),
        title: const Text('由谁应答'),
        subtitle: Text(
          device.attachedCompanionName.isNotEmpty
              ? device.attachedCompanionName
              : device.attachedCompanionId ?? _quietText(device),
        ),
        trailing: widget.onBindCompanion == null
            ? null
            : TextButton(
                key: const Key('bind-device-companion'),
                onPressed: _binding || _removing || _platformRemoved
                    ? null
                    : _bindCompanion,
                child: Text(
                  device.attachedCompanionId == null ? '指定' : '更换或解除',
                ),
              ),
      );

  Widget _outputsTile(MountedDevice device) => ListTile(
        key: const Key('device-outputs'),
        title: const Text('它可以怎么表达'),
        subtitle: Text(_outputsText(device.outputs)),
        trailing: widget.onSetOutputs == null
            ? null
            : TextButton(
                key: const Key('decide-device-outputs'),
                onPressed: _binding || _removing || _platformRemoved
                    ? null
                    : _decideOutputs,
                child: Text(device.outputs.decided ? '更改' : '设置'),
              ),
      );

  /// Why this device cannot be used yet, and the one thing that changes it.
  ///
  /// In the Owner's terms. The device's own screen already says "service is not
  /// ready", which is true and is exactly the sentence nobody can act on — it
  /// names a service, when what is missing is a decision only a person can make.
  Widget? _unfinishedLead(BuildContext context, MountedDevice device) {
    final (why, action, act) = switch (device.state) {
      MountedDeviceState.awaitingOutputs => (
          '这台设备还不能开始对话：你还没决定它可以怎么表达。'
              '在定下来之前，主机不会给它通道——它自己的屏幕会一直说服务没有就绪。',
          '决定它可以怎么表达',
          widget.onSetOutputs == null ? null : _decideOutputs,
        ),
      MountedDeviceState.awaitingCompanion => (
          '这台设备还不能开始对话：还没有哪个 Eidolon 通过它应答。',
          '指定由谁应答',
          widget.onBindCompanion == null ? null : _bindCompanion,
        ),
      _ => (null, null, null),
    };
    if (why == null || act == null) return null;
    return Card(
      key: const Key('device-unfinished-lead'),
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(why),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('device-unfinished-action'),
              onPressed: _binding || _removing || _platformRemoved ? null : act,
              child: Text(action!),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final stateLabel = switch (device.state) {
      MountedDeviceState.ready => '已接入',
      MountedDeviceState.awaitingCompanion => '没有谁应答',
      MountedDeviceState.awaitingOutputs => '还没定它怎么表达',
      MountedDeviceState.accessRevoked => '已停用，待移除',
    };
    final lead = _unfinishedLead(context, device);
    return Scaffold(
      key: const Key('mounted-device-detail'),
      appBar: AppBar(
        title: Text(device.label),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (lead != null) ...[lead, const SizedBox(height: 16)],
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
                  trailing: Text('${device.mountRevision}'),
                ),
                // Drawn in the order they unblock the device, not the order
                // they were built in: until the outputs are decided the Host
                // gives it no channel, so an Eidolon bound first answers into
                // nothing and looks like a binding that failed.
                ...(device.state == MountedDeviceState.awaitingOutputs
                    ? [_outputsTile(device), _companionTile(device)]
                    : [_companionTile(device), _outputsTile(device)]),
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
          // The second half of this note used to read 「它也是设备重新添加的
          // 前提：主机不会为已经持有的设备重复登记。」 No such rule exists in
          // the server, and it is the sentence that explained away a real
          // incident: a Body whose stored DeviceRef fell behind its own Claim
          // was refused 409 forever, and this copy told whoever read it that
          // the only way out was a removal.
          //
          // What the Authority actually does, pinned by
          // `tests/unit/admission/test_admission_authority.py::
          // test_a_claimed_body_may_still_propose_itself_at_the_next_generation`
          // in eidolon_hub: a Body holding an *active* Claim may propose itself
          // again on its own enrolled base key, with no Controller and no
          // commissioning code, and on the Owner's approval the Claim is
          // upserted in place at the next generation. `requires_fresh_presence`
          // fences a *rejected* Proposal or a *revoked* Claim — the two cases
          // where the Owner has already said no. Removal was never the
          // precondition; it is the thing that creates one.
          Text(
            '移除后这台设备立即失去访问，它的挂载被撤掉，你为它选的 Companion 绑定也随之失效。'
            '这不是设备重新登记的前提：主机不要求先移除 —— 已归属的设备再登记一次，'
            '主机会在原记录上更新，不会多出一台设备。'
            '移除之后它反而回不来了 —— 要重新加入，得有人带着 Controller 再做一次现场确认。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Choose what one device may present.
///
/// Only what the device declared it can do is offered: allowing an output a
/// device does not have would be a decision nothing could ever carry out, and
/// it is the Authority that intersects the two anyway. Allowing nothing is
/// reachable on purpose — it is how a device is silenced without taking it off
/// the Host.
class _OutputsPicker extends StatefulWidget {
  const _OutputsPicker({required this.outputs});

  final DeviceOutputs outputs;

  @override
  State<_OutputsPicker> createState() => _OutputsPickerState();
}

class _OutputsPickerState extends State<_OutputsPicker> {
  late Map<String, bool> _chosen;

  static const Map<String, String> _labels = {
    'speech': '说话',
    'dialogue_text': '显示对话文字',
    'expression': '表情',
    'audio_cue': '提示音',
    'motion': '动作',
  };

  @override
  void initState() {
    super.initState();
    final allowed = widget.outputs.allowed?.toJson() ?? const {};
    _chosen = {
      for (final name in _declared) name: allowed[name] == true,
    };
  }

  /// The outputs this device said it has, in the order the labels are written.
  List<String> get _declared {
    final capabilities = widget.outputs.capabilities.toJson();
    return [
      for (final name in _labels.keys)
        if (capabilities[name] == true) name,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        key: const Key('device-outputs-picker'),
        shrinkWrap: true,
        padding: const EdgeInsets.all(20),
        children: [
          Text('它可以怎么表达', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '只列出这台设备自己声明具备的能力。没有被打开的，主机不会为它生成，'
            '也不会换一种方式送出去。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final name in _declared)
            SwitchListTile(
              key: Key('device-output-$name'),
              title: Text(_labels[name]!),
              value: _chosen[name] ?? false,
              onChanged: (value) => setState(() => _chosen[name] = value),
            ),
          const SizedBox(height: 4),
          // Nothing arrives switched on: a pre-ticked box is the system
          // deciding and asking the Owner to notice, which is the one thing
          // this decision exists to prevent. Allowing everything is still one
          // tap, and it is still the Owner who takes it — and it can never
          // reach past what the device declared, because it only fills in the
          // switches that are drawn.
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('device-outputs-allow-all'),
              onPressed: () => setState(() {
                for (final name in _declared) {
                  _chosen[name] = true;
                }
              }),
              child: const Text('全部允许'),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('device-outputs-save'),
            onPressed: () => Navigator.of(context).pop(
              OutputSelection.fromJson({
                for (final entry in _chosen.entries) entry.key: entry.value,
              }),
            ),
            child: const Text('保存'),
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

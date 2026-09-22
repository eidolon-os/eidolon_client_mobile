import 'dart:math';

import 'package:flutter/material.dart';

import '../../theme/eidolon_theme.dart';
import '../../theme/neon_components.dart';

import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_checkpoint_store.dart';
import '../device_setup/device_setup_ports.dart';
import '../device_setup/device_admission_queue.dart';
import '../device_setup/device_setup_page.dart';
import '../device_setup/host_controller_device_admission.dart';
import '../device_setup/platform_device_provisioning.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../../management/companion_creation_flow.dart';
import '../../management/companion_creation_checkpoint.dart';
import '../../platform/app_preferences.dart';
import '../host_setup/host_product_controller.dart';
import 'mounted_device_models.dart';
import 'device_companion_setup.dart';
import '../../management/companion_portrait.dart';

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
    this.companionName,
    this.companionId,
    this.creationPreferences,
  });

  final HostProductController controller;
  final AppPreferences? creationPreferences;

  /// Supplied by tests; production builds get the protocomm adapter, which is
  /// the only transport this app speaks to a device.
  final DeviceProvisioningTransport? deviceProvisioning;
  final DeviceSetupCheckpointStore? checkpoints;

  /// Guidance only: choosing a device never silently changes its binding.
  final String? companionName;
  final String? companionId;

  @override
  State<MountedDevicesPage> createState() => _MountedDevicesPageState();
}

class _MountedDevicesPageState extends State<MountedDevicesPage> {
  CompanionCreationFlow? _creation;
  String? _creationOwnerId;
  CompanionSetupIntent? _handoff;
  String? _handoffError;
  DeviceCompanionSetupStore? get _selectionStore {
    final owner = widget.controller.workspace?.owner;
    if (owner == null) return null;
    return DeviceCompanionSetupStore(
        hostId: widget.controller.host.hostId,
        controllerId: widget.controller.host.controllerId,
        ownerId: owner.ownerId,
        preferences: widget.creationPreferences);
  }

  Future<void> _loadHandoff() async {
    try {
      final store = _selectionStore;
      var saved = await store?.load();
      if (widget.companionId != null && saved == null) {
        saved = CompanionSetupIntent(
            step: CompanionSetupStep.confirmBinding,
            requestId: 'select-${widget.companionId}',
            expectedRevision: 0,
            companionId: widget.companionId,
            companionName: widget.companionName ?? '伙伴');
        await store?.save(saved);
      }
      if (mounted) setState(() => _handoff = saved);
    } catch (error) {
      if (mounted) setState(() => _handoffError = '$error');
    }
  }

  Future<CreatedCompanion?> _createCompanion(
      DeviceCompanionSetupStore? progress, CompanionSetupIntent intent) async {
    final controller = widget.controller;
    final capabilities = await controller.managementContext();
    if (!hostCan(capabilities, 'companion.create')) {
      throw StateError('这台主机暂不允许创建伙伴。');
    }
    final owner = controller.workspace?.owner;
    if (owner == null) throw StateError('请先重新连接主机。');
    if (!mounted) return null;
    if (_creationOwnerId != owner.ownerId) {
      _creation?.dispose();
      _creation = null;
      _creationOwnerId = owner.ownerId;
    }
    final checkpoints = CompanionCreationCheckpointStore(
        hostId: controller.host.hostId,
        controllerId: controller.host.controllerId,
        ownerId: owner.ownerId,
        preferences: widget.creationPreferences);
    final previous = await progress?.load();
    if (previous != null && !previous.isRecoverable) {
      await progress?.clear(previous.requestId);
    }
    final operation = previous?.creationOperationId;
    Future<void> received(CreatedCompanion created) async {
      final pending = await progress?.load();
      if (pending != null) {
        await progress!.save(pending.at(CompanionSetupStep.confirmBinding,
            companionId: created.companionId,
            companionName: created.displayName));
        final id = pending.creationOperationId;
        if (id != null) await checkpoints.acknowledge(id);
      }
    }

    if (operation != null && previous!.isRecoverable) {
      final receipt = await checkpoints.result(operation);
      if (receipt != null) {
        await received(receipt);
        return receipt;
      }
      final pending = await checkpoints.load();
      if (pending?.operationId != operation) {
        throw StateError('原创建请求已不在待确认列表，请保留当前设置后从已有伙伴中选择。');
      }
    }
    _creation ??= CompanionCreationFlow(
        loadTemplate: controller.personaAuthoringTemplate,
        loadPresets: controller.personaPresets,
        preview: controller.previewPersona,
        checkpoints: checkpoints,
        create: (id, name, persona, preferences, source) =>
            controller.createCompanion(
                operationId: id,
                displayName: name,
                persona: persona,
                preferences: preferences,
                sourcePreset: source));
    if (!mounted) return null;
    return _creation!.open(context, onCreated: received,
        onSubmitting: (id) async {
      // The first moment anything about this creation is with the Host, and
      // so the first moment there is something a later visit could not work
      // out on its own. Written from the caller's intent rather than from an
      // earlier entry: until now there was deliberately none.
      await checkpoints.watch(id);
      await progress?.save(
          intent.at(CompanionSetupStep.creating, creationOperationId: id));
    });
  }

  Future<CompanionRosterView> _allCompanions() =>
      loadDeviceCompanionChoices(widget.controller.roster);

  DeviceCompanionSetupStore? _progressFor(MountedDevice device) {
    final controller = widget.controller;
    final ownerId = controller.workspace?.owner?.ownerId;
    if (ownerId == null) return null;
    return DeviceCompanionSetupStore(
        hostId: controller.host.hostId,
        controllerId: controller.host.controllerId,
        ownerId: ownerId,
        deviceId: device.deviceId,
        preferences: widget.creationPreferences);
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    _loadHandoff();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _creation?.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  bool get _hostOffersAssignment =>
      hostOffersBodyAssignment(widget.controller.managementCapabilities);

  Future<void> _openProvisioning({MountedDevice? existing}) async {
    final admission = HostControllerDeviceAdmission(widget.controller);
    final transport = widget.deviceProvisioning ?? PlatformDeviceProvisioning();
    final completedDeviceId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => DeviceSetupPage(
          transport: transport,
          admission: admission,
          checkpoints:
              widget.checkpoints ?? PersistentDeviceSetupCheckpointStore(),
          loadTarget: widget.controller.deviceOnboardingTarget,
          expectedDeviceId: existing?.deviceId,
          knownDevices: {
            for (final device
                in widget.controller.devices?.devices ?? <MountedDevice>[])
              device.deviceId: device.label,
          },
        ),
      ),
    );
    if (!mounted) return;
    await widget.controller.refreshDevices();
    if (!mounted || completedDeviceId == null || existing != null) return;
    // Only continue the device this flow actually completed. Cancelling must
    // never select an unrelated device from the inventory.
    final devices = widget.controller.devices?.devices ?? <MountedDevice>[];
    for (final device in devices) {
      if (device.deviceId == completedDeviceId) {
        await _openDevice(device);
        break;
      }
    }
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
    final progress = _progressFor(device);
    final handoff = _handoff;
    if (handoff != null && progress != null) {
      try {
        final existing = await progress.load();
        if (existing != null && existing.requestId != handoff.requestId) {
          throw StateError('这台设备有未完成的配置，请先结束选设备，再打开设备继续原配置。');
        }
        if (existing == null) {
          await progress.save(CompanionSetupIntent(
              step: CompanionSetupStep.confirmBinding,
              requestId: handoff.requestId,
              expectedRevision: device.revision,
              companionId: handoff.companionId,
              companionName: handoff.companionName));
        }
        await _selectionStore?.clear(handoff.requestId);
        if (mounted) setState(() => _handoff = null);
      } catch (error) {
        if (mounted) setState(() => _handoffError = '$error');
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MountedDeviceDetailPage(
          device: device,
          onChangeNetwork: () => _openProvisioning(existing: device),
          onRemove: (deviceId, requestId) =>
              controller.removeDevice(deviceId: deviceId, requestId: requestId),
          loadCompanions: _allCompanions,
          progress: progress,
          loadFace: controller.companionFacePicture,
          reload: () async {
            await controller.refreshDevices();
            if (controller.devicesError != null) {
              throw StateError(controller.devicesError!);
            }
            final latest = controller.devices?.devices
                .where((d) => d.deviceId == device.deviceId)
                .firstOrNull;
            if (latest == null) throw StateError('这台设备已不在主机上。');
            return latest;
          },
          onCreateCompanion: controller.managementCapabilities != null &&
                  hostCan(
                      controller.managementCapabilities!, 'companion.create')
              ? (intent) => _createCompanion(progress, intent)
              : null,
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
          if (_handoffError != null) Text(_handoffError!),
          if (_handoff != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '为 ${_handoff!.companionName} 选择一台桌面设备。选好后还会确认关联，已有设置不会立即改变。'),
                          TextButton(
                              onPressed: () async {
                                await _selectionStore
                                    ?.clear(_handoff!.requestId);
                                if (mounted) setState(() => _handoff = null);
                              },
                              child: const Text('稍后再连接')),
                        ]))),
          if ((_handoff == null ? widget.companionName : null) case final name?)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                    '让 $name 来到桌面：添加或选择一台设备，在设备详情中将回应伙伴设为 $name，再选择它的表达方式。已有设备切换伙伴时，请确认当前绑定。',
                    key: const Key('companion-device-guidance')),
              ),
            ),
          _InventoryMeaningCard(coverage: inventory?.coverage ?? ''),
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
                  device: device, onOpen: () => _openDevice(device)),
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
            label: const Text('添加设备或恢复网络'),
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

/// What this list does not include, in the Host's own words.
///
/// Relayed rather than restated. The Host composes this sentence beside the
/// list it describes, and the copy that used to be written here drifted from it
/// — both halves of what they said about presence had gone stale by the time
/// anybody noticed, because neither one was where the answer is decided.
///
/// Absent until there is a sentence: before the list arrives there is nothing
/// to be misread, and an empty card is not a caveat.
class _InventoryMeaningCard extends StatelessWidget {
  const _InventoryMeaningCard({required this.coverage});

  final String coverage;

  @override
  Widget build(BuildContext context) => coverage.isEmpty
      ? const SizedBox.shrink()
      : Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.verified_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(coverage, key: const Key('device-coverage')),
                ),
              ],
            ),
          ),
        );
}

class _MountedDeviceCard extends StatelessWidget {
  const _MountedDeviceCard({required this.device, required this.onOpen});
  final MountedDevice device;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (device.state) {
      MountedDeviceState.ready => (
          '已添加',
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
    return NeonPanel(
      key: Key('mounted-device-${device.deviceId}'),
      padding: const EdgeInsets.all(Neon.s4),
      onTap: onOpen,
      child: Row(
        children: [
          GlyphBadge(Icons.developer_board_outlined, color: color, size: 42),
          const SizedBox(width: Neon.s3 + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Neon.ink)),
                const SizedBox(height: Neon.s1),
                const Text('连接状态未知', style: TextStyle(color: Neon.inkFaint)),
                // What kind of thing it is. The revision is a fact about a
                // mount record, and nobody reading this list is asking about a
                // mount record. When the Host cannot say, this is a long
                // identifier — set as one, and clipped rather than wrapped.
                Text(device.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Neon.mono(size: 11.5, color: Neon.inkFaint)),
              ],
            ),
          ),
          const SizedBox(width: Neon.s3),
          StatusPill(label, color: color),
        ],
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
    this.onCreateCompanion,
    this.onBindCompanion,
    this.onSetOutputs,
    this.progress,
    this.loadFace,
    this.reload,
    this.onChangeNetwork,
  });

  final MountedDevice device;
  final Future<void> Function()? onChangeNetwork;
  final DeviceCompanionSetupStore? progress;
  final CompanionFaceLoader? loadFace;
  final Future<MountedDevice> Function()? reload;
  final Future<DeviceRemovalProgress> Function(
    String deviceId,
    String requestId,
  ) onRemove;

  /// This Owner's Companions, read when the Owner asks to choose one. Not held
  /// on this screen: which Companions exist is the Host's to say, and it
  /// changes without this device changing.
  final Future<CompanionRosterView> Function()? loadCompanions;

  /// Takes the intent it is submitting under, because the journal entry for a
  /// creation is written at the moment the request leaves for the Host, and
  /// only the caller knows which device and revision it is being made for.
  final Future<CreatedCompanion?> Function(CompanionSetupIntent intent)?
      onCreateCompanion;

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
    InputSelection? inputs,
    required int expectedRevision,
  })? onSetOutputs;

  @override
  State<MountedDeviceDetailPage> createState() =>
      _MountedDeviceDetailPageState();
}

enum _DeviceDecision { companion, outputs }

class _MountedDeviceDetailPageState extends State<MountedDeviceDetailPage> {
  late MountedDevice _device;
  CompanionSetupIntent? _pending;
  bool _recovering = true;
  @override
  void initState() {
    super.initState();
    _device = widget.device;
    _readProgress();
  }

  @override
  void didUpdateWidget(MountedDeviceDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device != widget.device) _device = widget.device;
  }

  String _setupError(Object error) {
    if (error is CompanionSetupException) return error.message;
    if (error is ManagementRequestException) {
      return refusalText(error, subject: '设备配置');
    }
    return '配置尚未完成。请检查与主机的连接后继续；本次选择和已创建的伙伴会保留。';
  }

  Future<void> _readProgress() async {
    try {
      var pending = await widget.progress?.load();
      if (pending != null && !pending.isRecoverable) {
        await widget.progress?.clear(pending.requestId);
        pending = null;
      }
      if (mounted) setState(() => _pending = pending);
    } catch (error) {
      if (mounted) setState(() => _notice = '$error');
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  Future<void> _saveProgress(CompanionSetupIntent intent) async {
    await widget.progress?.save(intent);
    if (mounted) setState(() => _pending = intent);
  }

  Future<void> _clearProgress() async {
    final intent = _pending;
    if (intent != null) await widget.progress?.clear(intent.requestId);
    if (mounted) setState(() => _pending = null);
  }

  DeviceCompanionSetup? get _setup =>
      widget.progress == null || widget.reload == null
          ? null
          : DeviceCompanionSetup(
              store: widget.progress!,
              loadDevice: widget.reload!,
              bind: (intent) => widget.onBindCompanion!(
                  deviceId: _device.deviceId,
                  requestId: intent.requestId,
                  companionId: intent.companionId,
                  expectedRevision: intent.expectedRevision),
              setOutputs: (allowed, inputs, revision) => widget.onSetOutputs!(
                  deviceId: _device.deviceId,
                  allowed: allowed,
                  inputs: inputs,
                  expectedRevision: revision));

  Future<void> _resumeSetup() async {
    if (_binding || _removing || _recovering) return;
    final intent = _pending;
    if (intent == null) return;
    if (intent.step == CompanionSetupStep.outputs ||
        intent.step == CompanionSetupStep.savingOutputs) {
      await _decideOutputs();
    } else {
      await _bindCompanion(resume: true);
    }
  }

  Future<void> _stopSetup() async {
    if (_binding || _removing) return;
    setState(() => _binding = true);
    try {
      // Read before abandoning uncertain progress; never claim that cancelling
      // local continuation undoes a decision already accepted by the Host.
      final latest = await widget.reload?.call();
      if (latest != null && mounted) setState(() => _device = latest);
      await _clearProgress();
      if (mounted) {
        setState(() {
          _notice = '已保留主机当前设置。你可以重新选择；已创建的伙伴也会保留。';
          _creationNotice = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _notice = _setupError(error));
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_notice!)));
      }
    } finally {
      if (mounted) setState(() => _binding = false);
    }
  }

  final Random _random = Random.secure();
  bool _removing = false;
  bool _binding = false;

  /// Which of the two decisions is waiting on the Host.
  ///
  /// Both rows share [_binding], so without this the row nobody touched would
  /// claim to be contacting the Host as well.
  _DeviceDecision? _running;
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
  bool _creationNotice = false;
  String? _removalRequestId;

  /// Nothing on this page can act until the saved checkpoint has been read,
  /// so [_recovering] belongs here too. It used to gate the handlers but not
  /// the buttons, which left them lit and inert for the length of that read.
  bool get _busy => _binding || _removing || _recovering || _platformRemoved;

  /// A saved checkpoint sends both rows through [_resumeSetup]. The labels
  /// have to say so: a row that reads 「更换或解除」 and then silently resumes
  /// something else is the screen lying about its own control.
  bool get _resumesCompanion => _pending != null;

  bool get _resumesOutputs =>
      _pending != null &&
      _pending!.step != CompanionSetupStep.outputs &&
      _pending!.step != CompanionSetupStep.savingOutputs;

  Future<void> _bindCompanion({bool resume = false}) async {
    final bind = widget.onBindCompanion;
    final load = widget.loadCompanions;
    if (bind == null || load == null || _binding || _removing || _recovering) {
      return;
    }
    if (!resume && _pending != null) {
      await _resumeSetup();
      return;
    }
    setState(() {
      _binding = true;
      _running = _DeviceDecision.companion;
      _notice = null;
      _creationNotice = false;
    });
    try {
      var intent = resume ? _pending : null;
      if (intent == null) {
        final roster = await load();
        if (!mounted) return;
        final chosen = await showModalBottomSheet<_CompanionChoice>(
            context: context,
            builder: (_) => _CompanionPicker(
                loadFace: widget.loadFace,
                roster: roster,
                attachedCompanionId: _device.attachedCompanionId,
                canCreate: widget.onCreateCompanion != null));
        if (chosen == null || !mounted) return;
        // Deliberately not journalled yet. Choosing in the picker commits
        // nothing to the Host, so there is nothing here a later visit could
        // not reconstruct by asking the same question again.
        intent = CompanionSetupIntent(
            step: chosen.createNew
                ? CompanionSetupStep.creating
                : CompanionSetupStep.confirmBinding,
            requestId: _requestId('device-companion'),
            expectedRevision: _device.revision,
            companionId: chosen.companionId,
            companionName: chosen.name,
            description: chosen.description);
      }
      if (intent.step == CompanionSetupStep.creating) {
        final create = widget.onCreateCompanion;
        if (create == null) throw StateError('这台主机暂不允许创建伙伴。');
        final created = await create(intent);
        if (created == null) {
          // Backing out of creation and losing the app mid-creation look the
          // same from here; the journal tells them apart. An entry carrying an
          // operation id has a request with the Host behind it and must stay,
          // or the Companion it made is orphaned. Anything else was only a
          // choice, and must not survive the visit that made it.
          if (mounted) {
            await _readProgress();
            if (_pending?.creationOperationId == null) await _clearProgress();
          }
          return;
        }
        if (!mounted) return;
        intent = (await widget.progress?.load() ?? intent).at(
            CompanionSetupStep.confirmBinding,
            companionId: created.companionId,
            companionName: created.displayName);
        await _saveProgress(intent);
        if (!mounted) return;
        setState(() {
          _notice = '${created.displayName} 已创建。设备尚未更换应答伙伴。';
          _creationNotice = true;
        });
      }
      if (intent.step == CompanionSetupStep.confirmBinding) {
        if (!mounted) return;
        final selection = intent;
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                    title: Text(selection.companionId == null
                        ? '让设备暂时不回应？'
                        : '确认由这位伙伴回应？'),
                    content: Text(selection.companionId == null
                        ? '解除「${_device.label}」的伙伴关联。伙伴和记忆会保留。'
                        : '让「${selection.companionName}」通过「${_device.label}」回应。'
                            '${selection.description.isEmpty ? "" : "\n${selection.description}"}\n确认后才会更换这台设备的应答伙伴。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('暂不更换')),
                      FilledButton(
                          key: const Key('confirm-device-companion'),
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('确认'))
                    ]));
        if (confirmed != true || !mounted) {
          await _clearProgress();
          return;
        }
        intent = intent.at(CompanionSetupStep.binding);
        await _saveProgress(intent);
      }
      final setup = _setup;
      if (setup == null) {
        await bind(
            deviceId: _device.deviceId,
            requestId: intent.requestId,
            companionId: intent.companionId,
            expectedRevision: intent.expectedRevision);
        await _clearProgress();
      } else {
        final latest = await setup.finishBinding(intent);
        if (!mounted) return;
        setState(() => _device = latest);
        await _readProgress();
      }
      if (mounted && _pending == null) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _creationNotice = false;
          _notice = _setupError(error);
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_notice!)));
      }
    } finally {
      if (mounted) setState(() => _binding = false);
    }
  }

  Future<void> _decideOutputs() async {
    final decide = widget.onSetOutputs;
    if (decide == null || _binding || _removing || _recovering) return;
    if (_resumesOutputs) {
      await _resumeSetup();
      return;
    }
    setState(() {
      _binding = true;
      _running = _DeviceDecision.outputs;
      _notice = null;
      _creationNotice = false;
    });
    try {
      var intent = _pending;
      if (intent?.step != CompanionSetupStep.savingOutputs) {
        final latest = await widget.reload?.call();
        if (!mounted) return;
        if (latest != null) setState(() => _device = latest);
        if (intent != null &&
            _device.attachedCompanionId != intent.companionId) {
          throw StateError('应答伙伴已改变，请核对主机设置后重新选择表达方式。');
        }
        final chosen = await showModalBottomSheet<DeviceOutputsRequest>(
            context: context,
            isScrollControlled: true,
            builder: (_) => _OutputsPicker(outputs: _device.outputs));
        if (chosen == null || !mounted) return;
        intent = (intent ??
                CompanionSetupIntent(
                    step: CompanionSetupStep.outputs,
                    requestId: _requestId('device-outputs'),
                    expectedRevision: _device.revision,
                    companionId: _device.attachedCompanionId))
            .at(CompanionSetupStep.savingOutputs,
                allowed: chosen.allowed, inputs: chosen.inputs, outputRevision: _device.outputs.revision);
        await _saveProgress(intent);
      }
      final setup = _setup;
      if (setup == null) {
        await decide(
            deviceId: _device.deviceId,
            allowed: intent!.allowed!,
            inputs: intent.inputs,
            expectedRevision: intent.outputRevision!);
        await _clearProgress();
      } else {
        await setup.finishOutputs(intent!);
        await _readProgress();
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _notice = _setupError(error));
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_notice!)));
      }
    } finally {
      if (mounted) {
        setState(() {
          _binding = false;
          _running = null;
        });
      }
    }
  }

  Future<void> _confirmRemoval() async {
    final device = _device;
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
      _creationNotice = false;
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
  static String _quietText(MountedDevice device) =>
      switch (device.quietBecause) {
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
    final named = [
      if (outputs.inputCapabilities?.microphone == true)
        (outputs.inputs?.microphone ?? true) ? '收音已开启' : '收音已关闭',
      ..._outputNames(allowed),
    ];
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
                onPressed: _busy ? null : _bindCompanion,
                child: Text(_binding && _running == _DeviceDecision.companion
                    ? '正在联系主机…'
                    : _resumesCompanion
                        ? '继续配置'
                        : device.attachedCompanionId == null
                            ? '指定'
                            : '更换或解除'),
              ),
      );

  Widget _outputsTile(MountedDevice device) => ListTile(
        key: const Key('device-outputs'),
        title: const Text('它可以听和表达什么'),
        subtitle: Text(_outputsText(device.outputs)),
        trailing: widget.onSetOutputs == null
            ? null
            : TextButton(
                key: const Key('decide-device-outputs'),
                onPressed: _busy ? null : _decideOutputs,
                child: Text(_binding && _running == _DeviceDecision.outputs
                    ? '正在联系主机…'
                    : _resumesOutputs
                        ? '继续配置'
                        : device.outputs.decided
                            ? '更改'
                            : '设置'),
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
              onPressed: _busy ? null : act,
              child: Text(_binding ? '正在联系主机…' : action!),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final stateLabel = switch (device.state) {
      MountedDeviceState.ready => '已添加',
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
          if (widget.onChangeNetwork != null)
            OutlinedButton.icon(
              key: const Key('change-device-network'),
              onPressed: _busy ? null : widget.onChangeNetwork,
              icon: const Icon(Icons.wifi),
              label: const Text('恢复连接 / 更换 Wi-Fi'),
            ),
          if (_pending != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(switch (_pending!.step) {
                            CompanionSetupStep.creating => '伙伴创建还未确认',
                            CompanionSetupStep.confirmBinding =>
                              '伙伴已选好，等待你确认设备关联',
                            CompanionSetupStep.binding => '正在确认设备关联结果',
                            CompanionSetupStep.outputs => '伙伴已关联，还需要选择表达方式',
                            CompanionSetupStep.savingOutputs => '正在确认表达设置结果',
                          }),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, children: [
                            FilledButton(
                                key: const Key('resume-companion-setup'),
                                onPressed:
                                    _binding || _removing ? null : _resumeSetup,
                                child: const Text('继续配置')),
                            TextButton(
                                onPressed:
                                    _binding || _removing ? null : _stopSetup,
                                child: const Text('保留当前设置，结束配置')),
                          ])
                        ]))),

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
            // About this page, and only what is true of it. The sentence here
            // used to add that nothing on this Host observes presence, which
            // stopped being exactly right: the channel provider knows which
            // bodies are on a channel. That is "in a call", not "switched on",
            // so this page still cannot say — and no longer says anything
            // about what the rest of the Host can see.
            '这些是主机权威确认的挂载关系，不是设备此刻的状态：这台主机不观测设备有没有通电。',
          ),
          const SizedBox(height: 24),
          if (_notice case final notice?) ...[
            Card(
              // Access already gone is not a setback, whatever is still
              // converging behind it.
              color: _accessRevoked || _creationNotice
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
            '只更换 Wi-Fi 时，请使用“恢复连接 / 更换 Wi-Fi”，无需先移除。'
            '保留原身份的设备会继续使用原记录；设备被重置或身份改变后，需要另行恢复或重新认领。',
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
  late bool _microphone;

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
    _microphone = widget.outputs.inputs?.microphone ?? widget.outputs.decided;
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
          Text('它可以听和表达什么', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '收音控制是否允许发送麦克风声音；说话、文字和表情分别控制回复方式。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (widget.outputs.inputCapabilities?.microphone == true)
            SwitchListTile(
              key: const Key('device-input-microphone'),
              title: const Text('听说话'),
              subtitle: const Text('关闭后不采集麦克风声音，仍可接收已允许的回复'),
              value: _microphone,
              onChanged: (value) => setState(() => _microphone = value),
            ),
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
                if (widget.outputs.inputCapabilities?.microphone == true) _microphone = true;
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
              DeviceOutputsRequest(
                allowed: OutputSelection.fromJson({
                  for (final entry in _chosen.entries) entry.key: entry.value,
                }),
                inputs: widget.outputs.inputCapabilities == null ? null : InputSelection(
                  microphone: widget.outputs.inputCapabilities?.microphone == true && _microphone),
                expectedRevision: widget.outputs.revision,
              ),
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
  const _CompanionChoice(this.companionId,
      {this.name = '', this.description = ''})
      : createNew = false;
  const _CompanionChoice.create()
      : companionId = null,
        name = '',
        description = '',
        createNew = true;

  final String? companionId;
  final String name;
  final String description;
  final bool createNew;
}

class _CompanionPicker extends StatelessWidget {
  const _CompanionPicker({
    required this.roster,
    required this.attachedCompanionId,
    this.canCreate = false,
    this.loadFace,
  });

  final CompanionRosterView roster;
  final String? attachedCompanionId;
  final bool canCreate;
  final CompanionFaceLoader? loadFace;

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
            subtitle: Text('选择已有伙伴，或认识一位新伙伴。选好后还会请你确认，不会重新配网。'),
          ),
          if (canCreate)
            ListTile(
                key: const Key('device-create-companion'),
                leading: const Icon(Icons.person_add_alt_1),
                title: const Text('新建伙伴'),
                subtitle: const Text('选择角色或自定义，创建后回到这台设备确认。'),
                onTap: () =>
                    Navigator.of(context).pop(const _CompanionChoice.create())),
          const Divider(height: 1),
          if (active.isEmpty)
            const ListTile(
              key: Key('device-companion-picker-empty'),
              title: Text('这台主机上还没有可用的 Eidolon。'),
            ),
          ...active.map(
            (companion) => ListTile(
              key: Key('companion-choice-${companion.companionId}'),
              leading: CompanionPortrait(
                  companionId: companion.companionId,
                  name: _companionName(companion),
                  artworkId: companion.artworkId,
                  loadFace: loadFace),
              title: Text(
                _companionName(companion),
              ),
              subtitle: Text(_choiceDescription(companion, active)),
              trailing: companion.companionId == attachedCompanionId
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.of(context).pop(
                _CompanionChoice(companion.companionId,
                    name: _companionName(companion),
                    description: _choiceDescription(companion, active)),
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

String _companionName(CompanionSummaryView row) =>
    (row.displayName ?? '').trim().isEmpty ? '未命名伙伴' : row.displayName!.trim();

String _choiceDescription(
    CompanionSummaryView row, List<CompanionSummaryView> rows) {
  final peers = rows
      .where((other) => _companionName(other) == _companionName(row))
      .toList();
  final date = DateTime.tryParse(row.createdAt)?.toLocal();
  final created = date == null
      ? '创建时间未知'
      : '${date.year}/${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} 创建';
  if (peers.length < 2) return created;
  var length = 6;
  String suffix(String id) => id.substring(max(0, id.length - length));
  while (length < row.companionId.length &&
      peers.any((other) =>
          other.companionId != row.companionId &&
          suffix(other.companionId) == suffix(row.companionId))) {
    length++;
  }
  return '$created · 同名编号 ${suffix(row.companionId)}';
}

// Include later pages and refuse a looping cursor rather than show a partial list.
Future<CompanionRosterView> loadDeviceCompanionChoices(
    Future<CompanionRosterView> Function({String? cursor}) load) async {
  var page = await load();
  final defaultId = page.defaultCompanionId;
  final rows = <String, CompanionSummaryView>{};
  final seen = <String>{};
  while (true) {
    for (final row in page.companions) {
      rows[row.companionId] = row;
    }
    final cursor = page.nextCursor;
    if (cursor == null) break;
    if (!seen.add(cursor)) throw StateError('伙伴列表翻页未完成，请重新读取。');
    page = await load(cursor: cursor);
  }
  return CompanionRosterView(
      companions: rows.values.toList(), defaultCompanionId: defaultId);
}

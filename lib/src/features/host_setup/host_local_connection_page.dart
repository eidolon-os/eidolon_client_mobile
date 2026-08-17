import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../naming/ask_for_a_name.dart';

import '../device_management/mounted_devices_page.dart';
import '../device_setup/device_setup_ports.dart';
import '../setup/change_network_page.dart';
import '../setup/commissioning_transport.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/host_registry.dart';
import 'face_picker.dart';
import 'host_product_controller.dart';
import 'companion_page.dart';
import 'managed_controllers_page.dart';
import 'mission_control_page.dart';
import 'persona_history_page.dart';
import 'recollections_page.dart';
import 'host_product_session.dart';
import 'workspace_runtime_models.dart';
import 'host_system_page.dart';
import 'local_api_discovery.dart';
import 'workspace_models.dart';

export 'host_product_controller.dart' show ManagedHostUpdater;

typedef HostConversationBuilder = Widget Function(
  BuildContext context,
  HostProductController controller,
);

class HostLocalConnectionPage extends StatefulWidget {
  const HostLocalConnectionPage({
    super.key,
    required this.host,
    required this.onHostUpdated,
    this.transport,
    this.controllerKeys,
    this.discovery,
    this.localApiClientFactory,
    this.deviceProvisioning,
    this.conversationBuilder,
    this.setupContinuation = false,
    this.onSetupComplete,
    this.facePicker,
  }) : assert(!setupContinuation || onSetupComplete != null);

  final ManagedHost host;
  final ManagedHostUpdater onHostUpdated;
  final CommissioningTransport? transport;
  final ControllerKeyBridge? controllerKeys;
  final LocalApiDiscovery? discovery;
  final LocalApiClientFactory? localApiClientFactory;
  final DeviceProvisioningTransport? deviceProvisioning;
  final HostConversationBuilder? conversationBuilder;

  /// Where the picture an Eidolon wears comes from. The gallery, unless a
  /// test says otherwise.
  final FacePicker? facePicker;
  final bool setupContinuation;
  final VoidCallback? onSetupComplete;

  @override
  State<HostLocalConnectionPage> createState() =>
      _HostLocalConnectionPageState();
}

class _HostLocalConnectionPageState extends State<HostLocalConnectionPage> {
  late final HostProductController _controller;
  final _ownerName = TextEditingController();
  final _companionName = TextEditingController(text: 'Eidolon');

  @override
  void initState() {
    super.initState();
    _controller = HostProductController(
      host: widget.host,
      onHostUpdated: widget.onHostUpdated,
      transport: widget.transport,
      controllerKeys: widget.controllerKeys,
      discovery: widget.discovery,
      localApiClientFactory: widget.localApiClientFactory,
    )..addListener(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.connect();
    });
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_refresh)
      ..dispose();
    _ownerName.dispose();
    _companionName.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _openNetworkChange() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChangeNetworkPage(
          host: _controller.host,
          transport: widget.transport,
          controllerKeys: widget.controllerKeys,
        ),
      ),
    );
    if (mounted) await _controller.connect();
  }

  /// Ask what this person should be called, and tell the Host.
  Future<void> _renameOwner() async {
    final owner = _controller.workspace?.owner;
    if (owner == null) return;
    final name = await askForAName(
      context,
      question: '你叫什么？',
      hint: '它会这样称呼你',
      current: owner.displayName,
      dialogKey: const Key('rename-owner-dialog'),
      fieldKey: const Key('owner-name-field'),
      confirmKey: const Key('confirm-owner-name'),
    );
    if (name == null || !mounted) return;
    try {
      await _controller.renameOwner(displayName: name);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('改名没有完成：$error')),
      );
    }
  }

  /// Ask what this Eidolon should be called, and tell the Host.
  Future<void> _renameCompanion() async {
    final runtime = _controller.workspaceRuntime;
    if (runtime == null) return;
    final companion = runtime.primaryCompanion;
    final name = await askForAName(
      context,
      question: '这个 Eidolon 叫什么？',
      hint: '给它起个名字',
      current: companion.displayName,
      dialogKey: const Key('rename-companion-dialog'),
      fieldKey: const Key('companion-name-field'),
      confirmKey: const Key('confirm-companion-name'),
    );
    if (name == null || !mounted) return;
    try {
      await _controller.renameCompanion(
        companionId: companion.companionId,
        displayName: name,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('改名没有完成：$error')),
      );
    }
  }

  /// Open the Eidolon itself. A Host is a machine someone owns; this is who
  /// they talk to, and it had been living as rows on the machine's card.
  Future<void> _openCompanion() {
    final runtime = _controller.workspaceRuntime;
    if (runtime == null) return Future<void>.value();
    // Asked for as the page opens rather than with the rest of the workspace:
    // a photograph is worth fetching when someone is about to look at it.
    unawaited(
      _controller
          .loadCompanionFace(
            companionId: runtime.primaryCompanion.companionId,
          )
          .catchError((Object _) {}),
    );
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AnimatedBuilder(
          animation: _controller,
          builder: (_, __) {
            final current = _controller.workspaceRuntime;
            if (current == null) return const SizedBox.shrink();
            return CompanionPage(
              runtime: current,
              devices: _controller.devices,
              onRename: _renameCompanion,
              onOpenHistory: _openPersonaHistory,
              onOpenRecollections: () => _openRecollections(current),
              face: _controller.companionFace,
              onChangeFace: () => _changeCompanionFace(current),
              onClearFace: _controller.companionFace == null
                  ? null
                  : () => _clearCompanionFace(current),
            );
          },
        ),
      ),
    );
  }

  /// Ask this Eidolon what it remembers.
  Future<void> _openRecollections(WorkspaceRuntime runtime) {
    final name = runtime.primaryCompanion.displayName;
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RecollectionsPage(
          companionName: name.isNotEmpty ? name : '它',
          onSearch: (query) => _controller.recollections(query: query),
        ),
      ),
    );
  }

  /// Choose the picture this Eidolon wears.
  ///
  /// The picker is asked for a bounded JPEG rather than the original file. The
  /// face is a conditioning image for a digital human — a camera's full
  /// resolution is of no use to it, and would not fit through the pinned
  /// transport that carries everything else this app says to its Host.
  Future<void> _changeCompanionFace(WorkspaceRuntime runtime) async {
    final Uint8List? bytes;
    try {
      bytes = await (widget.facePicker ?? const GalleryFacePicker()).pickFace();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没能打开相册:$error')),
      );
      return;
    }
    if (bytes == null || !mounted) return;
    try {
      await _controller.setCompanionFace(
        companionId: runtime.primaryCompanion.companionId,
        face: bytes,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('这张照片没能用上:$error')),
      );
    }
  }

  Future<void> _clearCompanionFace(WorkspaceRuntime runtime) async {
    try {
      await _controller.clearCompanionFace(
        companionId: runtime.primaryCompanion.companionId,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没能拿掉这张脸:$error')),
      );
    }
  }

  Future<void> _openPersonaHistory() {
    final runtime = _controller.workspaceRuntime;
    if (runtime == null) return Future<void>.value();
    final companion = runtime.primaryCompanion;
    final name = companion.displayName.isNotEmpty
        ? companion.displayName
        : '它';
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PersonaHistoryPage(
          companionName: name,
          loadHistory: () => _controller.personaHistory(
            companionId: companion.companionId,
          ),
          restore: (chapterId) => _controller.restorePersona(
            companionId: companion.companionId,
            chapterId: chapterId,
          ),
        ),
      ),
    );
  }

  Future<void> _openControllers() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ManagedControllersPage(
            thisControllerId: _controller.controllerId,
            loadControllers: _controller.listControllers,
            invite: _controller.inviteController,
            revoke: (controllerId) =>
                _controller.revokeController(controllerId: controllerId),
          ),
        ),
      );

  /// What this Host is doing, and what happened on it lately.
  Future<void> _openMissionControl() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => MissionControlPage(
            loadActivity: _controller.activity,
            listServices: _controller.listHostServices,
            // What the Host already said, rather than asking again: this
            // screen is a place to look, not a second opinion.
            devices: _controller.devices,
            devicesError: _controller.devicesError,
          ),
        ),
      );

  Future<void> _openDevices() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => MountedDevicesPage(
            controller: _controller,
            deviceProvisioning: widget.deviceProvisioning,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final connection = _controller.connection;
    return Scaffold(
      key: const Key('host-local-connection-page'),
      appBar: AppBar(
        title: Text(
          (_controller.workspace?.isReady ?? false) ? '我的 Eidolon' : '连接主机',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            _controller.host.displayName,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text('仅连接同一局域网中的主机；发现地址后仍会验证 Host 和管理设备身份。'),
          const SizedBox(height: 24),
          if (_controller.connecting) ...[
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            Text(
              _controller.progress ?? '正在连接',
              key: const Key('local-connection-progress'),
              textAlign: TextAlign.center,
            ),
          ] else if (connection != null) ...[
            _ConnectedHostCard(
              connection: connection,
              // Offered only once there is an Owner for the history to belong
              // to. Before that there is nothing this screen could be about.
              onOpenActivity: (_controller.workspace?.isReady ?? false)
                  ? _openMissionControl
                  : null,
              onOpenSystem: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => HostSystemPage(
                    host: _controller.host,
                    connection: connection,
                    listServices: _controller.listHostServices,
                    changeService: _controller.changeHostService,
                    readVitals: _controller.hostVitals,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _WorkspaceCard(
              controller: _controller,
              ownerName: _ownerName,
              companionName: _companionName,
              setupContinuation: widget.setupContinuation,
              onSetupComplete: widget.onSetupComplete,
              onReconnect: _controller.connect,
              onRenameCompanion: _renameCompanion,
              onOpenPersona: _openPersonaHistory,
              onOpenCompanion: _openCompanion,
              onRenameOwner: _renameOwner,
              onChangeNetwork: _openNetworkChange,
            ),
            if ((_controller.workspace?.isReady ?? false) &&
                !widget.setupContinuation) ...[
              const SizedBox(height: 16),
              if (widget.conversationBuilder case final builder?) ...[
                _ConversationCard(
                  onOpen: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (context) => builder(context, _controller),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              _DevicesSummaryCard(
                controller: _controller,
                onOpen: _openDevices,
                onOpenControllers: _openControllers,
              ),
            ],
          ] else if (_controller.connectionError case final error?) ...[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(error, key: const Key('local-connection-error')),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('retry-local-connection'),
              onPressed: _controller.connect,
              icon: const Icon(Icons.refresh),
              label: const Text('重新连接'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('conversation-card'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.graphic_eq,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '对话',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '这台移动设备使用独立 Device 身份连接 Hub。首次使用需要完成设备批准和 Companion 绑定。',
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('open-conversation'),
                onPressed: onOpen,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('打开对话'),
              ),
            ],
          ),
        ),
      );
}

class _ConnectedHostCard extends StatelessWidget {
  const _ConnectedHostCard({
    required this.connection,
    required this.onOpenSystem,
    this.onOpenActivity,
  });

  final HostProductConnection connection;
  final VoidCallback onOpenSystem;

  /// Null until this Host has an Owner whose devices could have a history.
  final VoidCallback? onOpenActivity;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('local-connection-complete'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.verified_user,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '已安全连接',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Text(networkLabel(connection.overview.state.network)),
                ],
              ),
              const SizedBox(height: 16),
              // How the Host was located is not shown. It was the mDNS
              // instance name here, which was already developer detail, and
              // once locating gained other means it started printing their
              // internal labels — 服务：remembered — at a person. Where it
              // answered is a fact about their Host; which mechanism found it
              // is a fact about this App.
              Text('Host IP：${connection.endpoint.ipAddress}'),
              Text('Controller：${connection.controllerId}'),
              Text('本次管理会话有效至 ${_localTime(connection.sessionExpiresAt)}'),
              const SizedBox(height: 12),
              if (onOpenActivity case final open?) ...[
                FilledButton.tonalIcon(
                  key: const Key('open-mission-control'),
                  onPressed: open,
                  icon: const Icon(Icons.timeline),
                  label: const Text('主机动态'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                key: const Key('open-host-system-status'),
                onPressed: onOpenSystem,
                icon: const Icon(Icons.monitor_heart_outlined),
                label: const Text('查看系统状态'),
              ),
            ],
          ),
        ),
      );
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.controller,
    required this.ownerName,
    required this.companionName,
    required this.setupContinuation,
    required this.onSetupComplete,
    required this.onReconnect,
    required this.onChangeNetwork,
    required this.onRenameCompanion,
    required this.onOpenPersona,
    required this.onOpenCompanion,
    required this.onRenameOwner,
  });

  final HostProductController controller;
  final TextEditingController ownerName;
  final TextEditingController companionName;
  final bool setupContinuation;
  final VoidCallback? onSetupComplete;
  final Future<void> Function() onReconnect;
  final Future<void> Function() onChangeNetwork;
  final VoidCallback onRenameCompanion;
  final VoidCallback onOpenPersona;
  final VoidCallback onOpenCompanion;

  /// Null until the Host has a Workspace to name anyone in.
  final VoidCallback? onRenameOwner;

  @override
  Widget build(BuildContext context) {
    final workspace = controller.workspace;
    if (workspace?.isReady ?? false) {
      return _buildReady(context, workspace!);
    }
    if (workspace == null && controller.workspaceError != null) {
      return _buildUnavailable(context);
    }
    return Card(
      key: const Key('workspace-setup'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('完成你的 Eidolon', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('主机已经安全接入。现在创建首个 Owner、主 Companion 和 Workspace。'),
            if (controller.workspaceError case final error?) ...[
              const SizedBox(height: 12),
              Text(
                error,
                key: const Key('workspace-setup-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              key: const Key('workspace-owner-name'),
              controller: ownerName,
              enabled: !controller.workspaceBusy,
              maxLength: 128,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '怎么称呼你',
                hintText: '例如：Manson',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('workspace-companion-name'),
              controller: companionName,
              enabled: !controller.workspaceBusy,
              maxLength: 128,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _initialize(),
              decoration: const InputDecoration(
                labelText: 'Eidolon 的名字',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('initialize-workspace'),
              onPressed: controller.workspaceBusy ? null : _initialize,
              icon: controller.workspaceBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(controller.workspaceBusy ? '正在创建' : '创建我的 Eidolon'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('retry-workspace-status'),
              onPressed:
                  controller.workspaceBusy ? null : controller.refreshWorkspace,
              icon: const Icon(Icons.refresh),
              label: const Text('检查已有进度'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnavailable(BuildContext context) => Card(
        key: const Key('workspace-unavailable'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Workspace 状态暂不可用',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                controller.workspaceError!,
                key: const Key('workspace-setup-error'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const Key('retry-workspace-status'),
                onPressed: controller.workspaceBusy
                    ? null
                    : controller.refreshWorkspace,
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载 Workspace'),
              ),
            ],
          ),
        ),
      );

  void _initialize() => controller.initializeWorkspace(
        ownerDisplayName: ownerName.text,
        companionDisplayName: companionName.text,
      );

  Widget _buildReady(BuildContext context, WorkspaceStatus workspace) {
    final runtime = controller.workspaceRuntime;
    return Card(
      key: const Key('workspace-ready'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Eidolon 已准备就绪',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text('你好，${workspace.owner!.displayName}。'),
                ),
                if (onRenameOwner != null)
                  IconButton(
                    key: const Key('rename-owner'),
                    onPressed: onRenameOwner,
                    tooltip: '改名',
                    icon: const Icon(Icons.edit_outlined),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _WorkspaceResourceStatus(
              key: const Key('workspace-companion'),
              onOpen: runtime == null ? null : onOpenCompanion,
              icon: Icons.face_retouching_natural,
              // The name its Owner gave it, which is what they typed at setup
              // and had never been shown back to them. The identifier is what
              // remains when the Host cannot say.
              label: runtime?.primaryCompanion.displayName.isNotEmpty ?? false
                  ? runtime!.primaryCompanion.displayName
                  : '主 Companion',
              statusLabel: runtime == null ? '已创建' : '运行中',
              detail: runtime == null
                  ? 'Workspace 已创建'
                  : '打开它的页面：改名、它的变化、连到它的设备',
            ),
            _WorkspaceResourceStatus(
              icon: Icons.auto_stories_outlined,
              label: '它的记忆',
              statusLabel: runtime == null ? '已创建' : '运行中',
              // Not the realm identifier. That line was the only thing this
              // row ever said, and it named a thing an Owner cannot open,
              // search or act on — an identifier standing in for the fact
              // that there is nothing here to show yet.
              detail: runtime == null
                  ? '已经为它准备好'
                  : '它记住的东西留在这台主机上,没有离开过',
            ),
            if (controller.workspaceRuntimeError case final error?) ...[
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error,
                    key: const Key('workspace-runtime-error'),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                key: const Key('retry-workspace-runtime'),
                onPressed: controller.workspaceBusy
                    ? null
                    : controller.refreshWorkspace,
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载日常状态'),
              ),
            ],
            if (setupContinuation) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('finish-workspace-setup'),
                onPressed: onSetupComplete,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('进入我的 Eidolon'),
              ),
            ] else ...[
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                key: const Key('refresh-host-product-state'),
                onPressed: controller.connecting || controller.workspaceBusy
                    ? null
                    : onReconnect,
                icon: const Icon(Icons.refresh),
                label: const Text('重新发现并刷新'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('change-network-from-product'),
                onPressed: controller.connecting || controller.workspaceBusy
                    ? null
                    : onChangeNetwork,
                icon: const Icon(Icons.wifi),
                label: const Text('更换 Wi-Fi'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DevicesSummaryCard extends StatelessWidget {
  const _DevicesSummaryCard({
    required this.controller,
    required this.onOpen,
    required this.onOpenControllers,
  });

  final HostProductController controller;
  final VoidCallback onOpen;
  final VoidCallback onOpenControllers;

  @override
  Widget build(BuildContext context) {
    final count = controller.devices?.devices.length;
    return Card(
      key: const Key('mounted-devices-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_other_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child:
                      Text('设备', style: Theme.of(context).textTheme.titleLarge),
                ),
                if (count != null) Chip(label: Text('$count')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              controller.devicesError ??
                  (count == 0
                      ? '还没有由主机确认接入的设备。'
                      : '查看主机已确认挂载的设备和 Companion 关联。'),
              style: controller.devicesError == null
                  ? null
                  : TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              key: const Key('open-mounted-devices'),
              onPressed: onOpen,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('打开设备管理'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('open-managed-controllers'),
              onPressed: onOpenControllers,
              icon: const Icon(Icons.phonelink_lock_outlined),
              label: const Text('管理手机'),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceResourceStatus extends StatelessWidget {
  const _WorkspaceResourceStatus({
    super.key,
    required this.icon,
    required this.label,
    required this.detail,
    required this.statusLabel,
    this.onOpen,
  });

  final IconData icon;
  final String label;
  final String detail;
  final String statusLabel;

  /// Offered where the row stands for something with more behind it than a
  /// status. Tapping goes there; the row is not itself the whole story.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            if (onOpen != null)
              IconButton(
                key: const Key('open-persona-history'),
                onPressed: onOpen,
                tooltip: '它的变化',
                icon: const Icon(Icons.chevron_right),
              ),
            Icon(
              Icons.check_circle_outline,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 4),
            Text(statusLabel),
          ],
        ),
      );
}


String _localTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

import 'package:flutter/material.dart';

import '../device_management/mounted_devices_page.dart';
import '../device_setup/device_setup_ports.dart';
import '../setup/change_network_page.dart';
import '../setup/commissioning_transport.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/host_registry.dart';
import 'host_product_controller.dart';
import 'host_product_session.dart';
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
  }) : assert(!setupContinuation || onSetupComplete != null);

  final ManagedHost host;
  final ManagedHostUpdater onHostUpdated;
  final CommissioningTransport? transport;
  final ControllerKeyBridge? controllerKeys;
  final LocalApiDiscovery? discovery;
  final LocalApiClientFactory? localApiClientFactory;
  final LegacyHotspotProvisioningPort? deviceProvisioning;
  final HostConversationBuilder? conversationBuilder;
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
              onOpenSystem: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => HostSystemPage(
                    host: _controller.host,
                    connection: connection,
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
  });

  final HostProductConnection connection;
  final VoidCallback onOpenSystem;

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
              Text('服务：${connection.endpoint.instanceName}'),
              Text('Host IP：${connection.endpoint.ipAddress}'),
              Text('Controller：${connection.controllerId}'),
              Text('本次管理会话有效至 ${_localTime(connection.sessionExpiresAt)}'),
              const SizedBox(height: 12),
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
  });

  final HostProductController controller;
  final TextEditingController ownerName;
  final TextEditingController companionName;
  final bool setupContinuation;
  final VoidCallback? onSetupComplete;
  final Future<void> Function() onReconnect;
  final Future<void> Function() onChangeNetwork;

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
            Text('你好，${workspace.owner!.displayName}。'),
            const SizedBox(height: 12),
            _WorkspaceResourceStatus(
              icon: Icons.face_retouching_natural,
              label: '主 Companion',
              statusLabel: runtime == null ? '已创建' : '运行中',
              detail: runtime == null
                  ? 'Workspace 已创建'
                  : '运行身份 ${_shortId(runtime.primaryCompanion.companionId)}',
            ),
            _WorkspaceResourceStatus(
              icon: Icons.psychology_alt_outlined,
              label: 'Persona',
              statusLabel: runtime == null ? '已创建' : '运行中',
              detail: runtime == null
                  ? 'Workspace 已创建'
                  : 'v${runtime.persona.version} · ${_shortId(runtime.persona.genomeId)}',
            ),
            _WorkspaceResourceStatus(
              icon: Icons.auto_stories_outlined,
              label: 'Memory Workspace',
              statusLabel: runtime == null ? '已创建' : '运行中',
              detail: runtime == null
                  ? 'Workspace 已创建'
                  : '运行空间 ${_shortId(runtime.memoryWorkspace.realmId)}',
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
  });

  final HostProductController controller;
  final VoidCallback onOpen;

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
          ],
        ),
      ),
    );
  }
}

class _WorkspaceResourceStatus extends StatelessWidget {
  const _WorkspaceResourceStatus({
    required this.icon,
    required this.label,
    required this.detail,
    required this.statusLabel,
  });

  final IconData icon;
  final String label;
  final String detail;
  final String statusLabel;

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

String _shortId(String value) {
  if (value.length <= 16) return value;
  return '…${value.substring(value.length - 12)}';
}

String _localTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

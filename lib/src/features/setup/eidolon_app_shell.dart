import 'dart:async';

import 'package:flutter/material.dart';

import '../naming/ask_for_a_name.dart';
import 'package:flutter/foundation.dart';

import '../device_setup/device_setup_ports.dart';
import '../../management/management_client.dart';
import '../host_setup/host_local_connection_page.dart';
import '../host_setup/host_product_controller.dart';
import '../host_setup/host_product_session.dart';
import 'commissioning_transport.dart';
import 'change_network_page.dart';
import 'controller_key_bridge.dart';
import 'controller_recovery_page.dart';
import 'host_registry.dart';
import 'host_list_info.dart';
import '../host_setup/host_locator.dart';
import '../host_setup/local_api_candidate_sources.dart';
import '../host_setup/local_api_discovery.dart';
import '../host_setup/network_changes.dart';
import 'setup_wizard_page.dart';

class EidolonAppShell extends StatefulWidget {
  const EidolonAppShell({
    super.key,
    this.registry,
    this.hostInfoReader,
    this.networkChanges,
    this.setupTransport,
    this.controllerKeys,
    this.deviceProvisioning,
    this.conversationBuilder,
  });

  final HostRegistry? registry;
  final HostListInfoReader? hostInfoReader;
  final NetworkChanges? networkChanges;
  final CommissioningTransport? setupTransport;
  final ControllerKeyBridge? controllerKeys;
  final DeviceProvisioningTransport? deviceProvisioning;
  final HostConversationBuilder? conversationBuilder;

  @override
  State<EidolonAppShell> createState() => _EidolonAppShellState();
}

class _EidolonAppShellState extends State<EidolonAppShell>
    with WidgetsBindingObserver {
  late final HostRegistry _registry;
  List<ManagedHost>? _hosts;
  final Map<String, String> _hostStatuses = {};
  late final NetworkChanges _networkChanges;
  StreamSubscription<void>? _networkSubscription;
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  bool _foreground = true;
  int _revision = 0;
  Completer<void>? _refreshCancelled;
  final _refreshSessions = <HostProductSession>{};

  void _cancelRefresh() {
    _revision += 1;
    final cancelled = _refreshCancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    for (final session in _refreshSessions.toList()) {
      unawaited(session.close());
    }
    _refreshSessions.clear();
  }

  @override
  void initState() {
    super.initState();
    _registry = widget.registry ??
        (defaultTargetPlatform == TargetPlatform.android
            ? PlatformHostRegistry()
            : InMemoryHostRegistry());
    WidgetsBinding.instance.addObserver(this);
    _networkChanges = widget.networkChanges ?? PlatformNetworkChanges();
    _networkSubscription = _networkChanges.changes.listen((_) {
      if (_foreground &&
          mounted &&
          ModalRoute.of(context)?.isCurrent != false) {
        unawaited(_load());
      } else {
        _cancelRefresh();
      }
    });
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _cancelRefresh();
    if (_foreground && ModalRoute.of(context)?.isCurrent != false) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _cancelRefresh();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_networkSubscription?.cancel());
    unawaited(_networkChanges.close());
    super.dispose();
  }

  Future<void> _load({bool refreshInfo = true}) async {
    if (!refreshInfo) {
      final hosts = await _registry.load();
      if (mounted) setState(() => _hosts = hosts);
      return;
    }
    _cancelRefresh();
    _refreshAgain = true;
    await (_refreshing ??=
        _refreshHosts().whenComplete(() => _refreshing = null));
  }

  Future<void> _refreshHosts() async {
    do {
      _refreshAgain = false;
      final revision = _revision;
      final cancelled = _refreshCancelled = Completer<void>();
      final hosts = await _registry.load();
      if (!mounted) return;
      setState(() => _hosts = hosts);
      if (!_foreground || ModalRoute.of(context)?.isCurrent == false) return;
      final discovery = LocalApiDiscoveryPass(platformLocalApiDiscovery(
          hostNames: hosts.expand(hostNamesRemembered).toSet()));
      await Future.wait(hosts.map((host) async {
        bool current() =>
            mounted &&
            _foreground &&
            revision == _revision &&
            ModalRoute.of(context)?.isCurrent != false;
        if (!current()) return;
        setState(() => _hostStatuses[host.hostId] = '正在查找主机');
        HostProductSession? ownedSession;
        try {
          final result = await Future.any<HostListInfo?>([
            widget.hostInfoReader != null
                ? widget.hostInfoReader!(host)
                : readHostListInfo(host, discovery: discovery,
                    onProgress: (status) {
                    if (current()) {
                      setState(() => _hostStatuses[host.hostId] = status);
                    }
                  }, onSession: (session) {
                    ownedSession = session;
                    if (current()) {
                      _refreshSessions.add(session);
                    } else {
                      unawaited(session.close());
                    }
                  }),
            cancelled.future.then((_) => null),
          ]);
          if (result == null || !current()) return;
          final updated = await _registry.updateObservation(result.host);
          if (updated == null || !current()) return;
          setState(() {
            _hosts = _hosts
                ?.map((h) => h.hostId == updated.hostId ? updated : h)
                .toList();
            _hostStatuses[host.hostId] =
                updated.lastConnectedAt == result.host.lastConnectedAt
                    ? result.status
                    : '可连接';
          });
        } catch (_) {
          if (current()) {
            setState(() => _hostStatuses[host.hostId] = '暂时无法确认 · 重新查找');
          }
        } finally {
          _refreshSessions.remove(ownedSession);
          await ownedSession?.close();
        }
      }));
    } while (_refreshAgain && mounted && _foreground);
  }

  Future<void> _observeHost(ManagedHost host) async {
    await _registry.updateObservation(host);
    await _load(refreshInfo: false);
  }

  Future<void> _openSetup() async {
    _cancelRefresh();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => SetupWizardPage(
          registry: _registry,
          transport: widget.setupTransport,
          controllerKeys: widget.controllerKeys,
          onComplete: (host) async {
            final known = (await _registry.load())
                .where((item) => item.hostId == host.hostId)
                .firstOrNull;
            if (known == null) await _registry.save(host);
            final registered = known ?? host;
            if (!context.mounted) return;
            await Navigator.of(context).pushReplacement<void, void>(
              MaterialPageRoute(
                builder: (localContext) => HostLocalConnectionPage(
                  host: registered,
                  onHostUpdated: _observeHost,
                  transport: widget.setupTransport,
                  controllerKeys: widget.controllerKeys,
                  setupContinuation: known == null,
                  onSetupComplete: () => Navigator.of(localContext).pop(),
                  conversationBuilder: widget.conversationBuilder,
                ),
              ),
            );
          },
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;
    if (hosts == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (hosts.isEmpty) {
      return _WelcomePage(onSetup: _openSetup);
    }
    return _HostsPage(
      hosts: hosts,
      statuses: _hostStatuses,
      onAdd: _openSetup,
      onHostUpdated: (host) async {
        await _registry.save(host);
        await _load(refreshInfo: false);
      },
      onHostObserved: _observeHost,
      onRefresh: _load,
      onLeave: _cancelRefresh,
      onHostRemoved: (hostId) async {
        await _registry.remove(hostId);
        await _load();
      },
      setupTransport: widget.setupTransport,
      controllerKeys: widget.controllerKeys,
      deviceProvisioning: widget.deviceProvisioning,
      conversationBuilder: widget.conversationBuilder,
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.onSetup});

  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('eidolon-welcome-page'),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.blur_on, size: 72),
                    const SizedBox(height: 24),
                    Text(
                      '让 Eidolon 主机准备就绪',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '无需屏幕、SSH 或预先联网。手机会找到主机、配置 Wi-Fi、完成本地认领，并创建你的 Eidolon Workspace。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    FilledButton.icon(
                      key: const Key('start-host-setup'),
                      onPressed: onSetup,
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('设置新主机'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '主机认领完成后会立即保存；如果 Workspace 暂不可用，可以稍后继续。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _HostsPage extends StatelessWidget {
  const _HostsPage({
    required this.hosts,
    required this.statuses,
    required this.onAdd,
    required this.onHostUpdated,
    required this.onHostObserved,
    required this.onRefresh,
    required this.onLeave,
    required this.onHostRemoved,
    this.setupTransport,
    this.controllerKeys,
    this.deviceProvisioning,
    this.conversationBuilder,
  });

  final List<ManagedHost> hosts;
  final Map<String, String> statuses;
  final VoidCallback onAdd;
  final ManagedHostUpdater onHostUpdated;
  final ManagedHostUpdater onHostObserved;
  final Future<void> Function() onRefresh;
  final VoidCallback onLeave;
  final Future<void> Function(String hostId) onHostRemoved;
  final CommissioningTransport? setupTransport;
  final ControllerKeyBridge? controllerKeys;
  final DeviceProvisioningTransport? deviceProvisioning;
  final HostConversationBuilder? conversationBuilder;

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('managed-hosts-page'),
        appBar: AppBar(
          title: const Text('我的 Eidolon'),
          actions: [
            IconButton(
                onPressed: onRefresh,
                tooltip: '重新查找主机',
                icon: const Icon(Icons.refresh)),
            IconButton(
              key: const Key('add-another-host'),
              onPressed: onAdd,
              tooltip: '设置另一台主机',
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        body: ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: hosts.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final host = hosts[index];
            return Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(18),
                leading: const CircleAvatar(child: Icon(Icons.memory)),
                title: Text(host.displayName),
                subtitle: _HostIdentitySummary(
                    host: host,
                    showAddress: false,
                    status: statuses[host.hostId] ?? '待确认连接'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  onLeave();
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => _HostDetailPage(
                        host: host,
                        onHostUpdated: onHostUpdated,
                        onHostObserved: onHostObserved,
                        onHostRemoved: onHostRemoved,
                        setupTransport: setupTransport,
                        controllerKeys: controllerKeys,
                        deviceProvisioning: deviceProvisioning,
                        conversationBuilder: conversationBuilder,
                      ),
                    ),
                  );
                  await onRefresh();
                },
              ),
            );
          },
        ),
      );
}

class _HostDetailPage extends StatefulWidget {
  const _HostDetailPage({
    required this.host,
    required this.onHostUpdated,
    required this.onHostObserved,
    required this.onHostRemoved,
    this.setupTransport,
    this.controllerKeys,
    this.deviceProvisioning,
    this.conversationBuilder,
  });

  final ManagedHost host;
  final ManagedHostUpdater onHostUpdated;
  final ManagedHostUpdater onHostObserved;
  final Future<void> Function(String hostId) onHostRemoved;
  final CommissioningTransport? setupTransport;
  final ControllerKeyBridge? controllerKeys;
  final DeviceProvisioningTransport? deviceProvisioning;
  final HostConversationBuilder? conversationBuilder;

  @override
  State<_HostDetailPage> createState() => _HostDetailPageState();
}

class _HostDetailPageState extends State<_HostDetailPage> {
  late ManagedHost host = widget.host;

  CommissioningTransport? get setupTransport => widget.setupTransport;
  ControllerKeyBridge? get controllerKeys => widget.controllerKeys;
  DeviceProvisioningTransport? get deviceProvisioning =>
      widget.deviceProvisioning;
  HostConversationBuilder? get conversationBuilder =>
      widget.conversationBuilder;
  ManagedHostUpdater get onHostUpdated => widget.onHostUpdated;
  Future<void> Function(String hostId) get onHostRemoved =>
      widget.onHostRemoved;

  bool _openingConversation = false;

  Future<void> _openConversation() async {
    final builder = conversationBuilder;
    if (builder == null || _openingConversation) return;
    _openingConversation = true;
    final controller = HostProductController(
        host: host,
        transport: setupTransport,
        controllerKeys: controllerKeys,
        onHostUpdated: (updated) async {
          await widget.onHostObserved(updated);
          if (mounted) setState(() => host = updated);
        });
    try {
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (context) => builder(context, controller)));
    } finally {
      controller.dispose();
      _openingConversation = false;
    }
  }

  /// What this Host is called is this phone's to decide.
  ///
  /// A Host names itself after its own identifier, so a second one looks like
  /// the first with different hex. The name lives in this phone's registry
  /// rather than on the Host, and that is the whole story: nothing is asked of
  /// the Host, and nothing about it changes.
  Future<void> _renameHost() async {
    final name = await askForAName(
      context,
      question: '这台主机叫什么？',
      hint: '比如「书房那台」',
      current: host.displayName,
      dialogKey: const Key('rename-host-dialog'),
      fieldKey: const Key('host-name-field'),
      confirmKey: const Key('confirm-host-name'),
    );
    if (name == null || name == host.displayName) return;
    final renamed = host.copyWith(displayName: name);
    await onHostUpdated(renamed);
    if (mounted) setState(() => host = renamed);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('managed-host-detail'),
        appBar: AppBar(
          title: Text(host.displayName),
          actions: [
            IconButton(
              key: const Key('rename-host'),
              onPressed: _renameHost,
              tooltip: '改名',
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const CircleAvatar(radius: 24, child: Icon(Icons.memory)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            host.displayName,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 4),
                          _HostIdentitySummary(host: host, status: '已保存的主机资料'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (conversationBuilder != null) ...[
              _ManagementEntry.available(
                key: const Key('open-device-conversation'),
                icon: Icons.graphic_eq_rounded,
                title: '开始对话',
                subtitle: '将本机作为虚拟设备，与这台主机上的伙伴交谈',
                onTap: _openConversation,
              ),
              const SizedBox(height: 20),
            ],
            Text('主机管理', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _ManagementEntry.available(
              key: const Key('connect-local-host'),
              icon: Icons.lan_outlined,
              title: '打开我的 Eidolon',
              subtitle: '安全连接主机，查看状态或继续完成设置',
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => HostLocalConnectionPage(
                    host: host,
                    onHostUpdated: (updated) async {
                      await widget.onHostObserved(updated);
                      if (mounted) setState(() => host = updated);
                    },
                    transport: setupTransport,
                    controllerKeys: controllerKeys,
                    deviceProvisioning: deviceProvisioning,
                    conversationBuilder: conversationBuilder,
                  ),
                ),
              ),
            ),
            _ManagementEntry.available(
              key: const Key('change-host-network'),
              icon: Icons.wifi,
              title: '更换 Wi-Fi',
              subtitle: '保留 Owner、Controller 和主机数据；需要靠近主机',
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ChangeNetworkPage(
                    host: host,
                    controllerKeys: controllerKeys,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('设备', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _ManagementEntry.unavailable(
              key: const Key('add-device-needs-session'),
              icon: Icons.developer_board_outlined,
              title: '添加设备',
              subtitle: '设置一台设备要把这台主机的身份交给它，请先打开我的 Eidolon',
            ),
            _ManagementEntry.unavailable(
              key: const Key('manage-controllers-needs-session'),
              icon: Icons.admin_panel_settings_outlined,
              title: '管理手机',
              // The Host has answered this for a while; what this page lacks is
              // a session, the same thing 添加设备 lacks here.
              subtitle: '查看、添加或撤销管理这台主机的手机，请先打开我的 Eidolon',
            ),
            const SizedBox(height: 20),
            Text(
              '恢复',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
            const SizedBox(height: 8),
            _ManagementEntry.available(
              key: const Key('controller-recovery'),
              icon: Icons.phonelink_erase_outlined,
              title: '手机丢失或重新认领',
              // Open, but honest about what it needs: the Host opens the
              // window, not this phone. An entry that could open it remotely
              // would hand the same key to whoever stole the phone.
              subtitle: '需要有人在主机旁边开一次限时窗口；会撤销所有已授权手机',
              destructive: true,
              onTap: () => _openControllerRecovery(context),
            ),
            _ManagementEntry.available(
              key: const Key('forget-managed-host'),
              icon: Icons.delete_outline,
              title: '不再管理这台主机',
              subtitle: '这台手机会忘记它；主机本身不受影响',
              destructive: true,
              onTap: () => _confirmForget(context),
            ),
            const SizedBox(height: 20),
            // Kept, but no longer the first thing about a Host. These are what
            // one machine is called by other machines; an Owner needs them
            // when something has gone wrong, and never before that.
            Card(
              child: ExpansionTile(
                key: const Key('host-technical-identity'),
                leading: const Icon(Icons.fingerprint),
                title: const Text('技术信息'),
                subtitle: const Text('出问题时用得上'),
                childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('主机 ID', style: Theme.of(context).textTheme.labelMedium),
                  SelectableText(host.hostId),
                  const SizedBox(height: 8),
                  Text('Controller',
                      style: Theme.of(context).textTheme.labelMedium),
                  SelectableText(host.controllerId),
                ],
              ),
            ),
          ],
        ),
      );

  /// Explain the recovery, then hand the Owner back to the claim flow.
  ///
  /// Re-claiming produces a new Controller grant for the same Host, so the
  /// registry entry is updated rather than added — and the name this phone
  /// gave the Host is this phone's, so it survives the Host forgetting who
  /// held it.
  Future<void> _openControllerRecovery(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (recoveryContext) => ControllerRecoveryPage(
          host: host,
          onReclaim: () => Navigator.of(recoveryContext).pushReplacement(
            MaterialPageRoute(
              builder: (wizardContext) => SetupWizardPage(
                transport: setupTransport,
                controllerKeys: controllerKeys,
                onComplete: (reclaimed) async {
                  final renamed =
                      reclaimed.copyWith(displayName: host.displayName);
                  await onHostUpdated(renamed);
                  if (mounted) setState(() => host = renamed);
                  if (wizardContext.mounted) {
                    Navigator.of(wizardContext).pop();
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmForget(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('confirm-forget-host'),
        title: Text('移除 ${host.displayName}？'),
        content: const Text(
          '这只会让这台手机忘记它。主机上的 Owner、设备和数据都不受影响；'
          '如果它还在，可以重新设置一次把它加回来。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-forget-host-action'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await onHostRemoved(host.hostId);
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _ManagementEntry extends StatelessWidget {
  const _ManagementEntry.available({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required VoidCallback onTap,
    this.destructive = false,
  })  : _onTap = onTap,
        _unavailable = false;

  // Nothing still-unbuilt is destructive: the one entry that was both is now
  // open, and an unavailable row cannot take anything away by being read.
  const _ManagementEntry.unavailable({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  })  : _onTap = null,
        _unavailable = true,
        destructive = false;

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? _onTap;
  final bool _unavailable;
  final bool destructive;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: Icon(
            icon,
            color: destructive ? Theme.of(context).colorScheme.error : null,
          ),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: _unavailable
              ? const Chip(label: Text(holdNotBuilt))
              : const Icon(Icons.chevron_right),
          enabled: !_unavailable,
          onTap: _onTap,
        ),
      );
}

class _HostIdentitySummary extends StatelessWidget {
  const _HostIdentitySummary(
      {required this.host, required this.status, this.showAddress = true});
  final ManagedHost host;
  final String status;
  final bool showAddress;

  @override
  Widget build(BuildContext context) {
    final info = host.machineInfo;
    final address = Uri.tryParse(host.lastKnownBaseUrl ?? '')?.host;
    final hardware = <String>[
      if (info?.model?.isNotEmpty == true) info!.model!,
      if (info?.cpuModel?.isNotEmpty == true && info!.cpuModel != info.model)
        info.cpuModel!,
      if ((info?.cpuCores ?? 0) > 0) '${info!.cpuCores} 核',
      if ((info?.memoryBytes ?? 0) > 0)
        '${(info!.memoryBytes! / (1024 * 1024 * 1024)).toStringAsFixed(0)} GiB 内存',
    ];
    final last = host.lastConnectedAt?.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hardware.isEmpty ? '机型待主机提供' : hardware.join(' · ')),
        if (info?.operatingSystem?.isNotEmpty == true)
          Text(info!.operatingSystem!),
        if (info?.hostname.isNotEmpty == true) Text('主机名：${info!.hostname}'),
        if (showAddress)
          Text(address?.isNotEmpty == true ? '上次连接地址：$address' : 'IP 尚未确认'),
        const SizedBox(height: 6),
        Text(status, style: Theme.of(context).textTheme.labelMedium),
        if (last != null)
          Text(
              '最近连接：${last.year}-${two(last.month)}-${two(last.day)} ${two(last.hour)}:${two(last.minute)}',
              style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

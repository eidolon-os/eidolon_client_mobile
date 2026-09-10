import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart';

import '../device_setup/device_setup_ports.dart';
import '../host_setup/host_local_connection_page.dart';
import '../host_setup/host_product_session.dart';
import 'commissioning_transport.dart';
import 'controller_key_bridge.dart';
import 'host_registry.dart';
import 'host_identity_summary.dart';
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
                  onHostRenamed: (id, name) => _registry.rename(id, name),
                  onHostSaved: (updated) async {
                    await _registry.save(updated);
                    await _load(refreshInfo: false);
                  },
                  onHostRemoved: (id) async {
                    await _registry.remove(id);
                    await _load(refreshInfo: false);
                  },
                  deviceProvisioning: widget.deviceProvisioning,
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
      onHostRenamed: (id, name) => _registry.rename(id, name),
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
    required this.onHostRenamed,
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
  final Future<void> Function(String hostId, String name) onHostRenamed;
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
                subtitle: HostIdentitySummary(
                    host: host,
                    showAddress: true,
                    status: statuses[host.hostId] ?? '待确认连接'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  onLeave();
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => HostLocalConnectionPage(
                        host: host,
                        onHostUpdated: onHostObserved,
                        onHostSaved: onHostUpdated,
                        onHostRenamed: onHostRenamed,
                        onHostRemoved: onHostRemoved,
                        transport: setupTransport,
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

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'commissioning_transport.dart';
import 'change_network_page.dart';
import 'controller_key_bridge.dart';
import 'host_registry.dart';
import 'setup_wizard_page.dart';

class EidolonAppShell extends StatefulWidget {
  const EidolonAppShell({
    super.key,
    this.registry,
    this.setupTransport,
    this.controllerKeys,
  });

  final HostRegistry? registry;
  final CommissioningTransport? setupTransport;
  final ControllerKeyBridge? controllerKeys;

  @override
  State<EidolonAppShell> createState() => _EidolonAppShellState();
}

class _EidolonAppShellState extends State<EidolonAppShell> {
  late final HostRegistry _registry;
  List<ManagedHost>? _hosts;

  @override
  void initState() {
    super.initState();
    _registry = widget.registry ??
        (defaultTargetPlatform == TargetPlatform.android
            ? PlatformHostRegistry()
            : InMemoryHostRegistry());
    _load();
  }

  Future<void> _load() async {
    final hosts = await _registry.load();
    if (mounted) setState(() => _hosts = hosts);
  }

  Future<void> _openSetup() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => SetupWizardPage(
          transport: widget.setupTransport,
          controllerKeys: widget.controllerKeys,
          onComplete: (host) async {
            await _registry.save(host);
            if (!context.mounted) return;
            Navigator.of(context).pop();
            await _load();
          },
        ),
      ),
    );
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
      onAdd: _openSetup,
      controllerKeys: widget.controllerKeys,
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
                      '无需屏幕、SSH 或预先联网。手机会在附近找到主机，安全配置 Wi-Fi，并完成本地认领。',
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
                      '完成认领后，这台手机会把主机保存在“我的 Eidolon”。',
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
    required this.onAdd,
    this.controllerKeys,
  });

  final List<ManagedHost> hosts;
  final VoidCallback onAdd;
  final ControllerKeyBridge? controllerKeys;

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('managed-hosts-page'),
        appBar: AppBar(
          title: const Text('我的 Eidolon'),
          actions: [
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
                subtitle: Text('已认领 · ${host.hostId}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => _HostDetailPage(
                      host: host,
                      controllerKeys: controllerKeys,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
}

class _HostDetailPage extends StatelessWidget {
  const _HostDetailPage({required this.host, this.controllerKeys});

  final ManagedHost host;
  final ControllerKeyBridge? controllerKeys;

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('managed-host-detail'),
        appBar: AppBar(title: Text(host.displayName)),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('主机身份', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    SelectableText(host.hostId),
                    const SizedBox(height: 4),
                    Text('Controller：${host.controllerId}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('主机管理', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
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
            _ManagementEntry.unavailable(
              key: const Key('manage-controllers-unavailable'),
              icon: Icons.admin_panel_settings_outlined,
              title: '管理手机',
              subtitle: '需要先实现 Host Controller Grant 管理协议',
            ),
            const SizedBox(height: 20),
            Text(
              '恢复',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
            const SizedBox(height: 8),
            _ManagementEntry.unavailable(
              key: const Key('controller-recovery-unavailable'),
              icon: Icons.phonelink_erase_outlined,
              title: '手机丢失或重新认领',
              subtitle: '需要先实现主机侧限时物理恢复通道',
              destructive: true,
            ),
          ],
        ),
      );
}

class _ManagementEntry extends StatelessWidget {
  const _ManagementEntry.available({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required VoidCallback onTap,
  })  : _onTap = onTap,
        _unavailable = false,
        destructive = false;

  const _ManagementEntry.unavailable({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.destructive = false,
  })  : _onTap = null,
        _unavailable = true;

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
              ? const Chip(label: Text('尚未开放'))
              : const Icon(Icons.chevron_right),
          enabled: !_unavailable,
          onTap: _onTap,
        ),
      );
}

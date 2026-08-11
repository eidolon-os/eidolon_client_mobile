import 'package:flutter/material.dart';

import '../setup/host_registry.dart';
import 'host_models.dart';
import 'host_product_session.dart';
import 'host_service_models.dart';

typedef HostServiceLister = Future<HostServiceInventory> Function();
typedef HostServiceChanger = Future<HostServiceChange> Function({
  required String serviceId,
  required String operation,
  required int expectedRevision,
});

class HostSystemPage extends StatelessWidget {
  const HostSystemPage({
    super.key,
    required this.host,
    required this.connection,
    this.listServices,
    this.changeService,
  });

  final ManagedHost host;
  final HostProductConnection connection;

  /// Host services are optional so a Host that predates the contract still
  /// renders its status instead of failing the whole page.
  final HostServiceLister? listServices;
  final HostServiceChanger? changeService;

  @override
  Widget build(BuildContext context) {
    final state = connection.overview.state;
    return Scaffold(
      key: const Key('host-system-page'),
      appBar: AppBar(title: const Text('系统状态')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _StatusHeader(state: state),
          const SizedBox(height: 16),
          _SectionCard(
            title: '本地连接',
            children: [
              _StatusRow(label: '服务', value: connection.endpoint.instanceName),
              _StatusRow(
                  label: 'Host IP', value: connection.endpoint.ipAddress),
              _StatusRow(
                label: '管理会话',
                value: '有效至 ${_dateTime(connection.sessionExpiresAt)}',
              ),
              _StatusRow(label: 'Controller', value: connection.controllerId),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '主机状态',
            children: [
              _StatusRow(
                label: '运行模式',
                value: connection.overview.mode == BootstrapMode.development
                    ? '开发'
                    : '产品',
              ),
              _StatusRow(label: 'Owner', value: _claimLabel(state.claim)),
              _StatusRow(label: '网络', value: networkLabel(state.network)),
              _StatusRow(
                label: 'Workspace',
                value: _workspaceLabel(state.workspace),
              ),
              _StatusRow(label: 'Reset epoch', value: '${state.resetEpoch}'),
              _StatusRow(label: '状态更新时间', value: _dateTime(state.updatedAt)),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '主机身份',
            children: [
              _SelectableStatusRow(label: 'Host ID', value: host.hostId),
              _SelectableStatusRow(
                label: 'Host fingerprint',
                value: host.hostFingerprint,
              ),
            ],
          ),
          if (listServices case final lister?) ...[
            const SizedBox(height: 16),
            _HostServicesCard(
              listServices: lister,
              changeService: changeService,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '这里展示主机状态与服务。发布、激活和回滚仍由 Ops 在工作站执行。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.state});

  final HostBootstrapState state;

  @override
  Widget build(BuildContext context) {
    final healthy = state.claim == HostClaimState.claimed &&
        state.network == HostNetworkState.connected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(
              healthy ? Icons.check_circle : Icons.warning_amber_rounded,
              size: 34,
              color: healthy
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.tertiary,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    healthy ? '主机本地管理正常' : '主机需要关注',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text('网络：${networkLabel(state.network)}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HostServicesCard extends StatefulWidget {
  const _HostServicesCard({required this.listServices, this.changeService});

  final HostServiceLister listServices;
  final HostServiceChanger? changeService;

  @override
  State<_HostServicesCard> createState() => _HostServicesCardState();
}

class _HostServicesCardState extends State<_HostServicesCard> {
  List<HostService>? _services;
  String? _error;
  String? _busyServiceId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inventory = await widget.listServices();
      if (!mounted) return;
      setState(() {
        _services = inventory.services;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _restart(HostService service) async {
    final changer = widget.changeService;
    if (changer == null) return;
    setState(() {
      _busyServiceId = service.serviceId;
      _error = null;
    });
    try {
      await changer(
        serviceId: service.serviceId,
        operation: 'restart',
        // The revision on screen, so a stale view is rejected rather than applied.
        expectedRevision: service.revision,
      );
      if (!mounted) return;
      setState(() => _busyServiceId = null);
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busyServiceId = null;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    return _SectionCard(
      title: '主机服务',
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error case final message?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          )
        else if (services == null || services.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('这台主机没有报告任何服务。'),
          )
        else
          ...services.map(
            (service) => _HostServiceRow(
              service: service,
              busy: _busyServiceId == service.serviceId,
              onRestart:
                  widget.changeService == null ? null : () => _restart(service),
            ),
          ),
      ],
    );
  }
}

class _HostServiceRow extends StatelessWidget {
  const _HostServiceRow({
    required this.service,
    required this.busy,
    this.onRestart,
  });

  final HostService service;
  final bool busy;
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final healthy = service.runtimeState == HostServiceRuntimeState.ready;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(
            healthy ? Icons.check_circle : Icons.error_outline,
            size: 18,
            color: healthy ? scheme.primary : scheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(service.serviceId),
                Text(
                  service.detail ?? hostServiceStateLabel(service.runtimeState),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (onRestart case final restart?)
            TextButton(onPressed: restart, child: const Text('重启')),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 112, child: Text(label)),
            Expanded(child: Text(value, textAlign: TextAlign.end)),
          ],
        ),
      );
}

class _SelectableStatusRow extends StatelessWidget {
  const _SelectableStatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 4),
            SelectableText(value),
          ],
        ),
      );
}

String networkLabel(HostNetworkState state) => switch (state) {
      HostNetworkState.unconfigured => '未配置',
      HostNetworkState.staging => '正在切换',
      HostNetworkState.connected => '已连接',
      HostNetworkState.degraded => '异常',
      HostNetworkState.rollingBack => '正在恢复',
    };

String _claimLabel(HostClaimState state) => switch (state) {
      HostClaimState.unclaimed => '未认领',
      HostClaimState.claimed => '已认领',
    };

String _workspaceLabel(HostWorkspaceState state) => switch (state) {
      HostWorkspaceState.absent => '未创建',
      HostWorkspaceState.ready => '已就绪',
    };

String _dateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

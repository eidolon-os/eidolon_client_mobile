import 'package:flutter/material.dart';

import '../setup/host_registry.dart';
import 'host_models.dart';
import 'host_product_session.dart';

class HostSystemPage extends StatelessWidget {
  const HostSystemPage({
    super.key,
    required this.host,
    required this.connection,
  });

  final ManagedHost host;
  final HostProductConnection connection;

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
              _StatusRow(
                label: '恢复状态',
                value: _recoveryLabel(state.recovery),
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
          const SizedBox(height: 12),
          Text(
            '这里只展示用户层所需的安全摘要。服务日志、进程控制、任意配置和凭据仍属于 Admin/Ops 运维边界。',
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
        state.network == HostNetworkState.connected &&
        state.recovery == HostRecoveryState.normal;
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
      HostWorkspaceState.provisioning => '正在创建',
      HostWorkspaceState.ready => '已就绪',
      HostWorkspaceState.degraded => '异常',
    };

String _recoveryLabel(HostRecoveryState state) => switch (state) {
      HostRecoveryState.normal => '正常',
      HostRecoveryState.physicallyArmed => '已物理授权',
      HostRecoveryState.controllerRecovery => '正在恢复管理权限',
      HostRecoveryState.factoryResetPending => '等待恢复出厂设置',
    };

String _dateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

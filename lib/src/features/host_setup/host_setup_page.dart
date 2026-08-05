import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'host_models.dart';
import 'local_api_client.dart';

const _configuredLocalApiUrl = String.fromEnvironment(
  'EIDOLON_LOCAL_API_URL',
);

class HostSetupPage extends StatefulWidget {
  const HostSetupPage({super.key, this.localApiClient});

  final LocalApiClient? localApiClient;

  @override
  State<HostSetupPage> createState() => _HostSetupPageState();
}

class _HostSetupPageState extends State<HostSetupPage> {
  late final LocalApiClient _client;
  late final TextEditingController _address;
  HostOverview? _host;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _client = widget.localApiClient ?? LocalApiClient();
    _address = TextEditingController(text: _configuredLocalApiUrl);
  }

  @override
  void dispose() {
    if (widget.localApiClient == null) _client.close();
    _address.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final host = await _client.fetchHost(_address.text);
      if (!mounted) return;
      setState(() => _host = host);
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _error = '连接超时，请确认 Local API 地址和网络可达性');
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } on LocalApiRequestException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } on http.ClientException catch (error) {
      if (!mounted) return;
      setState(() => _error = '无法连接 Eidolon Local API：${error.message}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Eidolon OS'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              key: const Key('host-setup-page'),
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  '连接你的 Eidolon 主机',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '当前阶段只连接树莓派上的 Bootstrap / Local API。'
                  'Hub、LiveKit 和 Audio Channel 暂不参与。',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                TextField(
                  key: const Key('local-api-address'),
                  controller: _address,
                  enabled: !_loading,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Eidolon Local API 地址',
                    hintText: 'http://eidolon.local:9002',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _connect(),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('connect-eidolon-host'),
                  onPressed: _loading ? null : _connect,
                  icon: _loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.dns_outlined),
                  label: Text(_loading ? '正在连接' : '连接 Eidolon OS'),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 16),
                  _MessageCard(
                    key: const Key('host-setup-error'),
                    icon: Icons.error_outline,
                    color: Theme.of(context).colorScheme.errorContainer,
                    text: error,
                  ),
                ],
                if (_host case final host?) ...[
                  const SizedBox(height: 24),
                  _HostCard(host: host),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.host});

  final HostOverview host;

  @override
  Widget build(BuildContext context) {
    final state = host.state;
    return Card(
      key: const Key('host-overview'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle_outline, color: Colors.green),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Bootstrap 正在运行',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Chip(label: Text(host.mode.name)),
              ],
            ),
            const Divider(height: 32),
            _ValueRow(label: 'Host ID', value: host.descriptor.hostId),
            _ValueRow(
              label: '公钥指纹',
              value: host.descriptor.hostPublicKeyFingerprint,
            ),
            _ValueRow(label: '认领状态', value: _claimLabel(state.claim)),
            _ValueRow(label: '网络状态', value: _networkLabel(state.network)),
            _ValueRow(
              label: 'Workspace',
              value: '${_workspaceLabel(state.workspace)}（后续阶段）',
            ),
            _ValueRow(label: '恢复状态', value: _recoveryLabel(state.recovery)),
            _ValueRow(label: 'Reset epoch', value: '${state.resetEpoch}'),
          ],
        ),
      ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 100, child: Text(label)),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

String _claimLabel(HostClaimState value) => switch (value) {
      HostClaimState.unclaimed => '未认领',
      HostClaimState.claimed => '已认领',
    };

String _networkLabel(HostNetworkState value) => switch (value) {
      HostNetworkState.unconfigured => '未配置',
      HostNetworkState.staging => '配置中',
      HostNetworkState.connected => '已连接',
      HostNetworkState.degraded => '异常',
      HostNetworkState.rollingBack => '回滚中',
    };

String _workspaceLabel(HostWorkspaceState value) => switch (value) {
      HostWorkspaceState.absent => '未初始化',
      HostWorkspaceState.provisioning => '初始化中',
      HostWorkspaceState.ready => '已就绪',
      HostWorkspaceState.degraded => '异常',
    };

String _recoveryLabel(HostRecoveryState value) => switch (value) {
      HostRecoveryState.normal => '正常',
      HostRecoveryState.physicallyArmed => '物理恢复已触发',
      HostRecoveryState.controllerRecovery => 'Controller 恢复中',
      HostRecoveryState.factoryResetPending => '等待恢复出厂设置',
    };

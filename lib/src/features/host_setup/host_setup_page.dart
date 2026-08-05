import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'dev_descriptor.dart';
import 'host_models.dart';
import 'local_api_client.dart';

const _configuredLocalApiUrl = String.fromEnvironment(
  'EIDOLON_LOCAL_API_URL',
);

class HostSetupPage extends StatefulWidget {
  const HostSetupPage({
    super.key,
    this.localApiClient,
    this.clock,
    this.hostChallengeFactory,
  });

  final LocalApiClient? localApiClient;
  final DateTime Function()? clock;
  final String Function()? hostChallengeFactory;

  @override
  State<HostSetupPage> createState() => _HostSetupPageState();
}

class _HostSetupPageState extends State<HostSetupPage> {
  late final LocalApiClient _client;
  late final TextEditingController _address;
  late final TextEditingController _devDescriptorInput;
  DevelopmentCommissioningDescriptor? _devDescriptor;
  HostOverview? _host;
  String? _error;
  bool _loading = false;
  bool _verifying = false;
  bool _hostIdentityVerified = false;

  @override
  void initState() {
    super.initState();
    _client = widget.localApiClient ?? LocalApiClient();
    _address = TextEditingController(text: _configuredLocalApiUrl);
    _devDescriptorInput = TextEditingController();
  }

  @override
  void dispose() {
    if (widget.localApiClient == null) _client.close();
    _address.dispose();
    _devDescriptorInput.dispose();
    super.dispose();
  }

  Future<void> _verifyConnectedHost(
    DevelopmentCommissioningDescriptor descriptor,
    HostOverview host,
  ) async {
    descriptor.requireNotExpired(clock: widget.clock);
    descriptor.requireHostMatch(host);
    final challenge =
        (widget.hostChallengeFactory ?? LocalApiClient.createHostChallenge)();
    final proof = await _client.fetchHostProof(_address.text, challenge);
    await descriptor.verifyHostProof(
      proof,
      expectedChallenge: challenge,
    );
  }

  Future<void> _verifyDevDescriptor() async {
    setState(() {
      _verifying = true;
      _error = null;
      _devDescriptor = null;
      _hostIdentityVerified = false;
    });
    try {
      final descriptor =
          await DevelopmentCommissioningDescriptor.parseAndVerify(
        _devDescriptorInput.text,
        clock: widget.clock,
      );
      final host = _host;
      if (host != null) await _verifyConnectedHost(descriptor, host);
      if (!mounted) return;
      setState(() {
        _devDescriptor = descriptor;
        _hostIdentityVerified = host != null;
      });
    } on SetupTrustException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _connect() async {
    setState(() {
      _loading = true;
      _error = null;
      _host = null;
      _hostIdentityVerified = false;
    });
    try {
      final host = await _client.fetchHost(_address.text);
      final descriptor = _devDescriptor;
      if (descriptor != null) await _verifyConnectedHost(descriptor, host);
      if (!mounted) return;
      setState(() {
        _host = host;
        _hostIdentityVerified = descriptor != null;
      });
    } on SetupTrustException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
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
                  'Setup 负责引导用户；Bootstrap 是树莓派上常驻的最小控制面。'
                  '当前阶段先验证 Host 身份并连接 Local API，认领、配网和 Audio Channel 后续接入。',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                _SetupProgress(
                  descriptorVerified: _devDescriptor != null,
                  hostReachable: _host != null,
                  hostIdentityVerified: _hostIdentityVerified,
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 24),
                  Text(
                    '开发阶段带外凭据',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '在 Host 上执行 eidolon-bootstrapctl dev issue，粘贴完整 JSON。'
                    '临时凭据只保留在内存，不会显示或持久化。',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('dev-descriptor-input'),
                    controller: _devDescriptorInput,
                    enabled: !_verifying && !_loading,
                    minLines: 4,
                    maxLines: 8,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Dev Descriptor JSON',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (_devDescriptor == null && !_hostIdentityVerified) {
                        return;
                      }
                      setState(() {
                        _devDescriptor = null;
                        _hostIdentityVerified = false;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('verify-dev-descriptor'),
                    onPressed:
                        _verifying || _loading ? null : _verifyDevDescriptor,
                    icon: _verifying
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_user_outlined),
                    label: Text(_verifying ? '正在验证' : '验证 Dev Descriptor'),
                  ),
                  if (_devDescriptor case final descriptor?) ...[
                    const SizedBox(height: 12),
                    _MessageCard(
                      key: const Key('dev-descriptor-verified'),
                      icon: Icons.verified_outlined,
                      color: Theme.of(context).colorScheme.primaryContainer,
                      text: 'Descriptor 签名有效：${descriptor.hostId}',
                    ),
                  ],
                ],
                const SizedBox(height: 24),
                Text(
                  '连接 Bootstrap Local API',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
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
                  onChanged: (_) {
                    if (_host == null && !_hostIdentityVerified) return;
                    setState(() {
                      _host = null;
                      _hostIdentityVerified = false;
                    });
                  },
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
                  _HostCard(
                    host: host,
                    identityVerified: _hostIdentityVerified,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SetupProgress extends StatelessWidget {
  const _SetupProgress({
    required this.descriptorVerified,
    required this.hostReachable,
    required this.hostIdentityVerified,
  });

  final bool descriptorVerified;
  final bool hostReachable;
  final bool hostIdentityVerified;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('setup-progress'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _SetupStep(
              label: '1. 验证带外 Host 凭据',
              complete: descriptorVerified,
            ),
            _SetupStep(
              label: '2. 连接 Bootstrap Local API',
              complete: hostReachable,
            ),
            _SetupStep(
              label: '3. 验证 Bootstrap 持有目标 Host 私钥',
              complete: hostIdentityVerified,
            ),
            const _SetupStep(
              label: '4. 认领与配网（下一阶段）',
              complete: false,
              deferred: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupStep extends StatelessWidget {
  const _SetupStep({
    required this.label,
    required this.complete,
    this.deferred = false,
  });

  final String label;
  final bool complete;
  final bool deferred;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            complete
                ? Icons.check_circle
                : deferred
                    ? Icons.more_horiz
                    : Icons.radio_button_unchecked,
            color:
                complete ? Colors.green : Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.host, required this.identityVerified});

  final HostOverview host;
  final bool identityVerified;

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
                    identityVerified
                        ? 'Bootstrap 身份已验证'
                        : 'Bootstrap 可达（身份未验证）',
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

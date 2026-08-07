import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../setup/commissioning_transport.dart';
import '../setup/change_network_page.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/host_identity.dart';
import '../setup/host_registry.dart';
import '../setup/setup_models.dart';
import '../setup/setup_trust.dart';
import 'controller_session.dart';
import 'host_models.dart';
import 'local_api_client.dart';
import 'local_api_discovery.dart';
import 'pinned_http_client.dart';
import 'workspace_models.dart';
import 'workspace_runtime_models.dart';

typedef LocalApiClientFactory = LocalApiClient Function(String fingerprint);
typedef ManagedHostUpdater = Future<void> Function(ManagedHost host);

class _RuntimeLoad {
  const _RuntimeLoad({this.value, this.error});

  final WorkspaceRuntime? value;
  final String? error;
}

class _ProductStateLoad {
  const _ProductStateLoad({
    this.workspace,
    this.workspaceError,
    this.runtime,
    this.runtimeError,
  });

  final WorkspaceStatus? workspace;
  final String? workspaceError;
  final WorkspaceRuntime? runtime;
  final String? runtimeError;
}

class HostLocalConnectionPage extends StatefulWidget {
  const HostLocalConnectionPage({
    super.key,
    required this.host,
    required this.onHostUpdated,
    this.transport,
    this.controllerKeys,
    this.discovery,
    this.localApiClientFactory,
    this.setupContinuation = false,
    this.onSetupComplete,
  }) : assert(!setupContinuation || onSetupComplete != null);

  final ManagedHost host;
  final ManagedHostUpdater onHostUpdated;
  final CommissioningTransport? transport;
  final ControllerKeyBridge? controllerKeys;
  final LocalApiDiscovery? discovery;
  final LocalApiClientFactory? localApiClientFactory;
  final bool setupContinuation;
  final VoidCallback? onSetupComplete;

  @override
  State<HostLocalConnectionPage> createState() =>
      _HostLocalConnectionPageState();
}

class _HostLocalConnectionPageState extends State<HostLocalConnectionPage> {
  late final CommissioningTransport _transport;
  late final ControllerKeyBridge _controllerKeys;
  late final LocalApiDiscovery _discovery;
  late ManagedHost _host;
  final _ownerName = TextEditingController();
  final _companionName = TextEditingController(text: 'Eidolon');

  bool _busy = false;
  String? _progress;
  String? _error;
  String? _endpointName;
  String? _endpointIpAddress;
  String? _baseUrl;
  HostOverview? _overview;
  LocalControllerSession? _session;
  WorkspaceStatus? _workspace;
  String? _workspaceError;
  WorkspaceRuntime? _workspaceRuntime;
  String? _workspaceRuntimeError;
  bool _workspaceBusy = false;

  @override
  void initState() {
    super.initState();
    _host = widget.host;
    _transport = widget.transport ?? PlatformBleCommissioningTransport();
    _controllerKeys = widget.controllerKeys ?? PlatformControllerKeyBridge();
    _discovery = widget.discovery ?? PlatformLocalApiDiscovery();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _connect();
    });
  }

  @override
  void dispose() {
    unawaited(_transport.close());
    _ownerName.dispose();
    _companionName.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _overview = null;
      _session = null;
      _workspace = null;
      _workspaceError = null;
      _workspaceRuntime = null;
      _workspaceRuntimeError = null;
      _baseUrl = null;
    });
    try {
      if (_host.tlsSpkiFingerprint == null) {
        setState(() => _progress = '正在从附近主机更新本地连接信任');
        final updated = await _readTlsIdentityOverBle();
        await widget.onHostUpdated(updated);
        _host = updated;
      }

      setState(() => _progress = '正在同一局域网中查找主机');
      final endpoints = await _discovery.discover();
      Object? lastFailure;
      for (final endpoint in endpoints) {
        final client = _createClient(_host.tlsSpkiFingerprint!);
        try {
          final overview = await client.fetchHost(endpoint.baseUrl);
          _verifyHost(overview);
          final session = await client.authenticateController(
            endpoint.baseUrl,
            expectedControllerId: _host.controllerId,
            controllerKeys: _controllerKeys,
          );
          final productState = await _loadProductState(
            client,
            endpoint.baseUrl,
            session.accessToken,
          );
          if (!mounted) return;
          setState(() {
            _endpointName = endpoint.instanceName;
            _endpointIpAddress = endpoint.ipAddress;
            _baseUrl = endpoint.baseUrl;
            _overview = overview;
            _session = session;
            _workspace = productState.workspace;
            _workspaceError = productState.workspaceError;
            _workspaceRuntime = productState.runtime;
            _workspaceRuntimeError = productState.runtimeError;
            _progress = null;
          });
          return;
        } catch (error) {
          lastFailure = error;
        } finally {
          client.close();
        }
      }
      if (lastFailure != null) throw lastFailure;
      throw const LocalApiRequestException('局域网中没有兼容的 Eidolon 主机');
    } on SetupTrustException catch (error) {
      _showError(error.message);
    } on CommissioningRequestException catch (error) {
      _showError(error.message);
    } on LocalApiRequestException catch (error) {
      _showError(error.message);
    } on PinnedHttpException catch (error) {
      _showError(_pinnedHttpFailure(error));
    } on PlatformException catch (error) {
      _showError(_platformError(error));
    } on FormatException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('无法安全连接主机。请确认平板和主机连接同一 Wi-Fi 后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<ManagedHost> _readTlsIdentityOverBle() async {
    if (!await _transport.requestPermission()) {
      throw const CommissioningRequestException(
        'permission_denied',
        '需要“附近设备”权限来确认已保存主机的本地连接身份。',
      );
    }
    final marker = hostMarker(_host.hostId);
    final nearby = await _transport.scan(serviceUuid: _host.bleServiceUuid);
    final candidates = nearby.toList()
      ..sort((left, right) {
        final leftMatches = left.hostMarker.toLowerCase() == marker;
        final rightMatches = right.hostMarker.toLowerCase() == marker;
        if (leftMatches != rightMatches) return leftMatches ? -1 : 1;
        return right.rssi.compareTo(left.rssi);
      });
    for (final candidate in candidates) {
      try {
        final rawEndpoint = await _transport.open(
          address: candidate.address,
          serviceUuid: _host.bleServiceUuid,
        );
        final endpoint = await CommissioningEndpoint.parseAndVerifyHost(
          rawEndpoint,
          hostId: _host.hostId,
          hostPublicKey: _host.hostPublicKey,
          bleServiceUuid: _host.bleServiceUuid,
        );
        return _host.copyWith(
          tlsSpkiFingerprint: endpoint.tlsSpkiFingerprint,
        );
      } on SetupTrustException {
        // Multiple Eidolon Hosts may be nearby; only the saved Host can pass.
      } on FormatException {
        // Malformed advertisements are untrusted candidates, not fatal state.
      } on CommissioningRequestException {
        // A stale or unreachable candidate must not prevent trying another.
      } on PlatformException {
        // A stale advertisement must not prevent trying another candidate.
      } finally {
        await _transport.close();
      }
    }
    throw const CommissioningRequestException(
      'host_not_found',
      '没有在附近找到这台已保存的主机，无法安全更新本地连接身份。',
    );
  }

  LocalApiClient _createClient(String fingerprint) =>
      widget.localApiClientFactory?.call(fingerprint) ??
      LocalApiClient(
        httpClient: PlatformPinnedHttpClient(
          tlsSpkiFingerprint: fingerprint,
        ),
      );

  void _verifyHost(HostOverview overview) {
    final descriptor = overview.descriptor;
    if (descriptor.hostId != _host.hostId ||
        descriptor.hostPublicKey != _host.hostPublicKey ||
        descriptor.hostPublicKeyFingerprint != _host.hostFingerprint ||
        descriptor.bleServiceUuid != _host.bleServiceUuid) {
      throw const SetupTrustException(
        '局域网服务返回了另一台 Host 的身份，已拒绝连接',
      );
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _progress = null;
    });
  }

  String _platformError(PlatformException error) => switch (error.code) {
        'NOT_FOUND' => '局域网中没有发现主机。请确认平板和主机连接同一 Wi-Fi。',
        'DISCOVERY_FAILED' => 'Android 无法启动局域网发现，请稍后重试。',
        'BLUETOOTH_OFF' => '请先打开蓝牙，以确认已保存主机的本地连接身份。',
        'PERMISSION_DENIED' => '需要“附近设备”权限来确认主机身份。',
        _ => error.message ?? '平板无法完成本地主机连接',
      };

  String _pinnedHttpFailure(
    PinnedHttpException error, {
    bool workspaceIsOptional = false,
  }) {
    final message = switch (error.kind) {
      PinnedHttpFailureKind.invalidRequest =>
        'App 无法构造有效的本地管理请求，请更新或重新安装当前开发版本。',
      PinnedHttpFailureKind.unsupportedPlatform => '当前平台尚未实现安全的本地主机连接。',
      PinnedHttpFailureKind.secureChannel => '主机的加密身份与已保存身份不一致，已拒绝连接。',
      PinnedHttpFailureKind.timeout => '主机已找到，但本地管理请求超时。',
      PinnedHttpFailureKind.unreachable => '主机地址已找到，但当前网络无法到达该地址。',
      PinnedHttpFailureKind.io => '与主机的本地安全连接在传输过程中中断。',
      PinnedHttpFailureKind.platform => '平板的本地安全连接组件暂时不可用。',
    };
    if (!workspaceIsOptional) return message;
    return '$message 主机认领和 Wi-Fi 不会回滚，可稍后继续 Workspace。';
  }

  String _runtimePinnedHttpFailure(PinnedHttpException error) {
    return '${_pinnedHttpFailure(error)} Workspace 已就绪，可稍后刷新日常状态。';
  }

  Future<_ProductStateLoad> _loadProductState(
    LocalApiClient client,
    String baseUrl,
    String accessToken,
  ) async {
    WorkspaceStatus workspace;
    try {
      workspace = await client.fetchWorkspace(
        baseUrl,
        accessToken: accessToken,
      );
    } on LocalApiRequestException catch (error) {
      return _ProductStateLoad(workspaceError: _workspaceFailure(error));
    } on PinnedHttpException catch (error) {
      return _ProductStateLoad(
        workspaceError: _pinnedHttpFailure(
          error,
          workspaceIsOptional: true,
        ),
      );
    } on FormatException {
      return const _ProductStateLoad(
        workspaceError: '主机已安全连接，但 Workspace 返回了不兼容的数据。',
      );
    } catch (_) {
      return const _ProductStateLoad(
        workspaceError: '主机已安全接入，但 Workspace 服务暂时不可用。',
      );
    }
    if (!workspace.isReady) {
      return _ProductStateLoad(workspace: workspace);
    }
    final runtime = await _loadRuntime(client, baseUrl, accessToken);
    if (runtime.value case final value?
        when !value.matchesWorkspace(workspace)) {
      return _ProductStateLoad(
        workspace: workspace,
        runtimeError: 'Workspace 与日常运行状态不一致，已拒绝展示跨 Owner 或 Companion 数据。',
      );
    }
    return _ProductStateLoad(
      workspace: workspace,
      runtime: runtime.value,
      runtimeError: runtime.error,
    );
  }

  Future<_RuntimeLoad> _loadRuntime(
    LocalApiClient client,
    String baseUrl,
    String accessToken,
  ) async {
    try {
      return _RuntimeLoad(
        value: await client.fetchWorkspaceRuntime(
          baseUrl,
          accessToken: accessToken,
        ),
      );
    } on LocalApiRequestException catch (error) {
      return _RuntimeLoad(error: _workspaceRuntimeFailure(error));
    } on PinnedHttpException catch (error) {
      return _RuntimeLoad(
        error: _runtimePinnedHttpFailure(error),
      );
    } on FormatException {
      return const _RuntimeLoad(error: '主机返回了不兼容的日常运行状态。');
    } catch (_) {
      return const _RuntimeLoad(error: 'Eidolon 日常运行状态暂时不可用。');
    }
  }

  Future<void> _refreshWorkspace() async {
    final baseUrl = _baseUrl;
    final session = _session;
    if (baseUrl == null || session == null || _workspaceBusy) return;
    setState(() {
      _workspaceBusy = true;
      _workspaceError = null;
      _workspaceRuntimeError = null;
    });
    final client = _createClient(_host.tlsSpkiFingerprint!);
    try {
      final productState = await _loadProductState(
        client,
        baseUrl,
        session.accessToken,
      );
      if (mounted) {
        setState(() {
          _workspace = productState.workspace;
          _workspaceError = productState.workspaceError;
          _workspaceRuntime = productState.runtime;
          _workspaceRuntimeError = productState.runtimeError;
        });
      }
    } finally {
      client.close();
      if (mounted) setState(() => _workspaceBusy = false);
    }
  }

  Future<void> _initializeWorkspace() async {
    final baseUrl = _baseUrl;
    final session = _session;
    final ownerName = _ownerName.text.trim();
    final companionName = _companionName.text.trim();
    if (baseUrl == null || session == null || _workspaceBusy) return;
    if (ownerName.isEmpty || ownerName.length > 128) {
      setState(() => _workspaceError = '请填写 1–128 个字符的称呼。');
      return;
    }
    if (companionName.isEmpty || companionName.length > 128) {
      setState(() => _workspaceError = '请填写 1–128 个字符的 Eidolon 名称。');
      return;
    }
    setState(() {
      _workspaceBusy = true;
      _workspaceError = null;
      _workspaceRuntimeError = null;
    });
    final client = _createClient(_host.tlsSpkiFingerprint!);
    try {
      final workspace = await client.initializeWorkspace(
        baseUrl,
        accessToken: session.accessToken,
        ownerDisplayName: ownerName,
        companionDisplayName: companionName,
      );
      if (!workspace.isReady) {
        throw const FormatException('Workspace 初始化没有返回 ready');
      }
      final runtime = await _loadRuntime(
        client,
        baseUrl,
        session.accessToken,
      );
      final runtimeValue = runtime.value;
      final acceptedRuntime =
          runtimeValue != null && runtimeValue.matchesWorkspace(workspace)
              ? runtimeValue
              : null;
      final runtimeError = runtimeValue != null && acceptedRuntime == null
          ? 'Workspace 与日常运行状态不一致，已拒绝展示跨 Owner 或 Companion 数据。'
          : runtime.error;
      if (mounted) {
        setState(() {
          _workspace = workspace;
          _workspaceRuntime = acceptedRuntime;
          _workspaceRuntimeError = runtimeError;
        });
      }
    } on LocalApiRequestException catch (error) {
      if (mounted) setState(() => _workspaceError = _workspaceFailure(error));
    } on PinnedHttpException catch (error) {
      if (mounted) {
        setState(() {
          _workspaceError = _pinnedHttpFailure(
            error,
            workspaceIsOptional: true,
          );
        });
      }
    } on FormatException {
      if (mounted) {
        setState(() {
          _workspaceError = '主机没有返回完整的 Workspace 结果，请重试。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _workspaceError = 'Workspace 暂时未能完成；主机认领和 Wi-Fi 不会回滚。';
        });
      }
    } finally {
      client.close();
      if (mounted) setState(() => _workspaceBusy = false);
    }
  }

  Future<void> _openNetworkChange() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChangeNetworkPage(
          host: _host,
          transport: widget.transport,
          controllerKeys: widget.controllerKeys,
        ),
      ),
    );
    if (mounted) await _connect();
  }

  String _workspaceFailure(LocalApiRequestException error) =>
      switch (error.statusCode) {
        401 => '本次管理会话已失效，请重新连接主机。',
        409 => '主机的 Owner 绑定与 Workspace 不一致，已停止继续设置。',
        422 => 'Workspace 名称未被主机接受，请检查后重试。',
        _ => '主机已安全接入，但 Workspace 服务暂时不可用。认领和 Wi-Fi 不会回滚。',
      };

  String _workspaceRuntimeFailure(LocalApiRequestException error) =>
      switch (error.statusCode) {
        401 => '本次管理会话已失效，请重新连接主机。',
        404 => '主机尚未提供日常运行状态接口；Workspace 本身已就绪。',
        409 => 'Workspace 已创建，但主 Companion 的运行资源尚未一致。',
        _ => 'Workspace 已就绪，但日常运行状态暂时不可用。',
      };

  @override
  Widget build(BuildContext context) {
    final overview = _overview;
    final session = _session;
    return Scaffold(
      key: const Key('host-local-connection-page'),
      appBar: AppBar(
        title: Text(
          (_workspace?.isReady ?? false) ? '我的 Eidolon' : '连接主机',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(_host.displayName,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('仅连接同一局域网中的主机；发现到地址后仍会验证 Host 和管理手机身份。'),
          const SizedBox(height: 24),
          if (_busy) ...[
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            Text(
              _progress ?? '正在连接',
              key: const Key('local-connection-progress'),
              textAlign: TextAlign.center,
            ),
          ],
          if (!_busy && overview != null && session != null) ...[
            _ConnectedHostCard(
              endpointName: _endpointName ?? _host.displayName,
              ipAddress: _endpointIpAddress!,
              overview: overview,
              session: session,
            ),
            const SizedBox(height: 16),
            _buildWorkspaceCard(),
          ],
          if (!_busy && _error != null) ...[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, key: const Key('local-connection-error')),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('retry-local-connection'),
              onPressed: _connect,
              icon: const Icon(Icons.refresh),
              label: const Text('重新连接'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWorkspaceCard() {
    final workspace = _workspace;
    if (workspace?.isReady ?? false) {
      final runtime = _workspaceRuntime;
      return Card(
        key: const Key('workspace-ready'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 10),
                  Text('Eidolon 已准备就绪',
                      style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
              const SizedBox(height: 12),
              Text('你好，${workspace!.owner!.displayName}。'),
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
              if (_workspaceRuntimeError case final error?) ...[
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
                  onPressed: _workspaceBusy ? null : _refreshWorkspace,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新加载日常状态'),
                ),
              ],
              if (widget.setupContinuation) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('finish-workspace-setup'),
                  onPressed: widget.onSetupComplete,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('进入我的 Eidolon'),
                ),
              ] else ...[
                const SizedBox(height: 20),
                FilledButton.tonalIcon(
                  key: const Key('refresh-host-product-state'),
                  onPressed: _busy || _workspaceBusy ? null : _connect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新主机状态'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('change-network-from-product'),
                  onPressed:
                      _busy || _workspaceBusy ? null : _openNetworkChange,
                  icon: const Icon(Icons.wifi),
                  label: const Text('更换 Wi-Fi'),
                ),
              ],
            ],
          ),
        ),
      );
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
            if (_workspaceError case final error?) ...[
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
              controller: _ownerName,
              enabled: !_workspaceBusy,
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
              controller: _companionName,
              enabled: !_workspaceBusy,
              maxLength: 128,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _initializeWorkspace(),
              decoration: const InputDecoration(
                labelText: 'Eidolon 的名字',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('initialize-workspace'),
              onPressed: _workspaceBusy ? null : _initializeWorkspace,
              icon: _workspaceBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_workspaceBusy ? '正在创建' : '创建我的 Eidolon'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('retry-workspace-status'),
              onPressed: _workspaceBusy ? null : _refreshWorkspace,
              icon: const Icon(Icons.refresh),
              label: const Text('检查已有进度'),
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
                  Text(
                    detail,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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

class _ConnectedHostCard extends StatelessWidget {
  const _ConnectedHostCard({
    required this.endpointName,
    required this.ipAddress,
    required this.overview,
    required this.session,
  });

  final String endpointName;
  final String ipAddress;
  final HostOverview overview;
  final LocalControllerSession session;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('local-connection-complete'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.verified_user,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 10),
                  Text('已安全连接', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
              const SizedBox(height: 16),
              Text('服务：$endpointName'),
              Text('Host IP：$ipAddress'),
              Text('网络：${_networkLabel(overview.state.network)}'),
              Text('Controller：${session.controllerId}'),
              Text('本次管理会话有效至 ${_localTime(session.expiresAt)}'),
            ],
          ),
        ),
      );
}

String _networkLabel(HostNetworkState state) => switch (state) {
      HostNetworkState.unconfigured => '未配置',
      HostNetworkState.staging => '正在切换',
      HostNetworkState.connected => '已连接',
      HostNetworkState.degraded => '异常',
      HostNetworkState.rollingBack => '正在恢复',
    };

String _localTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

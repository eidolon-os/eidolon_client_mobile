import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../setup/commissioning_transport.dart';
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

typedef LocalApiClientFactory = LocalApiClient Function(String fingerprint);
typedef ManagedHostUpdater = Future<void> Function(ManagedHost host);

class HostLocalConnectionPage extends StatefulWidget {
  const HostLocalConnectionPage({
    super.key,
    required this.host,
    required this.onHostUpdated,
    this.transport,
    this.controllerKeys,
    this.discovery,
    this.localApiClientFactory,
  });

  final ManagedHost host;
  final ManagedHostUpdater onHostUpdated;
  final CommissioningTransport? transport;
  final ControllerKeyBridge? controllerKeys;
  final LocalApiDiscovery? discovery;
  final LocalApiClientFactory? localApiClientFactory;

  @override
  State<HostLocalConnectionPage> createState() =>
      _HostLocalConnectionPageState();
}

class _HostLocalConnectionPageState extends State<HostLocalConnectionPage> {
  late final CommissioningTransport _transport;
  late final ControllerKeyBridge _controllerKeys;
  late final LocalApiDiscovery _discovery;
  late ManagedHost _host;

  bool _busy = false;
  String? _progress;
  String? _error;
  String? _endpointName;
  String? _endpointIpAddress;
  HostOverview? _overview;
  LocalControllerSession? _session;

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
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _overview = null;
      _session = null;
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
          if (!mounted) return;
          setState(() {
            _endpointName = endpoint.instanceName;
            _endpointIpAddress = endpoint.ipAddress;
            _overview = overview;
            _session = session;
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
        'PINNED_HTTPS_FAILED' => '发现了主机地址，但其加密身份或连接不可用，已拒绝连接。',
        'BLUETOOTH_OFF' => '请先打开蓝牙，以确认已保存主机的本地连接身份。',
        'PERMISSION_DENIED' => '需要“附近设备”权限来确认主机身份。',
        _ => error.message ?? '平板无法完成本地主机连接',
      };

  @override
  Widget build(BuildContext context) {
    final overview = _overview;
    final session = _session;
    return Scaffold(
      key: const Key('host-local-connection-page'),
      appBar: AppBar(title: const Text('连接主机')),
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
          if (!_busy && overview != null && session != null)
            _ConnectedHostCard(
              endpointName: _endpointName ?? _host.displayName,
              ipAddress: _endpointIpAddress!,
              overview: overview,
              session: session,
            ),
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
              Text('工作区：${_workspaceLabel(overview.state.workspace)}'),
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

String _workspaceLabel(HostWorkspaceState state) => switch (state) {
      HostWorkspaceState.absent => '尚未创建',
      HostWorkspaceState.provisioning => '正在创建',
      HostWorkspaceState.ready => '已就绪',
      HostWorkspaceState.degraded => '异常',
    };

String _localTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

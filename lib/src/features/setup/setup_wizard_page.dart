import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/eidolon_theme.dart';
import '../../theme/neon_components.dart';
import 'package:flutter/services.dart';

import 'commissioning_transport.dart';
import 'change_network_page.dart';
import 'controller_key_bridge.dart';
import 'development_lan_commissioning.dart';
import 'host_registry.dart';
import 'host_identity.dart';
import 'host_discovery_sections.dart';
import 'host_discovery_details.dart';
import 'setup_models.dart';
import 'setup_trust.dart';

enum _SetupStage { nearby, code, wifi, configuring, complete }

typedef _NearbyHost = ({
  NearbyEidolonHost host,
  CommissioningEndpoint? endpoint,
  ManagedHost? known,
  String? error,
});

typedef _DiscoveredHost = ({
  _NearbyHost? ble,
  DevelopmentLanHost? lan,
  ManagedHost? known,
});

class SetupWizardPage extends StatefulWidget {
  const SetupWizardPage({
    super.key,
    required this.onComplete,
    this.registry,
    this.transport,
    this.controllerKeys,
    this.clock,
    this.developmentLanCommissioning,
  });

  final ValueChanged<ManagedHost> onComplete;
  final HostRegistry? registry;
  final CommissioningTransport? transport;
  final ControllerKeyBridge? controllerKeys;
  final DateTime Function()? clock;
  final DevelopmentLanCommissioning? developmentLanCommissioning;

  @override
  State<SetupWizardPage> createState() => _SetupWizardPageState();
}

class _SetupWizardPageState extends State<SetupWizardPage> {
  late final CommissioningTransport _transport;
  late final ControllerKeyBridge _controllerKeys;
  late final DevelopmentLanCommissioning _developmentLanCommissioning;
  final _setupCode = TextEditingController();
  final _passphrase = TextEditingController();
  final _hiddenSsid = TextEditingController();
  final _controllerName = TextEditingController(text: '我的手机');
  final _random = Random.secure();

  _SetupStage _stage = _SetupStage.nearby;
  CommissioningEndpoint? _endpoint;
  NearbyEidolonHost? _selectedNearbyHost;
  DevelopmentLanHost? _selectedLanHost;
  List<_NearbyHost> _nearby = const [];
  List<DevelopmentLanHost> _lanHosts = const [];
  List<ManagedHost> _knownHosts = const [];
  final Map<String, String> _discoveryFailures = {};
  bool _discovering = false;
  bool _lanClaimFailed = false;
  List<WifiNetwork> _networks = const [];
  WifiNetwork? _selectedNetwork;
  bool _canKeepCurrentNetwork = false;
  String? _currentSsid;
  String? _error;
  String? _progress;
  bool _busy = false;
  ManagedHost? _completedHost;
  late String _networkOperationId = _uuidV4();

  @override
  void initState() {
    super.initState();
    _transport = widget.transport ?? PlatformBleCommissioningTransport();
    _controllerKeys = widget.controllerKeys ?? PlatformControllerKeyBridge();
    _developmentLanCommissioning = widget.developmentLanCommissioning ??
        DevelopmentLanCommissioning(
            controllerKeys: _controllerKeys, clock: widget.clock);
  }

  @override
  void dispose() {
    unawaited(_transport.close());
    _setupCode.dispose();
    _passphrase.dispose();
    _hiddenSsid.dispose();
    _controllerName.dispose();
    super.dispose();
  }

  Future<void> _scanNearby() async {
    await _run(_scanNearbyInternal);
  }

  Future<void> _scanNearbyInternal() async {
    setState(() {
      _nearby = const [];
      _lanHosts = const [];
      _discoveryFailures.clear();
      _discovering = true;
      _progress = '正在查找并识别主机';
    });
    try {
      _knownHosts = await widget.registry?.load() ?? <ManagedHost>[];
      if (!mounted) return;
      // Each source owns its failures. A denied BLE permission, a missing LAN
      // entrance or an offline network must not suppress the other source.
      await Future.wait([
        _discoverWith('附近发现', _scanBle),
        if (kDebugMode)
          _discoverWith('局域网发现', () async {
            final report = await _developmentLanCommissioning.discover(
                knownHosts: _knownHosts);
            if (!mounted) return;
            setState(() => _lanHosts = report.hosts);
            if (report.failure case final failure?) throw failure;
          }),
      ]);
      if (!mounted) return;
      if (_discoveredHosts.isEmpty) {
        _showFailure('没有找到可连接的主机。请确认主机已通电，靠近手机或与手机连接同一局域网。\n'
            '${_discoveryFailures.entries.map((e) => '${e.key}：${e.value}').join('\n')}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _discovering = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _discoverWith(
      String source, Future<void> Function() discover) async {
    try {
      await discover();
    } on Object catch (error) {
      if (!mounted) return;
      final message = switch (error) {
        CommissioningRequestException() => error.message,
        SetupTrustException() => error.message,
        PlatformException(code: 'BLUETOOTH_OFF') => '蓝牙未开启',
        PlatformException(code: 'PERMISSION_DENIED') => '附近设备权限未开启',
        _ => '暂时无法完成查找，请重试',
      };
      setState(() => _discoveryFailures[source] = message);
    }
  }

  List<_DiscoveredHost> get _discoveredHosts {
    final lanById = {for (final host in _lanHosts) host.endpoint.hostId: host};
    return [
      for (final ble in _nearby)
        (
          ble: ble,
          lan: lanById.remove(ble.endpoint?.hostId),
          known: ble.known,
        ),
      for (final lan in lanById.values)
        (
          ble: null,
          lan: lan,
          known: knownHostForEndpoint(_knownHosts, lan.endpoint),
        ),
    ];
  }

  Future<void> _scanBle() async {
    await _transport.close();
    if (!mounted) return;
    if (!await _transport.requestPermission()) {
      throw const CommissioningRequestException(
        'permission_denied',
        '需要“附近设备”权限才能发现未联网的 Eidolon 主机。你可以在系统设置中重新允许。',
      );
    }
    if (!mounted) return;
    final discovered = await _transport.scan(
      serviceUuid: CommissioningEndpoint.defaultServiceUuid,
    );
    if (!mounted) return;
    final nearby = discovered.toList()
      ..sort((left, right) => right.rssi.compareTo(left.rssi));
    if (nearby.isEmpty) {
      throw const CommissioningRequestException(
        'host_not_found',
        '没有找到附近的 Eidolon 主机。请确认主机已通电、靠近手机，并且 Bootstrap 正在运行。',
      );
    }
    setState(() {
      _nearby = nearby
          .map((host) => (host: host, endpoint: null, known: null, error: null))
          .toList();
    });
    final seen = <String>{};
    // The native transport owns one GATT link. Inspect and close candidates
    // sequentially; advertisements alone must never select a saved identity.
    for (final host in nearby) {
      if (!mounted) return;
      _NearbyHost identified;
      try {
        final raw = await _transport
            .open(
              address: host.address,
              serviceUuid: CommissioningEndpoint.defaultServiceUuid,
            )
            .timeout(const Duration(seconds: 12));
        if (!mounted) return;
        final endpoint =
            await CommissioningEndpoint.parseAndVerifyDiscovered(raw);
        identified = (
          host: host,
          endpoint: endpoint,
          known: knownHostForEndpoint(_knownHosts, endpoint),
          error: null,
        );
      } on Object catch (error) {
        identified = (
          host: host,
          endpoint: null,
          known: null,
          error: error is SetupTrustException
              ? '主机身份未通过验证，请重试确认'
              : '暂时无法识别，请靠近主机后重试',
        );
      } finally {
        // dispose already closes our link. A late completion must not close
        // a link that a newly opened page may now own.
        if (mounted) await _transport.close();
      }
      if (!mounted) return;
      final id = identified.endpoint?.hostId;
      setState(() {
        if (id != null && !seen.add(id)) {
          _nearby = _nearby
              .where((item) => item.host.address != host.address)
              .toList();
        } else {
          _nearby = _nearby
              .map((item) =>
                  item.host.address == host.address ? identified : item)
              .toList();
        }
      });
    }
  }

  Future<void> _selectHost(NearbyEidolonHost host) async {
    await _run(() async {
      _selectedLanHost = null;
      _lanClaimFailed = false;
      setState(() => _progress = '正在验证 ${host.name} 的 Host 身份');
      final rawEndpoint = await _transport.open(
        address: host.address,
        serviceUuid: CommissioningEndpoint.defaultServiceUuid,
      );
      final endpoint = await CommissioningEndpoint.parseAndVerifyDiscovered(
        rawEndpoint,
      );
      final known =
          knownHostForEndpoint(await widget.registry?.load() ?? [], endpoint);
      if (known != null) {
        await _transport.close();
        if (!mounted) return;
        widget.onComplete(known);
        return;
      }
      setState(() => _progress = '正在建立加密 Setup 通道');
      await _transport.secure(tlsSpkiFingerprint: endpoint.tlsSpkiFingerprint);
      _endpoint = endpoint;
      _selectedNearbyHost = host;
      try {
        await _transport.authenticateController(_controllerKeys);
        await _rememberController(endpoint);
        await _loadNetworks();
        return;
      } on CommissioningRequestException catch (error) {
        if (error.code != 'controller_denied') rethrow;
      }
      final developmentSetup = endpoint.developmentSetup;
      if (developmentSetup == null) {
        throw const CommissioningRequestException(
            'setup_code_unavailable', '这台主机当前没有开放添加管理手机的窗口。');
      }
      final now = (widget.clock ?? DateTime.now)().toUtc();
      if (!developmentSetup.isOpenAt(now)) {
        throw const CommissioningRequestException(
          'setup_code_expired',
          '这台主机的开发 Setup 会话已过期，请重新选择主机。',
        );
      }
      setState(() {
        _selectedNearbyHost = host;
        _endpoint = endpoint;
        _setupCode.clear();
        _stage = _SetupStage.code;
        _progress = null;
      });
    });
  }

  Future<void> _authenticateSetupCode() async {
    final endpoint = _endpoint;
    final developmentSetup = endpoint?.developmentSetup;
    if (endpoint == null || developmentSetup == null) return;
    if (_controllerName.text.trim().isEmpty ||
        _controllerName.text.trim().length > 80) {
      setState(() => _error = '管理手机名称必须包含 1 到 80 个字符');
      return;
    }
    final code = _setupCode.text.trim();
    if (!setupCodePattern.hasMatch(code)) {
      setState(() => _error = '请输入 Host 上显示的 $setupCodeDigits 位 Setup 码');
      return;
    }
    if (_selectedLanHost case final lan?) {
      await _run(() async {
        setState(() {
          _lanClaimFailed = false;
          _progress = '正在验证 Setup 码并添加主机';
        });
        try {
          final host = await _developmentLanCommissioning.claim(lan,
              setupCode: code, controllerName: _controllerName.text);
          if (!mounted) return;
          await widget.registry?.save(host);
          if (!mounted) return;
          _setupCode.clear();
          setState(() {
            _completedHost = host;
            _stage = _SetupStage.complete;
            _progress = null;
          });
        } on Object {
          if (mounted) setState(() => _lanClaimFailed = true);
          rethrow;
        }
      });
      return;
    }
    await _run(() async {
      await _transport.request('session.authenticate', {
        'commissioning_id': developmentSetup.commissioningId,
        'setup_code': code,
      });
      await _enrollController(endpoint);
      await _transport.authenticateController(_controllerKeys);
      await _loadNetworks();
    });
  }

  Future<void> _loadNetworks() async {
    if (!mounted) return;
    setState(() => _progress = '管理权限已确认，正在读取主机可见的 Wi-Fi');
    final scanned = await _transport.request('wifi.scan', const {});
    final rawNetworks = scanned['networks'];
    if (rawNetworks is! List) {
      throw const CommissioningRequestException(
          'invalid_response', '主机没有返回 Wi-Fi 列表');
    }
    final current = scanned['current_network'];
    final ssid = current is Map ? current['ssid'] : null;
    if (!mounted) return;
    _setupCode.clear();
    setState(() {
      _networks = rawNetworks
          .whereType<Map<String, dynamic>>()
          .map(WifiNetwork.fromJson)
          .toList(growable: false);
      _canKeepCurrentNetwork =
          current is Map && current['state'] == 'connected';
      _currentSsid = ssid is String && ssid.isNotEmpty ? ssid : null;
      _stage = _SetupStage.wifi;
      _progress = null;
    });
  }

  Future<void> _finishSetup() async {
    await _transport.close();
    if (!mounted) return;
    setState(() {
      _stage = _SetupStage.complete;
      _progress = null;
    });
  }

  Future<void> _skipNetwork() => _run(_finishSetup);

  Future<void> _rememberController(CommissioningEndpoint endpoint) async {
    final controller = await _controllerKeys.getIdentity();
    final host = ManagedHost(
      hostId: endpoint.hostId,
      hostPublicKey: endpoint.hostPublicKey,
      hostFingerprint: endpoint.hostPublicKeyFingerprint,
      bleServiceUuid: endpoint.bleServiceUuid,
      controllerId: controller.controllerId,
      displayName: defaultHostDisplayName(endpoint.hostId),
      claimedAt: (widget.clock ?? DateTime.now)().toUtc(),
      tlsSpkiFingerprint: endpoint.tlsSpkiFingerprint,
    );
    // A committed Grant survives a network failure, cancellation, or app exit.
    await widget.registry?.save(host);
    _completedHost = host;
  }

  Future<void> _configureNetwork() async {
    final endpoint = _endpoint;
    if (endpoint == null) return;
    final ssid = (_selectedNetwork?.ssid ?? _hiddenSsid.text).trim();
    if (ssid.isEmpty) {
      setState(() => _error = '请选择 Wi-Fi，或输入隐藏网络名称');
      return;
    }
    final secured = _selectedNetwork?.secured ?? _passphrase.text.isNotEmpty;
    if (secured && _passphrase.text.length < 8) {
      setState(() => _error = '受保护 Wi-Fi 的密码至少需要 8 个字符');
      return;
    }
    if (_controllerName.text.trim().isEmpty) {
      setState(() => _error = '请为这台管理手机填写一个名称');
      return;
    }
    var networkCompleted = false;
    await _run(() async {
      setState(() {
        _stage = _SetupStage.configuring;
        _progress = '正在让主机加入 $ssid';
      });
      await _transport.configureWifi(
        operationId: _networkOperationId,
        ssid: ssid,
        passphrase: secured ? _passphrase.text : null,
        hidden: _selectedNetwork == null,
      );
      networkCompleted = true;
      await _finishSetup();
    });
    if (!networkCompleted && mounted) {
      _networkOperationId = _uuidV4();
    }
  }

  Future<void> _enrollController(CommissioningEndpoint endpoint) async {
    final controller = await _controllerKeys.getIdentity();
    final claimed = await _transport.request('claim.complete', {
      'controller_id': controller.controllerId,
      'public_key': controller.publicKey,
      'display_name': _controllerName.text.trim(),
      'platform': 'android',
    });
    final controllerResult = claimed['controller'];
    if (controllerResult is! Map ||
        controllerResult['controller_id'] != controller.controllerId) {
      throw const CommissioningRequestException(
        'claim_failed',
        '主机没有确认 Controller 认领结果',
      );
    }
    await _rememberController(endpoint);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on SetupTrustException catch (error) {
      if (mounted) _showFailure(error.message);
    } on CommissioningRequestException catch (error) {
      if (mounted) _showFailure(_friendlyError(error));
    } on PlatformException catch (error) {
      if (mounted) {
        _showFailure(switch (error.code) {
          'BLUETOOTH_OFF' => '请先打开平板蓝牙，再重新查找附近主机。',
          'PERMISSION_DENIED' => '需要“附近设备”权限才能查找 Eidolon 主机。',
          'LINK_FAILED' => '蓝牙暂时无法连接主机。请让平板靠近主机后重试。',
          _ => error.message ?? '平板无法完成附近设备操作',
        });
      }
    } on FormatException catch (error) {
      if (mounted) _showFailure(error.message);
    } on TimeoutException {
      if (mounted) _showFailure('主机响应超时，请重试或选择其他接入方式。');
    } on Object {
      if (mounted) _showFailure('主机接入暂时未完成，请检查连接后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showFailure(String message) {
    setState(() {
      _error = message;
      _progress = null;
      if (_stage == _SetupStage.configuring) _stage = _SetupStage.wifi;
    });
  }

  String _friendlyError(CommissioningRequestException error) =>
      switch (error.code) {
        'network_stage_failed' =>
          '主机未能完成 Wi-Fi 连接。请检查密码、网络安全模式和信号；主机仍可通过蓝牙继续设置。',
        'network_confirm_failed' => '主机加入了 Wi-Fi，但未能安全确认变更。请重试，失败时会自动回滚。',
        'network_rollback_failed' => '主机未能立即回滚 Wi-Fi；系统检查点会继续保护原网络。',
        // No longer says what happens after five wrong tries: nothing does.
        // A wrong code is refused and the window stays open, because revoking
        // an unexpiring one leaves nobody able to reopen it (ADR-0007).
        'commissioning_denied' => 'Setup 码错误或已失效。请核对 $setupCodeDigits 位码后再试。',
        'setup_code_unavailable' =>
          '这台主机现在没有开放的 Setup 窗口。$firstSetupCodeGuidance',
        'setup_code_expired' => '开发 Setup 会话已过期，请重新选择主机。',
        // A refusal an Owner can act on has to carry the action. Without the
        // recovery named here, this said "你没有权限" to someone holding the
        // only phone they own, and stopped.
        'controller_denied' => '当前会话没有这台主机的管理权限。$controllerRecoveryGuidance',
        'operation_conflict' => '主机正在处理另一项设置，或本次重试已失效。请重新开始这一步。',
        // Reserved for a failure the Host has no name for. A deterministic
        // conflict arriving here as "retry later" is a Host bug, not a hint;
        // the Grant identity collision that used to land here is fixed at the
        // Host and no longer reaches a phone at all.
        'internal_error' => '主机遇到了它自己也没有归类的故障，这一步没有完成。'
            '蓝牙入口仍会保持可用；如果重试仍然如此，需要看主机日志。',
        _ => error.message,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置 Eidolon 主机')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              key: const Key('setup-wizard-page'),
              padding:
                  const EdgeInsets.fromLTRB(Neon.s5, Neon.s4, Neon.s5, Neon.s7),
              children: [
                _ProgressHeader(
                    stage: _stage, alreadyNetworked: _selectedLanHost != null),
                const SizedBox(height: 24),
                if (_stage == _SetupStage.nearby) _buildNearby(),
                if (_stage == _SetupStage.code) _buildSetupCode(),
                if (_stage == _SetupStage.wifi) _buildWifi(),
                if (_stage == _SetupStage.configuring) _buildConfiguring(),
                if (_stage == _SetupStage.complete) _buildComplete(),
                if (_error case final error?) ...[
                  const SizedBox(height: 16),
                  _Notice(
                    key: const Key('setup-error'),
                    icon: Icons.error_outline,
                    text: error,
                    color: Theme.of(context).colorScheme.errorContainer,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNearby() {
    final hosts = _discoveredHosts;
    bool identified(_DiscoveredHost host) =>
        host.lan != null || host.ble?.endpoint != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('查找主机', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: Neon.s3),
        Text(
            kDebugMode
                ? '给主机接通电源，让它靠近手机或与手机连接同一局域网。App 会自动查找可用的接入方式。'
                : '给主机接通电源，并让手机保持在主机附近。首次设置不要求主机已经联网。',
            style:
                const TextStyle(fontSize: 14, height: 1.7, color: Neon.inkDim)),
        const SizedBox(height: Neon.s2),
        const Text('新主机需要 Setup 码；已添加的主机会单独列出，可以直接连接。',
            style: TextStyle(fontSize: 13, height: 1.65, color: Neon.inkFaint)),
        const SizedBox(height: Neon.s6),
        if (hosts.isEmpty)
          NeonCta(
            enabled: !_busy,
            child: FilledButton.icon(
              key: const Key('scan-nearby-hosts'),
              onPressed: _busy ? null : _scanNearby,
              icon: const Icon(Icons.search),
              label: const Text('查找主机'),
            ),
          ),
        HostDiscoverySections(
          identifying: _discovering,
          available: [
            for (final item in hosts)
              if (identified(item) && item.known == null)
                _buildDiscoveredHost(item),
          ],
          added: [
            for (final item in hosts)
              if (item.known != null) _buildDiscoveredHost(item),
          ],
          unidentified: [
            for (final item in hosts)
              if (!identified(item)) _buildDiscoveredHost(item),
          ],
        ),
        if (_progress != null) _BusyNotice(text: _progress!),
        if (hosts.isNotEmpty && !_discovering && _discoveryFailures.isNotEmpty)
          ExpansionTile(
            key: const Key('discovery-details'),
            title: const Text('部分查找方式未找到主机'),
            subtitle: const Text('已找到的主机仍可使用'),
            children: [
              for (final failure in _discoveryFailures.entries)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('${failure.key}：${failure.value}'),
                ),
            ],
          ),
        if (hosts.isNotEmpty) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _scanNearby,
            icon: const Icon(Icons.refresh),
            label: const Text('重新扫描'),
          ),
        ],
      ],
    );
  }

  Widget _buildDiscoveredHost(_DiscoveredHost item) {
    final ble = item.ble;
    final identifying =
        item.lan == null && ble?.endpoint == null && ble?.error == null;
    final action = item.known != null
        ? '连接'
        : ble?.error != null
            ? '重试识别'
            : '添加';
    final description = item.lan != null ? '当前局域网已发现' : '蓝牙已发现，尚未确认局域网连接';
    final displayName =
        item.known?.readableName ?? item.lan?.displayName ?? ble!.host.name;
    return Card(
      key: ValueKey(
          'discovered-host-${item.lan?.endpoint.hostId ?? ble!.host.address}'),
      child: Column(children: [
        ListTile(
          leading: const Icon(Icons.memory),
          title: Text(displayName),
          subtitle: HostDiscoveryDetails(
            displayName: displayName,
            known: item.known,
            lan: item.lan,
            nearby: ble?.host,
            endpoint: item.lan?.endpoint ?? ble?.endpoint,
            status: identifying
                ? '正在识别…'
                : ble?.error ??
                    '${item.known != null ? '已添加' : '未添加'} · $description',
          ),
          trailing: identifying
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(
                  onPressed: _busy ? null : () => _openDiscoveredHost(item),
                  child: Text(action),
                ),
          onTap: _busy ? null : () => _openDiscoveredHost(item),
        ),
        if (item.known != null && ble != null && item.lan == null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('更换路由器或 Wi-Fi 后，可以通过蓝牙为这台主机设置网络，无需重新添加。'),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: ValueKey('restore-host-network-${item.known!.hostId}'),
                  onPressed: _busy ? null : () => _restoreNetwork(item),
                  icon: const Icon(Icons.wifi),
                  label: const Text('为这台主机设置 Wi-Fi'),
                ),
              ],
            ),
          ),
      ]),
    );
  }

  Future<void> _restoreNetwork(_DiscoveredHost item) async {
    await _transport.close();
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ChangeNetworkPage(
        host: item.known!,
        nearbyHost: item.ble!.host,
        transport: _transport,
        controllerKeys: _controllerKeys,
      ),
    ));
    if (mounted && changed == true) widget.onComplete(item.known!);
  }

  void _openDiscoveredHost(_DiscoveredHost item) {
    final known = item.known;
    if (known != null) {
      // The normal connection flow checks current Controller authority.
      widget.onComplete(known);
    } else if (item.lan case final lan?) {
      unawaited(_run(() async {
        final recovered = await _developmentLanCommissioning.recover(lan);
        if (!mounted) return;
        if (recovered != null) {
          await widget.registry?.save(recovered);
          if (!mounted) return;
          setState(() {
            _completedHost = recovered;
            _stage = _SetupStage.complete;
          });
          return;
        }
        final setup = lan.endpoint.developmentSetup;
        if (setup == null ||
            !setup.isOpenAt((widget.clock ?? DateTime.now)())) {
          throw const CommissioningRequestException(
              'setup_code_unavailable', '主机没有开放添加管理手机的窗口。');
        }
        setState(() {
          _selectedLanHost = lan;
          _selectedNearbyHost = item.ble?.host;
          _endpoint = lan.endpoint;
          _lanClaimFailed = false;
          _setupCode.clear();
          _stage = _SetupStage.code;
        });
      }));
    } else {
      unawaited(_selectHost(item.ble!.host));
    }
  }

  Widget _buildSetupCode() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('输入 Setup 码',
              key: const Key('setup-code-title'),
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            '正在添加 ${_selectedLanHost?.displayName ?? _selectedNearbyHost?.name ?? 'Eidolon Host'}。'
            '请输入这台主机的 $setupCodeDigits 位 Setup 码。',
          ),
          if (_selectedLanHost != null) ...[
            const SizedBox(height: 8),
            const Text('已通过局域网找到主机，无需为添加手机重新配网。'),
          ],
          ExpansionTile(
            title: const Text('如何获取 Setup 码'),
            children: const [
              Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                    '请在主机上执行 `eidolon-ops commissioning-code` 获取 Setup 码；首次添加也需要。'),
              )
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('development-setup-code'),
            controller: _setupCode,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(setupCodeDigits),
            ],
            maxLength: setupCodeDigits,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(letterSpacing: 10),
            decoration: const InputDecoration(
              labelText: '$setupCodeDigits 位 Setup 码',
              hintText: '00000000',
              counterText: '',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _authenticateSetupCode(),
          ),
          ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('controller-name'),
              controller: _controllerName,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '这台管理手机的名称'),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('authenticate-setup-code'),
            onPressed: _busy ? null : _authenticateSetupCode,
            icon: const Icon(Icons.lock_open_outlined),
            label: Text(_selectedLanHost == null ? '验证并继续' : '验证并添加'),
          ),
          if (_progress != null) _BusyNotice(text: _progress!),
          if (_lanClaimFailed && _selectedNearbyHost != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('retry-setup-via-nearby'),
              onPressed: _busy ? null : () => _selectHost(_selectedNearbyHost!),
              child: const Text('换一种方式重试'),
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    await _transport.close();
                    if (!mounted) return;
                    setState(() {
                      _endpoint = null;
                      _selectedNearbyHost = null;
                      _selectedLanHost = null;
                      _lanClaimFailed = false;
                      _setupCode.clear();
                      _error = null;
                      _progress = null;
                      _stage = _SetupStage.nearby;
                    });
                  },
            child: const Text('选择其他主机'),
          ),
        ],
      );

  Widget _buildWifi() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _canKeepCurrentNetwork ? '确认主机网络' : '让主机加入 Wi-Fi',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            '这台手机已获得与其他管理手机平等的权限。Wi-Fi 设置通过加密蓝牙完成，可以选择与手机不同的网络。',
          ),
          if (_canKeepCurrentNetwork) ...[
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.wifi),
                title: Text(
                  _currentSsid == null ? '主机当前已经联网' : '主机已连接 $_currentSsid',
                ),
                subtitle: const Text('可以保持当前连接，也可以选择新的 Wi-Fi。'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '如需更换网络，请选择新的 Wi-Fi：',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ],
          const SizedBox(height: 16),
          ..._networks.map(
            (network) => ListTile(
              selected: _selectedNetwork == network,
              leading: Icon(
                _selectedNetwork == network
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(network.ssid),
              subtitle: Text(network.secured ? '需要密码' : '开放网络'),
              trailing: Icon(_wifiIcon(network.signal)),
              onTap: _busy
                  ? null
                  : () => setState(() {
                        _selectedNetwork = network;
                        _hiddenSsid.clear();
                        _passphrase.clear();
                      }),
            ),
          ),
          const Divider(height: 28),
          TextField(
            controller: _hiddenSsid,
            enabled: !_busy && _selectedNetwork == null,
            decoration: const InputDecoration(
              labelText: '隐藏网络名称（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('wifi-passphrase'),
            controller: _passphrase,
            enabled: !_busy && (_selectedNetwork?.secured ?? true),
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi 密码',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const Key('finish-without-network-change'),
            onPressed: _busy ? null : _skipNetwork,
            icon: const Icon(Icons.verified_user_outlined),
            label: Text(_canKeepCurrentNetwork ? '保持当前 Wi-Fi' : '稍后设置 Wi-Fi'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('configure-host-network'),
            onPressed: _busy ? null : _configureNetwork,
            icon: const Icon(Icons.rocket_launch_outlined),
            label: Text(
              _canKeepCurrentNetwork ? '更换 Wi-Fi' : '连接 Wi-Fi',
            ),
          ),
        ],
      );

  Widget _buildConfiguring() => _BusyNotice(
        text: _progress ?? '主机正在完成 Setup',
        detail: '请不要关闭 App 或让手机离开主机；如果 Wi-Fi 失败，蓝牙恢复通道仍然保留。',
      );

  Widget _buildComplete() => Column(
        children: [
          const Icon(Icons.check_circle, size: 72, color: Neon.ok),
          const SizedBox(height: 16),
          Text('主机接入已完成', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '${_completedHost!.readableName} 已接入，'
            '管理授权已保存，其他管理手机不受影响。访问主机功能需要手机与主机网络互通。',
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('finish-setup'),
            onPressed: () => widget.onComplete(_completedHost!),
            child: const Text('打开主机'),
          ),
        ],
      );

  String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// Authorization and optional networking have independent completion.
class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.stage, this.alreadyNetworked = false});

  final _SetupStage stage;
  final bool alreadyNetworked;

  List<String> get _steps => [
        '选一台主机',
        '确认管理权限',
        if (!alreadyNetworked) '设置 Wi-Fi（可选）',
      ];

  @override
  Widget build(BuildContext context) {
    final done = switch (stage) {
      _SetupStage.nearby => 0,
      _SetupStage.code => 1,
      _SetupStage.wifi => 2,
      _SetupStage.configuring => 2,
      _SetupStage.complete => _steps.length,
    };
    final steps = _steps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const NeonEyebrow('Setup'),
          const Spacer(),
          Text('$done / ${steps.length}',
              style: Neon.mono(size: 11, color: Neon.inkFaint)),
        ]),
        const SizedBox(height: Neon.s3),
        // One segment per step rather than a single bar: a bar says how far
        // along you are, segments say how many moves are left.
        Row(children: [
          for (var i = 0; i < steps.length; i++)
            Expanded(
              child: Container(
                height: 3,
                margin: EdgeInsets.only(
                    right: i == steps.length - 1 ? 0 : Neon.s1 + 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  color: i < done
                      ? Neon.cyan
                      : Colors.white.withValues(alpha: .08),
                  boxShadow: i < done
                      ? Neon.glow(Neon.cyan, blur: 8, alpha: .5)
                      : null,
                ),
              ),
            ),
        ]),
        const SizedBox(height: Neon.s4),
        Wrap(
          spacing: Neon.s2,
          runSpacing: Neon.s2,
          children: [
            for (final entry in steps.indexed)
              _StepChip(
                index: entry.$1,
                label: entry.$2,
                done: entry.$1 < done,
                current: entry.$1 == done,
              ),
          ],
        ),
      ],
    );
  }
}

/// One step in the setup row: a number that becomes a tick, and a label that
/// brightens when it is your turn.
class _StepChip extends StatelessWidget {
  const _StepChip({
    required this.index,
    required this.label,
    required this.done,
    required this.current,
  });

  final int index;
  final String label;
  final bool done;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final lit = done || current;
    final color = done ? Neon.ok : (current ? Neon.cyan : Neon.inkFaint);
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 5, 12, 5),
      decoration: BoxDecoration(
        color: lit ? color.withValues(alpha: .09) : Colors.transparent,
        borderRadius: BorderRadius.circular(99),
        border:
            Border.all(color: lit ? color.withValues(alpha: .3) : Neon.hair),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? color : Colors.transparent,
            border:
                done ? null : Border.all(color: color.withValues(alpha: .5)),
          ),
          child: done
              ? const Icon(Icons.check_rounded,
                  size: 12, color: Color(0xFF04140E))
              : Text('${index + 1}', style: Neon.mono(size: 9.5, color: color)),
        ),
        const SizedBox(width: 7),
        Text(label,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: lit ? Neon.ink : Neon.inkFaint)),
      ]),
    );
  }
}

class _BusyNotice extends StatelessWidget {
  const _BusyNotice({required this.text, this.detail});

  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(text, textAlign: TextAlign.center),
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(detail!, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(Neon.s4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .16),
          borderRadius: BorderRadius.circular(Neon.radiusM),
          border: Border.all(color: color.withValues(alpha: .38)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: Neon.warn),
          const SizedBox(width: Neon.s3),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 13, height: 1.6, color: Neon.ink))),
        ]),
      );
}

IconData _wifiIcon(int signal) {
  if (signal >= 70) return Icons.network_wifi;
  if (signal >= 40) return Icons.network_wifi_2_bar;
  return Icons.network_wifi_1_bar;
}

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'commissioning_transport.dart';
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
      final developmentSetup = endpoint.developmentSetup;
      if (developmentSetup == null) {
        // A null `setup_session` says there is no open claim window. It does
        // not say why, and this branch used to guess "it may already be
        // claimed" — which was wrong on a factory-fresh Host with no grants at
        // all, and sent the operator to the controller-reset guidance for
        // authority nobody held.
        //
        // The Host answers the question instead: `already_claimed` when it
        // belongs to someone, `controller_denied` when nobody is authorized on
        // it yet. Only the second one is a Host waiting for its first code.
        try {
          if (await _recoverCompletedClaim(endpoint)) return;
        } on CommissioningRequestException catch (error) {
          if (error.code != 'controller_denied') rethrow;
        }
        throw const CommissioningRequestException(
          'setup_code_unavailable',
          '这台主机没有开放的 Setup 窗口。',
        );
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
      setState(() => _progress = '正在读取主机可见的 Wi-Fi');
      final scanned = await _transport.request('wifi.scan', const {});
      final rawNetworks = scanned['networks'];
      if (rawNetworks is! List) {
        throw const CommissioningRequestException(
          'invalid_response',
          '主机没有返回 Wi-Fi 列表',
        );
      }
      final networks = rawNetworks
          .whereType<Map<String, dynamic>>()
          .map(WifiNetwork.fromJson)
          .toList(growable: false);
      final rawCurrentNetwork = scanned['current_network'];
      final currentNetwork = rawCurrentNetwork is Map
          ? Map<Object?, Object?>.from(rawCurrentNetwork)
          : const <Object?, Object?>{};
      final currentSsid = currentNetwork['ssid'];
      _setupCode.clear();
      setState(() {
        _networks = networks;
        _canKeepCurrentNetwork = currentNetwork['state'] == 'connected';
        _currentSsid = currentSsid is String && currentSsid.isNotEmpty
            ? currentSsid
            : null;
        _stage = _SetupStage.wifi;
        _progress = null;
      });
    });
  }

  Future<void> _claimUsingCurrentNetwork() async {
    final endpoint = _endpoint;
    if (endpoint == null || !_canKeepCurrentNetwork) return;
    if (_controllerName.text.trim().isEmpty) {
      setState(() => _error = '请为这台管理手机填写一个名称');
      return;
    }
    await _run(() async {
      setState(() {
        _stage = _SetupStage.configuring;
        _progress = '正在保留当前网络并认领主机';
      });
      await _completeClaim(endpoint);
    });
  }

  Future<bool> _recoverCompletedClaim(CommissioningEndpoint endpoint) async {
    final controller = await _controllerKeys.getIdentity();
    final challenge = await _transport.request('controller.challenge', {
      'controller_id': controller.controllerId,
    });
    if (challenge['contract_version'] != '1' ||
        challenge['purpose'] != 'eidolon-controller-ble-auth-v1' ||
        challenge['controller_id'] != controller.controllerId ||
        challenge['challenge'] is! String ||
        challenge['reset_epoch'] is! int) {
      return false;
    }
    final signature = await _controllerKeys.signChallenge(challenge);
    final authenticated = await _transport.request('controller.authenticate', {
      ...challenge,
      'signature': signature,
    });
    final state = authenticated['state'];
    if (state is! Map || state['claim_state'] != 'claimed') return false;
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
    await _transport.close();
    setState(() {
      _completedHost = host;
      _stage = _SetupStage.complete;
      _progress = null;
    });
    return true;
  }

  Future<void> _configureAndClaim() async {
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
    var staged = false;
    var networkCompleted = false;
    await _run(() async {
      setState(() {
        _stage = _SetupStage.configuring;
        _progress = '正在让主机加入 $ssid';
      });
      final configured = await _transport.request('wifi.configure', {
        'operation_id': _networkOperationId,
        'ssid': ssid,
        'passphrase': secured ? _passphrase.text : null,
        'hidden': _selectedNetwork == null,
      });
      final operation = configured['operation'];
      if (operation is! Map ||
          !{'waiting_confirmation', 'succeeded'}.contains(operation['state'])) {
        throw const CommissioningRequestException(
          'network_stage_failed',
          '主机没有完成 Wi-Fi 连接，请检查密码、网络安全模式和信号',
        );
      }
      if (operation['state'] == 'waiting_confirmation') {
        staged = true;
        setState(() => _progress = 'Wi-Fi 已连接，正在确认网络变更');
        await _transport.request('wifi.confirm', {
          'operation_id': _networkOperationId,
        });
        staged = false;
      }
      networkCompleted = true;
      setState(() => _progress = '正在把这台手机认领为主机管理员');
      await _completeClaim(endpoint);
    });
    if (staged) {
      try {
        await _transport.request('wifi.rollback', {
          'operation_id': _networkOperationId,
        });
      } catch (_) {
        // NetworkManager's Host-side checkpoint also rolls back on timeout.
      }
    }
    if (!networkCompleted && mounted) {
      _networkOperationId = _uuidV4();
    }
  }

  Future<void> _completeClaim(CommissioningEndpoint endpoint) async {
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
    await _transport.close();
    setState(() {
      _completedHost = host;
      _stage = _SetupStage.complete;
      _progress = null;
    });
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
        // Says only what the App knows: there is no window. Whether this Host
        // was ever claimed is a separate question, and the Host answers it with
        // `already_claimed` below.
        'setup_code_unavailable' =>
          '这台主机现在没有开放的 Setup 窗口。$firstSetupCodeGuidance',
        'already_claimed' => '这台主机已被认领，而且它不认这台手机的管理凭据。'
            '$controllerResetGuidance',
        'setup_code_expired' => '开发 Setup 会话已过期，请重新选择主机。',
        // A refusal an Owner can act on has to carry the action. Without the
        // recovery named here, this said "你没有权限" to someone holding the
        // only phone they own, and stopped.
        'controller_denied' => '这台主机已被认领，而且它不认这台手机的管理凭据；'
            '开箱凭据只能用来重新认领，不能改这台主机的设置。$controllerResetGuidance',
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
              padding: const EdgeInsets.all(24),
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
        Text('查找主机', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(kDebugMode
            ? '给主机接通电源，让它靠近手机或与手机连接同一局域网。App 会自动查找可用的接入方式。'
            : '给主机接通电源，并让手机保持在主机附近。首次设置不要求主机已经联网。'),
        const SizedBox(height: 8),
        const Text('新主机需要 Setup 码；已添加的主机会单独列出，可以直接连接。'),
        const SizedBox(height: 16),
        if (hosts.isEmpty)
          FilledButton.icon(
            key: const Key('scan-nearby-hosts'),
            onPressed: _busy ? null : _scanNearby,
            icon: const Icon(Icons.search),
            label: const Text('查找主机'),
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
    final description = item.lan != null ? '主机已联网' : '附近发现';
    final displayName =
        item.known?.displayName ?? item.lan?.displayName ?? ble!.host.name;
    return Card(
      key: ValueKey(
          'discovered-host-${item.lan?.endpoint.hostId ?? ble!.host.address}'),
      child: ListTile(
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
                dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(
                onPressed: _busy ? null : () => _openDiscoveredHost(item),
                child: Text(action),
              ),
        onTap: _busy ? null : () => _openDiscoveredHost(item),
      ),
    );
  }

  void _openDiscoveredHost(_DiscoveredHost item) {
    final known = item.known;
    if (known != null) {
      // The normal connection flow checks current Controller authority.
      widget.onComplete(known);
    } else if (item.lan case final lan?) {
      setState(() {
        _selectedLanHost = lan;
        _selectedNearbyHost = item.ble?.host;
        _endpoint = lan.endpoint;
        _lanClaimFailed = false;
        _setupCode.clear();
        _error = null;
        _progress = null;
        _stage = _SetupStage.code;
      });
    } else {
      unawaited(_selectHost(item.ble!.host));
    }
  }

  Widget _buildSetupCode() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('输入 Setup 码', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '正在添加 ${_selectedLanHost?.displayName ?? _selectedNearbyHost?.name ?? 'Eidolon Host'}。'
            '请输入这台主机的 $setupCodeDigits 位 Setup 码。',
          ),
          if (_selectedLanHost != null) ...[
            const SizedBox(height: 8),
            const Text('主机已经联网，无需重新配置 Wi-Fi。'),
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
          if (_selectedLanHost != null) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('lan-controller-name'),
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
            '密码只通过已加密的蓝牙 Setup 通道交给 NetworkManager，不保存在 App 或 Bootstrap DB。',
          ),
          if (_canKeepCurrentNetwork) ...[
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.wifi),
                title: Text(
                  _currentSsid == null ? '主机当前已经联网' : '主机已连接 $_currentSsid',
                ),
                subtitle: const Text('可以保持当前连接直接认领，也可以在下方选择新的 Wi-Fi。'),
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
          TextField(
            controller: _controllerName,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '这台管理手机的名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          if (_canKeepCurrentNetwork) ...[
            FilledButton.tonalIcon(
              key: const Key('keep-network-and-claim'),
              onPressed: _busy ? null : _claimUsingCurrentNetwork,
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('保持当前 Wi-Fi，直接认领主机'),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            key: const Key('configure-and-claim'),
            onPressed: _busy ? null : _configureAndClaim,
            icon: const Icon(Icons.rocket_launch_outlined),
            label: Text(
              _canKeepCurrentNetwork ? '更换 Wi-Fi 并认领主机' : '连接 Wi-Fi 并认领主机',
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
          const Icon(Icons.check_circle, size: 72, color: Colors.green),
          const SizedBox(height: 16),
          Text('主机接入已完成', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '${_completedHost!.displayName} 已接入，'
            '这台手机已取得 Host Admin 权限。主机已可恢复保存，下一步会通过局域网创建 Workspace。',
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('finish-setup'),
            onPressed: () => widget.onComplete(_completedHost!),
            child: const Text('继续创建我的 Eidolon'),
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

/// What the person is being asked to do, and how much of it is left.
///
/// It used to list five things — 附近主机 · Setup 码 · Wi-Fi · 认领 · 主机接入
/// — of which the person does three. 认领 is the phone and the Host talking to
/// each other, and 主机接入 is the outcome of that conversation; putting them
/// in the same row as "choose a Wi-Fi network" made the setup look half again
/// as long as it is. Meanwhile the one thing still waiting on the other side
/// — giving the Eidolon and yourself a name — was not mentioned at all, so
/// the bar reached the end and then asked for more.
///
/// Protocol phases are not what a progress bar is for. The phases are still
/// exactly as separate as they were: this only stops presenting them as
/// errands.
class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.stage, this.alreadyNetworked = false});

  final _SetupStage stage;
  final bool alreadyNetworked;

  /// The three things a person does here, plus the one waiting after.
  List<String> get _steps => [
        '选一台主机',
        '输入 Setup 码',
        if (!alreadyNetworked) '连上 Wi-Fi',
        '起名字',
      ];

  @override
  Widget build(BuildContext context) {
    final done = switch (stage) {
      _SetupStage.nearby => 0,
      _SetupStage.code => 1,
      _SetupStage.wifi => 2,
      // Working and finished are the same amount of the person's work: all of
      // it that happens here.
      _SetupStage.configuring ||
      _SetupStage.complete =>
        alreadyNetworked ? 2 : 3,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('设置', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: done / _steps.length),
        const SizedBox(height: 8),
        Text(
          _steps.indexed
              .map((entry) => entry.$1 < done ? '✓ ${entry.$2}' : entry.$2)
              .join('  ·  '),
        ),
      ],
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
  Widget build(BuildContext context) => Card(
        color: color,
        child: ListTile(leading: Icon(icon), title: Text(text)),
      );
}

IconData _wifiIcon(int signal) {
  if (signal >= 70) return Icons.network_wifi;
  if (signal >= 40) return Icons.network_wifi_2_bar;
  return Icons.network_wifi_1_bar;
}

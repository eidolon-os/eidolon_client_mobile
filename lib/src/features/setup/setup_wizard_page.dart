import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'commissioning_transport.dart';
import 'controller_key_bridge.dart';
import 'host_registry.dart';
import 'host_identity.dart';
import 'setup_models.dart';
import 'setup_trust.dart';

enum _SetupStage { nearby, code, wifi, configuring, complete }

class SetupWizardPage extends StatefulWidget {
  const SetupWizardPage({
    super.key,
    required this.onComplete,
    this.transport,
    this.controllerKeys,
    this.clock,
  });

  final ValueChanged<ManagedHost> onComplete;
  final CommissioningTransport? transport;
  final ControllerKeyBridge? controllerKeys;
  final DateTime Function()? clock;

  @override
  State<SetupWizardPage> createState() => _SetupWizardPageState();
}

class _SetupWizardPageState extends State<SetupWizardPage> {
  late final CommissioningTransport _transport;
  late final ControllerKeyBridge _controllerKeys;
  final _setupCode = TextEditingController();
  final _passphrase = TextEditingController();
  final _hiddenSsid = TextEditingController();
  final _controllerName = TextEditingController(text: '我的手机');
  final _random = Random.secure();

  _SetupStage _stage = _SetupStage.nearby;
  CommissioningEndpoint? _endpoint;
  NearbyEidolonHost? _selectedNearbyHost;
  List<NearbyEidolonHost> _nearby = const [];
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
    setState(() => _progress = '正在获取蓝牙权限');
    if (!await _transport.requestPermission()) {
      throw const CommissioningRequestException(
        'permission_denied',
        '需要“附近设备”权限才能发现未联网的 Eidolon 主机。你可以在系统设置中重新允许。',
      );
    }
    setState(() => _progress = '正在寻找附近的 Eidolon 主机');
    final discovered = await _transport.scan(
      serviceUuid: CommissioningEndpoint.defaultServiceUuid,
    );
    final nearby = discovered.toList()
      ..sort((left, right) => right.rssi.compareTo(left.rssi));
    if (nearby.isEmpty) {
      throw const CommissioningRequestException(
        'host_not_found',
        '没有找到附近的 Eidolon 主机。请确认主机已通电、靠近手机，并且 Bootstrap 正在运行。',
      );
    }
    setState(() {
      _nearby = nearby;
      _progress = null;
    });
  }

  Future<void> _selectHost(NearbyEidolonHost host) async {
    await _run(() async {
      setState(() => _progress = '正在验证 ${host.name} 的 Host 身份');
      final rawEndpoint = await _transport.open(
        address: host.address,
        serviceUuid: CommissioningEndpoint.defaultServiceUuid,
      );
      final endpoint = await CommissioningEndpoint.parseAndVerifyDiscovered(
        rawEndpoint,
      );
      setState(() => _progress = '正在建立加密 Setup 通道');
      await _transport.secure(
        tlsSpkiFingerprint: endpoint.tlsSpkiFingerprint,
      );
      final developmentSetup = endpoint.developmentSetup;
      if (developmentSetup == null) {
        try {
          if (await _recoverCompletedClaim(endpoint)) return;
        } on CommissioningRequestException catch (error) {
          if (error.code != 'controller_denied') rethrow;
        }
        throw const CommissioningRequestException(
          'setup_code_unavailable',
          '这台主机没有开放首次 Setup。它可能已被认领；请从“我的 Eidolon”进入，或使用 Owner/物理恢复流程。',
        );
      }
      final now = (widget.clock ?? DateTime.now)().toUtc();
      if (!developmentSetup.expiresAt.isAfter(now)) {
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
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      setState(() => _error = '请输入 Host 上显示的 6 位 Setup 码');
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

  Future<bool> _recoverCompletedClaim(
    CommissioningEndpoint endpoint,
  ) async {
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
        _showFailure(
          switch (error.code) {
            'BLUETOOTH_OFF' => '请先打开平板蓝牙，再重新查找附近主机。',
            'PERMISSION_DENIED' => '需要“附近设备”权限才能查找 Eidolon 主机。',
            'LINK_FAILED' => '蓝牙暂时无法连接主机。请让平板靠近主机后重试。',
            _ => error.message ?? '平板无法完成附近设备操作',
          },
        );
      }
    } on FormatException catch (error) {
      if (mounted) _showFailure(error.message);
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
        'commissioning_denied' => 'Setup 码错误、过期或已失效。请核对 6 位码；连续 5 次失败后请重新选择主机。',
        'setup_code_unavailable' =>
          '这台主机没有开放首次 Setup。如果已被认领，需要原 Controller 或物理恢复权限。',
        'setup_code_expired' => '开发 Setup 会话已过期，请重新选择主机。',
        'controller_denied' => '开箱凭据已失效，而且这台手机不是该主机已授权的管理手机。',
        'already_claimed' => '这台主机已经被认领，请从“主机恢复”入口操作。',
        'operation_conflict' => '主机正在处理另一项设置，或本次重试已失效。请重新开始这一步。',
        'internal_error' => '主机暂时无法完成这一步；蓝牙入口仍会保持可用，请稍后重试。',
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
                _ProgressHeader(stage: _stage),
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

  Widget _buildNearby() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('查找附近主机', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('给主机接通电源，并让平板保持在主机附近。首次设置不要求主机已经联网。'),
          const SizedBox(height: 8),
          const Text('附近列表可能同时包含待设置和已认领主机；选择后 App 才会验证 Host 身份和当前权限。'),
          if (kDebugMode) ...[
            const SizedBox(height: 12),
            const _Notice(
              icon: Icons.developer_mode,
              text: '开发测试：Host 可配置固定 6 位 Setup 码，也可临时生成。App 不再导入 JSON。',
              color: Color(0xFF24222D),
            ),
          ],
          const SizedBox(height: 16),
          if (_nearby.isEmpty)
            FilledButton.icon(
              key: const Key('scan-nearby-hosts'),
              onPressed: _busy ? null : _scanNearby,
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('查找附近 Eidolon 主机'),
            ),
          for (final host in _nearby)
            Card(
              child: ListTile(
                leading: const Icon(Icons.memory),
                title: Text(host.name),
                subtitle: Text('距离信号 ${host.rssi} dBm'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _selectHost(host),
              ),
            ),
          if (_progress != null) _BusyNotice(text: _progress!),
          if (_nearby.isNotEmpty) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _scanNearby,
              icon: const Icon(Icons.refresh),
              label: const Text('重新扫描'),
            ),
          ],
        ],
      );

  Widget _buildSetupCode() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('输入 Setup 码', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '已连接 ${_selectedNearbyHost?.name ?? 'Eidolon Host'}。'
            '请输入这台 Host 配置或临时生成的 6 位开发码。',
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
              LengthLimitingTextInputFormatter(6),
            ],
            maxLength: 6,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  letterSpacing: 10,
                ),
            decoration: const InputDecoration(
              labelText: '6 位 Setup 码',
              hintText: '000000',
              counterText: '',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _authenticateSetupCode(),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('authenticate-setup-code'),
            onPressed: _busy ? null : _authenticateSetupCode,
            icon: const Icon(Icons.lock_open_outlined),
            label: const Text('验证并继续'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    await _transport.close();
                    setState(() {
                      _endpoint = null;
                      _selectedNearbyHost = null;
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
              '密码只通过已加密的蓝牙 Setup 通道交给 NetworkManager，不保存在 App 或 Bootstrap DB。'),
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
            Text('如需更换网络，请选择新的 Wi-Fi：',
                style: Theme.of(context).textTheme.titleSmall),
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
            '${_completedHost!.displayName} 已连接 Wi-Fi，'
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

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.stage});

  final _SetupStage stage;

  @override
  Widget build(BuildContext context) {
    final index = switch (stage) {
      _SetupStage.nearby => 0,
      _SetupStage.code => 1,
      _SetupStage.wifi => 2,
      _SetupStage.configuring => 3,
      _SetupStage.complete => 4,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SETUP', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: (index + 1) / 5),
        const SizedBox(height: 8),
        Text('附近主机  ·  Setup 码  ·  Wi-Fi  ·  认领  ·  主机接入'),
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

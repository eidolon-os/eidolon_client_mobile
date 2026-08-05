import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../host_setup/dev_descriptor.dart';
import 'commissioning_transport.dart';
import 'host_registry.dart';
import 'setup_models.dart';

enum _SetupStage { credential, nearby, wifi, configuring, complete }

class SetupWizardPage extends StatefulWidget {
  const SetupWizardPage({
    super.key,
    required this.onComplete,
    this.transport,
    this.clock,
  });

  final ValueChanged<ManagedHost> onComplete;
  final CommissioningTransport? transport;
  final DateTime Function()? clock;

  @override
  State<SetupWizardPage> createState() => _SetupWizardPageState();
}

class _SetupWizardPageState extends State<SetupWizardPage> {
  late final CommissioningTransport _transport;
  final _credentialInput = TextEditingController();
  final _passphrase = TextEditingController();
  final _hiddenSsid = TextEditingController();
  final _controllerName = TextEditingController(text: '我的手机');
  final _random = Random.secure();

  _SetupStage _stage = _SetupStage.credential;
  DevelopmentCommissioningDescriptor? _credential;
  List<NearbyEidolonHost> _nearby = const [];
  List<WifiNetwork> _networks = const [];
  WifiNetwork? _selectedNetwork;
  String? _error;
  String? _progress;
  bool _busy = false;
  ManagedHost? _completedHost;
  late String _networkOperationId = _uuidV4();

  @override
  void initState() {
    super.initState();
    _transport = widget.transport ?? PlatformBleCommissioningTransport();
  }

  @override
  void dispose() {
    unawaited(_transport.close());
    _credentialInput.dispose();
    _passphrase.dispose();
    _hiddenSsid.dispose();
    _controllerName.dispose();
    super.dispose();
  }

  Future<void> _verifyCredential() async {
    await _run(() async {
      final credential =
          await DevelopmentCommissioningDescriptor.parseAndVerify(
        _credentialInput.text,
        clock: widget.clock,
      );
      setState(() {
        _credential = credential;
        _stage = _SetupStage.nearby;
        _progress = null;
      });
      await _scanNearbyInternal(credential);
    });
  }

  Future<void> _scanNearby() async {
    final credential = _credential;
    if (credential == null) return;
    await _run(() => _scanNearbyInternal(credential));
  }

  Future<void> _scanNearbyInternal(
    DevelopmentCommissioningDescriptor credential,
  ) async {
    setState(() => _progress = '正在获取蓝牙权限');
    if (!await _transport.requestPermission()) {
      throw const CommissioningRequestException(
        'permission_denied',
        '需要“附近设备”权限才能发现未联网的 Eidolon 主机。你可以在系统设置中重新允许。',
      );
    }
    setState(() => _progress = '正在寻找附近的 Eidolon 主机');
    final marker = credential.hostId.substring(credential.hostId.length - 6);
    final discovered = await _transport.scan(
      serviceUuid: credential.bleServiceUuid,
    );
    var matching = discovered
        .where((host) => host.hostMarker.toLowerCase() == marker)
        .toList();
    if (matching.isEmpty) matching = discovered.toList();
    matching.sort((left, right) => right.rssi.compareTo(left.rssi));
    if (matching.isEmpty) {
      throw const CommissioningRequestException(
        'host_not_found',
        '没有找到与凭据匹配的主机。请确认主机已通电、靠近手机，并且 Bootstrap 正在运行。',
      );
    }
    setState(() {
      _nearby = matching;
      _progress = null;
    });
  }

  Future<void> _selectHost(NearbyEidolonHost host) async {
    final credential = _credential;
    if (credential == null) return;
    await _run(() async {
      setState(() => _progress = '正在验证 ${host.name} 的 Host 身份');
      final rawEndpoint = await _transport.open(
        address: host.address,
        serviceUuid: credential.bleServiceUuid,
      );
      final endpoint = await CommissioningEndpoint.parseAndVerify(
        rawEndpoint,
        credential,
      );
      setState(() => _progress = '正在建立加密 Setup 通道');
      await _transport.secure(
        tlsSpkiFingerprint: endpoint.tlsSpkiFingerprint,
      );
      try {
        await _transport.request('session.authenticate', {
          'commissioning_id': credential.commissioningId,
          'commissioning_secret': credential.commissioningSecret,
        });
      } on CommissioningRequestException catch (error) {
        if (error.code != 'commissioning_denied') rethrow;
        if (await _recoverCompletedClaim(credential)) return;
        rethrow;
      }
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
      setState(() {
        _networks = networks;
        _stage = _SetupStage.wifi;
        _progress = null;
      });
    });
  }

  Future<bool> _recoverCompletedClaim(
    DevelopmentCommissioningDescriptor credential,
  ) async {
    final controller = await _transport.getControllerIdentity();
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
    final signature = await _transport.signControllerChallenge(challenge);
    final authenticated = await _transport.request('controller.authenticate', {
      ...challenge,
      'signature': signature,
    });
    final state = authenticated['state'];
    if (state is! Map || state['claim_state'] != 'claimed') return false;
    final host = ManagedHost(
      hostId: credential.hostId,
      hostPublicKey: credential.hostPublicKey,
      hostFingerprint: credential.hostPublicKeyFingerprint,
      bleServiceUuid: credential.bleServiceUuid,
      controllerId: controller.controllerId,
      displayName: 'Eidolon ${credential.hostId.substring(6, 12)}',
      claimedAt: (widget.clock ?? DateTime.now)().toUtc(),
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
    final credential = _credential;
    if (credential == null) return;
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
          '主机没有完成 Wi-Fi 连接，请检查网络名称和密码',
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
      final controller = await _transport.getControllerIdentity();
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
        hostId: credential.hostId,
        hostPublicKey: credential.hostPublicKey,
        hostFingerprint: credential.hostPublicKeyFingerprint,
        bleServiceUuid: credential.bleServiceUuid,
        controllerId: controller.controllerId,
        displayName: 'Eidolon ${credential.hostId.substring(6, 12)}',
        claimedAt: (widget.clock ?? DateTime.now)().toUtc(),
      );
      await _transport.close();
      setState(() {
        _completedHost = host;
        _stage = _SetupStage.complete;
        _progress = null;
      });
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
        _showFailure(error.message ?? '手机无法完成附近设备操作');
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
        'network_stage_failed' => '主机未能加入该 Wi-Fi。请检查密码；主机仍可通过蓝牙继续设置。',
        'network_confirm_failed' => '主机加入了 Wi-Fi，但未能安全确认变更。请重试，失败时会自动回滚。',
        'network_rollback_failed' => '主机未能立即回滚 Wi-Fi；系统检查点会继续保护原网络。',
        'commissioning_denied' => '开箱凭据已过期、已使用或被替换，请重新获取。',
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
                if (_stage == _SetupStage.credential) _buildCredential(),
                if (_stage == _SetupStage.nearby) _buildNearby(),
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

  Widget _buildCredential() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('准备连接主机', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('给主机接通电源，并让手机保持在主机附近。首次设置不要求主机已经联网。'),
          const SizedBox(height: 20),
          Card(
            child: ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('产品机：扫描机身或包装凭据'),
              subtitle: const Text('制造凭据和扫码入口在产品镜像阶段启用'),
              trailing: const Icon(Icons.lock_clock_outlined),
            ),
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 16),
            ExpansionTile(
              key: const Key('development-credential-entry'),
              initiallyExpanded: true,
              title: const Text('开发测试：导入 Dev Descriptor'),
              subtitle: const Text('每台主机独立、短期有效；不是固定万能码'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                TextField(
                  key: const Key('commissioning-credential-input'),
                  controller: _credentialInput,
                  minLines: 5,
                  maxLines: 10,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Dev Descriptor JSON',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('verify-and-find-host'),
                  onPressed: _busy ? null : _verifyCredential,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('验证并查找这台主机'),
                ),
              ],
            ),
          ],
        ],
      );

  Widget _buildNearby() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('选择附近主机', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('优先显示广播标记匹配的 Host；最终身份由 signed endpoint 验证，信号强弱只帮助定位。'),
          const SizedBox(height: 16),
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
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _scanNearby,
            icon: const Icon(Icons.refresh),
            label: const Text('重新扫描'),
          ),
        ],
      );

  Widget _buildWifi() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('让主机加入 Wi-Fi', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
              '密码只通过已加密的蓝牙 Setup 通道交给 NetworkManager，不保存在 App 或 Bootstrap DB。'),
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
          FilledButton.icon(
            key: const Key('configure-and-claim'),
            onPressed: _busy ? null : _configureAndClaim,
            icon: const Icon(Icons.rocket_launch_outlined),
            label: const Text('连接 Wi-Fi 并认领主机'),
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
          Text('主机已可以使用', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('${_completedHost!.displayName} 已联网，这台手机已成为 Host Admin。'),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('finish-setup'),
            onPressed: () => widget.onComplete(_completedHost!),
            child: const Text('进入我的 Eidolon'),
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
      _SetupStage.credential => 0,
      _SetupStage.nearby => 1,
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
        Text('凭据  ·  附近主机  ·  Wi-Fi  ·  认领  ·  完成'),
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

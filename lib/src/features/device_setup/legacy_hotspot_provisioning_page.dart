import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../setup/host_registry.dart';
import 'device_setup_models.dart';
import 'device_setup_ports.dart';
import 'legacy_hotspot_provisioning.dart';

enum _LegacyHotspotStep {
  introduction,
  connecting,
  credentials,
  configuring,
  // The device has what it needs and is on its way to the Host; the Owner's
  // device is waiting for it to arrive so it can finish the claim.
  claiming,
  complete
}

class LegacyHotspotProvisioningPage extends StatefulWidget {
  const LegacyHotspotProvisioningPage({
    super.key,
    required this.host,
    required this.loadTarget,
    required this.onCommissioned,
    this.provisioning,
  });

  final ManagedHost host;

  /// The Host this device is being given, read from the Local API while the
  /// Controller session is still authenticated — before the phone leaves the
  /// home network for the device's own hotspot.
  final Future<DeviceOnboardingTarget> Function() loadTarget;

  /// Finish the setup once the device accepted it: the person confirmed this
  /// device by commissioning it, so nothing asks them to approve it again.
  final Future<void> Function(String deviceId) onCommissioned;

  final LegacyHotspotProvisioningPort? provisioning;

  @override
  State<LegacyHotspotProvisioningPage> createState() =>
      _LegacyHotspotProvisioningPageState();
}

class _LegacyHotspotProvisioningPageState
    extends State<LegacyHotspotProvisioningPage> {
  late final LegacyHotspotProvisioningPort _provisioning;
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  var _step = _LegacyHotspotStep.introduction;
  DeviceOnboardingTarget? _target;
  CommissionableDevice? _device;
  var _networks = const <DeviceWifiNetwork>[];
  String? _selectedSsid;
  String? _error;
  var _showPassword = false;

  bool get _busy =>
      _step == _LegacyHotspotStep.connecting ||
      _step == _LegacyHotspotStep.configuring ||
      _step == _LegacyHotspotStep.claiming;

  @override
  void initState() {
    super.initState();
    _provisioning =
        widget.provisioning ?? const PlatformLegacyHotspotProvisioning();
  }

  @override
  void dispose() {
    unawaited(_provisioning.close());
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _step = _LegacyHotspotStep.connecting;
      _error = null;
    });
    try {
      final granted = await _provisioning.requestPermission();
      if (!granted) {
        throw const LegacyHotspotProvisioningException(
          code: 'WIFI_PERMISSION_DENIED',
          message: '没有“附近的 Wi-Fi 设备”权限，无法连接设备热点',
        );
      }
      // Read the Host while the phone is still on the home network: once it
      // moves to the device's hotspot the Local API is out of reach.
      final target = await widget.loadTarget();
      final networks = await _provisioning.openAndScan();
      final device = await _provisioning.identify();
      if (!mounted) return;
      final first = networks.firstOrNull;
      setState(() {
        _target = target;
        _device = device;
        _networks = networks;
        _selectedSsid = first?.ssid;
        _ssid.text = first?.ssid ?? '';
        _step = _LegacyHotspotStep.credentials;
      });
    } catch (error) {
      await _provisioning.close();
      if (!mounted) return;
      setState(() {
        _step = _LegacyHotspotStep.introduction;
        _error = _message(error);
      });
    }
  }

  Future<void> _reconnect() async {
    await _provisioning.close();
    if (!mounted) return;
    await _connect();
  }

  Future<void> _configure() async {
    if (_busy) return;
    final ssid = _ssid.text.trim();
    final password = _password.text;
    final validation = _validateCredentials(ssid, password);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    setState(() {
      _step = _LegacyHotspotStep.configuring;
      _error = null;
    });
    try {
      final target = _target ?? await widget.loadTarget();
      final commissioned = await _provisioning.commission(
        target: target,
        credentials: DeviceWifiCredentials(ssid: ssid, password: password),
      );
      _password.clear();
      await _provisioning.close();
      if (!mounted) return;
      setState(() => _step = _LegacyHotspotStep.claiming);
      await widget.onCommissioned(commissioned.deviceId);
      if (!mounted) return;
      setState(() => _step = _LegacyHotspotStep.complete);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _step = _LegacyHotspotStep.credentials;
        _error = _message(error);
      });
    }
  }

  String? _validateCredentials(String ssid, String password) {
    if (ssid.isEmpty) return '请选择或输入家庭 Wi-Fi 名称';
    if (utf8.encode(ssid).length > 32) return 'Wi-Fi 名称不能超过 32 字节';
    if (utf8.encode(password).length > 64) return 'Wi-Fi 密码不能超过 64 字节';
    final selected =
        _networks.where((network) => network.ssid == ssid).firstOrNull;
    if (selected != null && selected.security != 'open' && password.isEmpty) {
      return '该 Wi-Fi 需要密码';
    }
    return null;
  }

  String _message(Object error) => switch (error) {
        LegacyHotspotProvisioningException() => error.message,
        _ => error.toString().replaceFirst('Exception: ', ''),
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('legacy-hotspot-provisioning-page'),
        appBar: AppBar(title: const Text('设备配网')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _DevelopmentBoundaryCard(host: widget.host),
                  const SizedBox(height: 16),
                  if (_error case final error?) ...[
                    _ErrorCard(message: error),
                    const SizedBox(height: 16),
                  ],
                  switch (_step) {
                    _LegacyHotspotStep.introduction =>
                      _Introduction(onConnect: _connect),
                    _LegacyHotspotStep.connecting => const _Progress(
                        title: '连接设备配网热点',
                        body: '请在系统窗口中选择名称以 Xiaozhi- 开头的热点。',
                      ),
                    _LegacyHotspotStep.claiming => const _Progress(
                        title: '等待设备连上主机',
                        body: '设备已经收到网络和主机身份，正在上线。它出现后会自动完成认领。',
                      ),
                    _LegacyHotspotStep.credentials => _CredentialsForm(
                        device: _device,
                        networks: _networks,
                        selectedSsid: _selectedSsid,
                        ssid: _ssid,
                        password: _password,
                        showPassword: _showPassword,
                        onSsidSelected: (value) => setState(() {
                          _selectedSsid = value;
                          if (value != null) _ssid.text = value;
                        }),
                        onShowPasswordChanged: () =>
                            setState(() => _showPassword = !_showPassword),
                        onConfigure: _configure,
                        onReconnect: _reconnect,
                      ),
                    _LegacyHotspotStep.configuring => const _Progress(
                        title: '正在让设备加入 Wi-Fi',
                        body: '设备正在验证网络。这个过程可能需要约一分钟，请不要离开页面。',
                      ),
                    _LegacyHotspotStep.complete => _Completed(
                        host: widget.host,
                        onDone: () => Navigator.of(context).pop(),
                      ),
                  },
                ],
              ),
            ),
          ),
        ),
      );
}

class _DevelopmentBoundaryCard extends StatelessWidget {
  const _DevelopmentBoundaryCard({required this.host});

  final ManagedHost host;

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context)
            .colorScheme
            .errorContainer
            .withValues(alpha: 0.42),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.add_link,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '添加设备',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '这一步把家庭 Wi-Fi 和 ${host.displayName} 的身份一起交给设备：'
                '设备之后只信任这台主机。你在这里的确认就是这次授权，'
                '设备上线后会自动完成认领。',
              ),
              const SizedBox(height: 8),
              Text(
                '手机会临时加入设备自己的热点，凭据只发给它，不会离开这条连接。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
}

class _Introduction extends StatelessWidget {
  const _Introduction({required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('准备设备', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              const Text('1. 打开兼容设备，并让它进入 Wi-Fi 配网模式。'),
              const SizedBox(height: 8),
              const Text('2. 确认屏幕显示名称以 Xiaozhi- 开头的热点。'),
              const SizedBox(height: 8),
              const Text('3. 点击下方按钮，在 Android 系统窗口选择该热点。'),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('connect-device-hotspot'),
                onPressed: onConnect,
                icon: const Icon(Icons.wifi_find),
                label: const Text('选择并连接设备'),
              ),
            ],
          ),
        ),
      );
}

class _Progress extends StatelessWidget {
  const _Progress({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}

class _CredentialsForm extends StatelessWidget {
  const _CredentialsForm({
    required this.device,
    required this.networks,
    required this.selectedSsid,
    required this.ssid,
    required this.password,
    required this.showPassword,
    required this.onSsidSelected,
    required this.onShowPasswordChanged,
    required this.onConfigure,
    required this.onReconnect,
  });

  /// Which device this is about to set up, so the person can tell that the
  /// hotspot they joined belongs to the thing in front of them.
  final CommissionableDevice? device;
  final List<DeviceWifiNetwork> networks;
  final String? selectedSsid;
  final TextEditingController ssid;
  final TextEditingController password;
  final bool showPassword;
  final ValueChanged<String?> onSsidSelected;
  final VoidCallback onShowPasswordChanged;
  final VoidCallback onConfigure;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('选择家庭 Wi-Fi', style: Theme.of(context).textTheme.titleLarge),
              if (device case final found?) ...[
                const SizedBox(height: 6),
                Text(
                  '正在设置：${found.board.isEmpty ? found.deviceKind : found.board} · ${found.deviceId}',
                  key: const Key('commissionable-device'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                networks.isEmpty ? '设备没有扫描到网络，可以手动输入。' : '以下网络由设备扫描，不是手机的扫描结果。',
              ),
              if (networks.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: const Key('device-wifi-network'),
                  initialValue: selectedSsid,
                  decoration: const InputDecoration(
                    labelText: '设备扫描到的网络',
                    border: OutlineInputBorder(),
                  ),
                  items: networks
                      .map(
                        (network) => DropdownMenuItem(
                          value: network.ssid,
                          child: Text(
                            '${network.ssid}  ·  ${network.signalStrength}%${network.security == 'open' ? ' · 开放' : ''}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: onSsidSelected,
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: const Key('device-wifi-ssid'),
                controller: ssid,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Wi-Fi 名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('device-wifi-password'),
                controller: password,
                obscureText: !showPassword,
                onSubmitted: (_) => onConfigure(),
                decoration: InputDecoration(
                  labelText: 'Wi-Fi 密码',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: onShowPasswordChanged,
                    tooltip: showPassword ? '隐藏密码' : '显示密码',
                    icon: Icon(
                      showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('configure-device-wifi'),
                onPressed: onConfigure,
                icon: const Icon(Icons.router_outlined),
                label: const Text('让设备加入该 Wi-Fi'),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const Key('reconnect-device-hotspot'),
                onPressed: onReconnect,
                child: const Text('重新选择设备热点'),
              ),
            ],
          ),
        ),
      );
}

class _Completed extends StatelessWidget {
  const _Completed({required this.host, required this.onDone});

  final ManagedHost host;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.check_circle,
                size: 58,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                '设备已添加',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                '设备已加入家庭 Wi-Fi，认得 ${host.displayName}，并且已经完成认领。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('finish-device-development-provisioning'),
                onPressed: onDone,
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 12),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
}

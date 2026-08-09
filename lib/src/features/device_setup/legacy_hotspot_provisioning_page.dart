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
  complete
}

class LegacyHotspotProvisioningPage extends StatefulWidget {
  const LegacyHotspotProvisioningPage({
    super.key,
    required this.host,
    this.provisioning,
  });

  final ManagedHost host;
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
  var _networks = const <DeviceWifiNetwork>[];
  String? _selectedSsid;
  String? _error;
  var _showPassword = false;

  bool get _busy =>
      _step == _LegacyHotspotStep.connecting ||
      _step == _LegacyHotspotStep.configuring;

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
      final networks = await _provisioning.openAndScan();
      if (!mounted) return;
      final first = networks.firstOrNull;
      setState(() {
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
      await _provisioning.configureNetwork(
        DeviceWifiCredentials(ssid: ssid, password: password),
      );
      _password.clear();
      await _provisioning.close();
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
                    _LegacyHotspotStep.credentials => _CredentialsForm(
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
                    Icons.science_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '开发配网',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '当前兼容设备的热点没有产品身份证明。这一步只配置 Wi-Fi，不会把设备认领或添加到 ${host.displayName}。',
              ),
              const SizedBox(height: 8),
              Text(
                '请只在受控开发环境使用；家庭 Wi-Fi 凭据会发送给当前选中的开放配网热点。',
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
                '开发配网完成',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text(
                '设备已确认加入 Wi-Fi。当前固件没有返回可验证的设备身份，因此 App 还不能确认它是哪一台设备。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '它尚未被认领，也尚未添加到 ${host.displayName}。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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

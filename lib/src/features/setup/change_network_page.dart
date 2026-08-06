import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'commissioning_transport.dart';
import 'host_identity.dart';
import 'host_registry.dart';
import 'setup_models.dart';
import 'setup_trust.dart';

class ChangeNetworkPage extends StatefulWidget {
  const ChangeNetworkPage({super.key, required this.host, this.transport});

  final ManagedHost host;
  final CommissioningTransport? transport;

  @override
  State<ChangeNetworkPage> createState() => _ChangeNetworkPageState();
}

class _ChangeNetworkPageState extends State<ChangeNetworkPage> {
  late final CommissioningTransport _transport;
  final _passphrase = TextEditingController();
  final _hiddenSsid = TextEditingController();
  final _random = Random.secure();
  List<NearbyEidolonHost> _nearby = const [];
  List<WifiNetwork> _networks = const [];
  WifiNetwork? _selected;
  String? _error;
  String? _progress;
  bool _busy = false;
  bool _connected = false;
  bool _complete = false;
  late String _operationId = _uuidV4();

  @override
  void initState() {
    super.initState();
    _transport = widget.transport ?? PlatformBleCommissioningTransport();
  }

  @override
  void dispose() {
    unawaited(_transport.close());
    _passphrase.dispose();
    _hiddenSsid.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    await _run(() async {
      setState(() => _progress = '正在寻找 ${widget.host.displayName}');
      if (!await _transport.requestPermission()) {
        throw const CommissioningRequestException(
          'permission_denied',
          '更换 Wi-Fi 需要“附近设备”权限。',
        );
      }
      final marker = hostMarker(widget.host.hostId);
      final discovered = await _transport.scan(
        serviceUuid: widget.host.bleServiceUuid,
      );
      var nearby = discovered
          .where((item) => item.hostMarker.toLowerCase() == marker)
          .toList();
      if (nearby.isEmpty) nearby = discovered.toList();
      nearby.sort((a, b) => b.rssi.compareTo(a.rssi));
      if (nearby.isEmpty) {
        throw const CommissioningRequestException(
          'host_not_found',
          '没有在附近找到这台主机。换网不会自动开放重新认领，请确认主机已通电并靠近手机。',
        );
      }
      setState(() {
        _nearby = nearby;
        _progress = null;
      });
    });
  }

  Future<void> _connect(NearbyEidolonHost nearby) async {
    await _run(() async {
      setState(() => _progress = '正在验证 Host 和 Controller 身份');
      final rawEndpoint = await _transport.open(
        address: nearby.address,
        serviceUuid: widget.host.bleServiceUuid,
      );
      final endpoint = await CommissioningEndpoint.parseAndVerifyHost(
        rawEndpoint,
        hostId: widget.host.hostId,
        hostPublicKey: widget.host.hostPublicKey,
        bleServiceUuid: widget.host.bleServiceUuid,
      );
      await _transport.secure(
        tlsSpkiFingerprint: endpoint.tlsSpkiFingerprint,
      );
      final challenge = await _transport.request('controller.challenge', {
        'controller_id': widget.host.controllerId,
      });
      if (challenge['contract_version'] != '1' ||
          challenge['purpose'] != 'eidolon-controller-ble-auth-v1' ||
          challenge['controller_id'] != widget.host.controllerId ||
          challenge['challenge'] is! String ||
          challenge['reset_epoch'] is! int) {
        throw const CommissioningRequestException(
          'controller_denied',
          '主机返回了无效的 Controller challenge',
        );
      }
      final signature = await _transport.signControllerChallenge(challenge);
      await _transport.request('controller.authenticate', {
        ...challenge,
        'signature': signature,
      });
      final response = await _transport.request('wifi.scan', const {});
      final rawNetworks = response['networks'];
      if (rawNetworks is! List) {
        throw const CommissioningRequestException(
          'invalid_response',
          '主机没有返回 Wi-Fi 列表',
        );
      }
      setState(() {
        _networks = rawNetworks
            .whereType<Map<String, dynamic>>()
            .map(WifiNetwork.fromJson)
            .toList(growable: false);
        _connected = true;
        _progress = null;
      });
    });
  }

  Future<void> _change() async {
    final ssid = (_selected?.ssid ?? _hiddenSsid.text).trim();
    if (ssid.isEmpty) {
      setState(() => _error = '请选择 Wi-Fi，或输入隐藏网络名称');
      return;
    }
    final secured = _selected?.secured ?? _passphrase.text.isNotEmpty;
    if (secured && _passphrase.text.length < 8) {
      setState(() => _error = '受保护 Wi-Fi 的密码至少需要 8 个字符');
      return;
    }
    var staged = false;
    await _run(() async {
      setState(() => _progress = '正在切换主机 Wi-Fi；Controller 和数据不会改变');
      final result = await _transport.request('wifi.configure', {
        'operation_id': _operationId,
        'ssid': ssid,
        'passphrase': secured ? _passphrase.text : null,
        'hidden': _selected == null,
      });
      final operation = result['operation'];
      if (operation is! Map ||
          !{'waiting_confirmation', 'succeeded'}.contains(operation['state'])) {
        throw const CommissioningRequestException(
          'network_stage_failed',
          '主机没有完成新 Wi-Fi 连接',
        );
      }
      if (operation['state'] == 'waiting_confirmation') {
        staged = true;
        await _transport
            .request('wifi.confirm', {'operation_id': _operationId});
        staged = false;
      }
      await _transport.close();
      setState(() {
        _complete = true;
        _progress = null;
      });
    });
    if (staged) {
      try {
        await _transport
            .request('wifi.rollback', {'operation_id': _operationId});
      } catch (_) {
        // The Host-side NetworkManager checkpoint also has an automatic timeout.
      }
    }
    if (!_complete && mounted) _operationId = _uuidV4();
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
      if (mounted) setState(() => _error = error.message);
    } on CommissioningRequestException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? '手机无法完成蓝牙操作');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          if (_error != null) _progress = null;
        });
      }
    }
  }

  String _friendlyError(CommissioningRequestException error) =>
      switch (error.code) {
        'controller_denied' => '这台手机已没有该主机的管理权限。换网不会自动开放重新认领。',
        'network_stage_failed' => '主机未能加入新 Wi-Fi。请检查密码；原网络会被保留或自动恢复。',
        'network_confirm_failed' => '新 Wi-Fi 未能安全确认，主机将回滚到原网络。',
        'network_rollback_failed' => '主机尚未完成回滚，请保持通电并在附近稍后重试。',
        'operation_conflict' => '主机正在处理另一项网络变更，请稍后重新开始。',
        'internal_error' => '主机暂时无法完成换网，请保持通电并稍后重试。',
        _ => error.message,
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('change-network-page'),
        appBar: AppBar(title: const Text('更换 Wi-Fi')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(widget.host.displayName,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
                '此操作只修改 NetworkManager 的 Wi-Fi profile，不会重新认领、切换 Owner 或清除数据。'),
            const SizedBox(height: 20),
            if (!_connected && !_complete) ...[
              for (final host in _nearby)
                Card(
                  child: ListTile(
                    title: Text(host.name),
                    subtitle: Text('${host.rssi} dBm · 与 Host 身份匹配'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy ? null : () => _connect(host),
                  ),
                ),
              FilledButton.icon(
                key: const Key('scan-host-for-network-change'),
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(_nearby.isEmpty ? '查找这台主机' : '重新扫描'),
              ),
            ],
            if (_connected && !_complete) ...[
              for (final network in _networks)
                ListTile(
                  selected: _selected == network,
                  leading: Icon(
                    _selected == network
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(network.ssid),
                  subtitle: Text(network.secured ? '需要密码' : '开放网络'),
                  onTap: _busy
                      ? null
                      : () => setState(() {
                            _selected = network;
                            _hiddenSsid.clear();
                            _passphrase.clear();
                          }),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _hiddenSsid,
                enabled: !_busy && _selected == null,
                decoration: const InputDecoration(
                  labelText: '隐藏网络名称（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passphrase,
                enabled: !_busy && (_selected?.secured ?? true),
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Wi-Fi 密码',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('confirm-network-change'),
                onPressed: _busy ? null : _change,
                child: const Text('连接并确认新 Wi-Fi'),
              ),
            ],
            if (_complete) ...[
              const Icon(Icons.check_circle, size: 64, color: Colors.green),
              const SizedBox(height: 12),
              const Text('Wi-Fi 已更换', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ],
            if (_progress != null) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_progress!)),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(_error!),
                ),
              ),
            ],
          ],
        ),
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

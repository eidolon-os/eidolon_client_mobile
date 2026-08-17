import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'device_setup_coordinator.dart';
import 'device_setup_models.dart';
import 'device_setup_ports.dart';

/// One setup act, in the order the device abstraction states it.
///
/// The person picks a device, then a network; the Host and the network are
/// handed over together; the device enrolls under its own identity and this
/// Controller admits it. Which transport carried any of that — BLE, the device's
/// own access point, something a future device class speaks — is not visible
/// here and must not become visible here.
class DeviceSetupPage extends StatefulWidget {
  const DeviceSetupPage({
    super.key,
    required this.transport,
    required this.admission,
    required this.checkpoints,
    required this.loadTarget,
    this.allowDevelopmentTrust = true,
  });

  final DeviceProvisioningTransport transport;
  final DeviceAdmissionPort admission;
  final DeviceSetupCheckpointStore checkpoints;
  final Future<DeviceOnboardingTarget> Function() loadTarget;

  /// Development boards carry a shared setup secret rather than a per-device
  /// one, and say so in their descriptor. Refusing them outright would make
  /// every development device unusable; accepting one silently would let a
  /// production build treat it as proven.
  final bool allowDevelopmentTrust;

  @override
  State<DeviceSetupPage> createState() => _DeviceSetupPageState();
}

enum _Step { introduction, choosingDevice, choosingNetwork, working, complete }

class _DeviceSetupPageState extends State<DeviceSetupPage> {
  final _password = TextEditingController();
  final _hiddenSsid = TextEditingController();
  final _random = Random.secure();

  _Step _step = _Step.introduction;
  List<DeviceProvisioningCandidate> _candidates = const [];
  DeviceProvisioningCandidate? _candidate;
  DeviceProvisioningSession? _session;
  List<DeviceWifiNetwork> _networks = const [];
  DeviceWifiNetwork? _network;
  DeviceOnboardingTarget? _target;
  String? _error;
  String? _progress;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    _hiddenSsid.dispose();
    unawaited(widget.transport.close());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _progress = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discover() => _run(() async {
        setState(() => _progress = '正在寻找可以设置的设备');
        if (!await widget.transport.requestPermission()) {
          throw Exception('设置设备需要「附近设备」权限。');
        }
        // The Host is read while this phone is still on the Host's network.
        // Opening a session moves the phone onto the device's own access point,
        // where the Host is not reachable at all — asking for it there failed
        // every setup after the device had already answered for itself, which
        // pointed the search at the device rather than at this ordering.
        _target ??= await widget.loadTarget();
        final found = await widget.transport.discover();
        if (found.isEmpty) {
          throw Exception(
            '附近没有等待设置的设备。请长按设备按键让它进入设置模式,然后重试。',
          );
        }
        setState(() {
          _candidates = found;
          _step = _Step.choosingDevice;
          _progress = null;
        });
      });

  Future<void> _select(DeviceProvisioningCandidate candidate) => _run(() async {
        setState(() => _progress = '正在读取设备身份');
        final session = await widget.transport.open(candidate);
        final networks = await session.scanNetworks();
        setState(() {
          _candidate = candidate;
          _session = session;
          _networks = networks;
          _step = _Step.choosingNetwork;
          _progress = null;
        });
      });

  Future<void> _finish() async {
    final ssid = (_network?.ssid ?? _hiddenSsid.text).trim();
    if (ssid.isEmpty) {
      setState(() => _error = '请选择 Wi-Fi,或输入隐藏网络名称');
      return;
    }
    await _run(() async {
      setState(() {
        _step = _Step.working;
        _progress = '正在把网络和 Host 交给设备';
      });
      final target = _target;
      if (target == null) {
        throw Exception('还没有读到这台 Host 的信息,请退回上一步重新查找设备。');
      }
      final coordinator = DeviceSetupCoordinator(
        // The session is already open, so the coordinator is handed a transport
        // that returns it rather than opening a second one against the same
        // device.
        transport: _OpenSessionTransport(widget.transport, _session!),
        admission: widget.admission,
        checkpoints: widget.checkpoints,
        allowDevelopmentTrust: widget.allowDevelopmentTrust,
      );
      final checkpoint = await coordinator.provisionAndAdmit(
        setupId: _uuidV4(),
        requestId: _uuidV4(),
        candidate: _candidate!,
        credentials:
            DeviceWifiCredentials(ssid: ssid, password: _password.text),
        onboardingTarget: target,
      );
      if (checkpoint.failure != null) {
        throw Exception(checkpoint.failure!.message);
      }
      setState(() {
        _step = _Step.complete;
        _progress = null;
      });
    });
    if (mounted && _step != _Step.complete) {
      setState(() => _step = _Step.choosingNetwork);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('device-setup-page'),
        appBar: AppBar(title: const Text('设置设备')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            switch (_step) {
              _Step.introduction => _introduction(),
              _Step.choosingDevice => _deviceList(),
              _Step.choosingNetwork => _networkForm(),
              _Step.working => const SizedBox.shrink(),
              _Step.complete => _complete(),
            },
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

  Widget _introduction() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('准备设备', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text('1. 给设备通电。'),
          const SizedBox(height: 4),
          const Text('2. 按一下设备上的按键,让它进入设置模式。'),
          const SizedBox(height: 4),
          const Text('3. 设置窗口是有时限的;超时后再按一次即可重新打开。'),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('discover-devices'),
            onPressed: _busy ? null : _discover,
            icon: const Icon(Icons.search),
            label: const Text('查找设备'),
          ),
        ],
      );

  Widget _deviceList() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('选择设备', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          for (final candidate in _candidates)
            Card(
              child: ListTile(
                key: Key('candidate-${candidate.transportId}'),
                title: Text(candidate.displayName),
                subtitle: Text(candidate.signalStrength == null
                    ? candidate.transportKind
                    : '${candidate.transportKind} · ${candidate.signalStrength} dBm'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _select(candidate),
              ),
            ),
          TextButton(
            onPressed: _busy ? null : _discover,
            child: const Text('重新查找'),
          ),
        ],
      );

  Widget _networkForm() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('选择家庭 Wi-Fi', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_session != null)
            Text(
              key: const Key('provisionable-device'),
              '${_session!.descriptor.displayName} · ${_session!.descriptor.deviceId}',
            ),
          const SizedBox(height: 12),
          for (final network in _networks)
            ListTile(
              key: Key('network-${network.ssid}'),
              selected: _network == network,
              leading: Icon(_network == network
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: Text(network.ssid),
              subtitle: Text(network.security),
              onTap: _busy
                  ? null
                  : () => setState(() {
                        _network = network;
                        _hiddenSsid.clear();
                      }),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _hiddenSsid,
            enabled: !_busy && _network == null,
            decoration: const InputDecoration(
              labelText: '隐藏网络名称(可选)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: !_busy,
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
            key: const Key('confirm-device-setup'),
            onPressed: _busy ? null : _finish,
            child: const Text('把网络和 Host 交给设备'),
          ),
        ],
      );

  Widget _complete() => Column(
        children: [
          const Icon(Icons.check_circle, size: 64, color: Colors.green),
          const SizedBox(height: 12),
          const Text('设备已设置完成', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
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

/// Hands the coordinator the session this page already opened.
///
/// Reading the descriptor is what tells the person which device they are about
/// to configure, so it happens before they choose a network. Opening a second
/// session afterwards would either fail — a device offers one at a time — or
/// configure a different device than the one on screen.
class _OpenSessionTransport implements DeviceProvisioningTransport {
  _OpenSessionTransport(this._inner, this._session);

  final DeviceProvisioningTransport _inner;
  final DeviceProvisioningSession _session;

  @override
  Future<bool> requestPermission() => _inner.requestPermission();

  @override
  Future<List<DeviceProvisioningCandidate>> discover() => _inner.discover();

  @override
  Future<DeviceProvisioningSession> open(
    DeviceProvisioningCandidate candidate,
  ) async =>
      _session;

  @override
  Future<void> close() => _inner.close();
}

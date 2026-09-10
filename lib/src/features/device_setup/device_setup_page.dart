import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'device_setup_coordinator.dart';
import 'admission_observation.dart';
import 'device_setup_models.dart';
import 'device_setup_ports.dart';
import 'owner_domain_directory_verifier.dart';
import '../host_setup/failure_sentences.dart';

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

class _DeviceSetupPageState extends State<DeviceSetupPage>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  final _hiddenSsid = TextEditingController();
  final _random = Random.secure();

  _Step _step = _Step.introduction;
  List<DeviceProvisioningCandidate> _candidates = const [];
  DeviceProvisioningCandidate? _candidate;
  late final DeviceSetupCoordinator _coordinator;
  late final AdmissionObservation _admissionObservation;
  DeviceProvisioningDescriptor? _descriptor;
  CommissioningVoucher? _voucher;
  List<DeviceWifiNetwork> _networks = const [];
  DeviceWifiNetwork? _network;
  DeviceOnboardingTarget? _target;
  String? _error;
  String? _progress;
  bool _busy = false;
  bool _networkConfigured = false;

  bool _refused = false;
  List<DeviceSetupCheckpoint> _pendingSetups = const [];
  String? _activeSetupId;
  String? _activeRequestId;

  @override
  void initState() {
    super.initState();
    _coordinator = DeviceSetupCoordinator(
      transport: widget.transport,
      loadTarget: widget.loadTarget,
      admission: widget.admission,
      checkpoints: widget.checkpoints,
      ownerDirectoryVerifier: PlatformOwnerDomainDirectoryVerifier(),
      allowDevelopmentTrust: widget.allowDevelopmentTrust,
      onCheckpoint: _showCheckpoint,
    );
    _admissionObservation = AdmissionObservation(_resumePersistedAdmission);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPendingSetups());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _admissionObservation.resume();
      if (!_busy) {
        if (_activeSetupId != null && _step == _Step.working && !_refused) {
          unawaited(_resumePersistedAdmission());
        } else if (_step == _Step.introduction) {
          unawaited(_loadPendingSetups());
        }
      }
    } else {
      _admissionObservation.pause();
    }
  }

  @override
  void dispose() {
    _admissionObservation.dispose();
    WidgetsBinding.instance.removeObserver(this);
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
          _error = failureSentence(error);
          _progress = null;
          if (_step == _Step.working &&
              error is DeviceSetupException &&
              !error.retryable) {
            _refused = true;
            _admissionObservation.setWaiting(false);
          }
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
        _target = await widget.loadTarget();
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
        final target = _target;
        if (target == null) {
          await session.close();
          throw Exception('还没有读到目标主机的信息。');
        }
        late final DeviceProvisioningDescriptor descriptor;
        late final List<DeviceWifiNetwork> networks;
        try {
          descriptor = await session.prepareOwner(target);
          networks = await session.scanNetworks();
        } finally {
          await session.close();
        }
        // Everything this device needs from the Host is asked for here, with
        // the device's access point left behind and before going back to it.
        // Not an ordering preference: a phone joins that access point with the
        // radio it reaches the Host on, so while the session is open the Host
        // is not merely slow, it is absent — measured on real hardware, where
        // the platform listed the device's network as the only network the
        // phone had. So this is two visits, and the standing the device will
        // present is signed between them, for the key it just showed us.
        if (!mounted) return;
        setState(() => _progress = '正在向主机取得这台设备的准入凭据');
        final voucher = await _issueVoucher(descriptor);
        if (!mounted) return;
        setState(() {
          _candidate = candidate;
          _descriptor = descriptor;
          _voucher = voucher;
          _networks = networks;
          _step = _Step.choosingNetwork;
          _progress = null;
        });
      });

  /// Ask the Host to sign this device's standing, once this phone is back on
  /// the Host's network.
  ///
  /// Releasing the device's network is not instant on Android, so a first
  /// attempt can still leave from the wrong side of the switch. Retried rather
  /// than reported: the alternative is telling the operator that the Host is
  /// unreachable at the exact moment it is merely still being handed back.
  Future<CommissioningVoucher> _issueVoucher(
    DeviceProvisioningDescriptor descriptor,
  ) async {
    Object? failure;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        return await widget.admission.issueCommissioningVoucher(
          operationalSpkiSha256: descriptor.identityFingerprint,
        );
      } catch (error) {
        failure = error;
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    throw Exception('主机没有为这台设备签发准入凭据：$failure');
  }

  Future<void> _finish() async {
    if (_busy) return;
    final ssid = (_network?.ssid ?? _hiddenSsid.text).trim();
    if (ssid.isEmpty) {
      setState(() => _error = '请选择 Wi-Fi,或输入隐藏网络名称');
      return;
    }
    await _run(() async {
      setState(() {
        _step = _Step.working;
        _progress = '正在把网络和 Host 交给设备,然后等它在主机上登记';
      });
      final target = _target;
      if (target == null) {
        throw Exception('还没有读到这台 Host 的信息,请退回上一步重新查找设备。');
      }
      final voucher = _voucher;
      if (voucher == null) {
        throw Exception('还没有这台设备的准入凭据,请退回上一步重新选择设备。');
      }
      _activeSetupId ??= _uuidV4();
      _activeRequestId ??= _uuidV4();
      await _coordinator.provisionAndAdmit(
        setupId: _activeSetupId!,
        requestId: _activeRequestId!,
        candidate: _candidate!,
        credentials:
            DeviceWifiCredentials(ssid: ssid, password: _password.text),
        onboardingTarget: target,
        voucher: voucher,
      );
    });
  }

  Future<void> _loadPendingSetups() async {
    try {
      final pending = await _coordinator.resumableSetups();
      if (mounted && _step == _Step.introduction) {
        setState(() => _pendingSetups = pending);
      }
    } catch (error) {
      if (mounted && _step == _Step.introduction) {
        setState(() => _error = failureSentence(error));
      }
    }
  }

  Future<void> _continueSetup(DeviceSetupCheckpoint checkpoint) async {
    if (_busy) return;
    _activeSetupId = checkpoint.setupId;
    _activeRequestId = checkpoint.requestId;
    await _resumePersistedAdmission();
  }

  Future<void> _resumePersistedAdmission() => _run(() async {
        final setupId = _activeSetupId;
        if (setupId == null) return;
        setState(() {
          _step = _Step.working;
          _progress = '正在从主机恢复设备接入状态';
        });
        final recovered = await _coordinator.resumeAdmission(setupId);
        _showCheckpoint(recovered);
      });

  void _showCheckpoint(DeviceSetupCheckpoint checkpoint) {
    if (!mounted) return;
    setState(() {
      _networkConfigured = checkpoint.provisioningState ==
          DeviceProvisioningState.networkConfigured;
      if (checkpoint.provisioningState !=
          DeviceProvisioningState.networkConfigured) {
        _step = checkpoint.provisioningState == DeviceProvisioningState.failed
            ? _Step.choosingNetwork
            : _Step.working;
        _progress = checkpoint.failure != null
            ? null
            : checkpoint.provisioningState == DeviceProvisioningState.selected
                ? '正在重新连接设备，发送网络配置…'
                : '正在等待设备确认 Wi-Fi 和主机连接…';
        _error = checkpoint.failure?.message;
      } else if (checkpoint.isReady) {
        _step = _Step.complete;
        _progress = null;
        _error = null;
        _refused = false;
      } else {
        _step = _Step.working;
        // Two ways this setup is over. `rejected` is the Host's final word on
        // the Enrollment. A failure the coordinator graded un-retryable is the
        // other — a Host that answers 404 for this Enrollment will answer 404
        // forever — and it used to render as "in progress" with a retry the
        // Host had already ruled out.
        final failure = checkpoint.failure;
        _refused = checkpoint.admissionState == DeviceAdmissionState.rejected ||
            (failure != null && !failure.retryable);
        _progress =
            _refused ? null : _admissionProgress(checkpoint.admissionState);
        _error = checkpoint.failure?.message;
      }
    });
    _admissionObservation.setWaiting(
      checkpoint.provisioningState ==
              DeviceProvisioningState.networkConfigured &&
          !checkpoint.isReady &&
          !_refused,
    );
  }

  /// Explicitly abandon only the selected phone-side attempt.
  Future<void> _startOver() => _run(() async {
        final setupId = _activeSetupId;
        if (setupId != null) {
          await widget.checkpoints.remove(setupId);
        }
        // Nothing left to converge on; the periodic ask would otherwise keep
        // scanning for a checkpoint that has just been forgotten.
        _admissionObservation.setWaiting(false);
        if (!mounted) return;
        setState(() {
          _activeSetupId = null;
          _activeRequestId = null;
          _refused = false;
          _networkConfigured = false;
          _pendingSetups =
              _pendingSetups.where((item) => item.setupId != setupId).toList();
          _progress = null;
          _error = null;
          _candidates = const [];
          _candidate = null;
          _networks = const [];
          _network = null;
          _password.clear();
          _hiddenSsid.clear();
          _step = _Step.introduction;
        });
      });

  String _admissionProgress(DeviceAdmissionState state) => switch (state) {
        DeviceAdmissionState.awaitingEnrollment => '等待设备向主机登记，状态会自动更新',
        DeviceAdmissionState.pendingReview => '设备已登记，正在提交你确认的接入批准',
        DeviceAdmissionState.approvedAwaitingHandoff => '已批准，等待设备领取接入凭据',
        DeviceAdmissionState.grantDelivered => '凭据已交付，等待设备确认接入完成',
        DeviceAdmissionState.claimActive => '设备接入已生效',
        DeviceAdmissionState.rejected => '这次设备接入已终止',
        DeviceAdmissionState.failed => '正在自动重新查询主机接入状态',
        DeviceAdmissionState.notStarted => '等待设备向主机登记',
      };

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
              _Step.working => _working(),
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
          if (_pendingSetups.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('未完成的设备接入', style: Theme.of(context).textTheme.titleMedium),
            const Text('可以继续上次接入，也可以直接查找新设备。'),
            for (final checkpoint in _pendingSetups)
              Card(
                  child: ListTile(
                title: Text(
                    '设备 …${checkpoint.deviceId!.substring(max(0, checkpoint.deviceId!.length - 12))}'),
                subtitle: Text('上次操作：${checkpoint.updatedAt.toLocal()}'),
                trailing: TextButton(
                  key: Key('continue-setup-${checkpoint.setupId}'),
                  onPressed: _busy ? null : () => _continueSetup(checkpoint),
                  child: const Text('继续接入'),
                ),
              )),
          ],
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
          if (_descriptor != null)
            Text(
              key: const Key('provisionable-device'),
              '${_descriptor!.displayName} · ${_descriptor!.deviceId}',
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
          const Text(
            '确认后，应用会再次连接设备并发送 Wi-Fi 配置。'
            '若系统弹出“连接到设备”，请点“连接”。'
            '设备联网后，应用会自动批准它接入所选主机并更新结果。',
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('confirm-device-setup'),
            onPressed: _busy ? null : _finish,
            child: const Text('确认配网并批准这次设备接入'),
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

  /// The Host's verdict decides what this says, and whether resuming is worth
  /// offering. It does not decide whether the person may leave.
  ///
  /// Leaving is what forgets the checkpoint, and the checkpoint is what the
  /// resume scan adopts, so a way out is the only thing keeping this screen
  /// from becoming the entrance. Offering it solely on refusal moved that dead
  /// end one step along rather than closing it: a failure graded retryable —
  /// a device that never created its Enrollment, because it was reflashed and
  /// can no longer reach the Host — retries forever behind a door only a
  /// refusal can open.
  Widget _working() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _refused
                ? '这次接入进行不下去了'
                : _networkConfigured
                    ? 'Wi-Fi 已配置，正在接入主机'
                    : '正在配置设备网络',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            _refused
                ? '这次接入已结束或失效。可以重新添加设备；已有设备的状态请在主机设备列表查看。'
                : _networkConfigured
                    ? '网络配置已保存，无需再次输入密码。接下来由设备向主机登记并完成接入。'
                    : '正在把网络配置发送给设备，请保持设备通电。',
          ),
          const SizedBox(height: 16),
          if (!_refused) ...[
            FilledButton.icon(
              key: const Key('resume-device-admission'),
              onPressed: _busy ? null : _resumePersistedAdmission,
              icon: const Icon(Icons.refresh),
              label: const Text('从主机恢复状态'),
            ),
            const SizedBox(height: 8),
          ],
          OutlinedButton.icon(
            key: const Key('restart-device-setup'),
            onPressed: _busy ? null : _startOver,
            icon: const Icon(Icons.restart_alt),
            label: const Text('重新设置设备'),
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

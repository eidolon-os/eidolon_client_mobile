import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../theme/eidolon_theme.dart';

import 'device_setup_coordinator.dart';
import 'admission_observation.dart';
import 'device_setup_models.dart';
import 'device_setup_ports.dart';
import 'owner_domain_directory_verifier.dart';
import '../host_setup/failure_sentences.dart';
import '../host_setup/host_product_session.dart';
import '../host_setup/local_api_client.dart';
import '../host_setup/pinned_http_client.dart';

List<DeviceWifiNetwork> _strongestNetworkPerSsid(
    Iterable<DeviceWifiNetwork> networks) {
  final strongest = <String, DeviceWifiNetwork>{};
  for (final network in networks) {
    final existing = strongest[network.ssid];
    if (existing == null || network.signalStrength > existing.signalStrength) {
      strongest[network.ssid] = network;
    }
  }
  return strongest.values.toList(growable: false);
}

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
    this.expectedDeviceId,
    this.knownDevices = const {},
    this.hostReturnBudget = const Duration(seconds: 90),
    this.hostReturnInterval = const Duration(seconds: 3),
    this.clock = DateTime.now,
  });

  /// Where the time comes from, for the wait above. The coordinator's own
  /// notion, so a test can move it rather than wait it out.
  final DeviceSetupClock clock;

  final DeviceProvisioningTransport transport;
  final DeviceAdmissionPort admission;
  final DeviceSetupCheckpointStore checkpoints;
  final Future<DeviceOnboardingTarget> Function() loadTarget;
  final String? expectedDeviceId;
  final Map<String, String> knownDevices;

  /// How long the Host is given to become reachable again after this phone
  /// leaves the device's access point, before the person is told to put the
  /// phone back on the Host's network themselves.
  ///
  /// Not a request timeout. Leaving a device's access point hands the radio
  /// back to the platform, which then has to re-associate with the network
  /// the Host is on, and that step is the platform's and the router's, not
  /// ours: measured on real hardware, one tablet was refused by its own home
  /// router for over a minute and then had that network "temporarily
  /// disabled" by Android for consecutive failures. Asking the Host four
  /// times in twelve seconds and giving up — what this screen used to do —
  /// reported that platform step as the Host's refusal, and threw away the
  /// identity the device had just prepared, so the person's only move was to
  /// visit the device again for nothing.
  final Duration hostReturnBudget;
  final Duration hostReturnInterval;

  /// Development boards carry a shared setup secret rather than a per-device
  /// one, and say so in their descriptor. Refusing them outright would make
  /// every development device unusable; accepting one silently would let a
  /// production build treat it as proven.
  final bool allowDevelopmentTrust;

  @override
  State<DeviceSetupPage> createState() => _DeviceSetupPageState();
}

enum _Step {
  introduction,
  choosingDevice,
  // The device has prepared its identity and the session is closed, but
  // this phone has not come back onto the Host's network; the standing is
  // still to be asked for. Not a failure of the device or the Host.
  awaitingHost,
  choosingNetwork,
  working,
  complete,
}

/// The Host did not answer within [DeviceSetupPage.hostReturnBudget] after
/// the device's access point was left. Internal: the screen turns it into the
/// awaiting-Host step rather than an error, because nothing is wrong yet.
class _HostNotBackYet implements Exception {
  const _HostNotBackYet(this.lastFailure);

  final Object lastFailure;
}

class _DeviceSetupPageState extends State<DeviceSetupPage>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  final _hiddenSsid = TextEditingController();
  final _random = Random.secure();

  String? _scanWarning;
  String? _completedDeviceId;
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
  bool _networkOutcomeUnknown = false;
  bool _admissionActive = false;
  bool _showPassword = false;
  String? _connectingNetwork;

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
        } else if (_step == _Step.awaitingHost) {
          // Coming back from the system Wi-Fi settings is the usual way the
          // network is restored; the person should not also have to tap.
          unawaited(_resumeVoucher());
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
          _error = switch (error) {
            DeviceProvisioningTransportException failure => failure.message,
            DeviceSetupException failure => failure.message,
            _ => failureSentence(error),
          };
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
        setState(() {
          _progress = '正在寻找可以设置的设备';
          // A fresh search forgets the device the previous one prepared;
          // the one chosen next is read again in full.
          _candidate = null;
          _descriptor = null;
          _voucher = null;
          _networks = const [];
          _network = null;
        });
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
            '附近没有等待设置的设备。请在设备上打开网络设置,然后重试。',
          );
        }
        setState(() {
          _candidates = found;
          _step = _Step.choosingDevice;
          _progress = null;
        });
      });

  Future<void> _select(DeviceProvisioningCandidate candidate) => _run(() async {
        setState(() {
          _candidate = candidate;
          _progress = '正在连接设备并读取信息';
          _scanWarning = null;
        });
        final session = await widget.transport.open(candidate);
        final target = _target;
        if (target == null) {
          await session.close();
          throw Exception('还没有读到目标主机的信息。');
        }
        late final DeviceProvisioningDescriptor descriptor;
        late final List<DeviceWifiNetwork> networks;
        try {
          final originalId = session.descriptor.deviceId;
          final expected = widget.expectedDeviceId;
          if (expected != null && originalId != expected) {
            throw const DeviceProvisioningTransportException(
              'device_identity_changed',
              '发现的设备身份与原记录不同。可能选择了另一台设备，也可能设备被重置过。此次未修改网络或添加设备，请返回确认原设备记录。',
            );
          }
          if (mounted) setState(() => _progress = '正在确认设备归属');
          descriptor = await session.prepareOwner(target);
          final preserving = expected ??
              (widget.knownDevices.containsKey(originalId) ? originalId : null);
          if (preserving != null && descriptor.deviceId != preserving) {
            throw const DeviceProvisioningTransportException(
              'device_identity_replacement_required',
              '这次操作需要更换设备身份，不能作为普通换网继续。原设备记录已保留，请先处理设备归属或身份恢复。',
            );
          }
          if (mounted) setState(() => _progress = '正在扫描设备附近的 Wi-Fi');
          try {
            networks = _strongestNetworkPerSsid(await session.scanNetworks());
          } on DeviceProvisioningTransportException catch (error) {
            if (!{
              'device_scan_timeout',
              'device_scan_failed',
              'device_disconnected',
              'provisioning_closed'
            }.contains(error.code)) {
              rethrow;
            }
            networks = const [];
            if (mounted) {
              setState(() =>
                  _scanWarning = '未能读取设备附近的 Wi-Fi。可以手动输入网络名称，提交时会重新连接设备。');
            }
          }
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
        // What the first visit established is kept before the Host is asked,
        // so a Host that cannot be reached yet costs a wait and not a second
        // visit to the device.
        setState(() {
          _candidate = candidate;
          _descriptor = descriptor;
          _voucher = null;
          _networks = networks;
        });
        await _issueVoucherOrWait(descriptor);
      });

  /// Ask the Host for this device's standing, or leave the screen waiting for
  /// the phone to get back to the Host's network.
  ///
  /// Only the Host's answer moves the screen on; only a refusal is an error.
  /// Not reaching the Host within the budget is neither — it is the one state
  /// a person can fix from the system settings without touching the device.
  Future<void> _issueVoucherOrWait(
    DeviceProvisioningDescriptor descriptor,
  ) async {
    if (!descriptor.requiresVoucher) {
      if (!mounted) return;
      setState(() {
        _step = _Step.choosingNetwork;
        _progress = null;
      });
      return;
    }
    final CommissioningVoucher voucher;
    try {
      voucher = await _issueVoucher(descriptor);
    } on _HostNotBackYet {
      if (!mounted) return;
      setState(() {
        _step = _Step.awaitingHost;
        _progress = null;
        _error = null;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _voucher = voucher;
      _step = _Step.choosingNetwork;
      _progress = null;
    });
  }

  /// The person says the phone is back on the Host's network; ask again with
  /// what the device already prepared. Nothing about the device is redone.
  Future<void> _resumeVoucher() => _run(() async {
        final descriptor = _descriptor;
        if (descriptor == null) {
          throw Exception('还没有读到这台设备的信息，请重新选择设备。');
        }
        await _issueVoucherOrWait(descriptor);
      });

  /// Ask the Host to sign this device's standing, once this phone is back on
  /// the Host's network.
  ///
  /// Releasing the device's network is not instant on Android, and getting
  /// back onto the Host's network is slower still and not always automatic:
  /// the platform re-associates on its own schedule, and a router that does
  /// not answer leaves the phone with no network at all. So the Host is asked
  /// for as long as [DeviceSetupPage.hostReturnBudget] allows while the
  /// failure is "not reachable", and the person can see that this is what is
  /// being waited for. A refusal is reported at once: waiting cannot change
  /// the Host's mind, and pretending otherwise hides the one thing the person
  /// would need to read.
  Future<CommissioningVoucher> _issueVoucher(
    DeviceProvisioningDescriptor descriptor,
  ) async {
    final started = widget.clock();
    final deadline = started.add(widget.hostReturnBudget);
    Object? lastFailure;
    while (true) {
      if (!mounted) throw _HostNotBackYet(lastFailure ?? 'closed');
      if (lastFailure == null) {
        setState(() => _progress = '正在向主机取得这台设备的准入凭据');
      }
      try {
        return await widget.admission.issueCommissioningVoucher(
          operationalSpkiSha256: descriptor.identityFingerprint,
        );
      } catch (error) {
        if (!_hostNotReachedYet(error)) {
          throw Exception('主机没有为这台设备签发准入凭据：${failureSentence(error)}');
        }
        lastFailure = error;
      }
      if (!widget.clock().isBefore(deadline)) {
        throw _HostNotBackYet(lastFailure);
      }
      if (!mounted) throw _HostNotBackYet(lastFailure);
      // Said as soon as it is known, not after the first interval: what the
      // person sees during the wait is what tells them which network to look
      // at if it goes on.
      final waited = widget.clock().difference(started).inSeconds;
      setState(
          () => _progress = '正在等手机回到主机所在的网络，再向主机取得这台设备的准入凭据（已等 $waited 秒）');
      await Future<void>.delayed(widget.hostReturnInterval);
    }
  }

  /// Discovery candidates with another identity do not speak for the target.
  /// Actual target refusals and malformed responses still stop this wait.
  static bool _hostNotReachedYet(Object error) {
    if (error is PinnedHttpException) return _silentTransport(error);
    if (error is HostLocationException) {
      return error.targetFailures
          .every((failure) => _hostNotReachedYet(failure.error));
    }
    if (error is LocalApiRequestException) return false;
    if (error is HostControllerAuthorizationException) {
      final cause = error.cause;
      return !error.reclaimRequired &&
          cause != null &&
          _hostNotReachedYet(cause);
    }
    return error is TimeoutException ||
        error is SocketException ||
        error is http.ClientException;
  }

  static bool _silentTransport(PinnedHttpException error) =>
      switch (error.kind) {
        PinnedHttpFailureKind.unreachable ||
        PinnedHttpFailureKind.timeout ||
        PinnedHttpFailureKind.io ||
        PinnedHttpFailureKind.cancelled =>
          true,
        _ => false,
      };

  Future<void> _finish() async {
    if (_busy) return;
    final ssid = (_network?.ssid ?? _hiddenSsid.text).trim();
    if (ssid.isEmpty) {
      setState(() => _error = '请选择 Wi-Fi,或输入隐藏网络名称');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await _run(() async {
      setState(() {
        _connectingNetwork = ssid;
        _step = _Step.working;
        _progress = '正在连接设备';
      });
      final target = _target;
      if (target == null) {
        throw Exception('还没有读到这台 Host 的信息,请退回上一步重新查找设备。');
      }
      final voucher = _voucher;
      if (voucher == null && (_descriptor?.requiresVoucher ?? true)) {
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
        expectedDeviceId: _descriptor?.deviceId,
      );
    });
  }

  Future<void> _loadPendingSetups() async {
    try {
      final pending = await _coordinator.resumableSetups();
      if (mounted && _step == _Step.introduction) {
        setState(() => _pendingSetups = pending
            .where((item) =>
                widget.expectedDeviceId == null ||
                item.deviceId == widget.expectedDeviceId)
            .toList());
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
      _admissionActive =
          checkpoint.admissionState == DeviceAdmissionState.claimActive;
      _networkOutcomeUnknown = checkpoint.provisioningState ==
          DeviceProvisioningState.outcomeUnknown;
      if (!_networkConfigured && !_networkOutcomeUnknown) {
        _step = checkpoint.provisioningState == DeviceProvisioningState.failed
            ? _Step.choosingNetwork
            : _Step.working;
        _progress = checkpoint.failure != null
            ? null
            : checkpoint.provisioningState == DeviceProvisioningState.selected
                ? '正在连接设备'
                : '正在等待设备确认 Wi-Fi 和主机连接…';
        _error = checkpoint.failure?.message;
      } else if (checkpoint.isReady) {
        _completedDeviceId = checkpoint.deviceId;
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
        _progress = _refused || _admissionActive
            ? null
            : _admissionProgress(checkpoint.admissionState);
        _error = checkpoint.failure?.message;
      }
    });
    _admissionObservation.setWaiting(
      (_networkConfigured || _networkOutcomeUnknown) &&
          !_admissionActive &&
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
          _networkOutcomeUnknown = false;
          _admissionActive = false;
          _pendingSetups =
              _pendingSetups.where((item) => item.setupId != setupId).toList();
          _progress = null;
          _error = null;
          _candidates = const [];
          _candidate = null;
          _descriptor = null;
          _voucher = null;
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
              _Step.awaitingHost => _awaitingHost(),
              _Step.choosingNetwork => _networkForm(),
              _Step.working => _working(),
              _Step.complete => _complete(),
            },
            // Only while a visit to the device is what is being waited for.
            // Once the device has answered, what is being waited for is the
            // Host, and telling the person to join the device's hotspot then
            // sends them the wrong way.
            if (_busy &&
                _candidate?.transportKind == 'softap' &&
                !_networkConfigured &&
                !_networkOutcomeUnknown &&
                ((_step == _Step.choosingDevice && _descriptor == null) ||
                    _step == _Step.working)) ...[
              const SizedBox(height: 16),
              Text('如系统要求连接设备，请选择“${_candidate!.transportId}”并允许连接。'
                  '若进入 WLAN 页面，连接该热点后返回此处，设置会自动继续。'
                  '设备热点暂时无法上网是正常现象。'),
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

  Widget _introduction() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('准备设备', style: Theme.of(context).textTheme.titleLarge),
          if (widget.expectedDeviceId != null)
            const Text('为原设备更换 Wi-Fi。请在这台设备上打开网络设置；设备身份和已有绑定将保持不变。'),
          const SizedBox(height: 12),
          const Text('1. 给设备通电。'),
          const SizedBox(height: 4),
          const Text('2. 在设备上打开网络设置,进入配网模式。'),
          const SizedBox(height: 4),
          const Text('3. 设置模式会持续开启，完成配网后自动关闭。'),
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

  /// The device is ready and this phone is not where the Host is.
  ///
  /// Says which of the three parties is the one to act on, and that the
  /// device is not it: its setup mode stays open and what it prepared is kept
  /// on it, so touching it again would only start over. The way forward is
  /// the phone's own Wi-Fi, which this app cannot change for the person.
  Widget _awaitingHost() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('手机还没回到主机所在的网络', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (_descriptor != null)
            Text(
              key: const Key('provisionable-device'),
              _descriptor!.displayName,
            ),
          const SizedBox(height: 8),
          const Text('设备已经准备好，设备上的设置模式还开着，不用再碰设备。'),
          const SizedBox(height: 4),
          const Text('手机离开设备热点后没有自动连回主机所在的 Wi-Fi。'
              '请到系统的 Wi-Fi 设置连回那个网络（必要时先关闭再打开 Wi-Fi），然后回到这里。'),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('retry-host-voucher'),
            onPressed: _busy ? null : _resumeVoucher,
            icon: const Icon(Icons.wifi),
            label: const Text('已连回网络，继续'),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('rescan-devices'),
            onPressed: _busy ? null : _discover,
            child: const Text('重新选择设备'),
          ),
        ],
      );

  Widget _networkForm() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('选择家庭 Wi-Fi', style: Theme.of(context).textTheme.titleLarge),
          if (widget.knownDevices[_descriptor?.deviceId] case final name?)
            Text('已识别原设备：$name。此次更新网络，不会重复添加。'),
          if (_scanWarning != null) Text(_scanWarning!),
          const SizedBox(height: 8),
          if (_descriptor != null)
            Text(
              key: const Key('provisionable-device'),
              _descriptor!.displayName,
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
            decoration: InputDecoration(
              labelText: _networks.isEmpty ? 'Wi-Fi 名称' : '其他或隐藏网络名称(可选)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: !_busy,
            key: const Key('device-wifi-password'),
            obscureText: !_showPassword,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _finish(),
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Wi-Fi 密码',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _showPassword ? '隐藏密码' : '显示密码',
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '点击连接后，将自动完成 Wi-Fi 配置并将设备添加到当前主机。',
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('confirm-device-setup'),
            onPressed: _busy ? null : _finish,
            child: Text(_error == null ? '连接' : '重新连接'),
          ),
        ],
      );

  /// What this screen is allowed to claim: the network and the Claim, and not
  /// a finished setup.
  ///
  /// It used to say 设备已设置完成 and pop. A Companion device at that moment is
  /// claimed and still unusable — its Owner has not said what it may present,
  /// so the Host gives it no channel and its own display reads "service is not
  /// ready". Telling someone the setup is finished and then showing them that
  /// is how a person concludes the product is broken. What is left is not this
  /// screen's to list, because whether anything is left depends on what the
  /// Host says about the device; the caller reads that and takes them there.
  Widget _complete() => Column(
        children: [
          const Icon(Icons.check_circle, size: 64, color: Neon.ok),
          const SizedBox(height: 12),
          const Text('设备已接入这台主机', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_completedDeviceId),
            child: const Text('继续'),
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
                    : _networkOutcomeUnknown
                        ? (_admissionActive ? '主机已确认设备接入' : '正在确认设备接入结果')
                        : '正在配置设备网络',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            _refused
                ? '这次接入已结束或失效。可以重新添加设备；已有设备的状态请在主机设备列表查看。'
                : _networkConfigured
                    ? '网络配置已保存，无需再次输入密码。接下来由设备向主机登记并完成接入。'
                    : _networkOutcomeUnknown
                        ? (_admissionActive
                            ? '设备接入已生效，但本次 Wi-Fi 配置结果仍未确认。请检查设备实际连接的网络，必要时重新设置。'
                            : '尚未确认 Wi-Fi 配置结果，正在向主机查询。请保持设备通电，让手机连回主机网络，无需重复配网。')
                        : '正在自动完成设置，请保持设备通电，无需重复操作。',
          ),
          if (!_refused) ...[
            const SizedBox(height: 16),
            Text('1. 连接设备${_networkConfigured ? ' ✓' : ''}'),
            Text(
                '2. 配置 Wi-Fi${_connectingNetwork == null ? '' : ' · $_connectingNetwork'}${_networkConfigured ? ' ✓' : ''}'),
            Text(
                '3. 接入主机${_admissionActive ? ' ✓' : (_networkConfigured || _networkOutcomeUnknown) ? ' · 进行中' : ''}'),
          ],
          const SizedBox(height: 16),
          if (!_refused &&
              _error != null &&
              (_networkConfigured || _networkOutcomeUnknown)) ...[
            FilledButton.icon(
              key: const Key('resume-device-admission'),
              onPressed: _busy ? null : _resumePersistedAdmission,
              icon: const Icon(Icons.refresh),
              label: const Text('从主机恢复状态'),
            ),
            const SizedBox(height: 8),
          ],
          if (!_busy)
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

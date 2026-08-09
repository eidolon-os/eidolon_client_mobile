import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../host_setup/host_product_session.dart';
import '../host_setup/local_api_client.dart';
import '../host_setup/pinned_http_client.dart';
import 'device_pairing_scanner.dart';
import 'device_setup_models.dart';
import 'device_pairing_vault.dart';

typedef DevicePairingClaim = Future<DeviceAdmissionProgress> Function({
  required String setupId,
  required String requestId,
  required DevicePairingPayload pairing,
});

class DevicePairingPage extends StatefulWidget {
  const DevicePairingPage({
    super.key,
    required this.hostId,
    required this.onClaim,
    this.scanner,
    this.vault,
  });

  final String hostId;
  final DevicePairingClaim onClaim;
  final DevicePairingScanner? scanner;
  final DevicePairingVault? vault;

  @override
  State<DevicePairingPage> createState() => _DevicePairingPageState();
}

class _DevicePairingPageState extends State<DevicePairingPage> {
  late final DevicePairingScanner _scanner;
  late final DevicePairingVault _vault;
  DevicePairingPayload? _pairing;
  DeviceAdmissionProgress? _progress;
  String? _setupId;
  String? _requestId;
  String? _error;
  var _busy = true;

  @override
  void initState() {
    super.initState();
    _scanner = widget.scanner ?? const PlatformDevicePairingScanner();
    _vault = widget.vault ?? const PlatformDevicePairingVault();
    _restorePendingClaim();
  }

  Future<void> _restorePendingClaim() async {
    try {
      final pending = await _vault.load(widget.hostId);
      if (!mounted || pending == null) return;
      setState(() {
        _pairing = pending.pairing;
        _setupId = pending.setupId;
        _requestId = pending.requestId;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _vaultMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pairing = await _scanner.scan();
      if (pairing == null || !mounted) return;
      final workflow = await _workflowIds(pairing.enrollmentId);
      if (!mounted) return;
      final pending = PendingDevicePairingClaim(
        setupId: workflow.$1,
        requestId: workflow.$2,
        pairing: pairing,
      );
      await _vault.save(hostId: widget.hostId, claim: pending);
      if (!mounted) return;
      _pairing = pending.pairing;
      _setupId = pending.setupId;
      _requestId = pending.requestId;
      await _claim();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim() async {
    final pairing = _pairing;
    final setupId = _setupId;
    final requestId = _requestId;
    if (pairing == null || setupId == null || requestId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final progress = await widget.onClaim(
        setupId: setupId,
        requestId: requestId,
        pairing: pairing,
      );
      if (!mounted) return;
      if (progress.state == DeviceAdmissionState.ready) {
        await _vault.clear(widget.hostId);
        if (!mounted) return;
        _pairing = null;
      }
      setState(() => _progress = progress);
    } on LocalApiRequestException catch (error) {
      var message = _message(error);
      if (error.statusCode == 403 || error.statusCode == 409) {
        try {
          await _discardPendingClaim();
        } catch (vaultError) {
          message = '${_message(error)} ${_vaultMessage(vaultError)}';
        }
      }
      if (mounted) setState(() => _error = message);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discardPendingClaim() async {
    await _vault.clear(widget.hostId);
    if (!mounted) return;
    _pairing = null;
    _progress = null;
    _setupId = null;
    _requestId = null;
  }

  Future<void> _scanAnotherDevice() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _discardPendingClaim();
    } catch (error) {
      if (mounted) setState(() => _error = _vaultMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<(String, String)> _workflowIds(String enrollmentId) async {
    final value = '${widget.hostId}\n$enrollmentId';
    final digest = await Sha256().hash(utf8.encode(value));
    final suffix = base64UrlEncode(digest.bytes).replaceAll('=', '');
    return ('device-pair-$suffix', 'device-pair-claim-$suffix');
  }

  String _message(Object error) => switch (error) {
        FormatException() => '没有识别到有效的 Eidolon 设备二维码。',
        PlatformException(code: 'SCAN_FAILED') =>
          '系统扫码暂时不可用，请确认 Google Play 服务已更新后重试。',
        PlatformException() => error.message ?? '系统扫码暂时不可用。',
        HostControllerAuthorizationException() => error.message,
        LocalApiRequestException(statusCode: 404) =>
          '当前主机版本尚未提供设备安全认领接口，请先更新主机。',
        LocalApiRequestException(statusCode: 409) =>
          '该设备的认领状态已变化，请让设备重新显示配对二维码。',
        LocalApiRequestException(statusCode: 403) =>
          '设备配对凭据无效或已使用，请让设备重新进入配对模式。',
        LocalApiRequestException() => error.message,
        PinnedHttpException() => '与主机的安全连接中断，请返回后重新连接主机。',
        _ => '设备暂时未能接入，请稍后重试。',
      };

  String _vaultMessage(Object error) => switch (error) {
        PlatformException() => '本机安全存储暂时不可用，无法安全保存设备配对凭据。',
        FormatException() => '本机保存的设备配对状态已损坏，请重新扫描设备二维码。',
        _ => '未能读取本机的设备配对状态，请稍后重试。',
      };

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final ready = progress?.state == DeviceAdmissionState.ready;
    return Scaffold(
      key: const Key('device-pairing-page'),
      appBar: AppBar(title: const Text('添加设备')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (ready)
                  _ReadyCard(
                    progress: progress!,
                    onDone: () => Navigator.of(context).pop(),
                  )
                else ...[
                  const _PairingIntroduction(),
                  if (_error case final error?) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          error,
                          key: const Key('device-pairing-error'),
                        ),
                      ),
                    ),
                  ],
                  if (progress != null) ...[
                    const SizedBox(height: 16),
                    _ProgressCard(progress: progress),
                  ],
                  const SizedBox(height: 24),
                  if (_busy)
                    const Center(child: CircularProgressIndicator())
                  else if (_pairing == null)
                    FilledButton.icon(
                      key: const Key('scan-device-pairing-code'),
                      onPressed: _scan,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('扫描设备二维码'),
                    )
                  else
                    FilledButton.icon(
                      key: const Key('continue-device-admission'),
                      onPressed: _claim,
                      icon: const Icon(Icons.refresh),
                      label: const Text('继续完成接入'),
                    ),
                  const SizedBox(height: 10),
                  if (_pairing != null && !_busy)
                    TextButton(
                      key: const Key('scan-another-device'),
                      onPressed: _scanAnotherDevice,
                      child: const Text('扫描另一台设备'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PairingIntroduction extends StatelessWidget {
  const _PairingIntroduction();

  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('安全认领设备', style: TextStyle(fontSize: 20)),
              SizedBox(height: 14),
              Text('1. 先让设备加入与主机相同的 Wi‑Fi。'),
              SizedBox(height: 8),
              Text('2. 等待设备屏幕显示 Eidolon 配对二维码。'),
              SizedBox(height: 8),
              Text('3. 扫描后，主机会确认 Owner、挂载设备并关联当前 Companion。'),
              SizedBox(height: 14),
              Text(
                '二维码只证明你正在接触这台设备；App 不会信任二维码声明的网络地址或 Owner。',
              ),
            ],
          ),
        ),
      );
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress});

  final DeviceAdmissionProgress progress;

  @override
  Widget build(BuildContext context) {
    final label = switch (progress.state) {
      DeviceAdmissionState.approved => 'Hub 已批准，正在挂载到 Owner',
      DeviceAdmissionState.binding => '正在关联 Companion',
      DeviceAdmissionState.failed => '接入未完成',
      DeviceAdmissionState.ready => '已接入',
      _ => '正在接入',
    };
    return Card(
      child: ListTile(
        leading: const Icon(Icons.sync),
        title: Text(label),
        subtitle: Text('已完成：${progress.completedStage}'),
      ),
    );
  }
}

class _ReadyCard extends StatelessWidget {
  const _ReadyCard({required this.progress, required this.onDone});

  final DeviceAdmissionProgress progress;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('device-pairing-ready'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.verified,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                '设备已接入',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              const Text(
                '主机已经完成 Hub 批准、Owner 挂载和 Companion 关联。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('finish-device-pairing'),
                onPressed: onDone,
                child: const Text('查看设备'),
              ),
            ],
          ),
        ),
      );
}

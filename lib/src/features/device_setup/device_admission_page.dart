import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';

import '../host_setup/host_product_session.dart';
import '../host_setup/local_api_client.dart';
import '../host_setup/pinned_http_client.dart';
import 'device_setup_models.dart';

typedef PendingDeviceEnrollmentLoader = Future<List<PendingDeviceEnrollment>>
    Function();
typedef DeviceEnrollmentApproval = Future<DeviceAdmissionProgress> Function({
  required String requestId,
  required String deviceId,
});

/// Screen-independent human approval for Hub enrollments.
///
/// Devices enroll themselves and remain unclaimed. This page only lets an
/// authenticated Host Controller choose a pending enrollment and explicitly
/// bind it to the Host Owner. No device secret or Hub credential reaches App.
class DeviceAdmissionPage extends StatefulWidget {
  const DeviceAdmissionPage({
    super.key,
    required this.hostId,
    required this.loadPending,
    required this.onApprove,
  });

  final String hostId;
  final PendingDeviceEnrollmentLoader loadPending;
  final DeviceEnrollmentApproval onApprove;

  @override
  State<DeviceAdmissionPage> createState() => _DeviceAdmissionPageState();
}

class _DeviceAdmissionPageState extends State<DeviceAdmissionPage> {
  List<PendingDeviceEnrollment> _pending = const [];
  PendingDeviceEnrollment? _selected;
  DeviceAdmissionProgress? _progress;
  String? _error;
  var _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_busy) setState(() => _busy = true);
    setState(() => _error = null);
    try {
      final pending = await widget.loadPending();
      if (!mounted) return;
      setState(() {
        _pending = pending;
        if (_selected != null &&
            !pending.any((item) => item.deviceId == _selected!.deviceId)) {
          _selected = null;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final selected = _selected;
    if (_busy || selected == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final progress = await widget.onApprove(
        requestId: await _requestId(selected),
        deviceId: selected.deviceId,
      );
      if (!mounted) return;
      setState(() => _progress = progress);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Name this approval, not this device.
  ///
  /// The Host reads a repeated id as the same act again, which is what makes a
  /// second tap harmless. But an id derived from the Host and the device alone is
  /// the same forever, so approving a device that was removed and came back
  /// looked like a replay of the approval it was given months ago — and was
  /// refused, with advice to remove the device that had just been re-added.
  ///
  /// The enrolment's own moment is what separates one approval from the next: a
  /// device that enrolled again brings a new one, while every retry of this tap
  /// brings the same.
  Future<String> _requestId(PendingDeviceEnrollment enrollment) async {
    final digest = await Sha256().hash(
      utf8.encode(
        '${widget.hostId}\n${enrollment.deviceId}\n'
        '${enrollment.enrolledAt.toUtc().toIso8601String()}',
      ),
    );
    final suffix = base64UrlEncode(digest.bytes).replaceAll('=', '');
    return 'device-approval-$suffix';
  }

  /// Prefer whatever the Host said over this screen's guess at it.
  ///
  /// Guessing from the status code alone is how a refusal the Host could
  /// explain became "刷新列表" — advice that never helps when the refusal is not
  /// about the list. When the Host names a reason, that reason is the message.
  String _message(Object error) => switch (error) {
        HostControllerAuthorizationException() => error.message,
        LocalApiRequestException(reason: final reason?) => reason,
        LocalApiRequestException(statusCode: 404) => '当前主机尚未提供设备认领接口，请先更新主机。',
        LocalApiRequestException(statusCode: 409) =>
          '设备状态已变化。请刷新列表，确认设备尚未被其他 Owner 认领。',
        LocalApiRequestException(statusCode: 403) =>
          '当前 Controller 无权认领设备，请重新连接主机。',
        LocalApiRequestException() => error.message,
        PinnedHttpException() => '与主机的安全连接中断，请返回后重新连接主机。',
        FormatException() => '主机返回的待认领设备信息无效。',
        _ => '设备暂时未能接入，请稍后重试。',
      };

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final ready = progress?.outcome == ActOutcome.done;
    return Scaffold(
      key: const Key('device-admission-page'),
      appBar: AppBar(
        title: const Text('认领设备'),
        actions: [
          IconButton(
            key: const Key('refresh-pending-devices'),
            onPressed: _busy || ready ? null : _load,
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
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
                  const _AdmissionIntroduction(),
                  if (_error case final error?) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(error,
                            key: const Key('device-admission-error')),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (_busy)
                    const Center(child: CircularProgressIndicator())
                  else if (_pending.isEmpty)
                    const _EmptyPendingCard()
                  else ...[
                    Text(
                      '待认领设备',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    ..._pending.map(
                      (device) => Card(
                        child: ListTile(
                          key: Key('pending-device-${device.deviceId}'),
                          selected: _selected?.deviceId == device.deviceId,
                          leading: Icon(
                            _selected?.deviceId == device.deviceId
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                          ),
                          onTap: () => setState(() {
                            _selected = device;
                            _error = null;
                          }),
                          title: Text(
                            device.displayName.isEmpty
                                ? device.deviceKind
                                : device.displayName,
                          ),
                          subtitle: Text(
                            '${device.deviceKind}\n设备 ID：${device.deviceId}',
                          ),
                          isThreeLine: true,
                        ),
                      ),
                    ),
                    if (_selected case final selected?) ...[
                      const SizedBox(height: 16),
                      _ConfirmationCard(device: selected),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        key: const Key('confirm-device-admission'),
                        onPressed: _approve,
                        icon: const Icon(Icons.link),
                        label: const Text('确认认领并绑定'),
                      ),
                    ],
                  ],
                  if (progress != null && !ready) ...[
                    const SizedBox(height: 16),
                    _ProgressCard(progress: progress),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AdmissionIntroduction extends StatelessWidget {
  const _AdmissionIntroduction();

  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('把设备加入你的 Eidolon', style: TextStyle(fontSize: 20)),
              SizedBox(height: 14),
              Text('1. 先让设备完成配网并连接到这台主机。'),
              SizedBox(height: 8),
              Text('2. 在下方选择刚刚设置的设备。'),
              SizedBox(height: 8),
              Text('3. 由你确认后，主机才会认领、挂载并绑定设备。'),
              SizedBox(height: 14),
              Text('设备在确认前始终处于未认领状态；App 不会自动认领附近设备。'),
            ],
          ),
        ),
      );
}

class _EmptyPendingCard extends StatelessWidget {
  const _EmptyPendingCard();

  @override
  Widget build(BuildContext context) => const Card(
        key: Key('no-pending-devices'),
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('暂时没有待认领设备'),
              SizedBox(height: 8),
              Text('请确认设备已完成配网并保持开机。设备连接 Hub 后可能需要几十秒才会出现在这里。'),
            ],
          ),
        ),
      );
}

class _ConfirmationCard extends StatelessWidget {
  const _ConfirmationCard({required this.device});

  final PendingDeviceEnrollment device;

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '请确认这是你刚刚设置的设备：${device.displayName}\n${device.deviceId}',
            key: const Key('device-admission-confirmation'),
          ),
        ),
      );
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress});

  final DeviceAdmissionProgress progress;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: const Icon(Icons.sync),
          // One sentence about what to do, and the internal hand-off it
          // stopped at kept as a technical detail beneath it. This card used
          // to name the hand-off in its title, which told a person the shape
          // of our authority sequence instead of telling them anything.
          title: Text(switch (progress.outcome) {
            ActOutcome.done => '已接入',
            ActOutcome.unfinished => '还没完成，可以再试一次',
            ActOutcome.refused => '主机拒绝了这次接入',
          }),
          subtitle: Text('停在：${progress.stoppedAfter}'),
        ),
      );
}

class _ReadyCard extends StatelessWidget {
  const _ReadyCard({required this.progress, required this.onDone});

  final DeviceAdmissionProgress progress;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('device-admission-ready'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.check_circle, size: 52),
              const SizedBox(height: 16),
              const Text(
                '设备已认领并绑定',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22),
              ),
              const SizedBox(height: 10),
              SelectableText(
                progress.deviceId,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: onDone, child: const Text('完成')),
            ],
          ),
        ),
      );
}

import 'dart:async';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../device_management/mounted_device_models.dart';

/// `status`, `open` or `close` for one device; [conversationId] scopes a close.
typedef DeviceSessionCommand = Future<DeviceSessionStatus> Function(
    String action, String deviceId, String? conversationId);

/// Mirrors the conversation the device itself holds, whoever started it.
///
/// Nothing is kept here: the Host says what the device is doing, and this page
/// asks the device to start or end. Leaving the page changes nothing.
class DeviceSessionControls extends StatefulWidget {
  const DeviceSessionControls(
      {super.key,
      required this.device,
      required this.command,
      required this.online,
      this.refreshPresence});
  final MountedDevice device;
  final DeviceSessionCommand command;
  final bool Function() online;
  final Future<void> Function()? refreshPresence;
  @override
  State<DeviceSessionControls> createState() => _DeviceSessionControlsState();
}

class _DeviceSessionControlsState extends State<DeviceSessionControls> {
  DeviceSessionStatus? _status;
  String? _error;
  bool _asking = false;
  Timer? _timer;
  Timer? _soon;

  @override
  void initState() {
    super.initState();
    unawaited(_request('status'));
    _timer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        await widget.refreshPresence?.call();
      } catch (_) {}
      await _request('status');
    });
  }

  Future<void> _request(String action) async {
    if (_asking || !mounted) return;
    final asked = action != 'status';
    // A read never disables the buttons; a request holds them until answered.
    if (asked) setState(() => _asking = true);
    _soon?.cancel();
    try {
      final result = await widget.command(action, widget.device.deviceId,
          action == 'close' ? _status?.conversationId : null);
      if (!mounted) return;
      setState(() {
        _status = result;
        _error = (result.error?.isEmpty ?? true) ? null : '设备没有接受这次请求。';
      });
      if (result.state == 'starting') {
        _soon = Timer(const Duration(seconds: 1), () => _request('status'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = asked ? '请求没有完成，状态会自动更新。' : '暂时读不到对话状态。');
      }
    } finally {
      if (asked && mounted) setState(() => _asking = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _soon?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready =
        widget.device.state == MountedDeviceState.ready && widget.online();
    final state = _status?.state;
    final label = switch (state) {
      null => '正在读取对话状态…',
      'starting' => '正在进入对话，请稍候…',
      'in_conversation' => '对话进行中',
      'closing' => '正在结束，等待设备释放媒体…',
      'occupied' => '设备正被跨设备对话或团队对话占用',
      _ => ready ? '在线待机' : '设备离线或尚未配置完成',
    };
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  key: const Key('device-session-state'),
                  style: Theme.of(context).textTheme.titleLarge),
              if (_error != null) Text(_error!),
              const SizedBox(height: 8),
              if (state == 'standby')
                FilledButton(
                    key: const Key('device-session-start'),
                    onPressed:
                        !_asking && ready ? () => _request('open') : null,
                    child: const Text('开始对话'))
              else if (state == 'in_conversation' || state == 'closing')
                FilledButton(
                    key: const Key('device-session-end'),
                    onPressed: _asking ? null : () => _request('close'),
                    child: const Text('结束对话')),
              const Text('离开此页面不会结束设备对话。'),
            ])));
  }
}

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../../platform/app_preferences.dart';
import '../device_management/mounted_device_models.dart';

typedef DeviceSessionCommand = Future<DeviceConversationStatus> Function(
    String action, String sessionId, String? deviceId, String? companionId);

/// Persists only correlation, never authority or optimistic conversation state.
/// Leaving this page does not end a device-owned conversation.
class DeviceSessionControls extends StatefulWidget {
  const DeviceSessionControls(
      {super.key,
      required this.device,
      required this.command,
      required this.storageKey,
      required this.online,
      this.preferences,
      this.refreshPresence});
  final MountedDevice device;
  final DeviceSessionCommand command;
  final String storageKey;
  final bool Function() online;
  final AppPreferences? preferences;
  final Future<void> Function()? refreshPresence;
  @override
  State<DeviceSessionControls> createState() => _DeviceSessionControlsState();
}

class _DeviceSessionControlsState extends State<DeviceSessionControls> {
  late final AppPreferences _preferences =
      widget.preferences ?? PlatformAppPreferences();
  String? _id;
  String _state = 'loading';
  String? _error;
  bool _busy = false;
  Timer? _timer;
  Timer? _presenceTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
    _presenceTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        await widget.refreshPresence?.call();
      } catch (_) {}
      if (mounted) setState(() {});
    });
  }

  Future<void> _restore() async {
    try {
      final saved = await _preferences.readString(widget.storageKey);
      if (!mounted) return;
      _id = saved == null || saved.isEmpty ? null : saved;
      if (_id != null) {
        await _request('status');
      } else {
        setState(() => _state = 'closed');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _state = 'unknown';
          _error = '无法读取对话记录，请重新打开页面。';
        });
      }
    }
  }

  void _poll() {
    _timer?.cancel();
    if (mounted && _id != null) {
      _timer = Timer(const Duration(seconds: 2), () => _request('status'));
    }
  }

  Future<void> _request(String action) async {
    if (_busy || !mounted) return;
    if (action != 'open' && _id == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _timer?.cancel();
    try {
      if (action == 'open') {
        _id =
            'device-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
        // Persist before delivery: interrupted HTTP is not evidence of refusal.
        await _preferences.writeString(widget.storageKey, _id!);
      }
      final result = await widget.command(
          action,
          _id!,
          action == 'open' ? widget.device.deviceId : null,
          action == 'open' ? widget.device.attachedCompanionId : null);
      if (result.sessionId != _id) throw StateError('session mismatch');
      if (result.state == 'closed') {
        await _preferences.writeString(widget.storageKey, '');
        _id = null;
      }
      if (mounted) {
        setState(() {
          _state = result.state;
          _error = (result.error?.isEmpty ?? true)
              ? null
              : '对话未正常完成：${result.error}';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _state = 'unknown';
          _error = '尚未确认设备状态，请刷新或结束本次对话；不会自动重新开始。';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _poll();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _presenceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready =
        widget.device.state == MountedDeviceState.ready && widget.online();
    final label = switch (_state) {
      'loading' => '正在读取对话状态…',
      'preparing' => '正在进入对话，请稍候…',
      'ready' => '已进入对话，可以说话',
      'closing' => '正在结束，等待设备释放媒体…',
      'closed' => ready ? '在线待机' : '设备离线或尚未配置完成',
      'failed' => '对话失败，需确认结束',
      _ => '对话状态尚未确认',
    };
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, key: const Key('device-session-state'),
              style: Theme.of(context).textTheme.titleLarge),
              if (_error != null) Text(_error!),
              const SizedBox(height: 8),
              if (_id == null)
                FilledButton(
                    key: const Key('device-session-start'),
                    onPressed: !_busy && _state == 'closed' && ready
                        ? () => _request('open')
                        : null,
                    child: const Text('开始对话'))
              else
                Wrap(spacing: 8, children: [
                  FilledButton(
                      key: const Key('device-session-end'),
                      onPressed: _busy ? null : () => _request('close'),
                      child: const Text('结束对话')),
                  TextButton(
                      onPressed: _busy ? null : () => _request('status'),
                      child: const Text('刷新状态')),
                ]),
              const Text('离开此页面不会结束设备对话。'),
            ])));
  }
}

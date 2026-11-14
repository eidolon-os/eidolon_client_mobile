import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';

/// One setting a device may report and its Owner may change.
///
/// Mirrors the Host's installed contracts (`eidolon_sdk.biz.capabilities.
/// device_settings`): the value is an observable property the device reports,
/// and changing it is that property's `*.set` capability, whose result is the
/// value the device applied. A setting appears here only when the device
/// reported its value, so a device that cannot do it shows nothing rather
/// than a control at zero.
@immutable
class DeviceSetting {
  const DeviceSetting({
    required this.property,
    required this.capability,
    required this.argument,
    required this.label,
    required this.icon,
  });

  final String property;
  final String capability;
  final String argument;
  final String label;
  final IconData icon;
}

const deviceSettings = <DeviceSetting>[
  DeviceSetting(
    property: 'audio.volume',
    capability: 'audio.volume.set',
    argument: 'volume',
    label: '音量',
    icon: Icons.volume_up_outlined,
  ),
  DeviceSetting(
    property: 'display.brightness',
    capability: 'display.brightness.set',
    argument: 'brightness',
    label: '屏幕亮度',
    icon: Icons.brightness_6_outlined,
  ),
];

typedef DevicePropertiesReader = Future<DevicePropertiesView> Function(
    String deviceId);

typedef DeviceSettingWriter = Future<DeviceCapabilityExecutionView> Function({
  required String deviceId,
  required String capability,
  required Map<String, Object?> arguments,
  required String requestId,
});

/// A device's settings as sliders, following what the device reports.
///
/// Reads while it is on screen, because a setting also changes without this
/// page: by voice, or by the device's own buttons. A slider the person is
/// dragging, or one whose change is still on its way, is never overwritten by
/// such a read. Only the position the drag settled on is sent, under one
/// request id, and the slider then shows what the device applied.
class DeviceSettingsSection extends StatefulWidget {
  const DeviceSettingsSection({
    super.key,
    required this.deviceId,
    required this.read,
    required this.write,
    this.pollInterval = const Duration(seconds: 2),
  });

  final String deviceId;
  final DevicePropertiesReader read;
  final DeviceSettingWriter write;
  final Duration pollInterval;

  @override
  State<DeviceSettingsSection> createState() => _DeviceSettingsSectionState();
}

class _DeviceSettingsSectionState extends State<DeviceSettingsSection>
    with WidgetsBindingObserver {
  final _random = Random.secure();
  final Map<String, int> _reported = {};
  final Map<String, double> _dragging = {};
  final Set<String> _sending = {};
  Timer? _poll;
  String? _notice;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Nobody is looking at a backgrounded page, so nothing should keep asking
    // the Host on its behalf.
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _startPolling();
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(widget.pollInterval, (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_reading) return;
    _reading = true;
    try {
      final view = await widget.read(widget.deviceId);
      if (!mounted) return;
      final values = view.values ?? const <String, Object?>{};
      setState(() {
        for (final setting in deviceSettings) {
          final value = values[setting.property];
          if (_dragging.containsKey(setting.property) ||
              _sending.contains(setting.property)) {
            continue;
          }
          if (value is num) {
            _reported[setting.property] = value.round();
          } else {
            _reported.remove(setting.property);
          }
        }
      });
    } catch (_) {
      // A page that cannot reach the Host keeps what it last showed; the next
      // read tries again. Saying so on every tick would be noise.
    } finally {
      _reading = false;
    }
  }

  Future<void> _send(DeviceSetting setting, int value) async {
    setState(() {
      _sending.add(setting.property);
      _notice = null;
    });
    try {
      final execution = await widget.write(
        deviceId: widget.deviceId,
        capability: setting.capability,
        arguments: {setting.argument: value},
        requestId: _requestId(setting.capability),
      );
      if (!mounted) return;
      final applied = execution.result?[setting.argument];
      setState(() {
        if (execution.state == 'completed' && applied is num) {
          _reported[setting.property] = applied.round();
        } else {
          _notice = '${setting.label}没有调成：${_why(execution)}';
        }
      });
    } catch (error) {
      if (mounted) setState(() => _notice = '${setting.label}没有调成：$error');
    } finally {
      if (mounted) {
        setState(() {
          _sending.remove(setting.property);
          _dragging.remove(setting.property);
        });
      }
    }
  }

  static String _why(DeviceCapabilityExecutionView execution) {
    final error = execution.error;
    if (error != null && error.isNotEmpty) return '设备回答 $error';
    return '设备回答 ${execution.state}';
  }

  String _requestId(String purpose) {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final hex =
        bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '$purpose-$hex';
  }

  @override
  Widget build(BuildContext context) {
    final shown =
        deviceSettings.where((s) => _reported.containsKey(s.property)).toList();
    if (shown.isEmpty && _notice == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      key: const Key('device-settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('设备设置', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final setting in shown) _slider(setting),
        if (_notice case final notice?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              notice,
              key: const Key('device-settings-notice'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _slider(DeviceSetting setting) {
    final value =
        _dragging[setting.property] ?? _reported[setting.property]!.toDouble();
    return Row(
      children: [
        Icon(setting.icon),
        const SizedBox(width: 8),
        SizedBox(width: 72, child: Text(setting.label)),
        Expanded(
          child: Slider(
            key: Key('device-setting-${setting.property}'),
            value: value.clamp(0, 100).toDouble(),
            min: 0,
            max: 100,
            divisions: 100,
            label: '${value.round()}',
            onChanged: _sending.contains(setting.property)
                ? null
                : (next) => setState(() => _dragging[setting.property] = next),
            onChangeEnd: _sending.contains(setting.property)
                ? null
                : (next) => _send(setting, next.round()),
          ),
        ),
        SizedBox(width: 36, child: Text('${value.round()}')),
      ],
    );
  }
}

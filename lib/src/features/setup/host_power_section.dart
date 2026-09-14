import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../host_setup/host_product_controller.dart';
import '../host_setup/host_product_session.dart';

/// Power belongs to the selected Host; connection and submission state outlive
/// this settings route so reopening it cannot send the same intent twice.
class HostPowerSection extends StatefulWidget {
  const HostPowerSection({super.key, required this.controller});

  final HostProductController controller;

  @override
  State<HostPowerSection> createState() => _HostPowerSectionState();
}

class _HostPowerSectionState extends State<HostPowerSection> {
  HostPowerStatusWire? _capability;
  String? _error;
  bool _reading = false;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_reading ||
        widget.controller.connection == null ||
        widget.controller.powerOffOutcome != null) {
      return;
    }
    setState(() {
      _reading = true;
      _error = null;
    });
    try {
      final capability = await widget.controller.hostPower();
      if (mounted) setState(() => _capability = capability);
    } catch (error) {
      if (mounted) {
        setState(() {
          _capability = null;
          _error = switch (error) {
            ManagementRequestException(statusCode: 404) =>
              '这台主机尚未提供关机接口，请更新主机软件',
            ManagementRequestException(statusCode: 401 || 403) =>
              '认证已失效或没有权限，请重新连接主机',
            _ => '暂时无法读取关机能力，请重试',
          };
        });
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _confirm() async {
    final controller = widget.controller;
    if (_confirming ||
        controller.powerOffBusy ||
        controller.connection == null ||
        _capability?.canPowerOff != true) {
      return;
    }
    setState(() => _confirming = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('confirm-power-off-host'),
        title: Text('关闭「${controller.host.readableName}」？'),
        content: const Text('将停止这台主机上的所有服务并断开连接。重新使用前需要开机。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-power-off-host-action'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('关闭主机'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _confirming = false);
    if (confirmed != true) return;
    setState(() => _error = null);
    try {
      await controller.powerOff();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _capability = null;
        _error = switch (error) {
          ManagementRequestException(statusCode: 401) => '认证已失效，请重新连接后再操作',
          ManagementRequestException(statusCode: 403) => '关机被拒绝，请检查主机的关机权限',
          ManagementRequestException(statusCode: 404) => '这台主机尚未提供关机接口，请更新主机软件',
          ManagementRequestException(statusCode: 409) => '主机已接受另一条关机请求，请检查主机状态',
          HostControllerAuthorizationException() => '请重新连接主机后再操作',
          _ => '主机拒绝了关机请求，请检查主机状态',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final online = controller.connection != null;
          final busy = controller.powerOffBusy;
          final outcome = controller.powerOffOutcome;
          final enabled = online &&
              !controller.connecting &&
              !busy &&
              !_confirming &&
              !_reading &&
              outcome == null &&
              _capability?.canPowerOff == true;
          final subtitle = busy
              ? '正在请求关机…'
              : outcome ??
                  (!online
                      ? '连接主机后可用'
                      : _reading
                          ? '正在读取关机能力…'
                          : _error ??
                              _capability?.unavailableReason ??
                              (_capability == null
                                  ? '读取关机能力后可用'
                                  : '停止所有服务并断开连接'));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('电源', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ListTile(
                key: const Key('power-off-host'),
                leading: Icon(Icons.power_settings_new,
                    color:
                        enabled ? Theme.of(context).colorScheme.error : null),
                title: const Text('关闭主机'),
                subtitle: Text(subtitle),
                enabled: enabled,
                onTap: enabled ? _confirm : null,
                trailing: online &&
                        !busy &&
                        !_reading &&
                        outcome == null &&
                        (_error != null || _capability == null)
                    ? IconButton(
                        key: const Key('reload-host-power'),
                        tooltip: '重新读取关机能力',
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                      )
                    : null,
              ),
            ],
          );
        },
      );
}

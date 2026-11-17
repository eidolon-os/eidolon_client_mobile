import 'dart:async';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../device_management/mounted_device_models.dart';
import 'companion_tools_page.dart';
import 'tool_policies.dart';
import 'tools_overview_page.dart';
import 'tools_wording.dart';

/// Asks the device page holding a [DeviceToolsSection] to open its choice of
/// what the device may hear and present.
///
/// A notification rather than a callback: the section is built by whoever
/// opens the device page, and only that page owns the choice and the setup
/// journal around it.
class DeviceOutputsRequested extends Notification {
  const DeviceOutputsRequested();
}

/// 「{伙伴} 在这台设备上能用」 on a device's page (§5.4).
///
/// Reads its own data, like the device's settings beside it. What it says is
/// the Host's: the device facts are what the device's channel actually offers
/// a conversation, translated into reasons, never worked out here.
class DeviceToolsSection extends StatefulWidget {
  const DeviceToolsSection({
    super.key,
    required this.deviceId,
    required this.tools,
    this.companionName = '',
    this.devices = const [],
  });

  final String deviceId;
  final ToolPolicies tools;

  /// The Eidolon this device answers as, by name.
  final String companionName;

  /// Every device the Owner has, handed on to the pages a reason opens.
  final List<MountedDevice> devices;

  @override
  State<DeviceToolsSection> createState() => _DeviceToolsSectionState();
}

class _DeviceToolsSectionState extends State<DeviceToolsSection> {
  DeviceToolsView? _view;
  String? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    setState(() => _failure = null);
    try {
      final view = await widget.tools.device(widget.deviceId);
      if (mounted) setState(() => _view = view);
    } catch (error) {
      if (mounted) setState(() => _failure = toolFailure(error));
    }
  }

  String get _name =>
      widget.companionName.isNotEmpty ? widget.companionName : '伙伴';

  Future<void> _act(ToolReasonAction action, DeviceToolsView view) async {
    switch (action) {
      case ToolReasonAction.outputs:
        const DeviceOutputsRequested().dispatch(context);
        return;
      case ToolReasonAction.companion:
        final companionId = view.companionId;
        if (companionId == null) return;
        await Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) => CompanionToolsPage(
                companionId: companionId,
                companionName: _name,
                tools: widget.tools,
                devices: widget.devices)));
      case ToolReasonAction.overview:
        await Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) => ToolsOverviewPage(
                tools: widget.tools, devices: widget.devices)));
    }
    // What was changed there is what this section is about.
    if (mounted) await _read();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final view = _view;
    final answering = view?.companionId != null;
    return Column(
      key: const Key('device-tools'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(answering ? '$_name 在这台设备上能用' : '在这台设备上能用的工具',
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_failure case final failure?)
          Card(
            child: ListTile(
              key: const Key('device-tools-failure'),
              title: Text(failure),
              trailing: TextButton(onPressed: _read, child: const Text('重试')),
            ),
          )
        else if (view == null)
          const LinearProgressIndicator()
        else if (!answering)
          const Card(
            child: ListTile(
              key: Key('device-tools-no-companion'),
              title: Text('还没有伙伴'),
              subtitle: Text('指定由谁应答之后，这里会列出它在这台设备上能用的工具。'),
            ),
          )
        else
          Card(child: Column(children: _rows(view))),
      ],
    );
  }

  List<Widget> _rows(DeviceToolsView view) {
    final usable = view.tools.where((row) => row.available).toList();
    final not = view.tools.where((row) => !row.available).toList();
    return [
      if (usable.isEmpty)
        const ListTile(title: Text('现在没有能用的工具'))
      else
        for (final row in usable)
          ListTile(
            key: Key('device-tool-${row.key}'),
            leading: const Icon(Icons.check_circle_outline),
            title: Text(row.label),
            subtitle: row.requires.hostFeature == null
                ? null
                : Text(toolHostRequirementText(row.requires.hostFeature!)),
          ),
      if (not.isNotEmpty)
        ExpansionTile(
          key: const Key('device-tools-unavailable'),
          title: Text('用不了的（${not.length}）'),
          children: [for (final row in not) _unavailable(view, row)],
        ),
    ];
  }

  Widget _unavailable(DeviceToolsView view, DeviceToolRowView row) {
    final reason = row.reasons.firstOrNull ?? '';
    final action = toolReasonAction(reason);
    return ListTile(
      key: Key('device-tool-${row.key}'),
      leading: const Icon(Icons.remove_circle_outline),
      title: Text(row.label),
      subtitle: Text(toolReasonText(reason),
          key: Key('device-tool-reason-${row.key}')),
      trailing: action == null
          ? null
          : TextButton(
              key: Key('device-tool-action-${row.key}'),
              onPressed: () => _act(action, view),
              child: Text(toolReasonActionLabel(action)),
            ),
    );
  }
}

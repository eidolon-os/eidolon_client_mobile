import 'dart:async';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../device_management/mounted_device_models.dart';
import 'companion_tools_page.dart';
import 'tool_policies.dart';
import 'tool_widgets.dart';
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

/// 「{伙伴} 在这台设备上能用」 on a device's page (§5.4), and, where the Host
/// offers it, which tools this device never offers (§6.1).
///
/// Reads its own data, like the device's settings beside it. What it says is
/// the Host's: the device facts are what the device's channel actually offers
/// a conversation, translated into reasons, never worked out here. The
/// restriction only narrows, so a tool kept off by a switch stays off whatever
/// is chosen here.
class DeviceToolsSection extends StatefulWidget {
  const DeviceToolsSection({
    super.key,
    required this.deviceId,
    required this.tools,
    this.companionName = '',
    this.devices = const [],
    this.canRestrict = false,
  });

  final String deviceId;
  final ToolPolicies tools;

  /// The Eidolon this device answers as, by name.
  final String companionName;

  /// Every device the Owner has, handed on to the pages a reason opens.
  final List<MountedDevice> devices;

  /// Whether each tool carries 「在这台设备上禁止」; false keeps the section
  /// read-only, on a Host that does not offer restrictions.
  final bool canRestrict;

  @override
  State<DeviceToolsSection> createState() => _DeviceToolsSectionState();
}

class _DeviceToolsSectionState extends State<DeviceToolsSection> {
  DeviceToolsView? _view;
  String? _failure;
  bool _saving = false;

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

  /// Sends the whole new list, against the revision on screen. A device that
  /// was never restricted is at revision 0.
  Future<void> _restrict(DeviceToolsView view, String key, bool deny) async {
    if (_saving) return;
    final current = view.restriction;
    final denied = {...?current?.denied};
    if (deny) {
      denied.add(key);
    } else {
      denied.remove(key);
    }
    setState(() => _saving = true);
    try {
      final answer = await widget.tools.restrict(
          widget.deviceId,
          DeviceToolRestrictionRequest(
              expectedRevision: current?.revision ?? 0,
              denied: denied.toList()..sort()));
      if (!mounted) return;
      setState(() => _view = DeviceToolsView(
          deviceId: view.deviceId,
          companionId: view.companionId,
          tools: view.tools,
          restriction: answer));
      sayToolNotice(context, toolRestrictionNotice);
      // The reasons follow the restriction; only the Host can say how.
      await _read();
    } catch (error) {
      if (!mounted) return;
      final refusal = error is ManagementRequestException ? error : null;
      if (refusal?.code == 'output_policy_required') {
        // Nothing reaches this device until its outputs are decided, a
        // restriction included: that decision comes first.
        sayToolNotice(context, toolRestrictionNeedsOutputs);
        const DeviceOutputsRequested().dispatch(context);
      } else if (refusal?.someoneElseChangedIt ?? false) {
        await _read();
        if (mounted) sayToolNotice(context, deviceRestrictionChangedElsewhere);
      } else {
        sayToolNotice(context, toolFailure(error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
      if (_saving) const LinearProgressIndicator(),
      if (usable.isEmpty)
        const ListTile(title: Text('现在没有能用的工具'))
      else
        for (final row in usable) _row(view, row),
      if (not.isNotEmpty)
        ExpansionTile(
          key: const Key('device-tools-unavailable'),
          title: Text('用不了的（${not.length}）'),
          children: [for (final row in not) _row(view, row)],
        ),
    ];
  }

  /// One tool: why it cannot be used here, if it cannot, with the way to the
  /// one place that changes that; and this device's own switch for it.
  Widget _row(DeviceToolsView view, DeviceToolRowView row) {
    final reason = row.reasons.firstOrNull;
    final action = reason == null ? null : toolReasonAction(reason);
    final hostFeature = row.requires.hostFeature;
    final lines = <Widget>[
      if (reason != null)
        Text(toolReasonText(reason), key: Key('device-tool-reason-${row.key}'))
      else if (hostFeature != null)
        Text(toolHostRequirementText(hostFeature)),
      if (action != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: Key('device-tool-action-${row.key}'),
            style: TextButton.styleFrom(
                padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            onPressed: () => _act(action, view),
            child: Text(toolReasonActionLabel(action)),
          ),
        ),
    ];
    // Nothing reserved can be offered here in the first place.
    final restrictable =
        widget.canRestrict && !row.reasons.contains('reserved');
    return ListTile(
      key: Key('device-tool-${row.key}'),
      leading: Icon(row.available
          ? Icons.check_circle_outline
          : Icons.remove_circle_outline),
      title: Text(row.label),
      subtitle: lines.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: lines),
      trailing: restrictable ? _restriction(view, row) : null,
    );
  }

  Widget _restriction(DeviceToolsView view, DeviceToolRowView row) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        Text(toolRestrictionLabel,
            style: Theme.of(context).textTheme.labelSmall),
        Switch(
          key: Key('device-tool-restrict-${row.key}'),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          value: view.restriction?.denied?.contains(row.key) ?? false,
          onChanged: _saving ? null : (deny) => _restrict(view, row.key, deny),
        ),
      ]);
}

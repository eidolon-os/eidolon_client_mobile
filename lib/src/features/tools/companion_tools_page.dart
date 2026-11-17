import 'dart:async';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../device_management/mounted_device_models.dart';
import 'tool_policies.dart';
import 'tool_widgets.dart';
import 'tools_overview_page.dart';
import 'tools_wording.dart';

/// 「它能做的事」: one Eidolon's own switches, inside what the Owner allows
/// (§5.3).
///
/// A tool the Owner turned off keeps this Eidolon's own choice, shown greyed,
/// so turning it back on in the overview restores exactly what was here. The
/// same holds under 「允许操控身体」 for the body groups.
class CompanionToolsPage extends StatefulWidget {
  const CompanionToolsPage({
    super.key,
    required this.companionId,
    required this.companionName,
    required this.tools,
    this.devices = const [],
  });

  final String companionId;
  final String companionName;
  final ToolPolicies tools;

  /// Every device the Owner has. Which are this Eidolon's is decided here,
  /// the way its own page decides it.
  final List<MountedDevice> devices;

  @override
  State<CompanionToolsPage> createState() => _CompanionToolsPageState();
}

class _CompanionToolsPageState extends State<CompanionToolsPage> {
  CompanionToolsView? _view;
  String? _failure;
  bool _loading = true, _saving = false;

  /// What each of its devices offers; a device that could not be read is
  /// absent, and the count under a tool is then left unsaid.
  final _onDevices = <String, DeviceToolsView>{};
  bool _devicesRead = false;

  List<MountedDevice> get _itsDevices => widget.devices
      .where((device) => device.attachedCompanionId == widget.companionId)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_readDevices());
  }

  Future<void> _load() async {
    setState(() {
      _loading = _view == null;
      _failure = null;
    });
    try {
      final view = await widget.tools.companion(widget.companionId);
      if (mounted) setState(() => _view = view);
    } catch (error) {
      if (mounted) setState(() => _failure = toolFailure(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _readDevices() async {
    Future<void> read(String deviceId) async {
      try {
        _onDevices[deviceId] = await widget.tools.device(deviceId);
      } catch (_) {
        // Left unread: the line under a tool then stops at 「需要设备支持」.
      }
    }

    await Future.wait(
        [for (final device in _itsDevices) read(device.deviceId)]);
    if (mounted) setState(() => _devicesRead = true);
  }

  Future<void> _write(
      ToolPolicyChange Function(int revision) change, String notice) async {
    final view = _view;
    if (view == null || _saving) return;
    setState(() => _saving = true);
    try {
      final answer = await widget.tools
          .changeCompanion(widget.companionId, change(view.revision));
      if (!mounted) return;
      setState(() => _view = answer);
      sayToolNotice(context, notice);
    } catch (error) {
      if (toolScreenIsStale(error)) await _load();
      if (!mounted) return;
      sayToolNotice(context,
          toolRefusal(error, changedElsewhere: companionToolsChangedElsewhere));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _change(Map<String, Object?> changes, bool on) => _write(
      (revision) =>
          ToolPolicyChange(expectedRevision: revision, changes: changes),
      toolChangeNotice(on));

  Future<void> _allowBody(bool on) => _write(
      (revision) =>
          ToolPolicyChange(expectedRevision: revision, allowBodyControl: on),
      toolChangeNotice(on));

  Future<void> _openOverview() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) =>
            ToolsOverviewPage(tools: widget.tools, devices: widget.devices)));
    if (mounted) await _load();
  }

  /// Whether this Eidolon's own switch decides [row] right now. A reserved
  /// tool, one the Owner turned off, and a body tool under a closed
  /// 「允许操控身体」 are decided above it.
  bool _switchable(CompanionToolsView view, CompanionToolRowView row) =>
      row.reserved == null &&
      row.globalEnabled &&
      !(row.bodyControl && !view.allowBodyControl);

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Scaffold(
      key: const Key('companion-tools-page'),
      appBar: AppBar(title: Text('${widget.companionName}能做的事')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : view == null
              ? ToolsUnreadable(
                  failure: _failure ?? '没能读到这个伙伴能做的事', retry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      if (_saving) const LinearProgressIndicator(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                        child: Text('在工具总览允许的范围内，'
                            '决定${widget.companionName}在对话里能用哪些工具。'),
                      ),
                      ..._sections(view),
                    ],
                  ),
                ),
    );
  }

  List<Widget> _sections(CompanionToolsView view) {
    final children = <Widget>[];
    var bodySwitchShown = !view.tools.any((row) => row.bodyControl);
    for (final (group, rows) in toolSections(view.tools,
        group: (row) => row.group, reserved: (row) => row.reserved != null)) {
      if (group == systemToolGroup) {
        children.add(ToolSystemGroup(
            children: [for (final row in rows) _row(view, row)]));
        continue;
      }
      if (!bodySwitchShown &&
          (bodyToolGroups.contains(group) || rows.any((r) => r.bodyControl))) {
        bodySwitchShown = true;
        children.add(_bodySwitch(view));
      }
      children
        ..add(ToolGroupHeader(
            group: group, action: _groupToggle(view, group, rows)))
        ..add(Card(
            child:
                Column(children: [for (final row in rows) _row(view, row)])));
    }
    return children;
  }

  Widget _bodySwitch(CompanionToolsView view) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Card(
          child: SwitchListTile(
            key: const Key('companion-tools-body-control'),
            title: const Text('允许操控身体'),
            subtitle: const Text('身体动作和设备设置的总开关。关掉后这两组都用不了，各自的开关会保留。'),
            value: view.allowBodyControl,
            onChanged: _saving ? null : _allowBody,
          ),
        ),
      );

  /// 「整组开/关」: a change to each tool in the group this Eidolon's own
  /// switch decides, and only those not already there. A tool added to the
  /// group later still starts at its default.
  Widget? _groupToggle(
      CompanionToolsView view, String group, List<CompanionToolRowView> rows) {
    final mine = rows.where((row) => _switchable(view, row)).toList();
    if (mine.isEmpty) return null;
    final on = !mine.every((row) => row.companionEnabled);
    return TextButton(
      key: Key('tool-group-toggle-$group'),
      onPressed: _saving
          ? null
          : () => _change({
                for (final row in mine)
                  if (row.companionEnabled != on) row.key: on,
              }, on),
      child: Text(on ? '全部开启' : '全部关闭'),
    );
  }

  Widget _row(CompanionToolsView view, CompanionToolRowView row) {
    final reserved = row.reserved;
    final switchable = _switchable(view, row);
    final lines = <Widget>[Text(row.summary)];
    if (reserved != null) {
      lines.add(Text(toolReservedText(reserved)));
    } else if (!row.globalEnabled) {
      lines.add(Text(toolGlobalOffText,
          key: Key('companion-tool-global-off-${row.key}')));
    } else if (row.bodyControl && !view.allowBodyControl) {
      lines.add(Text(toolBodyControlOffText,
          key: Key('companion-tool-body-off-${row.key}')));
    }
    if (reserved == null && deviceDependentKinds.contains(row.kind)) {
      lines.add(Text(_deviceLine(row),
          key: Key('companion-tool-devices-${row.key}')));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(
        key: Key('companion-tool-${row.key}'),
        enabled: switchable,
        title: Text(row.label),
        subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: lines),
        trailing: reserved != null
            ? const ToolLock()
            // The Eidolon's own value even when something above it decides,
            // so turning that back on restores what is shown here.
            : Switch(
                key: Key('companion-tool-switch-${row.key}'),
                value: row.companionEnabled,
                onChanged: !switchable || _saving
                    ? null
                    : (on) => _change({row.key: on}, on),
              ),
      ),
      if (reserved == null && !row.globalEnabled)
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              key: Key('companion-tool-open-overview-${row.key}'),
              onPressed: _openOverview,
              child: const Text('去工具总览'),
            ),
          ),
        ),
    ]);
  }

  /// 「需要设备支持 · 它的设备里有 2 台支持」, counted from what each of its
  /// devices offers; left at the first half until every one has answered.
  String _deviceLine(CompanionToolRowView row) {
    final devices = _itsDevices;
    final known = _devicesRead &&
        devices.every((device) => _onDevices.containsKey(device.deviceId));
    return toolDeviceSupportLine(
      devices: devices.length,
      supported: known
          ? devices.where((device) {
              final onDevice = _onDevices[device.deviceId]!
                  .tools
                  .where((tool) => tool.key == row.key)
                  .firstOrNull;
              return onDevice != null && deviceSupports(onDevice);
            }).length
          : null,
    );
  }
}

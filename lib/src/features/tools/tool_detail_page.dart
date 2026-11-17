import 'dart:async';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../device_management/mounted_device_models.dart';
import 'tool_policies.dart';
import 'tool_widgets.dart';
import 'tools_wording.dart';

/// One tool: each Eidolon's own switch for it, what it needs, and which of
/// the Owner's devices can run it (§5.2).
///
/// Each Eidolon's switch is that Eidolon's own, written the same way its
/// 「它能做的事」 page writes it: against the revision of its switches this
/// page read, which is why they are read here rather than taken from the
/// overview row, which carries no revision.
class ToolDetailPage extends StatefulWidget {
  const ToolDetailPage({
    super.key,
    required this.tools,
    required this.tool,
    this.devices = const [],
  });

  final ToolPolicies tools;

  /// The row the overview showed. Its name, sentence and requirements are the
  /// catalog's and do not change while this page is open.
  final ToolOverviewRowView tool;
  final List<MountedDevice> devices;

  @override
  State<ToolDetailPage> createState() => _ToolDetailPageState();
}

class _ToolDetailPageState extends State<ToolDetailPage> {
  final _companions = <String, CompanionToolsView>{};
  final _unreadCompanions = <String>{};
  final _saving = <String>{};
  final _onDevices = <String, DeviceToolRowView>{};
  final _unreadDevices = <String>{};

  ToolOverviewRowView get _tool => widget.tool;

  bool get _needsDevice => deviceDependentKinds.contains(_tool.kind);

  @override
  void initState() {
    super.initState();
    for (final companion in _tool.companions) {
      unawaited(_readCompanion(companion.companionId));
    }
    if (_needsDevice) {
      for (final device in widget.devices) {
        unawaited(_readDevice(device.deviceId));
      }
    }
  }

  Future<void> _readCompanion(String companionId) async {
    try {
      final view = await widget.tools.companion(companionId);
      if (!mounted) return;
      setState(() {
        _companions[companionId] = view;
        _unreadCompanions.remove(companionId);
      });
    } catch (_) {
      if (mounted) setState(() => _unreadCompanions.add(companionId));
    }
  }

  Future<void> _readDevice(String deviceId) async {
    try {
      final view = await widget.tools.device(deviceId);
      final row = view.tools.where((row) => row.key == _tool.key).firstOrNull;
      if (!mounted) return;
      setState(() {
        if (row == null) {
          _unreadDevices.add(deviceId);
        } else {
          _onDevices[deviceId] = row;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _unreadDevices.add(deviceId));
    }
  }

  Future<void> _switch(String companionId, bool on) async {
    final current = _companions[companionId];
    if (current == null || _saving.contains(companionId)) return;
    setState(() => _saving.add(companionId));
    try {
      final answer = await widget.tools.changeCompanion(
          companionId,
          ToolPolicyChange(
              expectedRevision: current.revision, changes: {_tool.key: on}));
      if (!mounted) return;
      setState(() => _companions[companionId] = answer);
      sayToolNotice(context, toolChangeNotice(on));
    } catch (error) {
      if (toolScreenIsStale(error)) await _readCompanion(companionId);
      if (!mounted) return;
      sayToolNotice(context,
          toolRefusal(error, changedElsewhere: companionToolsChangedElsewhere));
    } finally {
      if (mounted) setState(() => _saving.remove(companionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requirements = toolRequirementLines(_tool.requires);
    return Scaffold(
      key: const Key('tool-detail-page'),
      appBar: AppBar(title: Text(_tool.label)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_tool.summary),
                    if (!_tool.globalEnabled) ...[
                      const SizedBox(height: 8),
                      Text(toolGlobalOffText,
                          key: const Key('tool-detail-global-off'),
                          style: TextStyle(color: theme.colorScheme.error)),
                    ],
                  ]),
            ),
          ),
          const SizedBox(height: 16),
          Text('各个伙伴', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: _tool.companions.isEmpty
                ? const ListTile(title: Text('还没有伙伴'))
                : Column(children: [
                    for (final companion in _tool.companions)
                      _companionRow(companion),
                  ]),
          ),
          if (requirements.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('需要什么', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                for (final line in requirements)
                  ListTile(dense: true, title: Text(line)),
              ]),
            ),
          ],
          if (_needsDevice) ...[
            const SizedBox(height: 16),
            Text('哪些设备支持', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: widget.devices.isEmpty
                  ? const ListTile(title: Text('还没有设备'))
                  : Column(children: [
                      for (final device in widget.devices) _deviceRow(device),
                    ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _companionRow(ToolCompanionSwitchView companion) {
    final id = companion.companionId;
    final row =
        _companions[id]?.tools.where((row) => row.key == _tool.key).firstOrNull;
    final allowsBody = _companions[id]?.allowBodyControl ?? true;
    final overruled = !_tool.globalEnabled
        ? toolGlobalOffText
        : row != null && row.bodyControl && !allowsBody
            ? toolBodyControlOffText
            : null;
    return ListTile(
      key: Key('tool-companion-$id'),
      title: Text(companion.name),
      subtitle: _unreadCompanions.contains(id)
          ? const Text('读不到这个伙伴的开关')
          : overruled == null
              ? null
              : Text(overruled),
      enabled: overruled == null,
      trailing: row == null
          ? (_unreadCompanions.contains(id)
              ? null
              : const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)))
          : Switch(
              key: Key('tool-companion-switch-$id'),
              value: row.companionEnabled,
              onChanged: overruled != null || _saving.contains(id)
                  ? null
                  : (on) => _switch(id, on),
            ),
    );
  }

  Widget _deviceRow(MountedDevice device) {
    final row = _onDevices[device.deviceId];
    final line = row == null
        ? (_unreadDevices.contains(device.deviceId) ? '读不到这台设备' : '正在读取')
        : row.available
            ? '现在能用'
            : toolReasonText(row.reasons.firstOrNull ?? '');
    return ListTile(
      key: Key('tool-device-${device.deviceId}'),
      leading: Icon(row?.available == true
          ? Icons.check_circle_outline
          : Icons.remove_circle_outline),
      title: Text(device.label),
      subtitle: Text(line),
    );
  }
}

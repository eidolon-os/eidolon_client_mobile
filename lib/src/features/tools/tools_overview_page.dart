import 'dart:async';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../device_management/mounted_device_models.dart';
import 'tool_detail_page.dart';
import 'tool_policies.dart';
import 'tool_widgets.dart';
import 'tools_wording.dart';

/// Every tool this Host could hand a conversation, and the Owner's switch for
/// each (§5.2).
///
/// Turning one off here turns it off for every Eidolon; each keeps its own
/// switch underneath, which comes back when this one is turned on again. What
/// a row says about who uses a tool is the Host's composition of both layers,
/// never worked out here.
class ToolsOverviewPage extends StatefulWidget {
  const ToolsOverviewPage({
    super.key,
    required this.tools,
    this.devices = const [],
  });

  final ToolPolicies tools;

  /// The Owner's devices, for 「哪些设备支持」 on a tool's own page.
  final List<MountedDevice> devices;

  @override
  State<ToolsOverviewPage> createState() => _ToolsOverviewPageState();
}

class _ToolsOverviewPageState extends State<ToolsOverviewPage> {
  ToolsOverviewView? _view;
  String? _failure;
  bool _loading = true, _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = _view == null;
      _failure = null;
    });
    try {
      final view = await widget.tools.overview();
      if (mounted) setState(() => _view = view);
    } catch (error) {
      if (mounted) setState(() => _failure = toolFailure(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Sends only [changes], against the revision on screen, and says when it
  /// takes effect with [notice].
  Future<void> _change(Map<String, Object?> changes, String notice) async {
    final view = _view;
    if (view == null || _saving) return;
    setState(() => _saving = true);
    try {
      final answer = await widget.tools.change(
          ToolPolicyChange(expectedRevision: view.revision, changes: changes));
      if (!mounted) return;
      setState(() => _view = answer);
      sayToolNotice(context, notice);
    } catch (error) {
      if (toolScreenIsStale(error)) await _load();
      if (!mounted) return;
      sayToolNotice(
          context, toolRefusal(error, changedElsewhere: toolsChangedElsewhere));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _restore(ToolOverviewRowView row) => _change(
      {row.key: null},
      row.defaultEnabled == row.globalEnabled
          ? toolRestoredNotice
          : toolChangeNotice(row.defaultEnabled));

  Future<void> _open(ToolOverviewRowView row) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => ToolDetailPage(
            tools: widget.tools, tool: row, devices: widget.devices)));
    // Who uses it changes there.
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Scaffold(
      key: const Key('tools-overview-page'),
      appBar: AppBar(title: const Text('工具与能力')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : view == null
              ? ToolsUnreadable(failure: _failure ?? '没能读到工具', retry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      if (_saving) const LinearProgressIndicator(),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
                        child: Text('伙伴在对话里能用的全部工具。在这里关掉的，所有伙伴都用不了；'
                            '每个伙伴还可以在自己的「它能做的事」里再关掉。'),
                      ),
                      for (final (group, rows) in toolSections(view.tools,
                          group: (row) => row.group,
                          reserved: (row) => row.reserved != null))
                        if (group == systemToolGroup)
                          ToolSystemGroup(
                              children: [for (final row in rows) _row(row)])
                        else ...[
                          ToolGroupHeader(group: group),
                          Card(
                            child: Column(
                                children: [for (final row in rows) _row(row)]),
                          ),
                        ],
                    ],
                  ),
                ),
    );
  }

  Widget _row(ToolOverviewRowView row) {
    final reserved = row.reserved;
    return ListTile(
      key: Key('tool-${row.key}'),
      title: Row(children: [
        Expanded(child: Text(row.label)),
        if (reserved == null && row.globalOverridden)
          TextButton(
            key: Key('tool-restore-${row.key}'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _saving ? null : () => _restore(row),
            child: const Text('恢复默认'),
          ),
      ]),
      subtitle: Text([
        row.summary,
        reserved == null ? toolUsageLine(row) : toolReservedText(reserved),
      ].join('\n')),
      isThreeLine: true,
      trailing: reserved != null
          ? const ToolLock()
          : Switch(
              key: Key('tool-switch-${row.key}'),
              value: row.globalEnabled,
              onChanged: _saving
                  ? null
                  : (on) => _change({row.key: on}, toolChangeNotice(on)),
            ),
      onTap: reserved == null ? () => _open(row) : null,
    );
  }
}

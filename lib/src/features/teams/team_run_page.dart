import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../conversation/role_group_controller.dart';

/// Shows Host-owned runtime. Leaving this route never closes the run.
class TeamRunPage extends StatefulWidget {
  const TeamRunPage(
      {super.key,
      required this.team,
      required this.controller,
      required this.loadRuns,
      required this.reloadTeam,
      this.loadConflicts,
      this.openConflict});
  final TeamRevision team;
  final RoleGroupController controller;
  final Future<TeamStarts> Function() loadRuns;
  final Future<TeamRevision> Function() reloadTeam;
  final Future<TeamConflicts> Function()? loadConflicts;
  final Future<void> Function(String)? openConflict;
  @override
  State<TeamRunPage> createState() => _TeamRunPageState();
}

class _TeamRunPageState extends State<TeamRunPage> {
  bool _checking = true;
  bool _checkingConflicts = false;
  String? _error;
  late TeamRevision _team;
  @override
  void initState() {
    super.initState();
    _team = widget.team;
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final runs = await widget.loadRuns();
      final active = runs.starts.where((r) => !r.closed).toList();
      if (active.length > 1) throw StateError('Conflicting team runs');
      if (widget.controller.sessionId != null) {
        await widget.controller.refresh();
      } else if (active.isNotEmpty) {
        await widget.controller.restoreSaved(active.single);
      }
      final team = await widget.reloadTeam();
      if (mounted) setState(() => _team = team);
    } catch (_) {
      if (mounted) setState(() => _error = '无法确认团队状态，请重试。确认前不会启动另一场聊天。');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _conflicts() async {
    setState(() => _checkingConflicts = true);
    try {
      final result = await widget.loadConflicts!();
      if (!mounted) return;
      final selected = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('伙伴与设备占用'),
                  content: SizedBox(
                      width: double.maxFinite,
                      child: ListView(shrinkWrap: true, children: [
                        if (result.conflicts?.isEmpty ?? true)
                          const Text(
                              '未找到占用这些资源的团队。设备仍可能在单聊中，或配置已变化。请确认设备状态后再试。'),
                        if ((result.unresolvedRuns ?? 0) > 0)
                          const Text('还有聊天正在准备，暂时无法确认它们的占用，请稍后刷新。'),
                        for (final conflict
                            in result.conflicts ?? <TeamConflict>[])
                          ListTile(
                              title: Text(conflict.name),
                              subtitle: Text(
                                  conflict.companionIds?.isNotEmpty == true ? '伙伴正在这个团队聊天' : '设备正在这个团队使用'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () =>
                                  Navigator.pop(context, conflict.teamId)),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('返回'))
                  ]));
      if (selected != null && mounted && widget.openConflict != null) {
        await widget.openConflict!(selected);
        if (mounted) await _check();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂时无法确认占用情况，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _checkingConflicts = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final run = widget.controller;
        final active = run.sessionId != null;
        return Scaffold(
            appBar: AppBar(title: Text(_team.configuration.name), actions: [
              IconButton(
                  tooltip: '确认状态',
                  onPressed: _checking || run.busy ? null : _check,
                  icon: const Icon(Icons.refresh))
            ]),
            body: ListView(padding: const EdgeInsets.all(24), children: [
              Text('${_team.configuration.members.length} 位伙伴'),
              if ((_team.configuration.goal ?? '').trim().isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_team.configuration.goal!)),
              if (active && run.teamRevision != _team.revision)
                const Text('已保存新配置，下次聊天生效。'),
              const SizedBox(height: 20),
              if (_checking || run.busy) const LinearProgressIndicator(),
              if (_error != null) Text(_error!),
              if (run.notice != null) Text(run.notice!),
              const Text('按住已配置的说话设备提问。等待你回应或返回上一页，都不会结束聊天。'),
              const SizedBox(height: 20),
              if (widget.loadConflicts != null && !active)
                TextButton(
                    onPressed: _checkingConflicts ? null : _conflicts,
                    child: Text(_checkingConflicts ? '正在查询占用…' : '查看伙伴与设备占用')),
              FilledButton(
                  onPressed: _checking || _error != null || run.busy || active
                      ? null
                      : () => run.startSaved(_team),
                  child: const Text('开始聊天')),
              OutlinedButton(
                  onPressed: active ? run.close : null,
                  child: Text(run.closeUnconfirmed ? '重试结束' : '结束聊天')),
            ]));
      });
}

import 'package:flutter/material.dart';
import '../../generated/management_v1.dart' show RoleGroupAssignment;
import '../device_management/mounted_device_models.dart';
import 'shared_conversation_preparation_page.dart';
import 'role_group_controller.dart';

class RoleGroupPage extends StatefulWidget {
  const RoleGroupPage(
      {super.key, required this.load, required this.controller});
  final Future<SharedConversationSnapshot> Function() load;
  final RoleGroupController controller;
  @override
  State<RoleGroupPage> createState() => _RoleGroupPageState();
}

class _RoleGroupPageState extends State<RoleGroupPage> {
  List<MountedDevice> _devices = [];
  String? _input, _error;
  final _outputs = <String>[];
  final _roles = <String, String>{};
  bool _loading = true;
  String _goal = '';
  int _replyBudget = 8;
  final _descriptions = <String, String>{};
  @override
  void initState() {
    super.initState();
    final selected = widget.controller.selection;
    if (selected != null) {
      _input = selected.inputDeviceId;
      _outputs.addAll(selected.outputDeviceIds);
      _goal = selected.goal ?? '';
      _replyBudget = selected.replyBudget ?? 8;
      for (final assignment in selected.roles ?? <RoleGroupAssignment>[]) {
        _roles[assignment.outputDeviceId] = assignment.role.name;
        _descriptions[assignment.outputDeviceId] =
            assignment.role.description ?? '';
      }
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await widget.load();
      if (!mounted) return;
      setState(() {
        _devices = snapshot.devices
            .where((d) => d.deviceId != snapshot.localDeviceId)
            .toList();
        final ids = _devices.map((d) => d.deviceId).toSet();
        if (!ids.contains(_input)) _input = null;
        _outputs.removeWhere((id) => !ids.contains(id));
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取设备，请刷新重试。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final team = widget.controller;
        final labels = {for (final d in _devices) d.deviceId: d.label};
        final locked = team.sessionId != null || team.busy;
        final editable = !locked && !_loading && _error == null;
        final companionIds = _devices
            .where((d) => _outputs.contains(d.deviceId))
            .map((d) => d.attachedCompanionId)
            .toList();
        final distinct = companionIds.toSet().length == companionIds.length;
        return Scaffold(
            appBar: AppBar(title: const Text('IP 角色团队'), actions: [
              IconButton(
                  key: const Key('refresh-team-devices'),
                  icon: const Icon(Icons.refresh),
                  onPressed: locked
                      ? (team.busy ? null : team.refresh)
                      : (_loading ? null : _load))
            ]),
            body: ListView(padding: const EdgeInsets.all(20), children: [
              const Text('手机配置并控制开始、结束。团队静默时不会自动退出，返回上一页也不会结束。'),
              const SizedBox(height: 16),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) Text(_error!),
              DropdownButtonFormField<String>(
                  key: ValueKey('team-input-$_input'),
                  initialValue: _input,
                  decoration: const InputDecoration(labelText: '唯一 PTT 输入设备'),
                  items: [
                    for (final d in _devices)
                      DropdownMenuItem(
                          value: d.deviceId,
                          enabled: d.state != MountedDeviceState.accessRevoked,
                          child: Text(d.label))
                  ],
                  onChanged: editable
                      ? (id) => setState(() {
                            _input = id;
                            _outputs.remove(id);
                          })
                      : null),
              const Text('请选择按住说话的设备；启动时主机会校验 PTT 能力。'),
              const SizedBox(height: 16),
              const Text('参与成员（由对话内容决定谁回应）'),
              for (final d in _devices.where((d) => d.deviceId != _input))
                CheckboxListTile(
                    key: ValueKey('team-output-${d.deviceId}'),
                    title: Text(d.label),
                    subtitle: Text(d.attachedCompanionId == null
                        ? '尚未绑定伙伴'
                        : '${d.attachedCompanionName.isEmpty ? d.attachedCompanionId : d.attachedCompanionName}'),
                    value: _outputs.contains(d.deviceId),
                    onChanged: editable &&
                            d.state == MountedDeviceState.ready &&
                            d.attachedCompanionId != null
                        ? (value) => setState(() {
                              if (value == true) {
                                _outputs.add(d.deviceId);
                              } else {
                                _outputs.remove(d.deviceId);
                              }
                            })
                        : null),
              if (!distinct) const Text('每位伙伴只能选择一个回应设备。'),
              for (final id in _outputs)
                TextFormField(
                  key: ValueKey('team-role-$id'),
                  initialValue: _roles[id] ?? '',
                  enabled: editable,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: '${labels[id] ?? id} · 本场角色',
                    hintText: '留空使用原伙伴身份',
                  ),
                  onChanged: (value) => setState(() => _roles[id] = value),
                ),
              for (final id in _outputs
                  .where((id) => (_roles[id] ?? '').trim().isNotEmpty))
                TextFormField(
                    key: ValueKey('team-role-description-$id'),
                    initialValue: _descriptions[id] ?? '',
                    enabled: editable,
                    maxLength: 1000,
                    decoration: InputDecoration(
                        labelText: '${labels[id] ?? id} · 角色说明（可选）'),
                    onChanged: (value) => _descriptions[id] = value),
              const Text('每位只说自己的这一轮。角色在本场固定，修改请结束后重新开始。'),
              TextFormField(
                  key: const Key('team-goal'),
                  initialValue: _goal,
                  enabled: editable,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                      labelText: '交流目标（可选）', hintText: '例如：讨论周末出游，比较不同建议'),
                  onChanged: (value) => _goal = value),
              DropdownButtonFormField<int>(
                  key: ValueKey('team-budget-$_replyBudget'),
                  initialValue: _replyBudget,
                  decoration: const InputDecoration(labelText: '每次提问后的连续回复上限'),
                  items: [
                    for (var i = 1; i <= 32; i++)
                      DropdownMenuItem(value: i, child: Text('$i 次'))
                  ],
                  onChanged: editable
                      ? (value) => setState(() => _replyBudget = value!)
                      : null),
              const Text('成员可接续、提问或等待。达到上限后等你继续，不会为了凑次数继续说。'),
              const SizedBox(height: 16),
              if (team.notice != null) Text(team.notice!),
              FilledButton(
                  key: const Key('start-role-group'),
                  onPressed: editable &&
                          _input != null &&
                          _outputs.isNotEmpty &&
                          distinct
                      ? () => team.start(_input!, _outputs,
                          roles: _roles,
                          descriptions: _descriptions,
                          goal: _goal,
                          replyBudget: _replyBudget)
                      : null,
                  child: const Text('开始团队')),
              OutlinedButton(
                  key: const Key('close-role-group'),
                  onPressed: team.sessionId != null ? team.close : null,
                  child: Text(team.closeUnconfirmed ? '重试结束' : '结束团队')),
            ]));
      });
}

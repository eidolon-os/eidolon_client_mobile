import 'package:flutter/material.dart';
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
  bool _loading = true, _discussion = false;
  @override
  void initState() {
    super.initState();
    final selected = widget.controller.selection;
    if (selected != null) {
      _input = selected.inputDeviceId;
      _outputs.addAll(selected.outputDeviceIds);
      _discussion = selected.discussion ?? false;
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
              const Text('回应成员（按勾选顺序模拟裁决）'),
              for (final d in _devices.where((d) => d.deviceId != _input))
                CheckboxListTile(
                    key: ValueKey('team-output-${d.deviceId}'),
                    title: Text(d.label),
                    subtitle: Text(d.attachedCompanionId == null
                        ? '尚未绑定伙伴'
                        : '${d.attachedCompanionName.isEmpty ? d.attachedCompanionId : d.attachedCompanionName}${_outputs.contains(d.deviceId) ? ' · 第 ${_outputs.indexOf(d.deviceId) + 1} 位' : ''}'),
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
              SwitchListTile(
                  title: const Text('成员接续互聊（最多 4 次回复）'),
                  value: _discussion,
                  onChanged: editable
                      ? (value) => setState(() => _discussion = value)
                      : null),
              const Text('当前为模拟裁决：固定选择顺序，不会理解点名或“停止说话”等语义。PTT 按下仍会打断当前输出。'),
              const SizedBox(height: 16),
              if (team.notice != null) Text(team.notice!),
              FilledButton(
                  key: const Key('start-role-group'),
                  onPressed: editable &&
                          _input != null &&
                          _outputs.isNotEmpty &&
                          distinct
                      ? () => team.start(_input!, _outputs, _discussion)
                      : null,
                  child: const Text('开始团队')),
              OutlinedButton(
                  key: const Key('close-role-group'),
                  onPressed:
                      team.sessionId != null && !team.busy ? team.close : null,
                  child: const Text('结束团队')),
            ]));
      });
}

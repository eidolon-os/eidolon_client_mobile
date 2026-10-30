import 'dart:math';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../device_management/mounted_device_models.dart';

typedef SaveTeam = Future<TeamRevision> Function(
    String, int, TeamConfiguration);

class TeamManagementPage extends StatefulWidget {
  const TeamManagementPage(
      {super.key,
      required this.load,
      required this.save,
      required this.remove,
      required this.loadDevices,
      required this.openDevices,
      this.openRun});
  final Future<TeamPage> Function(String?) load;
  final SaveTeam save;
  final Future<void> Function(TeamRevision)? openRun;
  final Future<void> Function(String, int) remove;
  final Future<List<MountedDevice>> Function() loadDevices;
  final Future<void> Function() openDevices;
  @override
  State<TeamManagementPage> createState() => _TeamManagementPageState();
}

class _TeamManagementPageState extends State<TeamManagementPage> {
  final _teams = <TeamRevision>[];
  bool _busy = false;
  String? _error, _cursor;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.load(more ? _cursor : null);
      if (!mounted) return;
      setState(() {
        if (!more) _teams.clear();
        for (final team in page.teams) {
          _teams.removeWhere((t) => t.teamId == team.teamId);
          _teams.add(team);
        }
        _cursor = page.nextCursor;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法读取团队。已显示的内容可能不是最新版本。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([TeamRevision? team, bool duplicate = false]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => TeamEditorPage(
            initial: duplicate ? null : team,
            copyFrom: duplicate ? team?.configuration : null,
            save: widget.save,
            loadDevices: widget.loadDevices,
            openDevices: widget.openDevices)));
    if (mounted && saved == true) await _load();
  }

  Future<void> _remove(TeamRevision team) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('删除“${team.configuration.name}”？'),
                content: const Text('只删除团队配置，伙伴与设备会保留。正在使用的团队需要先结束聊天。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除团队'))
                ]));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.remove(team.teamId, team.revision);
      if (mounted) {
        setState(() => _teams.removeWhere((t) => t.teamId == team.teamId));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '未能确认删除。团队可能正在使用或已被修改，请刷新后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('团队管理'), actions: [
        IconButton(
            tooltip: '刷新团队',
            onPressed: _busy ? null : () => _load(),
            icon: const Icon(Icons.refresh))
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _busy ? null : () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('创建团队')),
      body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          children: [
            const Text('把常用伙伴和设备保存为团队，下次聊天直接使用。'),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) ...[
              Text(_error!),
              TextButton(
                  onPressed: _busy ? null : () => _load(),
                  child: const Text('重试'))
            ],
            if (!_busy && _error == null && _teams.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Text('还没有团队。创建一个，安排好伙伴和设备。')),
            for (final team in _teams)
              Card(
                  child: ListTile(
                      leading: TeamEmblem(name: team.configuration.name),
                      title: Text(team.configuration.name,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${team.configuration.members.length} 位伙伴'
                          '${(team.configuration.goal ?? '').trim().isEmpty ? '' : ' · ${team.configuration.goal}'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      onTap: _busy
                          ? null
                          : () => widget.openRun != null
                              ? widget.openRun!(team)
                              : _edit(team),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        PopupMenuButton<String>(
                          tooltip: '团队操作',
                          enabled: !_busy,
                          onSelected: (action) {
                            if (action == 'edit') _edit(team);
                            if (action == 'copy') _edit(team, true);
                            if (action == 'delete') _remove(team);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('编辑团队')),
                            PopupMenuItem(value: 'copy', child: Text('复制团队')),
                            PopupMenuItem(value: 'delete', child: Text('删除团队')),
                          ],
                        ),
                      ]))),
            if (_cursor != null)
              TextButton(
                  onPressed: _busy ? null : () => _load(more: true),
                  child: const Text('加载更多')),
          ]));
}

class TeamEditorPage extends StatefulWidget {
  const TeamEditorPage(
      {super.key,
      this.initial,
      this.copyFrom,
      required this.save,
      required this.loadDevices,
      required this.openDevices});
  final TeamRevision? initial;
  final TeamConfiguration? copyFrom;
  final SaveTeam save;
  final Future<List<MountedDevice>> Function() loadDevices;
  final Future<void> Function() openDevices;
  @override
  State<TeamEditorPage> createState() => _TeamEditorPageState();
}

class _TeamEditorPageState extends State<TeamEditorPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _goal;
  late final String _id;
  final _members = <String, TeamMember>{};
  List<MountedDevice> _devices = [];
  String? _input, _error;
  bool _loading = false, _saving = false, _dirty = false, _saved = false;
  @override
  void initState() {
    super.initState();
    final c = widget.initial?.configuration ?? widget.copyFrom;
    _dirty = widget.copyFrom != null;
    final name = c?.name ?? '';
    _name = TextEditingController(
        text: widget.copyFrom == null
            ? name
            : '${name.substring(0, min(name.length, 75))} 副本');
    _goal = TextEditingController(text: c?.goal ?? '');
    _id = widget.initial?.teamId ??
        'team-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    _input = c?.inputDeviceId;
    for (final m in c?.members ?? <TeamMember>[]) {
      _members[m.outputDeviceId] = m;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await widget.loadDevices();
      if (mounted) setState(() => _devices = devices);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取设备，请重试；你的编辑已保留。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_members.length > 16) {
      setState(() => _error = '一个团队最多安排 16 位伙伴。');
      return;
    }
    if (_input == null || _members.isEmpty) {
      setState(() => _error = '请选择说话设备和至少一位伙伴。');
      return;
    }
    final byId = {for (final d in _devices) d.deviceId: d};
    if (!byId.containsKey(_input) ||
        _members.values.any((m) =>
            byId[m.outputDeviceId]?.attachedCompanionId != m.companionId)) {
      setState(() => _error = '有设备暂不可用或伙伴绑定已改变，请调整选择。');
      return;
    }
    if (_members.containsKey(_input) ||
        _members.values.map((m) => m.companionId).toSet().length !=
            _members.length) {
      setState(() => _error = '说话设备与回应设备需分开，每位伙伴只选择一个设备。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(
          _id,
          widget.initial?.revision ?? 0,
          TeamConfiguration(
              name: _name.text.trim(),
              inputDeviceId: _input!,
              members: _members.values.toList(),
              goal: _goal.text.trim()));
      if (!mounted) return;
      setState(() {
        _saved = true;
        _dirty = false;
        _saving = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = '无法确认保存，内容已保留。可再次保存；若其他人已修改，请返回列表刷新后合并修改。');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _leave() async {
    if (_saving) return;
    final discard = await showDialog<bool>(
        context: context,
        builder: (context) =>
            AlertDialog(title: const Text('放弃未保存的修改？'), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('继续编辑')),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('放弃修改'))
            ]));
    if (discard == true && mounted) {
      setState(() => _dirty = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _goal.dispose();
    super.dispose();
  }

  Future<void> _chooseInput() async {
    final selected = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: .55,
            builder: (context, scroll) => ListView(
                    controller: scroll,
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text('选择说话设备',
                          style: Theme.of(context).textTheme.titleLarge),
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('在这台设备上按住 PTT 提问。它与伙伴的回应设备分开。')),
                      for (final d in _devices)
                        ListTile(
                            leading: const Icon(Icons.mic_none),
                            title: Text(d.label),
                            subtitle: Text(_members.containsKey(d.deviceId)
                                ? '已用作伙伴的回应设备'
                                : _availability(d)),
                            trailing: _input == d.deviceId
                                ? const Icon(Icons.check)
                                : null,
                            enabled: !_members.containsKey(d.deviceId),
                            onTap: () => Navigator.pop(context, d.deviceId)),
                      if (_devices.isEmpty) const Text('暂无设备，请先添加设备。'),
                    ])));
    if (selected != null && mounted) {
      setState(() {
        _input = selected;
        _dirty = true;
      });
    }
  }

  String _availability(MountedDevice device) =>
      switch (device.connectionState) {
        'online' => '在线',
        'offline' => '离线，连接后可聊天',
        _ => '连接状态待确认',
      };

  Widget _section(String title, String description, List<Widget> children) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(description, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ...children,
          ]));

  @override
  Widget build(BuildContext context) {
    final labels = {for (final d in _devices) d.deviceId: d.label};
    final companions =
        _devices.where((d) => d.attachedCompanionId != null).toList();
    final disabled = _loading || _saving;
    return PopScope(
        canPop: _saved || (!_dirty && !_saving),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: Scaffold(
            appBar: AppBar(
                title: Text(widget.initial == null ? '创建团队' : '编辑团队'),
                actions: [
                  IconButton(
                      tooltip: '刷新设备',
                      onPressed: disabled ? null : _load,
                      icon: const Icon(Icons.refresh))
                ]),
            bottomNavigationBar: SafeArea(
                top: false,
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: FilledButton(
                        onPressed: disabled ? null : _save,
                        child: Text(_saving ? '正在保存…' : '保存团队')))),
            body: Form(
                key: _form,
                child: ListView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.all(20),
                    children: [
                      if (_loading || _saving) const LinearProgressIndicator(),
                      if (_error != null)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      _section('团队资料', '给伙伴们一个共同的聊天背景。', [
                        TextFormField(
                            controller: _name,
                            enabled: !disabled,
                            maxLength: 80,
                            decoration: const InputDecoration(
                                labelText: '团队名称',
                                hintText: '例如：周末旅行搭子',
                                border: OutlineInputBorder()),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? '给团队起个名字'
                                : null,
                            onChanged: (_) => setState(() => _dirty = true)),
                        const SizedBox(height: 12),
                        TextFormField(
                            controller: _goal,
                            enabled: !disabled,
                            maxLength: 2000,
                            minLines: 3,
                            maxLines: 6,
                            decoration: const InputDecoration(
                                labelText: '团队背景（可选）',
                                alignLabelWithHint: true,
                                border: OutlineInputBorder(),
                                hintText: '这个团队为什么聚在一起，有哪些共同话题或背景？'),
                            onChanged: (_) => setState(() => _dirty = true)),
                      ]),
                      _section('参与伙伴', '沿用伙伴自己的档案和个性，无需为团队重新设定角色。', [
                        if (companions.isEmpty)
                          const Text('暂无绑定设备的伙伴，请先安排伙伴与设备。'),
                        for (final d in companions)
                          Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: CheckboxListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 4),
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  title: Text(d.attachedCompanionName.isEmpty
                                      ? '伙伴'
                                      : d.attachedCompanionName),
                                  subtitle: Text(
                                      '${d.label} · ${d.deviceId == _input ? '已用作说话设备' : _availability(d)}'),
                                  value: _members.containsKey(d.deviceId),
                                  onChanged: disabled || d.deviceId == _input
                                      ? null
                                      : (selected) {
                                          setState(() {
                                            _dirty = true;
                                            if (selected == true) {
                                              // One Companion, one output; selecting another body moves its assignment.
                                              _members.removeWhere((_, m) =>
                                                  m.companionId ==
                                                  d.attachedCompanionId);
                                              _members[d.deviceId] = TeamMember(
                                                  companionId:
                                                      d.attachedCompanionId!,
                                                  outputDeviceId: d.deviceId);
                                            } else {
                                              _members.remove(d.deviceId);
                                            }
                                          });
                                        })),
                        for (final m in _members.values.where(
                            (m) => !labels.containsKey(m.outputDeviceId)))
                          ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('已选设备暂不可用'),
                              subtitle: const Text('选择已保留，恢复连接后可继续使用。'),
                              trailing: IconButton(
                                  tooltip: '移除选择',
                                  icon: const Icon(Icons.close),
                                  onPressed: disabled
                                      ? null
                                      : () => setState(() {
                                            _members.remove(m.outputDeviceId);
                                            _dirty = true;
                                          }))),
                        Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                                icon: const Icon(Icons.devices),
                                label: const Text('管理伙伴与设备'),
                                onPressed: disabled
                                    ? null
                                    : () async {
                                        await widget.openDevices();
                                        if (mounted) await _load();
                                      })),
                      ]),
                      _section('说话设备', '按住这台设备的 PTT 向团队提问，伙伴们从各自设备回应。', [
                        Card(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                                leading: const Icon(Icons.mic_none),
                                title: Text(_input == null
                                    ? '选择说话设备'
                                    : labels[_input] ?? '原设备暂不可用'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: disabled ? null : _chooseInput)),
                      ]),
                      const Text('保存后可随时开始聊天。聊天中修改团队，下次开始时生效。'),
                    ]))));
  }
}

/// A lightweight identity marker; no separate image asset or team avatar service.
class TeamEmblem extends StatelessWidget {
  const TeamEmblem({super.key, required this.name});
  final String name;
  @override
  Widget build(BuildContext context) => CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
      foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
      child: Text(name.trim().isEmpty ? '团' : name.trim().characters.first,
          style: const TextStyle(fontWeight: FontWeight.w600)));
}

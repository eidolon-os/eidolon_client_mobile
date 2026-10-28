import 'dart:math';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import 'voiceprint_page.dart';
import '../../theme/eidolon_theme.dart';
import '../../theme/neon_components.dart';

/// OS people use the same authenticated management session as other Host data.
class PersonsPage extends StatefulWidget {
  const PersonsPage({super.key, required this.call, required this.voiceprints});
  final VoiceprintCall call;
  final VoiceprintCall voiceprints;
  @override
  State<PersonsPage> createState() => _PersonsPageState();
}

class _PersonsPageState extends State<PersonsPage> {
  List<PersonView> _people = [];
  bool _busy = false;
  String? _error;
  PersonCreate? _pendingCreate;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            e is ManagementRequestException ? e.message : '操作未确认，请刷新或重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final result = PersonCollection.fromJson(await widget.call());
    if (mounted) setState(() => _people = result.persons ?? []);
  }

  Future<void> _refresh() => _act(_load);

  Future<void> _savePending() => _act(() async {
        await widget.call(method: 'POST', body: _pendingCreate!.toJson());
        _pendingCreate = null;
        await _load();
      });

  Future<void> _edit([PersonView? person]) async {
    var name = person?.displayName ?? '';
    var preferred = person?.profile.preferredName ?? '';
    var language = person?.profile.language ?? '';
    var description = person?.profile.description ?? '';
    final save = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(person == null ? '添加用户' : '编辑用户资料'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextFormField(
                      initialValue: name,
                      onChanged: (value) => name = value,
                      maxLength: 128,
                      decoration: const InputDecoration(labelText: '姓名或名称')),
                  TextFormField(
                      initialValue: preferred,
                      onChanged: (value) => preferred = value,
                      maxLength: 128,
                      decoration: const InputDecoration(labelText: '希望怎样称呼你')),
                  TextFormField(
                      initialValue: language,
                      onChanged: (value) => language = value,
                      maxLength: 64,
                      decoration: const InputDecoration(labelText: '语言')),
                  TextFormField(
                      initialValue: description,
                      onChanged: (value) => description = value,
                      maxLength: 2000,
                      maxLines: 3,
                      decoration:
                          const InputDecoration(labelText: '个人描述（自行填写）')),
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        if (name.trim().isNotEmpty) {
                          Navigator.pop(context, true);
                        }
                      },
                      child: const Text('保存'))
                ]));
    final displayName = name.trim();
    final profile = PersonProfile(
        preferredName: preferred.trim(),
        language: language.trim(),
        description: description.trim(),
        preferences: person?.profile.preferences ?? [],
        schemaVersion: 1);
    if (save != true || !mounted) return;
    if (person == null) {
      final random = Random.secure();
      final id = List.generate(
              16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      _pendingCreate = PersonCreate(
          personId: id, displayName: displayName, profile: profile);
      await _savePending();
    } else {
      await _act(() async {
        await widget.call(
            method: 'PUT',
            suffix: '/${Uri.encodeComponent(person.personId)}',
            body: PersonUpdate(
                    displayName: displayName,
                    expectedRevision: person.revision,
                    profile: profile,
                    status: person.status)
                .toJson());
        await _load();
      });
    }
  }

  Future<void> _status(PersonView p) => _act(() async {
        await widget.call(
            method: 'PUT',
            suffix: '/${Uri.encodeComponent(p.personId)}',
            body: PersonUpdate(
                    displayName: p.displayName,
                    expectedRevision: p.revision,
                    profile: p.profile,
                    status: p.status == 'active' ? 'inactive' : 'active')
                .toJson());
        await _load();
      });

  Future<void> _delete(PersonView p) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('删除“${p.displayName}”？'),
                content: const Text('删除用户资料、该用户的声纹和录入声音。历史对话和记忆不会随之删除。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (yes != true || !mounted) return;
    await _act(() async {
      await widget.call(
          method: 'DELETE',
          suffix:
              '/${Uri.encodeComponent(p.personId)}?expected_revision=${p.revision}');
      await _load();
    });
  }

  Future<void> _memory(PersonView person) async {
    Map<String, dynamic>? state;
    final path = '/${Uri.encodeComponent(person.personId)}';
    await _act(() async {
      state = await widget.call(suffix: '$path/memory-state');
    });
    if (!mounted || state == null) return;
    final value = state!;
    final status = value['state'] as String;
    final active = value['person_status'] == 'active';
    final label = status == 'active'
        ? '暂停个人记忆'
        : status == 'unbound'
            ? '启用个人记忆'
            : '恢复个人记忆';
    final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('${person.displayName}的个人记忆'),
              content: Text(
                  '${status == 'active' ? '已启用' : status == 'unbound' ? '尚未启用' : '已暂停'}。'
                  '个人记忆由家庭管理员管理，只有当前发言获得有效身份确认时才会使用。'
                  '未识别、识别不确定或识别超时时，对话继续，但不读取或写入个人记忆。'
                  '暂停会保留原有记忆；恢复后继续使用原有记忆。'
                  '${active ? '' : '请先启用该用户，再启用或恢复记忆。'}'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('关闭')),
                if (active || status == 'active')
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(label)),
              ],
            ));
    if (confirm != true || !mounted) return;
    await _act(() async {
      if (status == 'unbound') {
        await widget.call(method: 'PUT', suffix: '$path/memory-realm');
      } else {
        final action = status == 'active' ? 'suspend' : 'restore';
        await widget.call(
            method: 'POST',
            suffix:
                '$path/memory-realm/$action?expected_revision=${value['person_revision']}');
      }
      await _load();
    });
  }

  void _openVoiceprints(PersonView person) {
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => VoiceprintPage(
        personName: person.displayName,
        personId: person.personId,
        personActive: person.status == 'active',
        call: widget.voiceprints,
      ),
    ));
  }

  Widget _personCard(PersonView person) => NeonPanel(
        key: ValueKey('person-${person.personId}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const GlyphBadge(Icons.person_outline),
                const SizedBox(width: Neon.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(person.displayName,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Neon.ink)),
                      const SizedBox(height: Neon.s1),
                      Text(
                        person.status == 'active' ? '使用中' : '已停用 · 不参与辅助识别',
                        style: const TextStyle(
                            fontSize: 12.5, height: 1.5, color: Neon.inkDim),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '${person.displayName}的更多操作',
                  enabled: !_busy,
                  onSelected: (action) {
                    if (action == 'status') _status(person);
                    if (action == 'delete') _delete(person);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'status',
                        child: Text(person.status == 'active' ? '停用' : '启用')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除用户', style: TextStyle(color: Neon.bad))),
                  ],
                ),
              ],
            ),
            const SizedBox(height: Neon.s4),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.badge_outlined, color: Neon.cyan),
              title: const Text('个人资料'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : () => _edit(person),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.graphic_eq, color: Neon.cyan),
              title: const Text('声纹管理'),
              subtitle: const Text('录入、重录与测试'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : () => _openVoiceprints(person),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.psychology_outlined, color: Neon.cyan),
              title: const Text('个人记忆'),
              subtitle: const Text('查看状态、启用或暂停'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : () => _memory(person),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('用户管理'),
          actions: [
            IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(Neon.s6),
          children: [
            const NeonPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeading(
                    eyebrow: 'People',
                    title: '认识这里的每个人',
                    icon: Icons.people_outline,
                  ),
                  SizedBox(height: Neon.s3),
                  Text('为用户保存个人资料和声纹。无需声纹，也可以与伙伴对话。',
                      style: TextStyle(
                          fontSize: 14, height: 1.6, color: Neon.inkDim)),
                ],
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: Neon.s4),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: Neon.s4),
              Semantics(
                liveRegion: true,
                child: NeonPanel(
                    accent: Neon.bad,
                    child: Text(_error!,
                        style: const TextStyle(color: Neon.bad, height: 1.5))),
              ),
            ],
            if (_pendingCreate != null) ...[
              const SizedBox(height: Neon.s4),
              OutlinedButton.icon(
                  onPressed: _busy ? null : _savePending,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试确认添加用户')),
            ],
            if (!_busy && _error == null && _people.isEmpty) ...[
              const SizedBox(height: Neon.s6),
              const Text('还没有用户',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Neon.ink)),
              const SizedBox(height: Neon.s2),
              const Text('从下方添加第一位用户，再按需录入声纹。',
                  style: TextStyle(height: 1.6, color: Neon.inkDim)),
            ],
            for (final person in _people) ...[
              const SizedBox(height: Neon.s4),
              _personCard(person),
            ],
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          minimum:
              const EdgeInsets.fromLTRB(Neon.s6, Neon.s3, Neon.s6, Neon.s4),
          child: NeonCta(
            child: FilledButton.icon(
              onPressed: _busy || _pendingCreate != null ? null : () => _edit(),
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('添加用户'),
            ),
          ),
        ),
      );
}

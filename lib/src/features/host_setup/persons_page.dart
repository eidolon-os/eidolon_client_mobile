import 'dart:math';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import 'voiceprint_page.dart';

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
                content: const Text('删除用户资料、关联声纹和录入声音。历史对话和记忆不会随之删除。'),
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

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('用户管理')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('管理 Eidolon OS 认识的用户。声纹用于辅助识别，不限制与伙伴对话。'),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        TextButton(onPressed: _busy ? null : _refresh, child: const Text('刷新')),
        if (_pendingCreate != null)
          FilledButton(
              onPressed: _busy ? null : _savePending,
              child: const Text('重试确认添加用户')),
        for (final p in _people)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.displayName,
                            style: Theme.of(context).textTheme.titleLarge),
                        Text(p.status == 'active' ? '使用中' : '已停用 · 不参与辅助识别'),
                        Wrap(children: [
                          TextButton(
                              onPressed: _busy ? null : () => _edit(p),
                              child: const Text('个人资料')),
                          TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => Navigator.of(context).push<void>(
                                      MaterialPageRoute(
                                          builder: (_) => VoiceprintPage(
                                              personName: p.displayName,
                                              personId: p.personId,
                                              personActive:
                                                  p.status == 'active',
                                              call: widget.voiceprints))),
                              child: const Text('声纹管理')),
                          TextButton(
                              onPressed: _busy ? null : () => _status(p),
                              child: Text(p.status == 'active' ? '停用' : '启用')),
                          TextButton(
                              onPressed: _busy ? null : () => _delete(p),
                              child: const Text('删除用户')),
                        ])
                      ]))),
        FilledButton.icon(
            onPressed: _busy || _pendingCreate != null ? null : () => _edit(),
            icon: const Icon(Icons.person_add_outlined),
            label: const Text('添加用户')),
      ]));
}

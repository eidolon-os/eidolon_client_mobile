import 'dart:math';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import 'voiceprint_page.dart';
import 'person_face_page.dart';
import '../../theme/eidolon_theme.dart';
import '../../theme/neon_components.dart';

String personManagementName(PersonView p) => p.identityState == 'missing'
    ? '保留记忆 · ${p.personId.length > 6 ? p.personId.substring(0, 6) : p.personId}'
    : p.displayName;

/// OS people use the same authenticated management session as other Host data.
class PersonsPage extends StatefulWidget {
  const PersonsPage(
      {super.key,
      required this.call,
      required this.voiceprints,
      this.openMemory,
      this.openHouseholdMemory});
  final Future<void> Function(PersonView person)? openMemory;
  /// The household layer: what anyone said about the home, for everyone.
  final Future<void> Function()? openHouseholdMemory;
  final VoiceprintCall call;
  final VoiceprintCall voiceprints;
  @override
  State<PersonsPage> createState() => _PersonsPageState();
}

class _PersonsPageState extends State<PersonsPage> {
  List<PersonView> _people = [];
  List<PersonView> _archived = [];
  String? _archiveError;
  bool _busy = false;
  Map<String, Map<String, dynamic>> _memoryStates = {};
  Map<String, int>? _voiceCounts;
  Map<String, bool> _faceStates = {};
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
            e is ManagementRequestException
                ? refusalText(e, subject: '用户管理')
                : '操作未确认，请刷新或重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final result = PersonCollection.fromJson(await widget.call());
    final people = result.persons ?? [];
    try {
      _archived =
          PersonCollection.fromJson(await widget.call(suffix: '/archived'))
                  .persons ??
              [];
      _archiveError = null;
    } catch (_) {
      _archiveError = '归档记录暂时无法读取';
    }

    final memory = <String, Map<String, dynamic>>{};
    final faces = <String, bool>{};
    Map<String, int>? voices;
    await Future.wait([
      for (final person in people)
        () async {
          try {
            final state = await widget.call(
                suffix:
                    '/${Uri.encodeComponent(person.personId)}/face-profile');
            if (state['has_image'] is bool) {
              faces[person.personId] = state['has_image'] as bool;
            }
          } catch (_) {
            /* Show unknown; photo failures do not hide the people. */
          }
        }(),
      for (final person in people)
        () async {
          try {
            final state = await widget.call(
                suffix:
                    '/${Uri.encodeComponent(person.personId)}/memory-state');
            if (['active', 'inactive', 'unbound'].contains(state['state']) &&
                state['person_revision'] is int) {
              memory[person.personId] = state;
            }
          } catch (_) {/* Unknown is shown explicitly; never assume enabled. */}
        }(),
      () async {
        try {
          final collection =
              VoiceprintCollection.fromJson(await widget.voiceprints());
          final counts = <String, int>{};
          for (final profile in collection.profiles ?? <SpeakerProfileView>[]) {
            counts.update(profile.personId, (n) => n + 1, ifAbsent: () => 1);
          }
          voices = counts;
        } catch (_) {
          /* A failed voice status query does not hide the people. */
        }
      }(),
    ]);
    if (mounted) {
      setState(() {
        _people = people;
        _memoryStates = memory;
        _voiceCounts = voices;
        _faceStates = faces;
      });
    }
  }

  Future<void> _refresh() => _act(_load);

  Future<void> _savePending() => _act(() async {
        await widget.call(method: 'POST', body: _pendingCreate!.toJson());
        _pendingCreate = null;
        await _load();
      });

  Future<void> _edit([PersonView? person]) async {
    var name = person?.displayName ?? '';
    var isNamed = person?.isNamed ?? true;
    var preferred = person?.profile.preferredName ?? '';
    var language = person?.profile.language ?? '';
    var description = person?.profile.description ?? '';
    final save = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, updateDialog) => AlertDialog(
                    title: Text(person == null ? '添加用户' : '编辑用户资料'),
                    content: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      TextFormField(
                          initialValue: name,
                          onChanged: (value) => name = value,
                          maxLength: 128,
                          decoration:
                              const InputDecoration(labelText: '姓名或名称')),
                      CheckboxListTile(
                          title: const Text('已命名'),
                          subtitle: const Text('命名不会改变身份确认阶段'),
                          value: isNamed,
                          onChanged: (value) =>
                              updateDialog(() => isNamed = value ?? false)),
                      TextFormField(
                          initialValue: preferred,
                          onChanged: (value) => preferred = value,
                          maxLength: 128,
                          decoration:
                              const InputDecoration(labelText: '希望怎样称呼你')),
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
                    ])));
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
          personId: id,
          displayName: displayName,
          profile: profile,
          isNamed: isNamed);
      await _savePending();
    } else {
      await _act(() async {
        await widget.call(
            method: 'PUT',
            suffix: '/${Uri.encodeComponent(person.personId)}',
            body: PersonUpdate(
                    displayName: displayName,
                    isNamed: isNamed,
                    expectedRevision: person.revision,
                    profile: profile,
                    status: person.status)
                .toJson());
        await _load();
      });
    }
  }

  Future<void> _archiveDetails(PersonView p) async {
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(personManagementName(p)),
              content: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                    if (p.identityState == 'missing')
                      const Text('原姓名和人物资料已被旧版本删除，不能据此确认身份。这里保留的是该身份原有的私人记忆。')
                    else ...[
                      Text(
                          '称呼：${(p.profile.preferredName ?? "").isEmpty ? '未填写' : p.profile.preferredName}'),
                      Text(
                          '语言：${(p.profile.language ?? "").isEmpty ? '未填写' : p.profile.language}'),
                      Text(
                          '人物说明：${(p.profile.description ?? "").isEmpty ? '未填写' : p.profile.description}'),
                      Text(
                          '偏好：${(p.profile.preferences ?? []).isEmpty ? '未填写' : (p.profile.preferences ?? []).join('、')}'),
                    ],
                    Text(
                        '归档时间：${p.archivedAt == null ? '旧记录未保存' : DateTime.tryParse(p.archivedAt!)?.toLocal().toString() ?? '未知'}'),
                    Text(p.deletionState == 'pending'
                        ? '永久删除尚未完成，人物和记忆访问保持关闭。请返回列表重试删除。'
                        : '个人记忆已停用。可通过“查看记忆”浏览概况、内容及导出。'),
                    if (p.identityState != 'missing')
                      const Text('归档时已移除声纹、录音和人脸资料。恢复不会自动启用用户或个人记忆。'),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'))
              ],
            ));
  }

  Widget _archiveCard(PersonView p) {
    final pending = p.deletionState == 'pending';
    return Card(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
          title: Text(personManagementName(p)),
          subtitle: Text(pending
              ? '永久删除未完成 · 请重试'
              : p.identityState == 'missing'
                  ? '身份资料缺失 · 点击查看说明'
                  : '资料和记忆保留 · 点击查看详情'),
          onTap: () => _archiveDetails(p)),
      Wrap(alignment: WrapAlignment.end, children: [
        if (widget.openMemory != null && !pending)
          TextButton(
              onPressed: _busy ? null : () => widget.openMemory!(p),
              child: const Text('查看记忆')),
        if (p.identityState != 'missing' && !pending)
          TextButton(
              onPressed: _busy
                  ? null
                  : () => _act(() async {
                        await widget.call(
                            method: 'POST',
                            suffix:
                                '/${Uri.encodeComponent(p.personId)}/restore?expected_revision=${p.revision}');
                        await _load();
                      }),
              child: const Text('恢复归档')),
        TextButton(
            onPressed: _busy ? null : () => _permanentDelete(p),
            child: Text(pending ? '重试永久删除' : '永久删除')),
      ]),
    ]));
  }

  Future<void> _permanentDelete(PersonView p) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('永久删除${personManagementName(p)}？'),
                content: const Text(
                    '将永久移除这份人物档案、声纹、人脸资料、个人记忆及待处理记忆任务。完成后不再显示，无法恢复。其他用户和家里的记忆不受影响；已有历史对话和独立备份不会随之删除。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('永久删除'))
                ]));
    if (confirmed != true || !mounted) return;
    await _act(() async {
      try {
        await widget.call(
            method: 'POST',
            suffix:
                '/${Uri.encodeComponent(p.personId)}/permanent-delete?expected_revision=${p.revision}');
      } finally {
        await _load();
      }
    });
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

  Future<void> _archive(PersonView p) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('归档“${p.displayName}”？'),
                content: const Text(
                    '将用户从正常列表移到归档，停止识别和个人记忆使用。姓名、资料和记忆保留；声纹、录入声音和人脸照片会移除。可以恢复归档，但恢复后仍停用，需重新录入识别档案。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('归档'))
                ]));
    if (yes != true || !mounted) return;
    await _act(() async {
      await widget.call(
          method: 'POST',
          suffix:
              '/${Uri.encodeComponent(p.personId)}/archive?expected_revision=${p.revision}');
      await _load();
    });
  }

  Future<void> _memoryDefaults() async {
    PersonMemoryDefaultsState? loaded;
    await _act(() async {
      loaded = PersonMemoryDefaultsState.fromJson(
          await widget.call(suffix: '/memory-policy'));
    });
    if (!mounted || loaded == null) return;
    final state = loaded!;
    var household = state.policy.householdMemory ?? true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('记忆设置'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SwitchListTile(
                key: const ValueKey('defaults-household'),
                title: const Text('家里的记忆'),
                subtitle: const Text('家里的事，谁说的都记下，谁问都能用；个人的事仍只记在本人名下。关闭后不再记，也不再用，已记下的保留'),
                value: household,
                onChanged: (value) => update(() => household = value),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    await _act(() async {
      try {
        await widget.call(
            method: 'PUT',
            suffix: '/memory-policy?expected_revision=${state.ownerRevision}',
            // Only the household layer is set here; the rest is the next
            // phase's (unknown voices) and goes back as it came.
            body: PersonMemoryDefaults(
              candidate: state.policy.candidate,
              prepareOnPromotion: state.policy.prepareOnPromotion,
              householdMemory: household,
            ).toJson());
      } finally {
        await _load();
      }
    });
  }

  Future<void> _setMemory(PersonView person, bool enabled) => _act(() async {
        final state = _memoryStates[person.personId];
        if (state == null || person.status != 'active') return;
        final path = '/${Uri.encodeComponent(person.personId)}';
        try {
          if (enabled && state['state'] == 'unbound') {
            await widget.call(method: 'PUT', suffix: '$path/memory-realm');
          } else {
            final action = enabled ? 'restore' : 'suspend';
            await widget.call(
                method: 'POST',
                suffix:
                    '$path/memory-realm/$action?expected_revision=${state['person_revision']}');
          }
        } finally {
          // Read authority again after success, conflicts, and uncertain outcomes.
          await _load();
        }
      });

  String _voiceStatus(PersonView person) {
    if (person.recognitionState == 'retained') return '已退出自动匹配 · 识别资料保留';
    if (_voiceCounts == null) return '状态暂不可用，请刷新';
    final count = _voiceCounts![person.personId] ?? 0;
    if (count == 0) return '未录入';
    return person.status == 'active' ? '已录入' : '已录入 · 用户已停用';
  }

  String _memoryStatus(PersonView person) {
    if (person.maturity == 'candidate') return '身份尚未确认 · 记忆不可用';
    final state = _memoryStates[person.personId]?['state'];
    if (state == null) return '状态暂不可用，请刷新';
    if (person.status != 'active') return '用户已停用 · 记忆不可用';
    return state == 'active'
        ? '已允许 · 本轮确认身份且记忆可用时使用'
        : state == 'unbound'
            ? '尚未开启'
            : '未启用 · 原有数据保留';
  }

  Future<void> _openVoiceprints(PersonView person) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => VoiceprintPage(
        personName: person.displayName,
        personId: person.personId,
        personActive: person.status == 'active',
        call: widget.voiceprints,
      ),
    ));
    if (mounted) await _refresh();
  }

  Future<void> _openFace(PersonView person) async {
    final path = '/${Uri.encodeComponent(person.personId)}/face-profile';
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => PersonFacePage(
            name: person.displayName,
            active: person.status == 'active',
            call: ({method = 'GET', suffix = '', body}) => widget.call(
                method: method, suffix: '$path$suffix', body: body))));
    if (mounted) await _refresh();
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
                    if (action == 'archive') _archive(person);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'status',
                        child: Text(person.status == 'active' ? '停用' : '启用')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                        value: 'archive',
                        child: Text('归档用户', style: TextStyle(color: Neon.bad))),
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
              subtitle: Text(_voiceStatus(person)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : () => _openVoiceprints(person),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.face_outlined, color: Neon.cyan),
              title: const Text('人脸档案'),
              subtitle: Text(!_faceStates.containsKey(person.personId)
                  ? '状态暂不可用，请刷新'
                  : _faceStates[person.personId]!
                      ? '照片已保存 · 识别尚未启用'
                      : '未添加照片 · 识别尚未启用'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : () => _openFace(person),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.psychology_outlined, color: Neon.cyan),
              title: const Text('个人记忆'),
              subtitle: Text(_memoryStatus(person)),
              trailing: Switch(
                key: ValueKey('memory-${person.personId}'),
                value: _memoryStates[person.personId]?['state'] == 'active',
                onChanged: _busy ||
                        person.maturity == 'candidate' ||
                        person.status != 'active' ||
                        !_memoryStates.containsKey(person.personId)
                    ? null
                    : (enabled) => _setMemory(person, enabled),
              ),
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
              onPressed: _busy ? null : _memoryDefaults,
              tooltip: '记忆设置',
              icon: const Icon(Icons.tune),
            ),
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
                  Text(
                      '手动创建的用户默认开启个人记忆，可随时暂停。每轮确认身份后才使用对应记忆，未识别时仍可正常对话。',
                      style: TextStyle(
                          fontSize: 14, height: 1.6, color: Neon.inkDim)),
                ],
              ),
            ),
            if (widget.openHouseholdMemory != null)
              ListTile(
                  key: const ValueKey('household-memory'),
                  leading: const Icon(Icons.home_outlined),
                  title: const Text('家里的记忆'),
                  subtitle: const Text('家里每个人说过的家里的事，谁问都能用'),
                  onTap: () => widget.openHouseholdMemory!()),
            if (_busy) ...[
              const SizedBox(height: Neon.s4),
              const LinearProgressIndicator(),
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
              if (widget.openMemory != null)
                ListTile(
                    leading: const Icon(Icons.history),
                    title: Text('管理${person.displayName}的记忆'),
                    subtitle: const Text('查看、导出或遗忘；暂停时仍可管理'),
                    onTap: () => widget.openMemory!(person)),
            ],
            if (_archiveError != null) Text(_archiveError!),
            if (_archived.any((p) => p.identityState != 'missing'))
              const SectionHeading(
                  eyebrow: 'Archive',
                  title: '已归档用户',
                  icon: Icons.archive_outlined),
            for (final person
                in _archived.where((p) => p.identityState != 'missing'))
              _archiveCard(person),
            if (_archived.any((p) => p.identityState == 'missing')) ...[
              const SectionHeading(
                  eyebrow: 'Retained memory',
                  title: '身份资料缺失的保留记忆',
                  icon: Icons.help_outline),
              const Text('旧版本删除了人物资料，只留下私人记忆。无法确认原用户身份；可查看内容或永久删除，不能直接恢复成用户。'),
            ],
            for (final person
                in _archived.where((p) => p.identityState == 'missing'))
              _archiveCard(person),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          minimum:
              const EdgeInsets.fromLTRB(Neon.s6, Neon.s3, Neon.s6, Neon.s4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
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
            NeonCta(
              child: FilledButton.icon(
                onPressed:
                    _busy || _pendingCreate != null ? null : () => _edit(),
                icon: const Icon(Icons.person_add_outlined),
                label: const Text('添加用户'),
              ),
            ),
          ]),
        ),
      );
}

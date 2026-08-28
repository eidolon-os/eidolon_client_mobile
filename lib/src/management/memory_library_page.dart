import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'memory_labels.dart';

/// The Owner-facing front door to memory.
///
/// This page deliberately separates three questions that used to be mixed in
/// the app bar: whose point of view is being shown, how the Owner wants to
/// explore it, and whether they want to govern it. Destructive governance is
/// last and named; ordinary exploration is visible in the page rather than
/// encoded as a row of unexplained icons.
class MemoryLibraryPage extends StatelessWidget {
  const MemoryLibraryPage({
    super.key,
    required this.library,
    this.onOpenRoom,
    this.onForget,
    this.onOpenToday,
    this.onExport,
    this.companions = const [],
    this.selectedCompanionId,
    this.onCompanionChanged,
    this.onOpenGraph,
    this.onSearch,
    this.onRefresh,
  });

  final MemoryLibraryView library;
  final void Function(MemoryWingView wing, MemoryRoomView room)? onOpenRoom;
  final VoidCallback? onForget;
  final VoidCallback? onOpenToday;
  final VoidCallback? onExport;
  final List<CompanionSummaryView> companions;
  final String? selectedCompanionId;
  final ValueChanged<String?>? onCompanionChanged;
  final VoidCallback? onOpenGraph;
  final VoidCallback? onSearch;
  final Future<void> Function()? onRefresh;

  String get _selectedCompanionName {
    for (final companion in companions) {
      if (companion.companionId != selectedCompanionId) continue;
      final name = (companion.displayName ?? '').trim();
      return name.isEmpty ? '当前 Eidolon' : name;
    }
    return '当前 Eidolon';
  }

  @override
  Widget build(BuildContext context) {
    final content = ListView(
      key: const Key('memory-library-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _MemoryOverview(
          library: library,
          companions: companions,
          selectedCompanionId: selectedCompanionId,
          selectedCompanionName: _selectedCompanionName,
          onCompanionChanged: onCompanionChanged,
        ),
        if (library.withheldCount > 0 || library.truncated) ...[
          const SizedBox(height: 12),
          _ReadNotice(library: library),
        ],
        if (_hasExploreActions) ...[
          const SizedBox(height: 24),
          const _SectionHeading(
            title: '浏览和理解',
            subtitle: '不用先知道它把内容放在哪里，选择你想了解的方式。',
          ),
          const SizedBox(height: 12),
          _ActionGrid(
            companionName: _selectedCompanionName,
            onSearch: onSearch,
            onOpenToday: onOpenToday,
            onOpenGraph: onOpenGraph,
            onExport: onExport,
          ),
        ],
        const SizedBox(height: 24),
        _SectionHeading(
          title: '记忆分类',
          subtitle: library.wings.isEmpty
              ? '随着你们相处，这里会逐渐形成偏好、人物、经历和计划。'
              : '按内容整理，不按数据库和内部编号展示。',
        ),
        const SizedBox(height: 12),
        if (library.wings.isEmpty)
          const _EmptyMemory()
        else
          for (final wing in library.wings) ...[
            _WingSection(wing: wing, onOpenRoom: onOpenRoom),
            const SizedBox(height: 10),
          ],
        if (onForget != null) ...[
          const SizedBox(height: 18),
          _GovernanceCard(onForget: onForget!),
        ],
      ],
    );

    return Scaffold(
      key: const Key('memory-library-page'),
      appBar: AppBar(title: const Text('你的记忆')),
      body: onRefresh == null
          ? content
          : RefreshIndicator(
              key: const Key('memory-library-refresh'),
              onRefresh: onRefresh!,
              child: content,
            ),
    );
  }

  bool get _hasExploreActions =>
      onSearch != null ||
      onOpenToday != null ||
      onOpenGraph != null ||
      onExport != null;
}

class _MemoryOverview extends StatelessWidget {
  const _MemoryOverview({
    required this.library,
    required this.companions,
    required this.selectedCompanionId,
    required this.selectedCompanionName,
    required this.onCompanionChanged,
  });

  final MemoryLibraryView library;
  final List<CompanionSummaryView> companions;
  final String? selectedCompanionId;
  final String selectedCompanionName;
  final ValueChanged<String?>? onCompanionChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selectedExists = companions.any(
      (companion) => companion.companionId == selectedCompanionId,
    );
    return Card(
      key: const Key('memory-library-overview'),
      margin: EdgeInsets.zero,
      color: colors.primaryContainer.withValues(alpha: .42),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child:
                      Icon(Icons.auto_stories_outlined, color: colors.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$selectedCompanionName 的视角',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '每位 Eidolon 都有独立的相处记忆；稳定的个人事实会在需要时共同使用。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (onCompanionChanged != null && companions.isNotEmpty) ...[
              const SizedBox(height: 18),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '正在查看',
                  prefixIcon: Icon(Icons.face_retouching_natural_outlined),
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const Key('memory-companion-selector'),
                    value: selectedExists ? selectedCompanionId : null,
                    isExpanded: true,
                    items: [
                      for (final companion in companions)
                        DropdownMenuItem(
                          value: companion.companionId,
                          child: Text(_companionName(companion)),
                        ),
                    ],
                    onChanged: onCompanionChanged,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                _Metric(value: '共 ${library.entryCount} 条', label: '可见记忆'),
                const SizedBox(width: 12),
                _Metric(value: '${library.wings.length} 个', label: '内容分类'),
                const Spacer(),
                Icon(Icons.shield_outlined, size: 18, color: colors.primary),
                const SizedBox(width: 5),
                Text('仅保存在你的主机',
                    style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _companionName(CompanionSummaryView companion) {
    final name = (companion.displayName ?? '').trim();
    return name.isEmpty ? '未命名 Eidolon' : name;
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      );
}

class _ReadNotice extends StatelessWidget {
  const _ReadNotice({required this.library});

  final MemoryLibraryView library;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (library.withheldCount > 0) '另有 ${library.withheldCount} 条没有在这个视角展开',
      if (library.withheldCount > 0) '它们可能属于其他 Eidolon，或已被设为不再提及。',
      if (library.truncated) '这次只读了一部分，下面不是全部',
    ];
    return Card(
      key: const Key('memory-library-preamble'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(line),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 3),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({
    required this.companionName,
    required this.onSearch,
    required this.onOpenToday,
    required this.onOpenGraph,
    required this.onExport,
  });

  final String companionName;
  final VoidCallback? onSearch;
  final VoidCallback? onOpenToday;
  final VoidCallback? onOpenGraph;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      if (onSearch != null)
        _ActionCard(
          key: const Key('memory-library-search'),
          icon: Icons.search,
          title: '搜索记忆',
          subtitle: '问$companionName是否记得一件事',
          onTap: onSearch!,
        ),
      if (onOpenToday != null)
        _ActionCard(
          key: const Key('memory-library-today'),
          icon: Icons.today_outlined,
          title: '最近记下',
          subtitle: '按时间查看最近形成的记录',
          onTap: onOpenToday!,
        ),
      if (onOpenGraph != null)
        _ActionCard(
          key: const Key('memory-library-graph'),
          icon: Icons.hub_outlined,
          title: '关系图谱',
          subtitle: '查看人物、地点和偏好的联系',
          onTap: onOpenGraph!,
        ),
      if (onExport != null)
        _ActionCard(
          key: const Key('memory-library-export'),
          icon: Icons.content_copy_outlined,
          title: '完整副本',
          subtitle: '查看并复制你拥有的完整记录',
          onTap: onExport!,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        final twoColumns = constraints.maxWidth >= 330;
        final width = twoColumns
            ? (constraints.maxWidth - gap) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final action in actions) SizedBox(width: width, child: action),
          ],
        );
      },
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 132),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: colors.primary),
                const SizedBox(height: 12),
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyMemory extends StatelessWidget {
  const _EmptyMemory();

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('memory-library-empty'),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Column(
          children: [
            Icon(Icons.book_outlined, size: 34),
            SizedBox(height: 10),
            Text('还没有记下什么'),
            SizedBox(height: 4),
            Text('和它聊聊，或者直接说“请记住……”。'),
          ],
        ),
      );
}

class _WingSection extends StatelessWidget {
  const _WingSection({required this.wing, required this.onOpenRoom});

  final MemoryWingView wing;
  final void Function(MemoryWingView wing, MemoryRoomView room)? onOpenRoom;

  @override
  Widget build(BuildContext context) {
    final name = (wing.displayName ?? '').trim().isNotEmpty
        ? wing.displayName!.trim()
        : '其他';
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: Key('memory-wing-${wing.wingId}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(_wingIcon(wing.wingId), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: Theme.of(context).textTheme.titleMedium),
                      if (_wingDescription(wing).isNotEmpty)
                        Text(
                          _wingDescription(wing),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text('${wing.entryCount} 条'),
                ),
              ],
            ),
            if (wing.rooms.isNotEmpty) const SizedBox(height: 8),
            for (final room in wing.rooms)
              _RoomRow(wing: wing, room: room, onOpen: onOpenRoom),
          ],
        ),
      ),
    );
  }

  static IconData _wingIcon(String wingId) {
    final id = wingId.toLowerCase();
    if (id.contains('profile') || id.contains('identity')) {
      return Icons.person_outline;
    }
    if (id.contains('life') || id.contains('preference')) {
      return Icons.favorite_border;
    }
    if (id.contains('project') || id.contains('work')) {
      return Icons.flag_outlined;
    }
    if (id.contains('knowledge') || id.contains('fact')) {
      return Icons.lightbulb_outline;
    }
    if (id.contains('privacy')) return Icons.visibility_off_outlined;
    return Icons.bookmark_outline;
  }

  static String _wingDescription(MemoryWingView wing) {
    switch (wing.wingId) {
      case 'Wing_Profile':
        return '关于你的背景、身份和重要价值观';
      case 'Wing_Interaction':
        return '你希望它如何称呼、理解和陪伴你';
      case 'Wing_Relationship':
        return '重要的人，以及你们长期的关系状态';
      case 'Wing_Emotion':
        return '情绪变化、压力来源和安全感';
      case 'Wing_Future':
        return '你想实现的目标和未来计划';
      case 'Wing_Event':
        return '带有时间和场景的一段经历';
      case 'Wing_Work':
        return '项目、学习、任务与职业进展';
      case 'Wing_Life':
        return '作息、饮食、兴趣和生活习惯';
      case 'Wing_Health':
        return '睡眠、运动、健康与治疗信息';
      case 'Wing_Theme':
        return '从多段经历中逐渐形成的长期主题';
      default:
        return (wing.description ?? '').trim();
    }
  }
}

class _RoomRow extends StatelessWidget {
  const _RoomRow({
    required this.wing,
    required this.room,
    required this.onOpen,
  });

  final MemoryWingView wing;
  final MemoryRoomView room;
  final void Function(MemoryWingView wing, MemoryRoomView room)? onOpen;

  @override
  Widget build(BuildContext context) {
    final titles = room.titles;
    return ListTile(
      key: Key('memory-room-${wing.wingId}-${room.roomId}'),
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 8,
      title: Text(memoryRoomLabel(room.roomId)),
      subtitle: titles.isEmpty
          ? const Text('这一组还没有可预览的内容')
          : Text(
              room.more ? '${titles.join('、')} 等' : titles.join('、'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${room.entryCount}',
              style: Theme.of(context).textTheme.bodySmall),
          if (onOpen != null) const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onOpen == null ? null : () => onOpen!(wing, room),
    );
  }
}

class _GovernanceCard extends StatelessWidget {
  const _GovernanceCard({required this.onForget});

  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const Key('memory-library-governance'),
      margin: EdgeInsets.zero,
      color: colors.errorContainer.withValues(alpha: .38),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const Key('memory-library-forget'),
        onTap: onForget,
        leading: Icon(Icons.delete_sweep_outlined, color: colors.error),
        title: const Text('纠正或忘记'),
        subtitle: const Text('先预览会影响哪些记忆，再由你确认处理。'),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

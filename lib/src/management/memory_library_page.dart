import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';
import 'memory_labels.dart';

/// The Owner-facing front door to memory.
///
/// This page deliberately separates three questions that used to be mixed in
/// the app bar: whose point of view is being shown, how the Owner wants to
/// explore it, and whether they need the correction fallback. Ordinary
/// exploration is visible in the page rather than encoded as a row of
/// unexplained icons; manual deletion is not part of the normal workflow.
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
    this.refreshError,
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

  /// A refresh that failed while this page was on screen. What is shown below
  /// it is the last answer the Host gave, and the page says so.
  final Object? refreshError;

  /// The selected Companion's name, or null for the Owner's own memory.
  String? get _selectedCompanionName {
    final selected = selectedCompanionId;
    if (selected == null) return null;
    for (final companion in companions) {
      if (companion.companionId != selected) continue;
      final name = (companion.displayName ?? '').trim();
      return name.isEmpty ? '这个伙伴' : name;
    }
    return '这个伙伴';
  }

  @override
  Widget build(BuildContext context) {
    final content = ListView(
      key: const Key('memory-library-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        if (refreshError != null) ...[
          Card(
            key: const Key('memory-library-refresh-error'),
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.sync_problem_outlined),
              title: Text(
                '没能刷新：${refusalText(refreshError!, subject: '它记住的')}',
              ),
              subtitle: const Text('下面是上一次读到的内容'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        _MemoryOverview(
          library: library,
          companions: companions,
          selectedCompanionId: selectedCompanionId,
          selectedCompanionName: _selectedCompanionName,
          onCompanionChanged: onCompanionChanged,
        ),
        if (library.withheldCount > 0 || library.truncated) ...[
          const SizedBox(height: 12),
          _ReadNotice(
            library: library,
            ownerView: selectedCompanionId == null,
          ),
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
          _MemoryCorrectionFallback(onForget: onForget!),
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
  final String? selectedCompanionName;
  final ValueChanged<String?>? onCompanionChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = selectedCompanionName;
    return Card(
      key: const Key('memory-library-overview'),
      margin: EdgeInsets.zero,
      color: colors.primaryContainer.withValues(alpha: .42),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
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
                  child: Icon(
                    Icons.auto_stories_outlined,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name == null ? '你的全部记忆' : '$name能想起的',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        key: const Key('memory-library-scope'),
                        name == null
                            ? '你的每个伙伴记下的，都在这里'
                            : '你们共享的，加上只告诉$name的',
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
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    key: const Key('memory-companion-selector'),
                    value: companions.any(
                      (companion) => companion.companionId == selectedCompanionId,
                    )
                        ? selectedCompanionId
                        : null,
                    isExpanded: true,
                    items: [
                      // The Owner's own view, always reachable: choosing one
                      // Companion used to be a one-way door.
                      const DropdownMenuItem<String?>(
                        key: Key('memory-companion-all'),
                        value: null,
                        child: Text('全部记忆'),
                      ),
                      for (final companion in companions)
                        DropdownMenuItem<String?>(
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
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _Metric(value: '共 ${library.entryCount} 条', label: '可见记忆'),
                _Metric(value: '${library.wings.length} 个', label: '内容分类'),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.shield_outlined, size: 18, color: colors.primary),
                  const SizedBox(width: 5),
                  Text('仅保存在你的主机',
                      style: Theme.of(context).textTheme.labelMedium),
                ]),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _companionName(CompanionSummaryView companion) {
    final name = (companion.displayName ?? '').trim();
    return name.isEmpty ? '未命名伙伴' : name;
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
  const _ReadNotice({required this.library, required this.ownerView});

  final MemoryLibraryView library;
  final bool ownerView;

  @override
  Widget build(BuildContext context) {
    final withheld = library.withheldCount;
    final lines = <String>[
      // In the Owner's own view every Companion's memory is shown, so what is
      // held back is only what was set aside — never "another Eidolon's".
      if (withheld > 0 && ownerView) '另有 $withheld 条你要求不再提起的，没有展开',
      if (withheld > 0 && !ownerView) '另有 $withheld 条没有在这里展开：它不知道，或你要求不再提起',
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

  final String? companionName;
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
          subtitle: companionName == null
              ? '看看你的记忆里有没有一件事'
              : '问$companionName是否记得一件事',
          onTap: onSearch!,
        ),
      if (onOpenToday != null)
        _ActionCard(
          key: const Key('memory-library-today'),
          icon: Icons.today_outlined,
          title: '记忆时间线',
          subtitle: '按日期浏览，查看原话和记下的时间',
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
            Text('在日常对话里自然分享就好，伙伴会在后台自动整理。'),
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
                      Text(
                        name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
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
          Text(
            '${room.entryCount}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (onOpen != null) const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onOpen == null ? null : () => onOpen!(wing, room),
    );
  }
}

class _MemoryCorrectionFallback extends StatelessWidget {
  const _MemoryCorrectionFallback({required this.onForget});

  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('memory-library-governance'),
      child: ListTile(
        key: const Key('memory-library-forget'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        onTap: onForget,
        leading: const Icon(Icons.shield_outlined),
        title: const Text('让它忘掉一件事'),
        subtitle: const Text('内容不准确或涉及隐私时使用；忘掉后不能恢复。日常记忆由伙伴自动整理。'),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

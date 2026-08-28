import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import '../protocol/companion_contract.dart';

/// Every partner this Owner has, on one screen.
///
/// This is the collection and management surface. Home only summarizes the
/// collection, while opening a row goes to the one place about that partner.
///
/// Three things this page deliberately does not do:
///
/// - It does not decide which Eidolon is the default. The page it was handed
///   says so once, and this widget compares identifiers against it. A per-row
///   flag would let two rows both claim it, and then something here would have
///   to adjudicate.
/// - It does not hide an archived Eidolon. The Owner archived it; that is a
///   state worth seeing, and dropping the row would leave a person no way to
///   find out what became of it.
/// - It does not show an identifier where a name should be. An unnamed Eidolon
///   gets a placeholder, because `companion-b` is not what anyone called it.
class CompanionRosterPage extends StatelessWidget {
  const CompanionRosterPage({
    super.key,
    required this.roster,
    this.onOpen,
    this.onLoadMore,
    this.onMakeDefault,
    this.busyCompanionId,
    this.refusal,
    this.onAdd,
    this.notice,
  });

  final CompanionRosterView roster;

  /// Opening one is a later slice; null while nothing is behind the tap.
  final void Function(CompanionSummaryView companion)? onOpen;

  /// Non-null only when the Host said there is another page.
  final VoidCallback? onLoadMore;

  /// Offered only when this Host says it can change the default at all.
  ///
  /// Null hides the action rather than disabling it: a control that is visible
  /// but dead is a promise the Host has not made.
  final void Function(CompanionSummaryView companion)? onMakeDefault;

  /// The row whose change is in flight, if any.
  final String? busyCompanionId;

  /// Offered only when this Host says it can create one at all.
  final VoidCallback? onAdd;

  /// Something that happened and is worth keeping on screen — an Eidolon added,
  /// or its memory still starting. Not a snackbar: "记忆还在启动" is a state a
  /// person may want to read twice.
  final String? notice;

  /// What the Host said when it refused the last attempt.
  ///
  /// Shown in the list rather than as a transient message, because the reason
  /// matters: "someone else changed this" means look again, and a person who
  /// missed a snackbar would just try the same thing.
  final String? refusal;

  @override
  Widget build(BuildContext context) {
    final rows = roster.companions;
    final refusalText = refusal;
    return Scaffold(
      key: const Key('companion-roster-page'),
      appBar: AppBar(title: const Text('你的伙伴')),
      body: Column(
        children: [
          if (refusalText != null)
            MaterialBanner(
              key: const Key('roster-refusal'),
              content: Text(refusalText),
              actions: const [SizedBox.shrink()],
            ),
          if (notice != null)
            MaterialBanner(
              key: const Key('roster-notice'),
              content: Text(notice!),
              actions: const [SizedBox.shrink()],
            ),
          _RosterSummary(roster: roster, onAdd: onAdd),
          Expanded(child: _list(rows)),
        ],
      ),
    );
  }

  Widget _list(List<CompanionSummaryView> rows) {
    return rows.isEmpty
        ? Center(
            key: Key('roster-empty'),
            // Said plainly rather than as an error. An Owner with none is a
            // real state, and it is not the same as a Host that could not
            // answer — that case never reaches this widget.
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.group_add_outlined, size: 40),
                  SizedBox(height: 12),
                  Text('这里还没有伙伴'),
                  SizedBox(height: 6),
                  Text('新建后，你可以在这里查看状态和选择默认应答伙伴。'),
                ],
              ),
            ),
          )
        : ListView.separated(
            key: const Key('roster-list'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: rows.length + (onLoadMore == null ? 0 : 1),
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              if (index == rows.length) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton(
                    key: const Key('roster-load-more'),
                    onPressed: onLoadMore,
                    child: const Text('看更多'),
                  ),
                );
              }
              final companion = rows[index];
              return _RosterRow(
                companion: companion,
                isDefault: companion.companionId == roster.defaultCompanionId,
                onOpen: onOpen,
                onMakeDefault: onMakeDefault,
                busy: busyCompanionId == companion.companionId,
                runtimeUnavailable: roster.runtimeUnavailable,
              );
            },
          );
  }
}

class _RosterSummary extends StatelessWidget {
  const _RosterSummary({required this.roster, required this.onAdd});

  final CompanionRosterView roster;
  final VoidCallback? onAdd;

  String get _defaultLine {
    final defaultId = roster.defaultCompanionId;
    if (defaultId == null) return '还没有设置默认应答伙伴';
    for (final companion in roster.companions) {
      if (companion.companionId != defaultId) continue;
      final name = (companion.displayName ?? '').trim();
      return '默认应答：${name.isEmpty ? '未命名伙伴' : name}';
    }
    return '默认应答伙伴在尚未加载的列表中';
  }

  String get _attentionLine {
    final unavailable = roster.runtimeUnavailable ?? '';
    if (unavailable.isNotEmpty) return '运行状态暂时无法读取';
    final attention = roster.companions
        .where(
          (row) => isCompanionActive(row.lifecycleState) && row.running != true,
        )
        .length;
    if (attention == 0) return '当前没有需要关注的运行状态';
    return '$attention 位伙伴需要关注运行状态';
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  roster.nextCursor == null
                      ? '共 ${roster.companions.length} 位伙伴'
                      : '已显示 ${roster.companions.length} 位伙伴',
                  key: const Key('roster-count'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(_defaultLine, key: const Key('roster-default-summary')),
                const SizedBox(height: 2),
                Text(
                  _attentionLine,
                  key: const Key('roster-attention-summary'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (onAdd != null) ...[
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    key: const Key('roster-add'),
                    onPressed: onAdd,
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: const Text('新建伙伴'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}

class _RosterRow extends StatelessWidget {
  const _RosterRow({
    required this.companion,
    required this.isDefault,
    required this.onOpen,
    required this.onMakeDefault,
    required this.busy,
    required this.runtimeUnavailable,
  });

  final CompanionSummaryView companion;
  final bool isDefault;
  final void Function(CompanionSummaryView companion)? onOpen;
  final void Function(CompanionSummaryView companion)? onMakeDefault;
  final bool busy;
  final String? runtimeUnavailable;

  /// Offered on a row that is not already the default and is not on its way
  /// out. Whether it is *allowed* stays the Host's answer — a guard is refused
  /// there, and duplicating that rule here is how two clients come to disagree
  /// about it.
  bool get _offerDefault =>
      onMakeDefault != null &&
      !isDefault &&
      isCompanionActive(companion.lifecycleState);

  @override
  Widget build(BuildContext context) {
    final name = (companion.displayName ?? '').isNotEmpty
        ? companion.displayName!
        : '还没有名字的 Eidolon';
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: Key('roster-row-${companion.companionId}'),
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        leading: const CircleAvatar(child: Icon(Icons.face_retouching_natural)),
        title: Text(name, overflow: TextOverflow.ellipsis),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (isDefault)
                const Chip(
                  key: Key('roster-default-badge'),
                  label: Text('默认应答'),
                  visualDensity: VisualDensity.compact,
                ),
              Chip(
                key: Key('roster-state-${companion.companionId}'),
                label: Text(_stateLabel),
                visualDensity: VisualDensity.compact,
              ),
              Text(_stateSentence),
            ],
          ),
        ),
        trailing: _trailing(),
        onTap: onOpen == null ? null : () => onOpen!(companion),
      ),
    );
  }

  String get _stateLabel {
    if (!isCompanionActive(companion.lifecycleState)) {
      return companionLifecycleLabel(companion.lifecycleState);
    }
    return switch (companion.running) {
      true => '运行中',
      false => '未运行',
      null => '状态未知',
    };
  }

  String get _stateSentence {
    if (!isCompanionActive(companion.lifecycleState)) {
      return companionLifecycleSentence(companion.lifecycleState);
    }
    return switch (companion.running) {
      true => '现在可以应答',
      false => '当前没有运行',
      null when (runtimeUnavailable ?? '').isNotEmpty => '运行状态暂时无法读取',
      null => '还没有读到运行状态',
    };
  }

  Widget? _trailing() {
    if (busy) {
      return const SizedBox(
        key: Key('roster-row-busy'),
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_offerDefault) {
      return TextButton(
        key: Key('roster-make-default-${companion.companionId}'),
        onPressed: () => onMakeDefault!(companion),
        child: const Text('设为默认'),
      );
    }
    return onOpen == null ? null : const Icon(Icons.chevron_right);
  }
}

/// What a state means to the person, not what the column says.
///

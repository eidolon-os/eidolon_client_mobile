import 'package:flutter/material.dart';

import '../generated/management_v1.dart';

/// Everything this Owner has, on one screen.
///
/// Until now the app could show exactly one Eidolon: the workspace runtime
/// answered with "the primary Companion" and the page was built around that
/// single thing. A person with two of them had no way to see the second, and no
/// way to tell which one the Host would use.
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
      appBar: AppBar(title: const Text('你的 Eidolon')),
      body: refusalText == null ? _list(rows) : Column(
        children: [
          MaterialBanner(
            key: const Key('roster-refusal'),
            content: Text(refusalText),
            actions: const [SizedBox.shrink()],
          ),
          Expanded(child: _list(rows)),
        ],
      ),
    );
  }

  Widget _list(List<CompanionSummaryView> rows) {
    return rows.isEmpty
          ? const Center(
              key: Key('roster-empty'),
              // Said plainly rather than as an error. An Owner with none is a
              // real state, and it is not the same as a Host that could not
              // answer — that case never reaches this widget.
              child: Text('这里还没有 Eidolon'),
            )
          : ListView.separated(
              key: const Key('roster-list'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: rows.length + (onLoadMore == null ? 0 : 1),
              separatorBuilder: (_, __) => const Divider(height: 1),
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
                );
              },
            );
  }
}

class _RosterRow extends StatelessWidget {
  const _RosterRow({
    required this.companion,
    required this.isDefault,
    required this.onOpen,
    required this.onMakeDefault,
    required this.busy,
  });

  final CompanionSummaryView companion;
  final bool isDefault;
  final void Function(CompanionSummaryView companion)? onOpen;
  final void Function(CompanionSummaryView companion)? onMakeDefault;
  final bool busy;

  /// Offered on a row that is not already the default and is not on its way
  /// out. Whether it is *allowed* stays the Host's answer — a guard is refused
  /// there, and duplicating that rule here is how two clients come to disagree
  /// about it.
  bool get _offerDefault =>
      onMakeDefault != null &&
      !isDefault &&
      companion.lifecycleState == 'active';

  @override
  Widget build(BuildContext context) {
    final name = (companion.displayName ?? '').isNotEmpty
        ? companion.displayName!
        : '还没有名字的 Eidolon';
    return ListTile(
      key: Key('roster-row-${companion.companionId}'),
      leading: const CircleAvatar(child: Icon(Icons.face_retouching_natural)),
      title: Row(
        children: [
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
          if (isDefault)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Chip(
                key: Key('roster-default-badge'),
                label: Text('默认'),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
      subtitle: Text(_lifecycleSentence(companion.lifecycleState)),
      trailing: _trailing(),
      onTap: onOpen == null ? null : () => onOpen!(companion),
    );
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
/// A value this app has never seen is described as unknown rather than shown
/// raw or treated as active: the Host is entitled to grow this set, and a row
/// must stay readable when it does.
String _lifecycleSentence(String lifecycleState) {
  switch (lifecycleState) {
    case 'active':
      return '在这台 Host 上运行';
    case 'retiring':
      return '正在退出，暂时还在';
    case 'archived':
      return '你已归档，记忆还留着';
    case 'deleting':
      return '正在删除';
    default:
      return '这台 Host 说的状态，这个版本还不认识';
  }
}

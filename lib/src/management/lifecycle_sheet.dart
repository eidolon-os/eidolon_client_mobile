import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';

/// 收起来 / 让它回来 — putting an Eidolon away, and bringing it back.
///
/// Nothing here is deletion, and the sheet never borrows deletion's language.
/// Putting one away stops new conversations from reaching it and keeps
/// everything it remembers, exactly as it was; bringing it back is the same
/// gesture with the other word. So there is no red button, no "确定要删除吗",
/// and the way back is named on the way out.
///
/// **The rule about who answers lives on the Host, not in here.** This sheet
/// does not know that the Eidolon which answers unaddressed messages needs a
/// successor before it can be put away. It asks, and if the Host comes back
/// with `default_replacement_required` — a refusal that is really a question —
/// it turns that into the question a person can answer, and asks again with
/// their answer. A client that encoded the rule itself would be a second copy
/// of it, wrong the day the Host's changed.
///
/// The other named refusal it can act on is `last_active_companion`: there is
/// nobody else, and putting this one away would leave someone with an Eidolon
/// that cannot answer at all. That is not an error to retry — it is a thing to
/// say plainly, with what to do instead.
class CompanionLifecycleSheet extends StatefulWidget {
  const CompanionLifecycleSheet({
    super.key,
    required this.companion,
    required this.others,
    required this.setLifecycle,
  });

  /// The Eidolon this sheet is about, as the detail read described it.
  final CompanionDetailView companion;

  /// This Owner's other Eidolons, for the successor question. Only ones that
  /// can actually take the role are offered — the Host would refuse the rest,
  /// and offering a choice that gets refused is worse than not offering it.
  final List<CompanionSummaryView> others;

  /// Performs the change. A null replacement is the first ask; the sheet only
  /// names one after the Host has said it needs one.
  final Future<CompanionLifecycleView> Function(
    String lifecycleState,
    String? replacementCompanionId,
  ) setLifecycle;

  @override
  State<CompanionLifecycleSheet> createState() =>
      _CompanionLifecycleSheetState();
}

class _CompanionLifecycleSheetState extends State<CompanionLifecycleSheet> {
  bool _busy = false;
  Object? _error;

  /// True once the Host has said this is the Eidolon that answers, so the sheet
  /// is showing the successor question rather than the confirmation.
  bool _needsSuccessor = false;

  /// Set when the Host says there is nobody else. A statement, not a retry.
  String? _blocked;

  bool get _archiving => widget.companion.lifecycleState == 'active';

  Future<void> _ask({String? replacementCompanionId}) async {
    setState(() {
      _busy = true;
      _error = null;
      _blocked = null;
    });
    try {
      final view = await widget.setLifecycle(
        _archiving ? 'archived' : 'active',
        replacementCompanionId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(view);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (error is ManagementRequestException) {
          switch (error.code) {
            // The refusal that is a question. Asked, not guessed at.
            case 'default_replacement_required':
              _needsSuccessor = true;
              return;
            case 'last_active_companion':
              _blocked = '这是你现在唯一还在的 Eidolon。先添一个新的，再把它收起来。';
              return;
            case 'default_replacement_ineligible':
              _blocked = '那位现在接不了。换一位，或者先让它回来。';
              return;
          }
        }
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.companion.displayName?.isNotEmpty == true
        ? widget.companion.displayName!
        : '这个 Eidolon';
    return SafeArea(
      key: const Key('companion-lifecycle-sheet'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _needsSuccessor
                  ? '现在是 $name 在回答你'
                  : (_archiving ? '把 $name 收起来' : '让 $name 回来'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Text(
              _needsSuccessor
                  ? '收起来之后，没有指名的话该由谁来回答？'
                  : (_archiving
                      // Said in full, because this is the moment someone is
                      // deciding whether it is safe to press.
                      // The device sentence belongs here rather than only in
                      // the answer afterwards: it is the part that changes
                      // whether someone presses at all.
                      ? '它不会再开始新的对话，正在由它应答的设备会先空下来。'
                        '它记得的一切都留着，随时可以让它回来。'
                      : '它可以再开始新的对话了。设备和默认回答都还是你之前定的。'),
            ),
            if (_blocked != null) ...[
              const SizedBox(height: 14),
              Text(
                _blocked!,
                key: const Key('lifecycle-blocked'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                '$_error',
                key: const Key('lifecycle-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 18),
            if (_needsSuccessor)
              ..._successors()
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('lifecycle-cancel'),
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('先不'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('lifecycle-confirm'),
                    onPressed: _busy || _blocked != null ? null : () => _ask(),
                    child: Text(_archiving ? '收起来' : '让它回来'),
                  ),
                ],
              ),
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(key: Key('lifecycle-busy')),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _successors() {
    if (widget.others.isEmpty) {
      // The Host would refuse this, and it is kinder to say so than to show an
      // empty list with a button under it.
      return [
        const Text(
          key: Key('lifecycle-no-successor'),
          '没有别的 Eidolon 可以接替。先添一个新的，再把它收起来。',
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: _CloseButton(),
        ),
      ];
    }
    return [
      for (final other in widget.others)
        ListTile(
          key: Key('lifecycle-successor-${other.companionId}'),
          contentPadding: EdgeInsets.zero,
          leading: const CircleAvatar(child: Icon(Icons.face_retouching_natural)),
          title: Text(
            other.displayName?.isNotEmpty == true
                ? other.displayName!
                : other.companionId,
          ),
          onTap: _busy
              ? null
              : () => _ask(replacementCompanionId: other.companionId),
        ),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerRight, child: _CloseButton()),
    ];
  }
}

class _CloseButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) => TextButton(
        key: const Key('lifecycle-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('先不'),
      );
}

import 'package:flutter/material.dart';

import 'persona_history_models.dart';

/// What this Eidolon has been, and the way back to any of it.
///
/// There is nothing to approve here. An Eidolon changes on its own; what the
/// person living with it needs is to see that it did, and to be able to say
/// no afterwards — which is how it goes between people, and unlike an approval
/// queue it asks nothing of someone who has no basis to judge a personality
/// diff. Reading is the point; going back is the recourse.
class PersonaHistoryPage extends StatefulWidget {
  const PersonaHistoryPage({
    super.key,
    required this.companionName,
    required this.loadHistory,
    required this.restore,
  });

  final String companionName;
  final Future<PersonaHistory> Function() loadHistory;
  final Future<PersonaHistory> Function(String chapterId) restore;

  @override
  State<PersonaHistoryPage> createState() => _PersonaHistoryPageState();
}

class _PersonaHistoryPageState extends State<PersonaHistoryPage> {
  PersonaHistory? _history;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final history = await widget.loadHistory();
      if (!mounted) return;
      setState(() => _history = history);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRestore(PersonaChapter chapter) async {
    final chapters = _history?.chapters ?? const <PersonaChapter>[];
    final since = chapters
        .where((value) => value.changedAt.isAfter(chapter.changedAt))
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('confirm-persona-restore'),
        title: Text('让${widget.companionName}回到那时候？'),
        content: Text(
          since == 0
              ? '它会回到 ${_day(chapter.changedAt)} 的样子。'
              : '它会回到 ${_day(chapter.changedAt)} 的样子，'
                  '这之后的 $since 次变化不再生效。'
                  '这些记录不会消失，你随时可以再回到其中任何一次。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-persona-restore-action'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('回到那时候'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final history = await widget.restore(chapter.chapterId);
      if (!mounted) return;
      setState(() => _history = history);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = _history;
    return Scaffold(
      key: const Key('persona-history-page'),
      appBar: AppBar(
        title: Text('${widget.companionName}的变化'),
        actions: [
          IconButton(
            key: const Key('refresh-persona-history'),
            onPressed: _busy ? null : _load,
            tooltip: '刷新',
            icon: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.auto_awesome_outlined),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '它会随着相处慢慢变化，不需要你批准。'
                      '这里是它变成过的样子；如果某次变化你不喜欢，可以让它回到之前。',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(error, key: const Key('persona-history-error')),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (history == null && _error != null)
            const SizedBox.shrink()
          else if (history == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ),
            )
          else if (history.chapters.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('还没有记录。', key: Key('persona-history-empty')),
              ),
            )
          else
            ...history.chapters.map(
              (chapter) => _ChapterCard(
                chapter: chapter,
                // The oldest entry is not a change, it is where it started.
                // Whatever was recorded there is a creation note written by
                // whatever created it, and reading it out as "what changed"
                // would be showing machinery again.
                isBeginning: chapter == history.chapters.last,
                onRestore: _busy || chapter.isCurrent
                    ? null
                    : () => _confirmRestore(chapter),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChapterCard extends StatelessWidget {
  const _ChapterCard({
    required this.chapter,
    required this.isBeginning,
    required this.onRestore,
  });

  final PersonaChapter chapter;
  final bool isBeginning;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final restored = chapter.restoredFrom;
    return Card(
      key: Key('persona-chapter-${chapter.chapterId}'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _day(chapter.changedAt),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 10),
                if (chapter.isCurrent) const Chip(label: Text('现在的它')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              // Nothing was recorded, and nothing is put in its place. Saying
              // "personality updated" would be this screen inventing a reason
              // on its behalf, which is worse than admitting the gap.
              isBeginning
                  ? '它刚来的时候'
                  : chapter.whatChanged.isNotEmpty
                      ? chapter.whatChanged
                      : restored != null
                          ? '回到了更早的样子'
                          : '这次变化没有留下说明',
              style: !isBeginning && chapter.whatChanged.isEmpty
                  ? Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      )
                  : null,
            ),
            if (onRestore != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: Key('restore-persona-${chapter.chapterId}'),
                  onPressed: onRestore,
                  icon: const Icon(Icons.history),
                  label: const Text('回到那时候'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _day(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';

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
  final Future<PersonaHistoryView> Function() loadHistory;
  final Future<PersonaHistoryView> Function(String chapterId) restore;

  @override
  State<PersonaHistoryPage> createState() => _PersonaHistoryPageState();
}

class _PersonaHistoryPageState extends State<PersonaHistoryPage> {
  PersonaHistoryView? _history;
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

  Future<void> _confirmRestore(PersonaChapterView chapter) async {
    final chapters = _history?.chapters ?? const <PersonaChapterView>[];
    final moment = _moment(chapter.changedAt);
    // Counted over the chapters this phone can place in time. One it cannot read
    // is left out of the count rather than assumed to be after or before: a
    // sentence that said "the 3 changes since then" when it meant 4 would be
    // worse than one that says 3 of the changes it is sure about.
    final since = moment == null
        ? 0
        : chapters
            .where((value) {
              final other = _moment(value.changedAt);
              return other != null && other.isAfter(moment);
            })
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.auto_awesome_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    // Written to be true now and true later. It says what
                    // happens when it changes, not that it is changing —
                    // because today nothing in the runtime proposes an
                    // evolution, and a page promising growth that is not
                    // happening is worse than a page that waits for it.
                    child: Text(
                      '它变化的时候不需要你批准。'
                      '这里是它变成过的样子；如果某次变化你不喜欢，可以让它回到之前。'
                      '${_stillTheSame(history) ? '\n\n目前它还是刚来时的样子。' : ''}',
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
                onRestore: _busy || (chapter.isCurrent ?? false)
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

  final PersonaChapterView chapter;
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
                if (chapter.isCurrent ?? false)
                  const Chip(label: Text('现在的它')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              // Nothing was recorded, and nothing is put in its place. Saying
              // "personality updated" would be this screen inventing a reason
              // on its behalf, which is worse than admitting the gap.
              isBeginning
                  ? '它刚来的时候'
                  : (chapter.whatChanged ?? '').isNotEmpty
                      ? chapter.whatChanged!
                      : restored != null
                          ? '回到了更早的样子'
                          : '这次变化没有留下说明',
              style: !isBeginning && (chapter.whatChanged ?? '').isEmpty
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

/// Whether this Eidolon has only ever been one thing.
bool _stillTheSame(PersonaHistoryView? history) =>
    history != null && history.chapters.length == 1;

/// The instant a chapter carries, when this phone can read it.
///
/// The wire carries a string. Parsed here rather than in a hand-written model,
/// because placing a chapter in time is what this screen does with it — order
/// the list, and count what came after.
DateTime? _moment(String value) => DateTime.tryParse(value);

/// The day, as a person reads it.
///
/// An unreadable value is shown as it arrived rather than hidden: here the date
/// is how someone recognises which chapter this is, so dropping it would leave a
/// row they cannot identify.
String _day(String value) {
  final parsed = _moment(value);
  if (parsed == null) return value;
  final local = parsed.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

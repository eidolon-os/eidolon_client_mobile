import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'memory_labels.dart';

/// 今日：what it wrote down today, newest first.
///
/// The library answers "what do you have"; this answers "what happened", which
/// is the question someone asks daily rather than once. It is also the page most
/// able to look right while being wrong, because a person cannot tell a missing
/// entry from an entry that was never recorded — so what it does not claim
/// matters more here than what it shows:
///
/// - **The window is stated.** A list with no window cannot be told apart from
///   an answer to a different question.
/// - **"More in this page" and "the Host stopped reading" are separate.**
///   Asking again helps with the first and not the second, and a person
///   deserves to know which.
/// - **Entries with no usable time are counted, not hidden.** Someone whose
///   entry never appears in any day should be able to learn that this is why.
class MemoryDayPage extends StatelessWidget {
  const MemoryDayPage({
    super.key,
    required this.day,
    required this.dayStartedAt,
    this.onLoadMore,
    this.onChooseAudience,
  });

  final MemoryDayView day;

  /// The local instant this page asked about, for saying so in the person's own
  /// terms. The wire carries an offset; a person reads a time of day.
  final DateTime dayStartedAt;

  /// Non-null only when the Host said the page ended inside the window.
  final VoidCallback? onLoadMore;

  /// Offered per entry: keep this one between me and a single Eidolon. Null
  /// hides the control rather than disabling it — a Host that cannot publish
  /// memory writes has not promised this.
  final void Function(MemoryEntryView entry)? onChooseAudience;

  @override
  Widget build(BuildContext context) {
    final entries = day.entries;
    return Scaffold(
      key: const Key('memory-day-page'),
      appBar: AppBar(title: const Text('今天记下的')),
      body: entries.isEmpty
          ? Center(
              key: const Key('memory-day-empty'),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // A quiet day is a real answer and a common one, so it is
                    // said plainly rather than drawn as an error.
                    const Text('这段时间没有记下什么'),
                    if (day.undatedCount > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        _undatedSentence(day.undatedCount),
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            )
          : ListView.separated(
              key: const Key('memory-day-list'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length + 1 + (onLoadMore == null ? 0 : 1),
              separatorBuilder: (_, index) => index == 0
                  ? const SizedBox.shrink()
                  : const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _Preamble(day: day, dayStartedAt: dayStartedAt);
                }
                if (index == entries.length + 1) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton(
                      key: const Key('memory-day-load-more'),
                      onPressed: onLoadMore,
                      child: const Text('看更早的'),
                    ),
                  );
                }
                final entry = entries[index - 1];
                return _EntryRow(
                  entry: entry,
                  onChooseAudience: onChooseAudience == null
                      ? null
                      : () => onChooseAudience!(entry),
                );
              },
            ),
    );
  }
}

class _Preamble extends StatelessWidget {
  const _Preamble({required this.day, required this.dayStartedAt});

  final MemoryDayView day;
  final DateTime dayStartedAt;

  @override
  Widget build(BuildContext context) {
    final local = dayStartedAt.toLocal();
    final lines = <String>[
      '从 ${_clock(local)} 起，记下 ${day.entryCount} 条',
      if (day.undatedCount > 0) _undatedSentence(day.undatedCount),
      // Two different partial answers. Only one of them is fixed by asking
      // again, so they are never merged into one sentence.
      if (day.truncated) '这次没有读完全部记忆，可能漏了更早的',
    ];
    return Padding(
      key: const Key('memory-day-preamble'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, this.onChooseAudience});

  final MemoryEntryView entry;
  final VoidCallback? onChooseAudience;

  @override
  Widget build(BuildContext context) {
    final when = DateTime.tryParse(entry.recordedAt)?.toLocal();
    return ListTile(
      key: Key('memory-day-entry-${entry.entryId}'),
      title: Text(entry.preview ?? '',
          maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          // Unparseable rather than absent: showing the raw string beats
          // inventing a time, and beats hiding the entry.
          if (when != null) _clock(when) else entry.recordedAt,
          if ((entry.roomId ?? '').isNotEmpty) memoryRoomLabel(entry.roomId!),
        ].join(' · '),
      ),
      trailing: onChooseAudience == null
          ? null
          : IconButton(
              key: Key('memory-day-audience-${entry.entryId}'),
              onPressed: onChooseAudience,
              tooltip: '谁记得这条',
              icon: const Icon(Icons.people_outline),
            ),
    );
  }
}

String _clock(DateTime moment) => '${moment.hour.toString().padLeft(2, '0')}:'
    '${moment.minute.toString().padLeft(2, '0')}';

String _undatedSentence(int count) => '另有 $count 条没有可用的时间，不在任何一天的清单里';

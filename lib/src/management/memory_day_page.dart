import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';
import 'memory_labels.dart';
import 'memory_detail_sheet.dart';

/// 记忆时间线：stored dates, newest first, with their meaning shown per row.
///
/// A person cannot tell a missing entry from one that was never recorded, so
/// what this does not claim matters more than what it shows:
///
/// - **"There is more" and "the Host stopped reading" are separate.** Asking
///   for the next page helps with the first and not the second, and a person
///   deserves to know which.
/// - **Entries with no usable time are counted, not hidden.** Someone whose
///   entry never appears under any day should be able to learn that this is why.
/// - **A failed next page does not erase the pages already read.**
class MemoryDayPage extends StatelessWidget {
  const MemoryDayPage({
    super.key,
    required this.entries,
    required this.undatedCount,
    required this.truncated,
    required this.today,
    this.onLoadMore,
    this.loadingMore = false,
    this.moreError,
    this.scopeLabel,
  });

  final List<MemoryEntryView> entries;
  final int undatedCount;
  final bool truncated;

  /// Which local day is "今天" in the headings.
  final DateTime today;

  /// Non-null only when the Host said there is another page.
  final VoidCallback? onLoadMore;
  final bool loadingMore;
  final Object? moreError;
  final String? scopeLabel;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      if (scopeLabel != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Text(scopeLabel!),
        ),
      _Preamble(undatedCount: undatedCount, truncated: truncated),
    ];
    String? heading;
    for (final entry in entries) {
      final when = DateTime.tryParse(entry.recordedAt)?.toLocal();
      final day = when == null ? '时间不明' : _dayLabel(when, today);
      if (day != heading) {
        heading = day;
        rows.add(_DayHeading(label: day));
      }
      rows.add(_EntryRow(entry: entry, when: when));
    }
    if (moreError != null) {
      rows.add(
        Padding(
          key: const Key('memory-day-more-error'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text(
            '没能读到更早的：${refusalText(moreError!, subject: '记忆时间线')}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    if (onLoadMore != null) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton(
            key: const Key('memory-day-load-more'),
            onPressed: loadingMore ? null : onLoadMore,
            child: Text(loadingMore ? '正在读取…' : '看更早的'),
          ),
        ),
      );
    }
    return Scaffold(
      key: const Key('memory-day-page'),
      appBar: AppBar(title: const Text('记忆时间线')),
      body: entries.isEmpty
          ? Center(
              key: const Key('memory-day-empty'),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (scopeLabel != null) ...[
                      Text(scopeLabel!),
                      const SizedBox(height: 8),
                    ],
                    // Nothing yet is a real answer for a new Eidolon, so it is
                    // said plainly rather than drawn as an error.
                    Text(truncated
                        ? '主机这次没有读完全部记忆，这里可能不完整'
                        : undatedCount > 0
                            ? '还没有带日期的记忆'
                            : '还没有记下什么'),
                    if (undatedCount > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        _undatedSentence(undatedCount),
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            )
          : ListView(
              key: const Key('memory-day-list'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: rows,
            ),
    );
  }
}

class _Preamble extends StatelessWidget {
  const _Preamble({required this.undatedCount, required this.truncated});

  final int undatedCount;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      '按记录中的日期从新到旧，点开可查看原话和不同时间的依据',
      if (undatedCount > 0) _undatedSentence(undatedCount),
      // Two different partial answers. Only one is fixed by reading on, so they
      // are never merged into one sentence.
      if (truncated) '主机这次没有读完全部记忆，这里可能不完整',
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

class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        child: Text(label, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.when});

  final MemoryEntryView entry;
  final DateTime? when;

  @override
  Widget build(BuildContext context) {
    final moment = when;
    return ListTile(
      key: Key('memory-day-entry-${entry.entryId}'),
      title: Text(
        entry.preview ?? '',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          // Unparseable rather than absent: showing the raw string beats
          // inventing a time, and beats hiding the entry.
          if (moment != null)
            '${memoryTimeSourceLabel(entry.recordedAtSource)}：${_clock(moment)}'
          else
            entry.recordedAt,
          if ((entry.roomId ?? '').isNotEmpty) memoryRoomLabel(entry.roomId!),
        ].join(' · '),
      ),
      trailing: const Icon(Icons.info_outline, size: 20),
      onTap: () => showMemoryDetail(
        context,
        content: entry.value ?? entry.preview ?? '',
        provenance: entry.provenance,
        recordedAt: entry.recordedAt,
        category: memoryRoomLabel(entry.roomId ?? ''),
      ),
    );
  }
}

String _dayLabel(DateTime moment, DateTime today) {
  final day = DateTime(moment.year, moment.month, moment.day);
  final base = DateTime(today.year, today.month, today.day);
  final difference = base.difference(day).inDays;
  if (difference == 0) return '今天';
  if (difference == 1) return '昨天';
  if (moment.year == today.year) return '${moment.month}月${moment.day}日';
  return '${moment.year}年${moment.month}月${moment.day}日';
}

String _clock(DateTime moment) =>
    '${moment.hour.toString().padLeft(2, '0')}:'
    '${moment.minute.toString().padLeft(2, '0')}';

String _undatedSentence(int count) => '另有 $count 条没有可用的时间，不在按日期的清单里';

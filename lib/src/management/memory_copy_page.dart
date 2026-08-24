import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../generated/management_v1.dart';

/// 导出：a copy of what my Eidolon remembers, that I can take with me.
///
/// The three pages beside this one answer questions — what does it hold, what
/// happened today, what would forgetting this remove. This one answers a
/// different kind of question, the one about ownership: can I have it. So the
/// design rule flips. Those pages shorten what they show because a list someone
/// scrolls is worse for being long; here shortening is the failure.
///
/// What the screen must therefore say, before anything else, is **how complete
/// this copy is**:
///
/// - how many memories it holds, and when it was taken (two copies of one
///   memory differ, and a file with no instant cannot be told from a stale one);
/// - how many carry no date — they are *in* the copy, at the end, and a person
///   who sees them there deserves to know why they have no time;
/// - whether the Host stopped reading before the end of the memory. That one is
///   not a detail: an export that is quietly part of a memory is the worst thing
///   this page could produce.
///
/// The take-away is the clipboard rather than a file. Saving to storage means a
/// platform picker this app does not carry yet, and a "保存" button that opened
/// nothing would be exactly the fake button these pages are meant not to have.
/// What is copied is the JSON, not the on-screen rendering: this is the copy,
/// and it should paste into something that can read it rather than into prose.
class MemoryCopyPage extends StatelessWidget {
  const MemoryCopyPage({
    super.key,
    required this.copy,
    this.onCopied,
    this.clipboard,
  });

  final MemoryCopyView copy;

  /// Told after the copy reached the clipboard, so the screen can say so.
  final VoidCallback? onCopied;

  /// Injected in tests. The real one is the platform's.
  final Future<void> Function(String text)? clipboard;

  @override
  Widget build(BuildContext context) {
    final records = copy.records;
    return Scaffold(
      key: const Key('memory-copy-page'),
      appBar: AppBar(title: const Text('导出记忆')),
      body: ListView.separated(
        key: const Key('memory-copy-list'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: records.length + 1,
        separatorBuilder: (_, index) =>
            index == 0 ? const SizedBox.shrink() : const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _Preamble(
              copy: copy,
              onCopy: records.isEmpty ? null : () => _copy(context),
            );
          }
          return _RecordRow(record: records[index - 1]);
        },
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final text = const JsonEncoder.withIndent('  ').convert(_asJson(copy));
    final put = clipboard ??
        (String value) => Clipboard.setData(ClipboardData(text: value));
    await put(text);
    onCopied?.call();
  }
}

/// The copy as it travels, rebuilt from the typed view.
///
/// Rebuilt rather than kept as the raw body: a person's file should hold the
/// fields this app understands, so a field the Host adds later cannot end up in
/// someone's saved copy without anyone having decided it should.
Map<String, dynamic> _asJson(MemoryCopyView copy) => {
      'taken_at': copy.takenAt,
      'record_count': copy.recordCount,
      'undated_count': copy.undatedCount,
      'truncated': copy.truncated,
      'records': [
        for (final record in copy.records)
          {
            'entry_id': record.entryId,
            'recorded_at': record.recordedAt ?? '',
            'recorded_at_source': record.recordedAtSource ?? '',
            'wing_id': record.wingId ?? '',
            'room_id': record.roomId ?? '',
            'memory_type': record.memoryType ?? '',
            'value': record.value,
          },
      ],
    };

class _Preamble extends StatelessWidget {
  const _Preamble({required this.copy, this.onCopy});

  final MemoryCopyView copy;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final taken = DateTime.tryParse(copy.takenAt)?.toLocal();
    final lines = <String>[
      '共 ${copy.recordCount} 条',
      // Unparseable rather than absent: showing the raw string beats inventing
      // a time for the copy itself.
      taken == null ? '取自 ${copy.takenAt}' : '取自 ${_stamp(taken)}',
      if (copy.undatedCount > 0)
        '其中 ${copy.undatedCount} 条没有可用的时间，排在最后',
      // Said on its own line and in its own words. This is the one thing on
      // this page that means "what you are about to keep is not all of it".
      if (copy.truncated) '这次没有读完全部记忆，这份副本不完整',
    ];
    return Padding(
      key: const Key('memory-copy-preamble'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line, style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 8),
          if (onCopy == null)
            const Text(
              key: Key('memory-copy-empty'),
              '这里还没有可以导出的记忆',
            )
          else
            OutlinedButton(
              key: const Key('memory-copy-button'),
              onPressed: onCopy,
              child: const Text('复制全部'),
            ),
        ],
      ),
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record});

  final MemoryExportRecordView record;

  @override
  Widget build(BuildContext context) {
    // Nullable on the wire: every field but ``value`` carries a default, so the
    // Host may leave it out. Absent and empty mean the same thing here — the
    // record does not say — and the row says so rather than filling one in.
    final when = DateTime.tryParse(record.recordedAt ?? '')?.toLocal();
    final where = [
      if ((record.roomId ?? '').isNotEmpty) record.roomId!,
      if ((record.memoryType ?? '').isNotEmpty) record.memoryType!,
    ].join(' · ');
    return ListTile(
      key: Key('memory-copy-record-${record.entryId}'),
      // Whole, not clipped: a person checking their copy is checking that it is
      // one. The row scrolls with the list rather than truncating.
      title: Text(record.value),
      subtitle: Text(
        [
          // Empty when nothing on the record gave a time. Said plainly rather
          // than filled in, which is the same reason it sits at the end.
          if (when != null) _stamp(when) else '没有可用的时间',
          if (where.isNotEmpty) where,
        ].join(' · '),
      ),
    );
  }
}

String _stamp(DateTime moment) =>
    '${moment.year}-${_two(moment.month)}-${_two(moment.day)} '
    '${_two(moment.hour)}:${_two(moment.minute)}';

String _two(int value) => value.toString().padLeft(2, '0');

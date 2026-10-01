import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'refusal_notice.dart';
import 'memory_day_page.dart';

/// 记忆时间线：everything written down, newest first, a page at a time.
///
/// It used to be "today", with 「看更早的」 widening the window by a day. That
/// button could never show anything older once today filled a page: the Host
/// sorts newest first and cuts the page, so an earlier `since` only added older
/// entries to the part that was cut. Now the list has no window to widen — the
/// lower bound includes dates before 1970 — and 「看更早的」 asks for the next
/// page with the position the Host handed back. Days are shown as headings in
/// the person's own time, which is the part of "today" worth keeping.
class MemoryDayScreen extends StatefulWidget {
  const MemoryDayScreen(
      {super.key, required this.load, this.now, this.scopeLabel});
  final String? scopeLabel;

  /// Reads one page. [cursor] is the previous page's `nextCursor`, or null for
  /// the newest page.
  final Future<MemoryDayView> Function(DateTime since, String? cursor) load;

  /// Injected in tests so "today" in the headings is a fact rather than the
  /// clock.
  final DateTime Function()? now;

  @override
  State<MemoryDayScreen> createState() => _MemoryDayScreenState();
}

class _MemoryDayScreenState extends State<MemoryDayScreen> {
  /// Every supported positive-year date, including pre-1970 memories. UTC
  /// avoids timezone conversion underflow at the minimum date.
  static final DateTime _since = DateTime.utc(1);

  final List<MemoryEntryView> _entries = [];
  MemoryDayView? _last;
  Object? _error;
  Object? _moreError;
  bool _busy = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _readFirst();
  }

  Future<void> _readFirst() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.load(_since, null);
      if (!mounted) return;
      setState(() {
        _entries
          ..clear()
          ..addAll(page.entries);
        _last = page;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  Future<void> _readMore() async {
    final cursor = _last?.nextCursor;
    if (cursor == null || _loadingMore) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final page = await widget.load(_since, cursor);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page.entries);
        _last = page;
        _loadingMore = false;
      });
    } catch (error) {
      // Said beside the list, which stays: what was already read is still true.
      if (!mounted) return;
      setState(() {
        _moreError = error;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _last;
    if (last != null) {
      return MemoryDayPage(
        entries: _entries,
        scopeLabel: widget.scopeLabel,
        undatedCount: last.undatedCount,
        truncated: last.truncated,
        today: (widget.now ?? DateTime.now)(),
        loadingMore: _loadingMore,
        moreError: _moreError,
        // Only when the Host said there is another page. Never a button in
        // front of a page that cannot exist.
        onLoadMore:
            last.moreInWindow && last.nextCursor != null ? _readMore : null,
      );
    }
    return Scaffold(
      key: const Key('memory-day-screen'),
      appBar: AppBar(title: const Text('记忆时间线')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('memory-day-loading'))
            : RefusalNotice(
                key: const Key('memory-day-error'),
                error: _error!,
                subject: '记忆时间线',
                onRetry: _readFirst,
                retryKey: const Key('memory-day-retry'),
              ),
      ),
    );
  }
}

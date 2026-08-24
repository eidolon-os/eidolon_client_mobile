import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';
import 'memory_day_page.dart';

/// Loads today, and decides what "today" means — because the Host cannot.
///
/// The window starts at local midnight, computed here. That is the one piece of
/// judgement this screen owns, and it is here rather than on the Host for a
/// concrete reason: the Host does not know where the person is standing, so a
/// day computed there would be wrong by up to a day and would not say so.
///
/// "Look further back" widens the same window rather than paging: a person
/// asking for more of today wants the morning, not an opaque cursor. Each step
/// goes back a day, and the page says when the window starts so nobody has to
/// guess which stretch they are looking at.
class MemoryDayScreen extends StatefulWidget {
  const MemoryDayScreen({super.key, required this.load, this.now});

  final Future<MemoryDayView> Function(DateTime since) load;

  /// Injected in tests so "today" is a fact rather than the clock.
  final DateTime Function()? now;

  @override
  State<MemoryDayScreen> createState() => _MemoryDayScreenState();
}

class _MemoryDayScreenState extends State<MemoryDayScreen> {
  MemoryDayView? _day;
  Object? _error;
  bool _busy = true;
  late DateTime _since = _localMidnight();

  @override
  void initState() {
    super.initState();
    _read();
  }

  DateTime _localMidnight() {
    final now = (widget.now ?? DateTime.now)();
    return DateTime(now.year, now.month, now.day);
  }

  Future<void> _read() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final day = await widget.load(_since);
      if (!mounted) return;
      setState(() {
        _day = day;
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

  Future<void> _widen() async {
    setState(() => _since = _since.subtract(const Duration(days: 1)));
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    if (day != null) {
      return MemoryDayPage(
        day: day,
        dayStartedAt: _since,
        // Offered whenever the page ended inside the window: there is more to
        // see, and widening is how this screen shows it.
        onLoadMore: _busy || !day.moreInWindow ? null : _widen,
      );
    }
    return Scaffold(
      key: const Key('memory-day-screen'),
      appBar: AppBar(title: const Text('今天记下的')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('memory-day-loading'))
            : Padding(
                key: const Key('memory-day-error'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error is ManagementRequestException &&
                              (_error as ManagementRequestException).hostHasNoOwner
                          ? '这台主机还没有主人，先完成设置'
                          : '$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('memory-day-retry'),
                      onPressed: _read,
                      child: const Text('再试一次'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

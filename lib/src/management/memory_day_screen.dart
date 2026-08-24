import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'audience_sheet.dart';
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
  const MemoryDayScreen({
    super.key,
    required this.load,
    this.now,
    this.loadCompanions,
    this.assignAudience,
  });

  final Future<MemoryDayView> Function(DateTime since) load;

  /// The Owner's Eidolons, read only when the audience action is offered: the
  /// sheet names them, and a list of ids would make a person guess.
  final Future<List<CompanionSummaryView>> Function()? loadCompanions;

  /// Null [companionId] gives the memory back to every Companion. Both this and
  /// [loadCompanions] are needed for the action to appear — half of it would be
  /// a control that opens a sheet with nothing in it.
  final Future<MemoryAudienceView> Function(
    String entryId,
    String? companionId,
  )? assignAudience;

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

  bool get _canChooseAudience =>
      widget.loadCompanions != null && widget.assignAudience != null;

  /// Its own screen rather than a dialog: the choice is about who will remember
  /// something, and a list of names inside a dialog is where that gets cramped.
  Future<void> _chooseAudience(MemoryEntryView entry) async {
    List<CompanionSummaryView> companions;
    try {
      companions = await widget.loadCompanions!();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没能读到伙伴名单:$error')),
      );
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AudienceSheet(
          entryId: entry.entryId,
          companions: companions,
          assign: (companionId) =>
              widget.assignAudience!(entry.entryId, companionId),
        ),
      ),
    );
    if (!mounted) return;
    // The entry may have left this list: a memory given to one Companion is no
    // longer in the Owner layer this page reads. Re-read rather than patch — the
    // Host says what is remembered, and a list that still shows it would be the
    // moment a person stops believing the change happened.
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    if (day != null) {
      return MemoryDayPage(
        day: day,
        dayStartedAt: _since,
        onChooseAudience: _canChooseAudience ? _chooseAudience : null,
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

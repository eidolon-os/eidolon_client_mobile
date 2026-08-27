/// Everything that has happened here, a page at a time.
///
/// The map carries a bounded now: the Host trims that list per Companion so one
/// talkative body cannot evict the rest of the household, and it says so through
/// the lane's own `truncated`. That bound is a display decision and it was being
/// read as a history — 「活动 12」 looked like an Owner who had had twelve
/// activities, ever, and looked stuck there no matter how much was said.
///
/// So the history is its own read, and it pages. Three states are kept apart
/// here because they are three different things to a person:
///
///   * nothing has happened yet — an empty household, said plainly;
///   * the Host could not read it — with the Host's own sentence, and a way to
///     ask again. Absent and unreadable are the same shape on the wire and must
///     never read the same on a screen;
///   * there is more, and it is coming — the next page loads as the list nears
///     its end rather than behind a button, because a person scrolling is
///     already asking.
library;

import 'package:flutter/material.dart';

import 'cockpit_details.dart';
import 'cockpit_models.dart';
import 'cockpit_theme.dart';
import 'cockpit_wire.dart';

/// Reads one page. [cursor] is null for the first, and afterwards is whatever
/// the previous page handed back — stored and returned untouched, so the Host's
/// page boundary stays the Host's.
typedef ActivityPageReader = Future<ActivityPage> Function(String? cursor);

Future<void> showActivityHistory(
  BuildContext context, {
  required ActivityPageReader read,
  required String Function(String companionId) companionName,
  required void Function(CockpitActivity activity) onTap,
}) =>
    showCockpitSheet(
      context,
      title: '这里发生过的事',
      kicker: '按时间倒序',
      accent: Cockpit.magenta,
      scrollingChild: (controller) => _History(
        controller: controller,
        read: read,
        companionName: companionName,
        onTap: onTap,
      ),
    );

class _History extends StatefulWidget {
  const _History({
    required this.controller,
    required this.read,
    required this.companionName,
    required this.onTap,
  });

  final ScrollController controller;
  final ActivityPageReader read;
  final String Function(String companionId) companionName;
  final void Function(CockpitActivity activity) onTap;

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  final List<CockpitActivity> _items = [];
  String? _cursor;
  bool _hasMore = true;
  bool _reading = false;
  String _failure = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
    _readMore();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() => _readIfNearTheEnd();

  /// Read again when the end is within a screen's reach.
  ///
  /// Checked after every page as well as on scroll, and that is not belt-and-
  /// braces: a first page that fits on screen leaves the list with nothing to
  /// scroll, so no scroll event ever arrives and a history with more in it
  /// simply stopped at one page. Reaching the end of the content *is* being
  /// near the end of it.
  void _readIfNearTheEnd() {
    // A read that failed is not retried on its own. Scrolling near the end of a
    // list that is only short because the Host is away would otherwise ask
    // again on every frame — hammering something already in trouble. The reader
    // asks again, once, by choosing to.
    if (_failure.isNotEmpty) return;
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    if (position.pixels >= position.maxScrollExtent - 400) _readMore();
  }

  /// Asked for again by a person, which is the only thing that clears a failure.
  void _retry() {
    setState(() => _failure = '');
    _readMore();
  }

  Future<void> _readMore() async {
    if (_reading || !_hasMore) return;
    setState(() {
      _reading = true;
      _failure = '';
    });
    try {
      final page = await widget.read(_cursor);
      if (!mounted) return;
      setState(() {
        _reading = false;
        if (!page.readable) {
          _failure = page.detail;
          return;
        }
        _items.addAll(page.items);
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
      if (_hasMore) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _readIfNearTheEnd();
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _failure = '读不到：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty && _failure.isNotEmpty) {
      return ListView(
        controller: widget.controller,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 28),
        children: [
          SheetNote(text: _failure),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _retry,
              child: Text('再试一次', style: Cockpit.mono(size: 11)),
            ),
          ),
        ],
      );
    }
    if (_items.isEmpty && !_reading) {
      return ListView(
        controller: widget.controller,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 28),
        children: const [SheetNote(text: '这里还没有发生过什么。')],
      );
    }
    return ListView.builder(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 28),
      itemCount: _items.length + 1,
      itemBuilder: (context, index) {
        if (index == _items.length) {
          return _Tail(
            reading: _reading,
            failure: _failure,
            hasMore: _hasMore,
            onRetry: _retry,
          );
        }
        final activity = _items[index];
        return _HistoryRow(
          activity: activity,
          companionName: widget.companionName(activity.companionId),
          onTap: () => widget.onTap(activity),
        );
      },
    );
  }
}

/// What the bottom of the list says. Never blank: reaching the end of a history
/// is itself a fact worth stating, and so is failing to load more of one.
class _Tail extends StatelessWidget {
  const _Tail({
    required this.reading,
    required this.failure,
    required this.hasMore,
    required this.onRetry,
  });

  final bool reading;
  final String failure;
  final bool hasMore;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (failure.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SheetNote(text: failure),
            TextButton(
              onPressed: onRetry,
              child: Text('再试一次', style: Cockpit.mono(size: 11)),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: Text(
          reading ? '正在读…' : (hasMore ? '' : '到这里为止了'),
          style: Cockpit.mono(size: 10, color: Cockpit.inkDim),
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.activity,
    required this.companionName,
    required this.onTap,
  });

  final CockpitActivity activity;
  final String companionName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = toneColor(statusTone(activity.status));
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(border: Border.all(color: Cockpit.hair)),
        child: Row(
          children: [
            CockpitLed(color: tone, size: 6),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    activity.summary,
                    style: Cockpit.sans(size: 12, color: Cockpit.ink),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (companionName.isNotEmpty) companionName,
                      activityKindLabel(activity.kind),
                      formatWhen(activity.startedAt),
                    ].where((part) => part.isNotEmpty).join(' · '),
                    style: Cockpit.mono(size: 9.5, color: Cockpit.inkDim),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One voice session, as the Host recorded it.
///
/// Engineering data on a product surface, and the framing matters. This is not
/// the Owner's reading of their household — that is the cockpit, and it speaks
/// in 对话 / 守护 / 指令. This screen speaks in `commit_to_llm_first_delta`,
/// because the person who opens it is diagnosing a call and greps for exactly
/// that string. Translating the writer's vocabulary would put a second name on
/// every stage and make the log and the screen disagree.
///
/// Reached from one interaction the reader already has in hand, never browsed.
/// A session trace answers "why was *that* one slow", and there is no version of
/// that question that starts with a list.
///
/// **Nothing here is computed.** Every number is one the writer measured and the
/// Provider relayed. The screen's whole job is to lay them out and to be honest
/// about the ones that are missing.
library;

import 'package:flutter/material.dart';

import 'cockpit_details.dart';
import 'cockpit_models.dart';
import 'cockpit_theme.dart';
import 'session_trace_wire.dart';

/// Reads one session's records. Throws when the Host refuses — the caller shows
/// that sentence rather than an empty screen.
typedef SessionTraceReader = Future<SessionTrace> Function(String sessionId);

class SessionTracePage extends StatefulWidget {
  const SessionTracePage({
    super.key,
    required this.sessionId,
    required this.read,
  });

  final String sessionId;
  final SessionTraceReader read;

  @override
  State<SessionTracePage> createState() => _SessionTracePageState();
}

class _SessionTracePageState extends State<SessionTracePage> {
  SessionTrace? _trace;
  String _failure = '';
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = '';
    });
    try {
      final trace = await widget.read(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _trace = trace;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = '$error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('session-trace-page'),
      backgroundColor: Cockpit.bg,
      appBar: AppBar(
        backgroundColor: Cockpit.bg,
        foregroundColor: Cockpit.ink,
        title: const Text('这次会话的链路'),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        key: Key('session-trace-loading'),
        child: CircularProgressIndicator(color: Cockpit.cyan),
      );
    }
    if (_failure.isNotEmpty) {
      // The Host's own sentence, and a way to ask again. A screen that could
      // not read and says nothing is the shape this whole line exists to remove.
      return Center(
        key: const Key('session-trace-failure'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _failure,
                textAlign: TextAlign.center,
                style: Cockpit.sans(size: 12.5, color: Cockpit.ink, height: 1.6),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                key: const Key('session-trace-retry'),
                onPressed: _load,
                child: const Text('再读一次'),
              ),
            ],
          ),
        ),
      );
    }
    final trace = _trace!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _Verdict(session: trace.session),
        const SizedBox(height: 18),
        _SessionMarks(session: trace.session),
        const SizedBox(height: 18),
        _Turns(turns: trace.turns, eventCount: trace.eventCount),
      ],
    );
  }
}

String _ms(double? value) {
  if (value == null) return '未测到';
  if (value.abs() >= 1000) return '${(value / 1000).toStringAsFixed(2)}s';
  return '${value.toStringAsFixed(1)}ms';
}

/// One sentence about the session, from the same read that draws everything
/// below it — so the top of the screen and the middle cannot disagree.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.session});

  final SessionTraceSummary session;

  @override
  Widget build(BuildContext context) {
    final sentence = session.closed
        ? '这次会话持续 ${_ms(session.durationMs)}，以 ${session.reason} 结束。'
        : '这次会话还没有结束 —— 记录里没有收尾那一行。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          sentence,
          key: const Key('session-trace-verdict'),
          style: Cockpit.sans(
            size: 13,
            weight: FontWeight.w500,
            color: Cockpit.ink,
            height: 1.6,
          ),
        ),
        if (session.lostRecords) ...[
          const SizedBox(height: 10),
          SheetNote(
            key: const Key('session-trace-incomplete'),
            // Said out loud: the writer drops records rather than slowing
            // speech down, so a full-looking screen can still be partial.
            text: session.truncated
                ? '这份记录被截断了，下面看到的不是全部。'
                : '写入时丢了 ${session.droppedRecordCount} 条记录，下面看到的不是全部。',
            tone: CockpitTone.warn,
          ),
        ],
        const SizedBox(height: 14),
        FactTable(
          rows: <(String, String)>[
            ('会话', session.sessionId),
            ('伙伴', session.companionId.isEmpty ? '—' : session.companionId),
            ('模式', session.interactionMode),
            ('开始于', session.startedAt),
            if (session.roomName.isNotEmpty) ('房间', session.roomName),
          ],
        ),
      ],
    );
  }
}

/// Room join → first turn, as the writer marked it.
class _SessionMarks extends StatelessWidget {
  const _SessionMarks({required this.session});

  final SessionTraceSummary session;

  @override
  Widget build(BuildContext context) {
    final missing = session.missingMarks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '会话建立',
          style: Cockpit.mono(size: 9.5, color: Cockpit.inkDim, tracking: 0.1),
        ),
        const SizedBox(height: 8),
        for (final entry in session.marks.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    entry.key,
                    style: Cockpit.mono(size: 10.5, color: Cockpit.ink),
                  ),
                ),
                Text(
                  _ms(entry.value),
                  style: Cockpit.mono(size: 10.5, color: Cockpit.cyan),
                ),
              ],
            ),
          ),
        if (missing == null)
          const SheetNote(
            key: Key('session-trace-marks-unknown'),
            // Still running: it may yet reach them, so nothing is called missing.
            text: '会话还开着，还说不上哪些环节没走到。',
          )
        else if (missing.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SheetNote(
              key: const Key('session-trace-marks-missing'),
              text: '没走到：${missing.join('、')}',
              tone: CockpitTone.warn,
            ),
          ),
      ],
    );
  }
}

class _Turns extends StatelessWidget {
  const _Turns({required this.turns, required this.eventCount});

  final List<SessionTraceTurn> turns;
  final int eventCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '轮次 ${turns.length} · 事件 $eventCount',
          style: Cockpit.mono(size: 9.5, color: Cockpit.inkDim, tracking: 0.1),
        ),
        const SizedBox(height: 8),
        if (turns.isEmpty)
          const SheetNote(
            key: Key('session-trace-no-turns'),
            // A session with no settled turn is a real outcome, not a failure
            // to read: nobody spoke, or nothing got far enough to settle.
            text: '这次会话没有已经结束的轮次。',
          ),
        for (final turn in turns) _TurnWaterfall(turn: turn),
      ],
    );
  }
}

class _TurnWaterfall extends StatelessWidget {
  const _TurnWaterfall({required this.turn});

  final SessionTraceTurn turn;

  @override
  Widget build(BuildContext context) {
    final measured = turn.measured.toList(growable: false);
    // Against the longest measured stage, not a total. These stretches overlap
    // and do not sum to the turn — bars drawn against a total would claim a
    // completeness the data does not have. Same rule the cockpit's breakdown
    // already follows.
    final longest = measured.fold<double>(
      0,
      (top, d) => d.ms! > top ? d.ms! : top,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${turn.turnId}  ·  ${turn.reason}',
            style: Cockpit.mono(size: 10, color: Cockpit.magenta),
          ),
          const SizedBox(height: 8),
          for (final duration in turn.durations)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 190,
                    child: Text(
                      duration.key,
                      style: Cockpit.mono(
                        size: 9.5,
                        color: duration.measured
                            ? Cockpit.ink
                            : Cockpit.inkDim,
                      ),
                    ),
                  ),
                  Expanded(
                    child: _Bar(ms: duration.ms, against: longest),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 64,
                    child: Text(
                      _ms(duration.ms),
                      textAlign: TextAlign.right,
                      style: Cockpit.mono(
                        size: 9.5,
                        color: duration.measured
                            ? Cockpit.cyan
                            : Cockpit.inkDim,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.ms, required this.against});

  final double? ms;
  final double against;

  @override
  Widget build(BuildContext context) {
    final value = ms;
    // Nothing is drawn for a stage that was never measured. A zero-width bar
    // would read as "instant", which is the one thing it is not.
    if (value == null || against <= 0) return const SizedBox(height: 6);
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          height: 6,
          width: (constraints.maxWidth * (value / against)).clamp(
            1.0,
            constraints.maxWidth,
          ),
          decoration: BoxDecoration(
            color: Cockpit.cyan.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

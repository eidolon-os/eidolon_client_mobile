/// Reads the Channel Provider's session-trace documents, relayed by the Host.
///
/// The one rule this file follows, and the reason it is so thin: **nothing here
/// is derived.** Durations, session marks, the list of marks a session never
/// reached — all of them are computed by the writer that observed the session
/// and carried through the Provider untouched. This app renders them.
///
/// That is not laziness, it is the Owner's constraint ("读取接口应该是统一的一份，
/// 不应该写重复读取实现") and one specific scar. A turn's "playback resumed"
/// moment and its interruption verdict are about six seconds apart, and a
/// consumer that recomputed the first from the second shipped that mistake
/// once already. So this file has no arithmetic in it at all: if a number is
/// not on the wire, the screen says it was not measured rather than deducing
/// one.
///
/// Unfamiliar keys are carried, not rejected. A phone is routinely older than
/// the Host beside it, and a duration this version has never heard of is still
/// a duration worth showing.
library;

class SessionTraceException implements Exception {
  const SessionTraceException(this.message);

  final String message;

  @override
  String toString() => '会话链路记录不符合契约：$message';
}

Never _bad(String what) => throw SessionTraceException(what);

Map<String, Object?> _object(Object? value, String what) =>
    value is Map ? Map<String, Object?>.from(value) : _bad(what);

String _stringOr(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

double? _msOrNull(Object? value) => value is num ? value.toDouble() : null;

int? _intOrNull(Object? value) => value is num ? value.toInt() : null;

/// One measured stretch inside a turn, named by the writer.
///
/// [ms] is null when the turn never reached it. That is a different fact from
/// zero and the screen must keep them apart — a stage that took no time and a
/// stage that never happened look nothing alike to someone diagnosing a call.
class TraceDuration {
  const TraceDuration({required this.key, required this.ms});

  final String key;
  final double? ms;

  bool get measured => ms != null;
}

/// One turn's final record.
class SessionTraceTurn {
  const SessionTraceTurn({
    required this.turnId,
    required this.reason,
    required this.durations,
  });

  final String turnId;

  /// How the turn ended, in the writer's words — `agent_audio_playback_done`,
  /// `user_turn_rejected`, and so on. Not translated: this screen's reader is
  /// the person who greps for that string.
  final String reason;

  /// In the order the writer emitted them, which groups related stages
  /// together. Sorting by size here would scatter a pipeline into a ranking.
  final List<TraceDuration> durations;

  Iterable<TraceDuration> get measured => durations.where((d) => d.measured);
}

/// What the Host knows about one recorded session.
class SessionTraceSummary {
  const SessionTraceSummary({
    required this.sessionId,
    required this.ownerId,
    required this.companionId,
    required this.roomName,
    required this.interactionMode,
    required this.startedAt,
    required this.status,
    required this.reason,
    required this.durationMs,
    required this.marks,
    required this.missingMarks,
    required this.traceBytes,
    required this.droppedRecordCount,
    required this.truncated,
  });

  final String sessionId;
  final String ownerId;
  final String companionId;
  final String roomName;
  final String interactionMode;
  final String startedAt;

  /// `open` until the closing record lands. An open session has no duration and
  /// no list of marks it missed — absent because it may still reach them, which
  /// is why [missingMarks] is nullable rather than empty.
  final String status;
  final String reason;
  final double? durationMs;

  /// Session-scope marks in the order a healthy session reaches them, as the
  /// writer ordered them.
  final Map<String, double> marks;

  /// Null while the session is open; a list once it closed.
  final List<String>? missingMarks;

  final int? traceBytes;

  /// Records the writer threw away because its queue was full. Non-zero means
  /// what follows is incomplete, and a screen that hid that would be lying by
  /// omission.
  final int droppedRecordCount;
  final bool truncated;

  bool get closed => status == 'closed';
  bool get lostRecords => droppedRecordCount > 0 || truncated;
}

class SessionTrace {
  const SessionTrace({
    required this.session,
    required this.turns,
    required this.eventCount,
    required this.recordCount,
  });

  final SessionTraceSummary session;
  final List<SessionTraceTurn> turns;

  /// Governance events in the file. Counted rather than listed: they are the
  /// tier the cockpit draws, and repeating them here would be a second telling.
  final int eventCount;
  final int recordCount;
}

SessionTraceSummary sessionTraceSummaryFromJson(Map<String, Object?> json) {
  final rawMarks = json['session_marks_ms'];
  final marks = <String, double>{};
  if (rawMarks is Map) {
    rawMarks.forEach((key, value) {
      final ms = _msOrNull(value);
      if (ms != null) marks['$key'] = ms;
    });
  }
  final rawMissing = json['missing_session_marks'];
  return SessionTraceSummary(
    sessionId: _stringOr(json['session_id']).isEmpty
        ? _bad('session_id 缺失')
        : _stringOr(json['session_id']),
    ownerId: _stringOr(json['owner_id']),
    companionId: _stringOr(json['companion_id']),
    roomName: _stringOr(json['room_name']),
    interactionMode: _stringOr(json['interaction_mode']),
    startedAt: _stringOr(json['started_at']),
    status: _stringOr(json['status'], 'open'),
    reason: _stringOr(json['reason']),
    durationMs: _msOrNull(json['duration_ms']),
    marks: marks,
    // Absent and empty are different: absent means still running.
    missingMarks: rawMissing is List
        ? rawMissing.map((item) => '$item').toList(growable: false)
        : null,
    traceBytes: _intOrNull(json['trace_bytes']),
    droppedRecordCount: _intOrNull(json['dropped_record_count']) ?? 0,
    truncated: json['truncated'] == true,
  );
}

SessionTrace sessionTraceFromJson(Map<String, Object?> json) {
  final summary = sessionTraceSummaryFromJson(
    _object(json['session'], 'session 不是对象'),
  );
  final rawRecords = json['records'];
  if (rawRecords is! List) _bad('records 不是数组');
  final turns = <SessionTraceTurn>[];
  var events = 0;
  for (final raw in rawRecords) {
    if (raw is! Map) continue;
    final record = Map<String, Object?>.from(raw);
    final kind = _stringOr(record['record_kind']);
    if (kind == 'event') {
      events += 1;
      continue;
    }
    // Only the settled row. A turn also emits progress rows, and counting both
    // would show one turn twice — the same duplication the writer's
    // `record_kind` split exists to prevent.
    if (kind != 'turn_final') continue;
    final rawDurations = record['durations_ms'];
    final durations = <TraceDuration>[];
    if (rawDurations is Map) {
      rawDurations.forEach((key, value) {
        durations.add(TraceDuration(key: '$key', ms: _msOrNull(value)));
      });
    }
    turns.add(
      SessionTraceTurn(
        turnId: _stringOr(record['turn_id']),
        reason: _stringOr(record['record_reason']),
        durations: durations,
      ),
    );
  }
  return SessionTrace(
    session: summary,
    turns: turns,
    eventCount: events,
    recordCount: _intOrNull(json['record_count']) ?? rawRecords.length,
  );
}

/// One page of the Owner's recorded sessions.
///
/// [recording] is the field this type exists to keep: `false` means the Host
/// records nothing, and an empty [sessions] with `true` means this Owner has
/// had none. A screen that showed one sentence for both would be the failure
/// this whole line was built to remove.
class SessionTraceListing {
  const SessionTraceListing({
    required this.recording,
    required this.sessions,
  });

  final bool recording;
  final List<SessionTraceSummary> sessions;
}

SessionTraceListing sessionTraceListingFromJson(Map<String, Object?> json) {
  final rows = json['sessions'];
  return SessionTraceListing(
    recording: json['recording'] == true,
    sessions: rows is List
        ? rows
              .whereType<Map>()
              .map(
                (row) =>
                    sessionTraceSummaryFromJson(Map<String, Object?>.from(row)),
              )
              .toList(growable: false)
        : const <SessionTraceSummary>[],
  );
}

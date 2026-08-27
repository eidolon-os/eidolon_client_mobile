import '../../protocol/mission_control_contract.dart' as wire;
import 'cockpit_models.dart';

/// Parses the Mission Control Local API payloads into the view models.
///
/// The contract is `eidolon_sdk/contracts/local_api/v1/*.schema.json`; the
/// vocabulary it uses is mirrored in `lib/src/protocol/mission_control_contract.dart`
/// and pinned to the SDK by that repository's mirror tests. This file is the
/// only place in the app that knows the wire exists.
///
/// It is deliberately unforgiving in one direction and forgiving in the other.
/// A malformed document is refused — a screen built from a half-understood
/// payload is worse than one that says it could not read. But an *unfamiliar*
/// value is not malformed: an App is routinely older than the Host beside it,
/// and a lane state or activity kind this version has never heard of is a fact
/// it should carry rather than a reason to show nothing.
class CockpitWireException implements Exception {
  const CockpitWireException(this.message);

  final String message;

  @override
  String toString() => 'Mission Control 投影不符合契约：$message';
}

Never _bad(String what) => throw CockpitWireException(what);

Map<String, Object?> _object(Object? value, String what) =>
    value is Map ? Map<String, Object?>.from(value) : _bad(what);

String _string(Object? value, String what) =>
    value is String ? value : _bad(what);

String _stringOr(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

int? _intOrNull(Object? value) => value is num ? value.toInt() : null;

bool _boolOr(Object? value, bool fallback) => value is bool ? value : fallback;

DateTime? _timeOrNull(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

DateTime _time(Object? value, String what) => _timeOrNull(value) ?? _bad(what);

List<String> _strings(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const <String>[];

/// One lane, health and payload together.
CockpitLane<T> _lane<T>(
  Object? raw,
  String what,
  T Function(Object? payload) parse, {
  required String payloadKey,
  required T empty,
}) {
  final map = _object(raw, what);
  final state = laneStateFromWire(map['state']);
  final detail = _stringOr(map['detail']);
  if (state == LaneState.unavailable) {
    // A failed lane's payload is not read even if one was sent: whatever is in
    // there was not observed, and carrying it would make the failure invisible.
    return CockpitLane<T>(
      state: state,
      value: empty,
      detail: detail.isEmpty ? '$what 没有读到' : detail,
    );
  }
  return CockpitLane<T>(
    state: state,
    value: parse(map[payloadKey]),
    detail: detail,
    observedAt: _timeOrNull(map['observed_at']),
    latencyMs: _intOrNull(map['latency_ms']),
    truncated: _boolOr(map['truncated'], false),
  );
}

List<E> _items<E>(Object? raw, E Function(Map<String, Object?>) parse) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => parse(Map<String, Object?>.from(item)))
      .toList(growable: false);
}

/// What Mission Control observed, with no claim about who exists.
///
/// The route takes `?companion_id=`, which is the tell: a caller that has to
/// name the Companion already knows which ones there are. So identity is not
/// here — the roster owns which Companions exist and `/context` owns the Owner
/// and the default pointer, and both are authority fields rather than
/// projections. This is only what was seen, keyed by ids the caller holds.
class CockpitRuntime {
  const CockpitRuntime({
    required this.observedAt,
    required this.devices,
    required this.activities,
    required this.turns,
    required this.jobs,
    required this.memory,
    required this.services,
    required this.events,
    this.cursor,
  });

  /// Every lane unavailable, because Mission Control has no producer yet. Not an
  /// empty domain — a domain nobody could ask about.
  factory CockpitRuntime.unavailable(String detail) => CockpitRuntime(
        observedAt: DateTime.now().toUtc(),
        devices: CockpitLane<List<CockpitDevice>>.missing(const [], detail),
        activities:
            CockpitLane<List<CockpitActivity>>.missing(const [], detail),
        turns: CockpitLane<List<CockpitTurn>>.missing(const [], detail),
        jobs: CockpitLane<List<CockpitJob>>.missing(const [], detail),
        memory: CockpitLane<CockpitMemory?>.missing(null, detail),
        services: CockpitLane<List<CockpitService>>.missing(const [], detail),
        events: CockpitLane<List<CockpitEvent>>.missing(const [], detail),
      );

  final DateTime observedAt;
  final int? cursor;
  final CockpitLane<List<CockpitDevice>> devices;
  final CockpitLane<List<CockpitActivity>> activities;
  final CockpitLane<List<CockpitTurn>> turns;
  final CockpitLane<List<CockpitJob>> jobs;
  final CockpitLane<CockpitMemory?> memory;
  final CockpitLane<List<CockpitService>> services;
  final CockpitLane<List<CockpitEvent>> events;
}

CockpitRuntime parseMissionControlRuntime(Map<String, Object?> json) {
  if (json['contract_version'] != wire.missionControlContractVersion) {
    _bad('contract_version 是 ${json['contract_version']}');
  }
  if (json['coverage'] != wire.missionControlSnapshotCoverage) {
    _bad('coverage 是 ${json['coverage']}');
  }
  final cursor = json['cursor'];
  return CockpitRuntime(
    observedAt: _time(json['generated_at'], 'generated_at 无法解析'),
    cursor: cursor is Map ? _intOrNull(cursor[wire.cursorField]) : null,
    devices: _lane<List<CockpitDevice>>(
      json['devices'],
      '身体',
      (payload) => _items(payload, _device),
      payloadKey: 'items',
      empty: const [],
    ),
    activities: _lane<List<CockpitActivity>>(
      json['activities'],
      '活动',
      (payload) => _items(payload, _activity),
      payloadKey: 'items',
      empty: const [],
    ),
    turns: _lane<List<CockpitTurn>>(
      json['turns'],
      '对话轮次',
      (payload) => _items(payload, _turn),
      payloadKey: 'items',
      empty: const [],
    ),
    jobs: _lane<List<CockpitJob>>(
      json['jobs'],
      '后台任务',
      (payload) => _items(payload, _job),
      payloadKey: 'items',
      empty: const [],
    ),
    memory: _lane<CockpitMemory?>(
      json['memory'],
      '记忆',
      (payload) => payload == null
          ? null
          : _memory(_object(payload, 'memory.value 不是对象')),
      payloadKey: 'value',
      empty: null,
    ),
    services: _lane<List<CockpitService>>(
      json['services'],
      '底座',
      (payload) => _items(payload, _service),
      payloadKey: 'items',
      empty: const [],
    ),
    events: _lane<List<CockpitEvent>>(
      json['events'],
      '事件',
      (payload) => _items(payload, parseCockpitEvent),
      payloadKey: 'items',
      empty: const [],
    ),
  );
}

CockpitDevice _device(Map<String, Object?> json) {
  final presence = _object(json['presence'], 'device.presence 缺失');
  final state = _stringOr(presence['state'], wire.presenceUnknown);
  final source = _stringOr(presence['source'], wire.presenceSourceNone);
  return CockpitDevice(
    deviceId: _string(json['device_id'], 'device_id 缺失'),
    name: _stringOr(json['display_name']),
    kind: _stringOr(json['device_kind']),
    // The app's own device model speaks in lifecycle words; presence is carried
    // separately and never inferred from them.
    status: switch (state) {
      wire.presenceOnline => 'active',
      wire.presenceDegraded => 'degraded',
      wire.presenceOffline => 'offline',
      _ => 'unknown',
    },
    online: state == wire.presenceOnline,
    companionId: _stringOr(json['companion_id']),
    role: _stringOr(json['role']),
    lastSeenAt: _timeOrNull(presence['observed_at']),
    capabilities: _strings(json['capabilities']),
    // A web body nobody has answered for is "prepared", not offline — and only
    // when the absence of an answer is what happened.
    preparedWebBody: state == wire.presenceUnknown &&
        source == wire.presenceSourceNone &&
        _stringOr(json['device_kind']).toLowerCase().contains('web'),
  );
}

/// One page of history, read with the same parser the map's lane uses.
///
/// The Host projects both from one function, so this reads both with one — an
/// interaction opened from the history and the same interaction on the map
/// cannot come out describing themselves differently.
///
/// [ActivityPage.detail] carries the Host's reason when the page is empty
/// because something could not be read. Empty-because-nothing-happened and
/// empty-because-unreadable are the same shape and must never read the same:
/// an Owner whose Agent is away has not stopped having a history.
class ActivityPage {
  const ActivityPage({
    required this.items,
    required this.nextCursor,
    required this.detail,
  });

  final List<CockpitActivity> items;
  final String? nextCursor;
  final String detail;

  bool get readable => detail.isEmpty;
  bool get hasMore => (nextCursor ?? '').isNotEmpty;
}

ActivityPage activityPageFromJson(Map<String, Object?> json) {
  final detail = _stringOr(json['state']) == 'unavailable'
      ? (_stringOr(json['detail']).isEmpty
          ? '这台主机没能读到这段历史'
          : _stringOr(json['detail']))
      : '';
  final cursor = _stringOr(json['next_cursor']);
  return ActivityPage(
    items: detail.isEmpty ? _items(json['items'], _activity) : const [],
    nextCursor: cursor.isEmpty ? null : cursor,
    detail: detail,
  );
}

CockpitActivity _activity(Map<String, Object?> json) => CockpitActivity(
      activityId: _string(json['activity_id'], 'activity_id 缺失'),
      kind: _string(json['kind'], 'activity.kind 缺失'),
      companionId: _stringOr(json['companion_id']),
      status: _string(json['status'], 'activity.status 缺失'),
      summary: _stringOr(json['summary']),
      outcome: _stringOr(json['outcome'], 'success'),
      turnId: _stringOr(json['turn_id']),
      originDeviceId: _stringOr(json['origin_device_id']),
      targetDeviceIds: _strings(json['target_device_ids']),
      currentHopId: _stringOr(json['current_hop_id']),
      startedAt: _timeOrNull(json['started_at']),
      updatedAt: _timeOrNull(json['updated_at']),
      route: _items(json['route'], _hop),
    );

CockpitHop _hop(Map<String, Object?> json) => CockpitHop(
      hopId: _string(json['hop_id'], 'hop_id 缺失'),
      label: _string(json['label'], 'hop.label 缺失'),
      stage: _stringOr(json['stage']),
      status: _string(json['status'], 'hop.status 缺失'),
      nodeType: _stringOr(json['node_type']),
      latencyMs: _intOrNull(json['latency_ms']),
    );

CockpitTurn _turn(Map<String, Object?> json) => CockpitTurn(
      turnId: _string(json['turn_id'], 'turn_id 缺失'),
      companionId: _string(json['companion_id'], 'turn.companion_id 缺失'),
      status: _string(json['status'], 'turn.status 缺失'),
      trigger: _stringOr(json['trigger']),
      latencyMs: _intOrNull(json['latency_ms']),
      memoryHits: _intOrNull(json['memory_hits']) ?? 0,
      toolNames: _strings(json['tool_names']),
      deviceId: _stringOr(json['device_id']),
      stages: _items(
        json['stages'],
        (stage) => CockpitTurnStage(
          key: _string(stage['key'], 'stage.key 缺失'),
          label: _string(stage['label'], 'stage.label 缺失'),
          status: _string(stage['status'], 'stage.status 缺失'),
          latencyMs: _intOrNull(stage['latency_ms']),
        ),
      ),
      // No status to read: a phase either was measured or was not reached, and
      // the latency being null says which.
      breakdown: _items(
        json['breakdown'],
        (phase) => CockpitTurnPhase(
          key: _string(phase['key'], 'breakdown.key 缺失'),
          label: _string(phase['label'], 'breakdown.label 缺失'),
          latencyMs: _intOrNull(phase['latency_ms']),
        ),
      ),
    );

CockpitJob _job(Map<String, Object?> json) => CockpitJob(
      jobId: _string(json['job_id'], 'job_id 缺失'),
      companionId: _stringOr(json['companion_id']),
      kind: _string(json['kind'], 'job.kind 缺失'),
      status: _string(json['status'], 'job.status 缺失'),
      summary: _stringOr(json['summary']),
    );

CockpitMemory _memory(Map<String, Object?> json) => CockpitMemory(
      realmsTotal: _intOrNull(json['realms_total']) ?? 0,
      activeRealmId: _stringOr(json['active_realm_id']),
      runnersOnline: _intOrNull(json['runners_online']) ?? 0,
      runnersTotal: _intOrNull(json['runners_total']) ?? 0,
      lastWriteDisposition: _stringOr(json['last_write_disposition']),
    );

CockpitService _service(Map<String, Object?> json) => CockpitService(
      serviceId: _string(json['service_id'], 'service_id 缺失'),
      name: _stringOr(json['display_name']),
      code: _stringOr(json['code']),
      role: '',
      mode: _stringOr(json['mode']),
      tier: switch (_stringOr(json['tier'])) {
        'middleware' => ServiceTier.middleware,
        'external' => ServiceTier.external,
        _ => ServiceTier.service,
      },
      glyph: '·',
      online: _boolOr(json['online'], false),
      // Absent means unprobed, never healthy. This is the one default that must
      // fall the pessimistic way.
      checked: _boolOr(json['checked'], false),
      latencyMs: _intOrNull(json['latency_ms']),
      detail: _stringOr(json['detail']),
    );

CockpitEvent parseCockpitEvent(Map<String, Object?> json) => CockpitEvent(
      eventId: _string(json['event_id'], 'event_id 缺失'),
      ingestSeq: _intOrNull(json[wire.cursorField]),
      ts: _time(json['ts'], 'event.ts 无法解析'),
      source: _string(json['source'], 'event.source 缺失'),
      type: _string(json['type'], 'event.type 缺失'),
      summary: _stringOr(json['summary']),
      severity: _stringOr(json['severity'], 'info'),
      outcome: _stringOr(json['outcome'], 'success'),
      origin: _stringOr(json['origin'], 'live'),
      companionId: _stringOr(json['companion_id']),
      deviceId: _stringOr(json['device_id']),
      turnId: _stringOr(json['turn_id']),
      milestone: _stringOr(json['milestone']),
    );

/// Whether an event is the stream telling a client its cursor is no longer
/// honourable. The client drops it and re-reads a snapshot.
bool isStreamReset(CockpitEvent event) => event.type == wire.streamResetEvent;

/// Fill each companion's recall from its own most recent turn.
///
/// The contract carries no per-companion recall, on purpose: it is already on
/// the turn, and asking the memory service per companion would be a cross
/// service read for a number that was in hand.
CockpitSnapshot attachRecall(CockpitSnapshot snapshot) {
  if (!snapshot.turnsLane.readable) return snapshot;
  final latest = <String, CockpitTurn>{};
  for (final turn in snapshot.turns) {
    latest.putIfAbsent(turn.companionId, () => turn);
  }
  return CockpitSnapshot(
    // Carried through: this rebuilds a reading, it does not make one.
    provenance: snapshot.provenance,
    generatedAt: snapshot.generatedAt,
    cursor: snapshot.cursor,
    defaultCompanionId: snapshot.defaultCompanionId,
    ownerLane: snapshot.ownerLane,
    companionsLane: CockpitLane<List<CockpitCompanion>>(
      state: snapshot.companionsLane.state,
      detail: snapshot.companionsLane.detail,
      observedAt: snapshot.companionsLane.observedAt,
      latencyMs: snapshot.companionsLane.latencyMs,
      truncated: snapshot.companionsLane.truncated,
      value: snapshot.companions
          .map(
            (companion) => CockpitCompanion(
              companionId: companion.companionId,
              displayName: companion.displayName,
              status: companion.status,
              kind: companion.kind,
              genomeId: companion.genomeId,
              realmId: companion.realmId,
              recallHits: latest[companion.companionId]?.memoryHits,
              runners: companion.runners,
              writeDisposition: companion.writeDisposition,
            ),
          )
          .toList(growable: false),
    ),
    devicesLane: snapshot.devicesLane,
    activitiesLane: snapshot.activitiesLane,
    turnsLane: snapshot.turnsLane,
    jobsLane: snapshot.jobsLane,
    memoryLane: snapshot.memoryLane,
    servicesLane: snapshot.servicesLane,
    eventsLane: snapshot.eventsLane,
    streamState: snapshot.streamState,
    traceId: snapshot.traceId,
  );
}

/// The moments in [events] that arrived after [watermark], oldest first.
///
/// The feed fires a dart for each of these. That is not the same as inventing
/// one from a snapshot diff — the thing this cockpit refuses to do — and the
/// difference is what an event is: an id, a moment, a subject and a direction
/// that a Host observed and recorded. Two snapshots differing in *state* say
/// nothing about when or how it changed; an event that was not in the last
/// reading and is in this one is a moment that happened in between, and the
/// Host's own sequence number is the proof of order.
///
/// A null [watermark] returns nothing. The first reading carries a backlog —
/// a hundred moments from before anyone was looking — and firing those would
/// claim they were happening now. The first reading sets the baseline instead.
///
/// Events with no sequence are skipped rather than guessed at: a Host that
/// keeps no order cannot say whether one of its events is new.
List<CockpitEvent> eventsAfter(int? watermark, List<CockpitEvent> events) {
  if (watermark == null) return const <CockpitEvent>[];
  final fresh = events
      .where((event) => (event.ingestSeq ?? -1) > watermark)
      .toList(growable: false)
    ..sort((a, b) => (a.ingestSeq ?? 0).compareTo(b.ingestSeq ?? 0));
  return fresh;
}

/// The highest sequence in [events], or [previous] when none of them carry one.
int? highestSequence(int? previous, List<CockpitEvent> events) {
  var top = previous;
  for (final event in events) {
    final seq = event.ingestSeq;
    if (seq != null && (top == null || seq > top)) top = seq;
  }
  return top;
}

/// One stage of one turn, as it was seen to move.
///
/// The unit of the live map. A turn's stages are the journey a signal takes —
/// heard, remembered, thought about, spoken — and a stage that was `pending` in
/// the last reading and `running` in this one is a thing that happened in
/// between. Same discipline as [eventsAfter]: reporting an observation, not
/// inventing one from a difference in state.
class StageAdvance {
  const StageAdvance({
    required this.turnId,
    required this.companionId,
    required this.stageKey,
    required this.label,
    required this.status,
    required this.at,
  });

  final String turnId;
  final String companionId;
  final String stageKey;
  final String label;

  /// What the stage moved *to*.
  final String status;

  /// When this reading was taken. A stage transition has no timestamp of its
  /// own — the Host reports a status, not a moment — so this is honest about
  /// what it is: the instant it became visible, not the instant it occurred.
  final DateTime at;
}

/// Stage transitions between two readings, oldest turn first.
///
/// A turn that is new to this reading contributes only its *running* stage, not
/// its whole history: a turn that arrived already half-done did those stages
/// before anyone was looking, and drawing them now would claim they are
/// happening. Same rule as the first reading in [eventsAfter].
///
/// And a dart needs a departure. A stage that goes straight from `pending` to a
/// settled status never ran — a turn that called no tools ends with its tool
/// stage settling from "not started" to "over" — so nothing travelled and
/// nothing comes back. Only a stage that *starts* running, or one that was
/// running and is now finished, is a journey. This was unreachable while every
/// turn arrived already complete; a turn watched across readings reaches it on
/// every conversation.
List<StageAdvance> stagesAdvanced(
  List<CockpitTurn> before,
  List<CockpitTurn> after, {
  required DateTime at,
}) {
  final previous = <String, Map<String, String>>{};
  for (final turn in before) {
    previous[turn.turnId] = {
      for (final stage in turn.stages) stage.key: stage.status,
    };
  }
  final moved = <StageAdvance>[];
  for (final turn in after) {
    final was = previous[turn.turnId];
    for (final stage in turn.stages) {
      final wasStatus = was?[stage.key];
      if (was == null) {
        // First sighting of this turn. Only what is happening now.
        if (!stageIsRunning(stage.status)) continue;
      } else if (wasStatus == stage.status) {
        continue;
      } else if (!stageIsRunning(stage.status) &&
          !stageIsRunning(wasStatus ?? '')) {
        // Settled without ever having started: bookkeeping, not a journey.
        continue;
      }
      moved.add(
        StageAdvance(
          turnId: turn.turnId,
          companionId: turn.companionId,
          stageKey: stage.key,
          label: stage.label,
          status: stage.status,
          at: at,
        ),
      );
    }
  }
  return moved;
}

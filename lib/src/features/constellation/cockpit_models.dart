import '../../protocol/companion_contract.dart';

// The view model the constellation is drawn from.
//
// It is deliberately the console cockpit's information model — Owner ▸
// companions ▸ (bodies, memory, activity) — and not this Host's Local API
// shapes. The screen is being built before the Owner-scoped projection exists
// (`GET /api/management/v1/mission-control/snapshot`), so a mock feed fills these
// same structures today and the wire adapter fills them tomorrow without the
// drawing changing.
//
// One rule survives from the product surface: no field here means "online" for
// anything nobody publishes presence for. Device presence is carried, service
// health is carried, and everything else says what it is.

/// One projection block, carrying its own health.
///
/// The contract's first rule (`docs/mission-control-local-api-contract.md` §2):
/// "read it, it was empty" and "could not read it" must not share a shape. A
/// lane that failed still ships an empty payload — so callers never crash — but
/// it says so, and every screen that shows it has to decide what to say instead
/// of quietly showing nothing.
enum LaneState { ok, degraded, unavailable }

class CockpitLane<T> {
  const CockpitLane({
    required this.state,
    required this.value,
    this.detail = '',
    this.observedAt,
    this.latencyMs,
    this.truncated = false,
  });

  /// A lane that was read.
  const CockpitLane.ok(
    this.value, {
    this.observedAt,
    this.latencyMs,
    this.truncated = false,
  }) : state = LaneState.ok,
       detail = '';

  /// A lane that could not be read. [value] is the caller's chosen empty — an
  /// empty list, or null — and [detail] is why.
  const CockpitLane.missing(this.value, this.detail)
    : state = LaneState.unavailable,
      observedAt = null,
      latencyMs = null,
      truncated = false;

  final LaneState state;
  final T value;

  /// Which authority did not answer, and why. Shown to the reader when the lane
  /// is not ok — a degraded lane with no detail is an unactionable screen.
  final String detail;
  final DateTime? observedAt;
  final int? latencyMs;

  /// The list hit its bound. Silent truncation reads as "that is all there is".
  final bool truncated;

  bool get readable => state != LaneState.unavailable;
  bool get healthy => state == LaneState.ok;
}

LaneState laneStateFromWire(Object? value) => switch (value) {
  'ok' => LaneState.ok,
  'degraded' => LaneState.degraded,
  'unavailable' => LaneState.unavailable,
  // An unknown state is not assumed healthy. The contract's whole point is
  // that this screen never guesses in the optimistic direction.
  _ => LaneState.unavailable,
};

/// The tones every runtime fact collapses to. Anything richer invites a screen
/// where "quiet" and "could not tell" look the same.
enum CockpitTone { ok, live, warn, bad, idle, off }

enum StreamState { connecting, live, degraded }

String streamLabel(StreamState state) => switch (state) {
  StreamState.connecting => 'SYNC',
  StreamState.live => 'ONLINE',
  StreamState.degraded => 'UNSTABLE',
};

CockpitTone streamTone(StreamState state) => switch (state) {
  StreamState.connecting => CockpitTone.idle,
  StreamState.live => CockpitTone.ok,
  StreamState.degraded => CockpitTone.bad,
};

/// Which of a companion's three asset moons a fact belongs to.
enum MoonKind { body, mem, act }

String moonLabel(MoonKind kind) => switch (kind) {
  MoonKind.body => '身体',
  MoonKind.mem => '记忆',
  MoonKind.act => '活动',
};

String moonGlyph(MoonKind kind) => switch (kind) {
  MoonKind.body => '⬡',
  MoonKind.mem => '◈',
  MoonKind.act => '⚡',
};

/// One hue per asset kind, matching the console's moon accents.
CockpitColorRole moonAccent(MoonKind kind) => switch (kind) {
  MoonKind.body => CockpitColorRole.cyan,
  MoonKind.mem => CockpitColorRole.yellow,
  MoonKind.act => CockpitColorRole.magenta,
};

enum CockpitColorRole { cyan, yellow, magenta }

enum PulseDirection { inward, outward }

enum PulseTone { normal, warn, bad }

class CockpitOwner {
  const CockpitOwner({
    required this.ownerId,
    required this.displayName,
    this.kind = 'person',
    this.status = 'active',
  });

  final String ownerId;
  final String displayName;
  final String kind;
  final String status;
}

class CockpitDevice {
  const CockpitDevice({
    required this.deviceId,
    required this.name,
    required this.kind,
    required this.status,
    required this.online,
    this.companionId = '',
    this.role = '',
    this.lastSeenAt,
    this.capabilities = const <String>[],
    this.presenceUnobserved = false,
  });

  final String deviceId;
  final String name;

  /// The Manifest identifier this body was admitted under.
  ///
  /// The wire calls this `device_kind` and the schema still describes it as a
  /// hardware class, but no producer has ever put one there: Hub copies
  /// `manifest_id` into a column it happens to have named `device_kind`
  /// (`hub/contracts/mappers.py`), and Admin projects it onward unchanged
  /// (`local_api/management/mission_control.py`). The wire key is deliberately
  /// not being renamed — see `docs/设备与Body/Manifest契约收敛.md` §8.3 ⑤ — so
  /// the correction that is available here is to stop reading it as a kind.
  ///
  /// It is an opaque identifier. Show it, match it whole against something an
  /// authority also names, but never take it apart for meaning.
  final String kind;
  final String status;
  final bool online;
  final String companionId;
  final String role;
  final DateTime? lastSeenAt;
  final List<String> capabilities;

  /// This body is on the Owner's roster and no authority has answered for
  /// whether it is present. Neither online nor a fault, and calling it either
  /// would be a lie.
  ///
  /// This is `presence.state == unknown` reached with `presence.source == none`
  /// — the Host's own words for it are "known to exist, and unobserved. Two
  /// different facts, and this is the second one." It says nothing about what
  /// the body runs on: this wire carries no field that does, which is why this
  /// used to be called `preparedWebBody` and was wrong.
  final bool presenceUnobserved;
}

class CockpitTurnStage {
  const CockpitTurnStage({
    required this.key,
    required this.label,
    required this.status,
    this.latencyMs,
  });

  final String key;
  final String label;
  final String status;
  final int? latencyMs;
}

/// One measured stretch inside a turn: where the time went.
///
/// Not a [CockpitTurnStage]. A stage is a place on the map that the darts and
/// the wavefront point at, which is why its keys are a controlled vocabulary; a
/// phase here is a number read in a list and nothing aims at one. A null
/// latency means the turn never reached it — different from zero, which would
/// read as a step that took no time.
class CockpitTurnPhase {
  const CockpitTurnPhase({
    required this.key,
    required this.label,
    this.latencyMs,
  });

  final String key;
  final String label;
  final int? latencyMs;
}

class CockpitTurn {
  const CockpitTurn({
    required this.turnId,
    required this.companionId,
    required this.status,
    this.trigger = '',
    this.latencyMs,
    this.memoryHits = 0,
    this.toolNames = const <String>[],
    this.stages = const <CockpitTurnStage>[],
    this.breakdown = const <CockpitTurnPhase>[],
    this.deviceId = '',
  });

  final String turnId;
  final String companionId;
  final String status;
  final String trigger;
  final int? latencyMs;
  final int memoryHits;
  final List<String> toolNames;

  /// Where this turn's time went, in order.
  final List<CockpitTurnPhase> breakdown;
  final List<CockpitTurnStage> stages;
  final String deviceId;
}

class CockpitHop {
  const CockpitHop({
    required this.hopId,
    required this.label,
    required this.stage,
    required this.status,
    required this.nodeType,
    this.latencyMs,
  });

  final String hopId;
  final String label;
  final String stage;
  final String status;
  final String nodeType;
  final int? latencyMs;
}

class CockpitActivity {
  const CockpitActivity({
    required this.activityId,
    required this.kind,
    required this.companionId,
    required this.status,
    required this.summary,
    this.outcome = 'success',
    this.turnId = '',
    this.originDeviceId = '',
    this.targetDeviceIds = const <String>[],
    this.route = const <CockpitHop>[],
    this.currentHopId = '',
    this.startedAt,
    this.updatedAt,
  });

  final String activityId;
  final String kind;
  final String companionId;
  final String status;
  final String summary;
  final String outcome;
  final String turnId;
  final String originDeviceId;
  final List<String> targetDeviceIds;
  final List<CockpitHop> route;
  final String currentHopId;
  final DateTime? startedAt;
  final DateTime? updatedAt;
}

class CockpitJob {
  const CockpitJob({
    required this.jobId,
    required this.companionId,
    required this.kind,
    required this.status,
    required this.summary,
  });

  final String jobId;
  final String companionId;
  final String kind;
  final String status;
  final String summary;
}

class CockpitCompanion {
  const CockpitCompanion({
    required this.companionId,
    required this.displayName,
    required this.status,
    this.kind = 'companion',
    this.genomeId = '',
    this.realmId,
    this.recallHits,
    this.runners = '',
    this.writeDisposition = '',
  });

  final String companionId;
  final String displayName;
  final String status;
  final String kind;
  final String genomeId;

  /// The Companion's memory realm: an id, `''` for "has none", and null for
  /// "nobody asked". The three are different answers and the screen says which.
  final String? realmId;
  final int? recallHits;
  final String runners;
  final String writeDisposition;
}

/// Which architectural plane a substrate service sits on.
enum ServiceTier { service, middleware, external }

class CockpitService {
  const CockpitService({
    required this.serviceId,
    required this.name,
    required this.code,
    required this.role,
    required this.mode,
    required this.tier,
    required this.glyph,
    required this.online,
    required this.checked,
    this.latencyMs,
    this.detail = '',
  });

  final String serviceId;
  final String name;
  final String code;
  final String role;
  final String mode;
  final ServiceTier tier;
  final String glyph;
  final bool online;

  /// Whether anybody actually asked. An unchecked service is not a healthy one.
  final bool checked;
  final int? latencyMs;
  final String detail;

  String get stateLabel => !checked ? '未探测' : (online ? '在线' : '离线');

  CockpitTone get tone =>
      !checked ? CockpitTone.warn : (online ? CockpitTone.ok : CockpitTone.bad);
}

class CockpitEvent {
  const CockpitEvent({
    required this.eventId,
    this.ingestSeq,
    required this.ts,
    required this.source,
    required this.type,
    required this.summary,
    this.severity = 'info',
    this.outcome = 'success',
    this.origin = 'live',
    this.companionId = '',
    this.deviceId = '',
    this.turnId = '',
    this.milestone = '',
  });

  final String eventId;

  /// Where this moment sits in the Host's own total order, when the Host keeps
  /// one. Carried on the event rather than read out of the payload beside it:
  /// a consumer that has to ask a second function where an event came in the
  /// order is a consumer that can forget to.
  final int? ingestSeq;
  final DateTime ts;
  final String source;
  final String type;
  final String summary;
  final String severity;
  final String outcome;
  final String origin;
  final String companionId;
  final String deviceId;
  final String turnId;

  /// The semantic phase the event reports, when it carries one. Milestone beats
  /// source when deciding which leg lights: Channel touches the body on the way
  /// in and the activity on the way to the brain.
  final String milestone;
}

class CockpitMemory {
  const CockpitMemory({
    this.realmsTotal = 0,
    this.activeRealmId = '',
    this.audienceScope = '',
    this.dataReadable = false,
    this.materializationState = 'unavailable',
    this.projectionPending = 0,
    this.lastMaterializedAt = '',
    this.degradedReason = '',
    this.lastRecallHits = 0,
    this.lastWriteDisposition = '',
  });

  final int realmsTotal;
  final String activeRealmId;
  final String audienceScope;
  final bool dataReadable;
  final String materializationState;
  final int projectionPending;
  final String lastMaterializedAt;
  final String degradedReason;
  final int lastRecallHits;
  final String lastWriteDisposition;
}

/// Everything the cockpit draws at one instant.
///
/// Each block is a lane, so a screen can tell "this Owner has no jobs" from
/// "nobody could tell us about jobs". The plain getters return the payload for
/// the many places that only need the facts; the `*Lane` fields are for the
/// places that have to say something when a lane did not read.
/// Who observed a reading. Not a style flag: it decides whether the chrome is
/// allowed to call a reading staged.
enum CockpitProvenance {
  /// A Host answered.
  host,

  /// A staged world, which must never be able to pass for a Host's own word.
  staged,
}

class CockpitSnapshot {
  const CockpitSnapshot({
    required this.generatedAt,
    required this.ownerLane,
    required this.companionsLane,
    required this.devicesLane,
    required this.servicesLane,
    this.activitiesLane = const CockpitLane<List<CockpitActivity>>.ok(
      <CockpitActivity>[],
    ),
    this.turnsLane = const CockpitLane<List<CockpitTurn>>.ok(<CockpitTurn>[]),
    this.jobsLane = const CockpitLane<List<CockpitJob>>.ok(<CockpitJob>[]),
    this.eventsLane = const CockpitLane<List<CockpitEvent>>.ok(
      <CockpitEvent>[],
    ),
    this.memoryLane = const CockpitLane<CockpitMemory?>.ok(null),
    this.streamState = StreamState.live,
    this.traceId = '',
    this.cursor,
    this.defaultCompanionId,
    required this.provenance,
  });

  final DateTime generatedAt;
  final CockpitLane<CockpitOwner?> ownerLane;
  final CockpitLane<List<CockpitCompanion>> companionsLane;
  final CockpitLane<List<CockpitDevice>> devicesLane;
  final CockpitLane<List<CockpitService>> servicesLane;
  final CockpitLane<List<CockpitActivity>> activitiesLane;
  final CockpitLane<List<CockpitTurn>> turnsLane;
  final CockpitLane<List<CockpitJob>> jobsLane;
  final CockpitLane<List<CockpitEvent>> eventsLane;
  final CockpitLane<CockpitMemory?> memoryLane;
  final StreamState streamState;
  final String traceId;

  /// Who observed this reading: a Host, or a staged world.
  ///
  /// Required, and carried by the data rather than assumed by the chrome. The
  /// header used to print a hardcoded `MOCK` badge, written when the mock was
  /// the only feed there was — so the first real reading of a real Host arrived
  /// on screen labelled as staged. A screen may only say where a fact came from
  /// if the fact says so itself.
  final CockpitProvenance provenance;

  /// Where the event stream should resume: the audit index's own total order.
  final int? cursor;

  /// Which Companion answers by default, said once. A flag on every row would be
  /// a second place the same question gets decided — and a per-row flag is only
  /// ever right while there is one Companion, which is the worst kind of wrong.
  final String? defaultCompanionId;

  CockpitOwner get owner =>
      ownerLane.value ?? const CockpitOwner(ownerId: '', displayName: '');
  List<CockpitCompanion> get companions => companionsLane.value;
  List<CockpitDevice> get devices => devicesLane.value;
  List<CockpitService> get services => servicesLane.value;
  List<CockpitActivity> get activities => activitiesLane.value;
  List<CockpitTurn> get turns => turnsLane.value;
  List<CockpitJob> get jobs => jobsLane.value;
  List<CockpitEvent> get events => eventsLane.value;
  CockpitMemory get memory => memoryLane.value ?? const CockpitMemory();

  /// Lanes that could not be read at all, by name. Said out loud on screen
  /// rather than folded into a healthy-looking whole.
  List<String> get unreadableLanes => <String>[
    if (!ownerLane.readable) '主人',
    if (!companionsLane.readable) '伙伴',
    if (!devicesLane.readable) '身体',
    if (!activitiesLane.readable) '活动',
    if (!turnsLane.readable) '对话轮次',
    if (!jobsLane.readable) '后台任务',
    if (!memoryLane.readable) '记忆',
    if (!servicesLane.readable) '底座',
    if (!eventsLane.readable) '事件',
  ];

  /// Bodies nobody has claimed yet. They belong to the frame, not to a planet.
  List<CockpitDevice> get unboundDevices => devices
      .where((device) => device.companionId.isEmpty)
      .toList(growable: false);

  bool get pipelineActive => activities.any(isActiveActivity);
}

/// A companion resolved against the snapshot: its bodies, its memory state and
/// what it is doing right now, in one object the geometry can consume.
class CompanionUnit {
  const CompanionUnit({
    required this.companion,
    required this.devices,
    required this.activities,
    required this.turns,
    required this.jobs,
    this.isDefault = false,
    this.bodiesReadable = true,
    this.activitiesReadable = true,
    this.recallReadable = true,
  });

  final CockpitCompanion companion;
  final List<CockpitDevice> devices;
  final List<CockpitActivity> activities;
  final List<CockpitTurn> turns;
  final List<CockpitJob> jobs;

  /// Whether this is the Companion that answers by default. Compared by the
  /// caller against the snapshot rather than read from a per-row flag.
  final bool isDefault;

  /// Whether the lane each of this companion's assets is drawn from actually
  /// read. An empty list from a failed lane must not be drawn as "none".
  final bool bodiesReadable;
  final bool activitiesReadable;
  final bool recallReadable;

  String get id => companion.companionId;
  String get name => companion.displayName.isEmpty
      ? companion.companionId
      : companion.displayName;
  String? get realm => companion.realmId;
  String get genome => companion.genomeId;

  CockpitActivity? get activeActivity =>
      activities.where(isActiveActivity).firstOrNull;

  CockpitTurn? get turn => turns.firstOrNull;

  CockpitTurn? get activeVoiceTurn {
    final activity = activeActivity;
    if (activity == null || activity.kind != 'voice_turn') return null;
    return turns.where((item) => item.turnId == activity.turnId).firstOrNull ??
        turns.firstOrNull;
  }

  int get onlineDevices => devices.where((device) => device.online).length;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

// ── pure semantics ─────────────────────────────────────────────────────────
// The mappings below are the console cockpit's, restated in Dart. They are
// pure so a test can pin them: a screen that quietly disagrees with the console
// about what "denied" looks like is worse than one that cannot draw it at all.

const Set<String> activeActivityStates = <String>{
  'running',
  'active',
  'pending',
  'queued',
  'accepted',
  'processing',
  'generating',
  'speaking',
  'deferred',
};

bool isActiveActivity(CockpitActivity? activity) =>
    activity != null &&
    activeActivityStates.contains(activity.status.toLowerCase());

CockpitTone statusTone(String? status) {
  final value = (status ?? '').toLowerCase();
  if (const [
    'ok',
    'done',
    'succeeded',
    'completed',
    'active',
    'success',
  ].contains(value)) {
    return CockpitTone.ok;
  }
  if (const [
    'running',
    'pending',
    'queued',
    'degraded',
    'warn',
    'interrupted',
  ].contains(value)) {
    return CockpitTone.warn;
  }
  if (const [
    'failed',
    'error',
    'errored',
    'offline',
    'orphaned',
  ].contains(value)) {
    return CockpitTone.bad;
  }
  return CockpitTone.idle;
}

String activityKindLabel(String kind) => switch (kind) {
  'voice_turn' => '对话',
  'guard_event' => '守护',
  'device_command' => '指令',
  'device_event' => '设备',
  'background_job' => '任务',
  _ => '活动',
};

String activityStatusLabel(String status) => switch (status.toLowerCase()) {
  'running' || 'active' => '进行中',
  'pending' => '等待中',
  'queued' => '排队中',
  'generating' => '生成中',
  'speaking' => '播报中',
  'completed' || 'succeeded' || 'success' => '已完成',
  'interrupted' => '已打断',
  'rejected' || 'denied' => '已拒绝',
  'timeout' => '已超时',
  'failed' || 'error' => '失败',
  'orphaned' => '已中断',
  _ => status.isEmpty ? '未知' : status,
};

// There is deliberately no `deviceTypeLabel` here any more.
//
// It read 虚拟身体 / 物理身体 out of `device.kind` by substring — but that field
// carries a Manifest identifier (see [CockpitDevice.kind]), so a Manifest named
// `eidolon-webcam-...` was announced as a virtual body and a real web body whose
// Manifest id happened not to spell `web` was announced as a physical one. The
// replacement is not a better pattern: nothing on this wire says what a body
// runs on. `role`/`role_kind` answer a different question (which Eidolon speaks
// through it), `capabilities` is empty for every body the blackboard has not
// seen, and the canonical `DeviceCapabilityManifest` — which is not on this wire
// at all — declares properties, actions, events and media, and no form factor.
// So this app does not say. A screen that needs a word for a body has its name,
// its role and its Manifest id, all of which somebody actually asserted.

String devicePresenceLabel(CockpitDevice device) {
  if (device.online) return '在线';
  if (device.presenceUnobserved) return '无人观测';
  if (device.status == 'degraded') return '不稳定';
  if (device.status == 'active') return '已绑定';
  if (device.status == 'unknown') return '未探测';
  return '离线';
}

CockpitTone devicePresenceTone(CockpitDevice device) {
  if (device.online) return CockpitTone.ok;
  if (device.presenceUnobserved) return CockpitTone.idle;
  if (device.status == 'degraded') return CockpitTone.warn;
  if (device.status == 'offline') return CockpitTone.bad;
  return CockpitTone.idle;
}

/// How a Companion's lifecycle reads in this cockpit's palette.
///
/// The words and the vocabulary live in `protocol/companion_contract.dart`,
/// shared with the management surface. Only the tone is here, because a tone is
/// this surface's own decision and the protocol layer has no business knowing
/// about a cockpit palette.
///
/// Three of the four values mean "not running", and they are not the same thing
/// to an Owner: on its way out, already put away, being destroyed. A generic
/// status-to-tone mapping collapses all three into one idle grey.
CockpitTone companionLifecycleTone(String state) => switch (state) {
  lifecycleActive => CockpitTone.ok,
  // In transition, and the Owner may still want to stop it.
  lifecycleRetiring || lifecycleDeleting => CockpitTone.warn,
  lifecycleArchived => CockpitTone.off,
  _ => CockpitTone.idle,
};

String genomeStateLabel(String genomeId) => genomeId.isEmpty ? '未绑定' : '已绑定';

/// Three answers, not two. `null` is not the same as none: the roster carries
/// existence and identity, and the realm is neither — so until a projection
/// says, this reads 未知 rather than telling the Owner their Eidolon has no
/// memory.
String memoryRealmStateLabel(String? realmId) => realmId == null
    ? '未知'
    : realmId.isEmpty
    ? '未开通'
    : '已配置';

String formatLatency(int? ms) {
  if (ms == null) return '—';
  return ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(2)}s';
}

String formatClock(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// When something happened, at the grain a history needs.
///
/// [formatClock] is for the live map, where everything is within the minute and
/// only the seconds matter. A history spans days, so a bare clock there tells a
/// reader nothing about which day they are looking at.
///
/// Local time, because the reader is in it. Null renders as an em dash rather
/// than as now: an activity with no start is one the Host did not say the start
/// of, and defaulting it to the present would make the oldest row look newest.
String formatWhen(DateTime? at, {DateTime? now}) {
  if (at == null) return '—';
  final local = at.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}';
  final sameDay =
      local.year == today.year &&
      local.month == today.month &&
      local.day == today.day;
  if (sameDay) return '今天 $clock';
  final yesterday = today.subtract(const Duration(days: 1));
  final wasYesterday =
      local.year == yesterday.year &&
      local.month == yesterday.month &&
      local.day == yesterday.day;
  if (wasYesterday) return '昨天 $clock';
  return '${local.month}月${local.day}日 $clock';
}

/// A short, human form of an opaque identifier. Presentation only — never a key.
String compactId(String value, {int maxLength = 18}) {
  if (value.length <= maxLength) return value;
  final visible = maxLength - 1 < 8 ? 8 : maxLength - 1;
  final tail = (visible * 0.4).floor().clamp(4, 8);
  final head = visible - tail;
  return '${value.substring(0, head)}…${value.substring(value.length - tail)}';
}

String deviceShortName(CockpitDevice device) {
  final name = device.name.trim();
  if (name.isNotEmpty && name != device.deviceId) return name;
  final id = device.deviceId.trim();
  if (RegExp(
    r'^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$',
    caseSensitive: false,
  ).hasMatch(id)) {
    return '尾号 ${id.substring(id.length - 5).toUpperCase()}';
  }
  return compactId(id).isEmpty ? '未命名设备' : compactId(id);
}

/// Which moon a voice stage lights. Same vocabulary the console uses, so the
/// constellation points at the same moment as everything else on screen.
const Map<String, MoonKind> _stageMoon = <String, MoonKind>{
  'input': MoonKind.body,
  'speech': MoonKind.body,
  'duck': MoonKind.body,
  'eot': MoonKind.body,
  'commit': MoonKind.act,
  'memory_recall': MoonKind.mem,
  'agent_turn': MoonKind.act,
  'brain': MoonKind.act,
  'response': MoonKind.act,
  'tools': MoonKind.act,
  'tts': MoonKind.body,
  'playback': MoonKind.body,
  'memory_write': MoonKind.mem,
};

MoonKind? stageMoon(String stageKey) => _stageMoon[stageKey];

const List<String> _stageRunning = ['running', 'active', 'in_progress'];
const List<String> _stageDone = ['done', 'ok', 'succeeded', 'skipped'];

/// Whether a stage is happening now.
///
/// `pending` is deliberately **not** running. It used to be, and the live
/// snapshot showed what that costs: every finished turn on that Host carried
/// `memory_write: pending`, so a turn that ended minutes ago read as "currently
/// writing memory" — forever, on every planet. `pending` means the Host has not
/// started it and may never: a turn can end with a stage still pending.
bool stageIsRunning(String status) =>
    _stageRunning.contains(status.toLowerCase());

/// Whether a stage has finished, one way or another.
bool stageIsDone(String status) => _stageDone.contains(status.toLowerCase());

/// The stage a turn is currently at, or '' when it has none.
String currentStageKey(CockpitTurn? turn) {
  final stages = turn?.stages ?? const <CockpitTurnStage>[];
  for (final stage in stages) {
    if (stageIsRunning(stage.status)) return stage.key;
  }
  for (final stage in stages.reversed) {
    if (_stageDone.contains(stage.status.toLowerCase())) return stage.key;
  }
  return '';
}

CockpitHop? currentActivityHop(CockpitActivity activity) {
  if (activity.currentHopId.isNotEmpty) {
    for (final hop in activity.route) {
      if (hop.hopId == activity.currentHopId) return hop;
    }
  }
  for (final hop in activity.route.reversed) {
    if (hop.status == 'running') return hop;
  }
  if (isActiveActivity(activity) && activity.route.isNotEmpty) {
    return activity.route.last;
  }
  return null;
}

/// Which legs of a companion's internal circuit are lit, and how bright the
/// memory leg burns.
class FlowLegs {
  const FlowLegs({
    required this.body,
    required this.mem,
    required this.memBright,
    required this.act,
  });

  final bool body;
  final bool mem;
  final double memBright;
  final bool act;

  bool get any => body || mem || act;
}

const double _memSaturation = 6;
const double _memFloor = 0.45;

FlowLegs flowLegs(CompanionUnit unit) {
  final body = unit.devices.any((device) => device.online);
  final hits = unit.turn?.memoryHits ?? 0;
  final mem = hits > 0;
  final bright = mem
      ? _memFloor + (1 - _memFloor) * (hits / _memSaturation).clamp(0.0, 1.0)
      : 0.0;
  return FlowLegs(
    body: body,
    mem: mem,
    memBright: bright,
    act: unit.activeActivity != null,
  );
}

/// Active-companion count at or below which unfocused companions still
/// circulate, so the resting view looks alive without a tap and a busy one
/// falls back to the lighter node pulse.
const int autoFlowMax = 2;

bool shouldFlow({
  required String companionId,
  required String? focusedId,
  required bool hasActivity,
  required int activeCount,
}) {
  if (!hasActivity) return false;
  if (focusedId != null && focusedId.isNotEmpty && companionId == focusedId) {
    return true;
  }
  return activeCount <= autoFlowMax;
}

/// The dart one observed stage transition travels.
///
/// One rule, uniform: **a stage that starts running goes out, a stage that
/// finishes comes back.** The signal leaves the planet for the organ that does
/// the work — the body that heard it, the memory being searched, the reasoning —
/// and returns when that organ answers. Nothing here needs a per-stage table of
/// directions, and the leg comes from [stageMoon], which the console uses for
/// the same stages, so the map and the event list cannot point at different
/// moments.
///
/// Null when this app has no leg for the stage. A stage it has never heard of is
/// still a real stage — it stays in the turn's own list — but drawing it on a
/// leg picked at random would put motion where none happened.
DirectedPulse? stageToPulse(String stageKey, String status) {
  final leg = stageMoon(stageKey);
  if (leg == null) return null;
  if (stageIsRunning(status)) {
    return DirectedPulse(leg: leg, direction: PulseDirection.outward);
  }
  if (stageIsDone(status)) {
    return DirectedPulse(leg: leg, direction: PulseDirection.inward);
  }
  // pending, failed, or a word this version does not know: not a journey.
  return null;
}

/// A directed dart fired by one observed event.
class DirectedPulse {
  const DirectedPulse({required this.leg, required this.direction});

  final MoonKind leg;
  final PulseDirection direction;
}

/// Map an event to the leg it travels and the way it goes. Milestone first,
/// source only as the fallback — kept in one place so the constellation and the
/// event list cannot disagree about what just happened.
DirectedPulse? eventToPulse(CockpitEvent event) {
  final semantic = event.milestone;
  if (event.source == 'channel') {
    if (const ['generating', 'brain_request_sent'].contains(semantic)) {
      return const DirectedPulse(
        leg: MoonKind.act,
        direction: PulseDirection.outward,
      );
    }
    if (const [
      'brain_first_delta',
      'brain_done',
      'brain_cancelled',
      'brain_error',
      'llm_error',
    ].contains(semantic)) {
      return const DirectedPulse(
        leg: MoonKind.act,
        direction: PulseDirection.inward,
      );
    }
    if (const [
      'tts_provider_first_audio',
      'first_audio',
      'playback_done',
    ].contains(semantic)) {
      return const DirectedPulse(
        leg: MoonKind.body,
        direction: PulseDirection.outward,
      );
    }
    if (event.type == 'channel.turn.completed') {
      return const DirectedPulse(
        leg: MoonKind.body,
        direction: PulseDirection.outward,
      );
    }
    return const DirectedPulse(
      leg: MoonKind.body,
      direction: PulseDirection.inward,
    );
  }
  if (event.source == 'hub') {
    return const DirectedPulse(
      leg: MoonKind.body,
      direction: PulseDirection.inward,
    );
  }
  if (event.source == 'memory') {
    final returning =
        event.type.contains('recalled') || event.type.contains('result');
    return DirectedPulse(
      leg: MoonKind.mem,
      direction: returning ? PulseDirection.inward : PulseDirection.outward,
    );
  }
  if (event.source == 'agent') {
    return const DirectedPulse(
      leg: MoonKind.act,
      direction: PulseDirection.inward,
    );
  }
  return null;
}

/// A pulse's tone, from both wire axes: how loud (severity) and what happened
/// (outcome). A failure is never allowed to travel in the calm colour.
PulseTone eventTone(String severity, String outcome) {
  if (outcome == 'failure' || severity == 'error') return PulseTone.bad;
  if (outcome == 'denied' || severity == 'warn') return PulseTone.warn;
  return PulseTone.normal;
}

/// One dart in flight.
class CockpitPulse {
  const CockpitPulse({
    required this.id,
    required this.companionId,
    required this.leg,
    required this.direction,
    required this.tone,
    required this.firedAt,
    this.deviceId = '',
  });

  final String id;
  final String companionId;
  final MoonKind leg;
  final PulseDirection direction;
  final PulseTone tone;
  final DateTime firedAt;
  final String deviceId;
}

// The view model the constellation is drawn from.
//
// It is deliberately the console cockpit's information model — Owner ▸
// companions ▸ (bodies, memory, activity) — and not this Host's Local API
// shapes. The screen is being built before the Owner-scoped projection exists
// (`GET /api/local/v1/mission-control/snapshot`), so a mock feed fills these
// same structures today and the wire adapter fills them tomorrow without the
// drawing changing.
//
// One rule survives from the product surface: no field here means "online" for
// anything nobody publishes presence for. Device presence is carried, service
// health is carried, and everything else says what it is.

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
    this.preparedWebBody = false,
  });

  final String deviceId;
  final String name;

  /// Hardware class. Never the logical role — that comes from the companion.
  final String kind;
  final String status;
  final bool online;
  final String companionId;
  final String role;
  final DateTime? lastSeenAt;
  final List<String> capabilities;

  /// A web body that has been provisioned but has not attached. It is neither
  /// online nor a fault, and calling it either would be a lie.
  final bool preparedWebBody;
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
    this.deviceId = '',
  });

  final String turnId;
  final String companionId;
  final String status;
  final String trigger;
  final int? latencyMs;
  final int memoryHits;
  final List<String> toolNames;
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
    this.isPrimary = false,
    this.genomeId = '',
    this.realmId = '',
    this.recallHits,
    this.runners = '',
    this.writeDisposition = '',
  });

  final String companionId;
  final String displayName;
  final String status;
  final String kind;
  final bool isPrimary;
  final String genomeId;
  final String realmId;
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
    this.runnersOnline = 0,
    this.runnersTotal = 0,
    this.lastRecallHits = 0,
    this.lastWriteDisposition = '',
  });

  final int realmsTotal;
  final String activeRealmId;
  final int runnersOnline;
  final int runnersTotal;
  final int lastRecallHits;
  final String lastWriteDisposition;
}

/// Everything the cockpit draws at one instant.
class CockpitSnapshot {
  const CockpitSnapshot({
    required this.generatedAt,
    required this.owner,
    required this.companions,
    required this.devices,
    required this.services,
    this.activities = const <CockpitActivity>[],
    this.turns = const <CockpitTurn>[],
    this.jobs = const <CockpitJob>[],
    this.events = const <CockpitEvent>[],
    this.memory = const CockpitMemory(),
    this.streamState = StreamState.live,
    this.traceId = '',
    this.degradedSources = const <String>[],
  });

  final DateTime generatedAt;
  final CockpitOwner owner;
  final List<CockpitCompanion> companions;
  final List<CockpitDevice> devices;
  final List<CockpitService> services;
  final List<CockpitActivity> activities;
  final List<CockpitTurn> turns;
  final List<CockpitJob> jobs;
  final List<CockpitEvent> events;
  final CockpitMemory memory;
  final StreamState streamState;
  final String traceId;

  /// Sources the projection could not read. Named out loud rather than folded
  /// into an empty list somewhere.
  final List<String> degradedSources;

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
  });

  final CockpitCompanion companion;
  final List<CockpitDevice> devices;
  final List<CockpitActivity> activities;
  final List<CockpitTurn> turns;
  final List<CockpitJob> jobs;

  String get id => companion.companionId;
  String get name => companion.displayName.isEmpty
      ? companion.companionId
      : companion.displayName;
  bool get isPrimary => companion.isPrimary;
  String get realm => companion.realmId;
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
  if (const ['ok', 'done', 'succeeded', 'completed', 'active', 'success']
      .contains(value)) {
    return CockpitTone.ok;
  }
  if (const ['running', 'pending', 'queued', 'degraded', 'warn', 'interrupted']
      .contains(value)) {
    return CockpitTone.warn;
  }
  if (const ['failed', 'error', 'errored', 'offline', 'orphaned']
      .contains(value)) {
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

String deviceTypeLabel(CockpitDevice device) {
  final kind = device.kind.toLowerCase();
  if (kind.contains('web') || kind.contains('virtual')) return '虚拟身体';
  if (kind.isEmpty || kind == 'unknown') return '设备';
  return '物理身体';
}

String devicePresenceLabel(CockpitDevice device) {
  if (device.online) return '在线';
  if (device.preparedWebBody) return '已准备';
  if (device.status == 'degraded') return '不稳定';
  if (device.status == 'active') return '已绑定';
  if (device.status == 'unknown') return '未探测';
  return '离线';
}

CockpitTone devicePresenceTone(CockpitDevice device) {
  if (device.online) return CockpitTone.ok;
  if (device.preparedWebBody) return CockpitTone.idle;
  if (device.status == 'degraded') return CockpitTone.warn;
  if (device.status == 'offline') return CockpitTone.bad;
  return CockpitTone.idle;
}

String genomeStateLabel(String genomeId) => genomeId.isEmpty ? '未绑定' : '已绑定';

String memoryRealmStateLabel(String realmId) => realmId.isEmpty ? '未开通' : '已配置';

String formatLatency(int? ms) {
  if (ms == null) return '—';
  return ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(2)}s';
}

String formatClock(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
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
  if (RegExp(r'^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$', caseSensitive: false)
      .hasMatch(id)) {
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

const List<String> _stageRunning = ['running', 'pending', 'active'];
const List<String> _stageDone = ['done', 'ok', 'succeeded'];

/// The stage a turn is currently at, or '' when it has none.
String currentStageKey(CockpitTurn? turn) {
  final stages = turn?.stages ?? const <CockpitTurnStage>[];
  for (final stage in stages) {
    if (_stageRunning.contains(stage.status.toLowerCase())) return stage.key;
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
    if (const ['tts_provider_first_audio', 'first_audio', 'playback_done']
        .contains(semantic)) {
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

import '../../protocol/companion_contract.dart';
import 'dart:async';

import 'cockpit_feed.dart';
import 'cockpit_models.dart';

/// A staged sovereign domain that behaves like a running one.
///
/// This exists because the Owner-scoped Mission Control projection does not
/// exist yet, and a constellation is one of those screens whose whole value is
/// in motion: a still frame of it proves nothing about whether a signal reads as
/// travelling from a body to a brain and back. So the world here runs a script —
/// a voice turn, a recall, a background job, a denied guard event, a command to
/// a body that is offline — on a loop, and every beat emits the same kinds of
/// events and pulses the real stream will.
///
/// It is a mock, and it says so: `origin` on every event is `mock`, and the
/// cockpit shows that badge. Nothing here is allowed to look like a fact from
/// the Host.
class MockCockpitFeed implements CockpitFeed {
  MockCockpitFeed({
    this.autoplay = true,
    DateTime? startedAt,
    this.firstReadDelay = Duration.zero,
  }) : _startedAt = startedAt ?? DateTime.now() {
    _world = _MockWorld(_startedAt);
  }

  /// Off in tests that want one deterministic frame instead of a moving one.
  final bool autoplay;

  /// How long this world pretends the first read takes.
  final Duration firstReadDelay;

  final DateTime _startedAt;
  late _MockWorld _world;
  var _started = false;
  CockpitSnapshot? _snapshot;
  CockpitObservation _observation =
      const CockpitObservation(state: ObservationState.connecting);
  final _updates = StreamController<CockpitSnapshot>.broadcast();
  final _pulses = StreamController<CockpitPulse>.broadcast();
  final _observations = StreamController<CockpitObservation>.broadcast();
  Timer? _timer;
  int _beat = 0;
  var _disposed = false;
  var _paused = false;

  @override
  CockpitSnapshot? get snapshot => _snapshot;

  @override
  CockpitObservation get observation => _observation;

  @override
  Stream<CockpitSnapshot> get updates => _updates.stream;

  @override
  Stream<CockpitPulse> get pulses => _pulses.stream;

  @override
  Stream<CockpitObservation> get observations => _observations.stream;

  /// The script does not run until somebody asks for it.
  ///
  /// This used to happen in the constructor, which made the mock the only feed
  /// in the codebase that observed without being asked — so the page could get
  /// away with never asking, and did. A staged world that self-starts is a
  /// staged lifecycle too, and the lifecycle is the part that has to be real.
  @override
  void start() {
    if (_disposed || _started) return;
    _started = true;
    if (firstReadDelay == Duration.zero) {
      _publish();
    } else {
      // Lets a caller exercise the state a real adapter always starts in: no
      // facts yet, and a screen that has to say so.
      Timer(firstReadDelay, () {
        if (!_disposed) _publish();
      });
    }
    if (autoplay) _scheduleBeat();
  }

  @override
  Future<void> refresh() async {
    _publish();
  }

  @override
  void pause() {
    if (_paused) return;
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_started && autoplay) _scheduleBeat();
  }

  /// Whether the script is currently running. Tests assert on this rather than
  /// on a timer, because "did backgrounding actually stop it" is the question.
  bool get running => !_paused && !_disposed;

  /// Advance the script by one beat without waiting for its timer. Tests drive
  /// the world this way so a scene is reproducible rather than timing-dependent.
  void step() {
    final beats = _script;
    final beat = beats[_beat % beats.length];
    beat.run(_world, _emit);
    _beat += 1;
    if (_beat % beats.length == 0) _world.reset();
    _publish();
  }

  void _scheduleBeat() {
    if (_disposed || _paused) return;
    final beats = _script;
    final beat = beats[_beat % beats.length];
    _timer = Timer(beat.after, () {
      if (_disposed || _paused) return;
      step();
      _scheduleBeat();
    });
  }

  void _emit(CockpitPulse pulse) {
    if (_disposed) return;
    _pulses.add(pulse);
  }

  void _publish() {
    if (_disposed) return;
    final snapshot = _world.snapshot(StreamState.live);
    _snapshot = snapshot;
    _observation = CockpitObservation(
      state: ObservationState.live,
      lastReadAt: snapshot.generatedAt,
      cursor: snapshot.events.isEmpty ? null : snapshot.events.first.eventId,
    );
    _updates.add(snapshot);
    _observations.add(_observation);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _updates.close();
    _pulses.close();
    _observations.close();
  }
}

typedef _PulseSink = void Function(CockpitPulse pulse);

class _Beat {
  const _Beat(this.after, this.run);

  /// How long after the previous beat this one lands.
  final Duration after;
  final void Function(_MockWorld world, _PulseSink emit) run;
}

const _master = 'companion-yanzhou';
const _second = 'companion-qingwu';
const _third = 'companion-linyuan';
const _living = 'dev-esp32-living';
const _study = 'dev-pi-study';
const _car = 'dev-esp32-car';

/// One turn of the script. Roughly 26 seconds, then the world resets and runs
/// again, so anybody looking at the screen sees the whole vocabulary of states
/// without staging anything.
final List<_Beat> _script = <_Beat>[
  _Beat(const Duration(milliseconds: 1600), (world, emit) {
    world.startVoiceTurn(companionId: _master, deviceId: _living);
    world.log(
      source: 'hub',
      type: 'hub.device.joined',
      summary: '客厅音箱 加入语音房间',
      companionId: _master,
      deviceId: _living,
    );
    emit(world.pulse(_master, MoonKind.body, PulseDirection.inward,
        deviceId: _living));
  }),
  _Beat(const Duration(milliseconds: 1100), (world, emit) {
    world.advanceVoiceStage('input', 'done', latencyMs: 42);
    world.log(
      source: 'channel',
      type: 'channel.turn.speech',
      summary: '收到一句话，端点检测已判定说完',
      companionId: _master,
      deviceId: _living,
      milestone: 'eot',
    );
    emit(world.pulse(_master, MoonKind.body, PulseDirection.inward,
        deviceId: _living));
  }),
  _Beat(const Duration(milliseconds: 900), (world, emit) {
    world.advanceVoiceStage('memory_recall', 'running');
    world.log(
      source: 'memory',
      type: 'memory.recall.requested',
      summary: '向记忆空间发起召回',
      companionId: _master,
      milestone: 'memory_recall',
    );
    emit(world.pulse(_master, MoonKind.mem, PulseDirection.outward));
  }),
  _Beat(const Duration(milliseconds: 850), (world, emit) {
    world.advanceVoiceStage('memory_recall', 'done', latencyMs: 61);
    world.setRecall(_master, 4);
    world.log(
      source: 'memory',
      type: 'memory.recall.recalled',
      summary: '召回 4 条相关记忆',
      companionId: _master,
      milestone: 'memory_recall',
    );
    emit(world.pulse(_master, MoonKind.mem, PulseDirection.inward));
  }),
  _Beat(const Duration(milliseconds: 900), (world, emit) {
    world.advanceVoiceStage('agent_turn', 'running');
    world.log(
      source: 'channel',
      type: 'channel.turn.generating',
      summary: '把这一轮交给智能体推理',
      companionId: _master,
      milestone: 'generating',
    );
    emit(world.pulse(_master, MoonKind.act, PulseDirection.outward));
  }),
  _Beat(const Duration(milliseconds: 1200), (world, emit) {
    world.log(
      source: 'agent',
      type: 'agent.turn.first_delta',
      summary: '智能体开始输出回应',
      companionId: _master,
      milestone: 'brain_first_delta',
    );
    emit(world.pulse(_master, MoonKind.act, PulseDirection.inward));
  }),
  _Beat(const Duration(milliseconds: 1000), (world, emit) {
    world.advanceVoiceStage('agent_turn', 'done', latencyMs: 780);
    world.advanceVoiceStage('tts', 'running');
    world.log(
      source: 'channel',
      type: 'channel.turn.first_audio',
      summary: '第一段语音已发往身体',
      companionId: _master,
      deviceId: _living,
      milestone: 'first_audio',
    );
    emit(world.pulse(_master, MoonKind.body, PulseDirection.outward,
        deviceId: _living));
  }),
  _Beat(const Duration(milliseconds: 1400), (world, emit) {
    world.advanceVoiceStage('tts', 'done', latencyMs: 240);
    world.advanceVoiceStage('memory_write', 'running');
    world.log(
      source: 'memory',
      type: 'memory.write.requested',
      summary: '把这一轮写回记忆',
      companionId: _master,
      milestone: 'memory_write',
    );
    emit(world.pulse(_master, MoonKind.mem, PulseDirection.outward));
  }),
  _Beat(const Duration(milliseconds: 1100), (world, emit) {
    world.advanceVoiceStage('memory_write', 'done', latencyMs: 88);
    world.finishVoiceTurn();
    world.log(
      source: 'channel',
      type: 'channel.turn.completed',
      summary: '这一轮对话完成，播放结束',
      companionId: _master,
      deviceId: _living,
      milestone: 'playback_done',
    );
    emit(world.pulse(_master, MoonKind.body, PulseDirection.outward,
        deviceId: _living));
  }),
  // A quiet stretch: the resting cockpit is a state worth seeing too.
  _Beat(const Duration(milliseconds: 2600), (world, emit) {
    world.startBackgroundJob(_second);
    world.log(
      source: 'agent',
      type: 'agent.job.accepted',
      summary: '青梧 接下一件后台整理任务',
      companionId: _second,
    );
    emit(world.pulse(_second, MoonKind.act, PulseDirection.inward));
  }),
  _Beat(const Duration(milliseconds: 1800), (world, emit) {
    world.log(
      source: 'memory',
      type: 'memory.runner.progress',
      summary: '整理 2026-08 的对话摘要',
      companionId: _second,
      milestone: 'memory_write',
    );
    emit(world.pulse(_second, MoonKind.mem, PulseDirection.outward));
  }),
  _Beat(const Duration(milliseconds: 1500), (world, emit) {
    // A lane goes away. Nothing else about the domain changed — and the screen
    // has to say that rather than showing zeroes.
    world.memoryReadable = false;
    world.log(
      source: 'memory',
      type: 'memory.probe.failed',
      summary: '读不到记忆服务，这一屏的记忆一栏是未知，不是 0',
      severity: 'warn',
      outcome: 'failure',
    );
  }),
  _Beat(const Duration(milliseconds: 2600), (world, emit) {
    world.memoryReadable = true;
  }),
  _Beat(const Duration(milliseconds: 1900), (world, emit) {
    world.denyGuardEvent(_third);
    world.log(
      source: 'hub',
      type: 'hub.guard.denied',
      summary: '临渊 请求开启摄像头，被授权边界拒绝',
      companionId: _third,
      severity: 'warn',
      outcome: 'denied',
    );
    emit(world.pulse(_third, MoonKind.body, PulseDirection.inward,
        tone: PulseTone.warn));
  }),
  _Beat(const Duration(milliseconds: 1700), (world, emit) {
    world.failDeviceCommand(_second, _car);
    world.log(
      source: 'hub',
      type: 'hub.command.failed',
      summary: '车机 不在线，指令没有送到',
      companionId: _second,
      deviceId: _car,
      severity: 'error',
      outcome: 'failure',
    );
    emit(world.pulse(_second, MoonKind.body, PulseDirection.outward,
        deviceId: _car, tone: PulseTone.bad));
  }),
  _Beat(const Duration(milliseconds: 2200), (world, emit) {
    world.finishBackgroundJob(_second);
    world.log(
      source: 'agent',
      type: 'agent.job.completed',
      summary: '后台整理完成，写回 3 条摘要',
      companionId: _second,
    );
    emit(world.pulse(_second, MoonKind.act, PulseDirection.inward));
  }),
  _Beat(const Duration(milliseconds: 1500), (world, emit) {
    world.startVoiceTurn(companionId: _third, deviceId: _study);
    world.log(
      source: 'hub',
      type: 'hub.device.joined',
      summary: '书房屏 被 临渊 接管',
      companionId: _third,
      deviceId: _study,
    );
    emit(world.pulse(_third, MoonKind.body, PulseDirection.inward,
        deviceId: _study));
  }),
  _Beat(const Duration(milliseconds: 1300), (world, emit) {
    world.advanceVoiceStage('input', 'done', latencyMs: 51);
    world.advanceVoiceStage('agent_turn', 'running');
    world.log(
      source: 'channel',
      type: 'channel.turn.generating',
      summary: '临渊 正在思考',
      companionId: _third,
      milestone: 'generating',
    );
    emit(world.pulse(_third, MoonKind.act, PulseDirection.outward));
  }),
  _Beat(const Duration(milliseconds: 1600), (world, emit) {
    world.interruptVoiceTurn();
    world.log(
      source: 'channel',
      type: 'channel.turn.interrupted',
      summary: '被主人打断，这一轮提前收束',
      companionId: _third,
      severity: 'warn',
      outcome: 'deferred',
      milestone: 'brain_cancelled',
    );
    emit(world.pulse(_third, MoonKind.act, PulseDirection.inward,
        tone: PulseTone.warn));
  }),
  _Beat(const Duration(milliseconds: 3000), (world, emit) {}),
];

/// The mutable world the script runs in.
class _MockWorld {
  _MockWorld(this.startedAt) {
    reset();
  }

  final DateTime startedAt;

  late List<CockpitCompanion> _companions;
  late List<CockpitDevice> _devices;
  late List<CockpitActivity> _activities;
  late List<CockpitTurn> _turns;
  late List<CockpitJob> _jobs;
  late List<CockpitEvent> _events;
  late CockpitMemory _memory;
  var _seq = 0;
  String _voiceActivityId = '';
  String _voiceTurnId = '';

  void reset() {
    _companions = <CockpitCompanion>[
      const CockpitCompanion(
        companionId: _master,
        displayName: '砚舟',
        status: 'active',
        kind: 'companion',
        genomeId: 'genome-yanzhou-7',
        realmId: 'realm-yanzhou',
        recallHits: 0,
        runners: '2/2 在线',
        writeDisposition: '摘要写回',
      ),
      const CockpitCompanion(
        companionId: _second,
        displayName: '青梧',
        status: 'active',
        genomeId: 'genome-qingwu-3',
        realmId: 'realm-qingwu',
        recallHits: 0,
        runners: '1/2 在线',
        writeDisposition: '全量写回',
      ),
      const CockpitCompanion(
        // Archived, not `pending`: this world used to stage a lifecycle value
        // the Companion authority never publishes, which is exactly the kind of
        // fiction a mock is supposed to avoid.
        companionId: _third,
        displayName: '临渊',
        status: lifecycleArchived,
        genomeId: '',
        realmId: '',
      ),
    ];
    _devices = <CockpitDevice>[
      CockpitDevice(
        deviceId: _living,
        name: '客厅音箱',
        kind: 'esp32-s3',
        status: 'active',
        online: true,
        companionId: _master,
        role: '常驻身体',
        lastSeenAt: startedAt,
        capabilities: const ['voice.duplex', 'audio.playback'],
      ),
      CockpitDevice(
        deviceId: _study,
        name: '书房屏',
        kind: 'raspberry-pi5',
        status: 'active',
        online: true,
        companionId: _master,
        role: '数字人展示',
        lastSeenAt: startedAt,
        capabilities: const ['avatar.render', 'voice.duplex'],
      ),
      const CockpitDevice(
        deviceId: 'dev-web-body',
        name: 'Web 身体',
        kind: 'web',
        status: 'active',
        online: false,
        companionId: _master,
        role: '临时化身',
        preparedWebBody: true,
      ),
      const CockpitDevice(
        deviceId: _car,
        name: '车机',
        kind: 'esp32-s3',
        status: 'offline',
        online: false,
        companionId: _second,
        role: '移动身体',
      ),
      const CockpitDevice(
        deviceId: 'dev-pi-kitchen',
        name: '厨房终端',
        kind: 'raspberry-pi5',
        status: 'active',
        online: true,
        companionId: _second,
        role: '常驻身体',
      ),
      const CockpitDevice(
        deviceId: 'dev-esp32-unclaimed',
        name: '',
        kind: 'esp32-s3',
        status: 'unknown',
        online: false,
      ),
    ];
    _activities = <CockpitActivity>[
      CockpitActivity(
        activityId: 'act-seed-1',
        kind: 'device_event',
        companionId: _master,
        status: 'completed',
        outcome: 'success',
        summary: '书房屏 完成一次数字人渲染',
        originDeviceId: _study,
        startedAt: startedAt.subtract(const Duration(minutes: 7)),
        updatedAt: startedAt.subtract(const Duration(minutes: 7)),
        route: const [
          CockpitHop(
            hopId: 'seed-1-a',
            label: '书房屏',
            stage: 'input',
            status: 'done',
            nodeType: 'device',
            latencyMs: 18,
          ),
          CockpitHop(
            hopId: 'seed-1-b',
            label: '设备中枢',
            stage: 'commit',
            status: 'done',
            nodeType: 'service',
            latencyMs: 30,
          ),
        ],
      ),
    ];
    _turns = <CockpitTurn>[];
    _jobs = <CockpitJob>[];
    _events = <CockpitEvent>[];
    _memory = const CockpitMemory(
      realmsTotal: 2,
      activeRealmId: 'realm-yanzhou',
      runnersOnline: 3,
      runnersTotal: 4,
      lastRecallHits: 0,
      lastWriteDisposition: '摘要写回',
    );
    _voiceActivityId = '';
    _voiceTurnId = '';
    memoryReadable = true;
  }

  String _id(String prefix) {
    _seq += 1;
    return '$prefix-${_seq.toString().padLeft(4, '0')}';
  }

  void log({
    required String source,
    required String type,
    required String summary,
    String companionId = '',
    String deviceId = '',
    String severity = 'info',
    String outcome = 'success',
    String milestone = '',
  }) {
    _events = <CockpitEvent>[
      CockpitEvent(
        eventId: _id('event'),
        ts: DateTime.now(),
        source: source,
        type: type,
        summary: summary,
        severity: severity,
        outcome: outcome,
        origin: 'mock',
        companionId: companionId,
        deviceId: deviceId,
        turnId: _voiceTurnId,
        milestone: milestone,
      ),
      ..._events,
    ].take(24).toList(growable: false);
  }

  CockpitPulse pulse(
    String companionId,
    MoonKind leg,
    PulseDirection direction, {
    String deviceId = '',
    PulseTone tone = PulseTone.normal,
  }) =>
      CockpitPulse(
        id: _id('pulse'),
        companionId: companionId,
        leg: leg,
        direction: direction,
        tone: tone,
        firedAt: DateTime.now(),
        deviceId: deviceId,
      );

  void startVoiceTurn({required String companionId, required String deviceId}) {
    final now = DateTime.now();
    _voiceTurnId = _id('turn');
    _voiceActivityId = _id('activity');
    _turns = <CockpitTurn>[
      CockpitTurn(
        turnId: _voiceTurnId,
        companionId: companionId,
        status: 'running',
        trigger: 'voice',
        latencyMs: null,
        memoryHits: 0,
        deviceId: deviceId,
        // Where the time went. Demo numbers, but the same shape a Host sends —
        // and `first_delta` unmeasured, because this turn has not answered yet.
        breakdown: const [
          CockpitTurnPhase(key: 'guard', label: '检查这句话能不能处理', latencyMs: 6),
          CockpitTurnPhase(key: 'triage', label: '判断这轮怎么走', latencyMs: 14),
          CockpitTurnPhase(key: 'compile', label: '组装上下文', latencyMs: 92),
          CockpitTurnPhase(key: 'first_delta', label: '等到第一个字'),
          CockpitTurnPhase(key: 'output', label: '把话说完'),
        ],
        stages: const [
          CockpitTurnStage(key: 'input', label: '输入', status: 'running'),
          CockpitTurnStage(
              key: 'memory_recall', label: '记忆召回', status: 'pending'),
          CockpitTurnStage(key: 'agent_turn', label: '推理', status: 'pending'),
          CockpitTurnStage(key: 'tts', label: '合成', status: 'pending'),
          CockpitTurnStage(key: 'memory_write', label: '写回', status: 'pending'),
        ],
      ),
      ..._turns,
    ].take(6).toList(growable: false);
    _activities = <CockpitActivity>[
      CockpitActivity(
        activityId: _voiceActivityId,
        kind: 'voice_turn',
        companionId: companionId,
        status: 'running',
        outcome: 'deferred',
        summary: '一次语音对话正在这条链路上推进',
        turnId: _voiceTurnId,
        originDeviceId: deviceId,
        targetDeviceIds: [deviceId],
        startedAt: now,
        updatedAt: now,
        currentHopId: 'hop-access',
        route: [
          CockpitHop(
            hopId: 'hop-access',
            label: _deviceName(deviceId),
            stage: 'input',
            status: 'running',
            nodeType: 'device',
          ),
        ],
      ),
      ..._activities,
    ].take(8).toList(growable: false);
  }

  void advanceVoiceStage(String key, String status, {int? latencyMs}) {
    if (_voiceTurnId.isEmpty) return;
    _turns = _turns.map((turn) {
      if (turn.turnId != _voiceTurnId) return turn;
      return CockpitTurn(
        turnId: turn.turnId,
        companionId: turn.companionId,
        status: turn.status,
        trigger: turn.trigger,
        latencyMs: latencyMs ?? turn.latencyMs,
        memoryHits: turn.memoryHits,
        toolNames: turn.toolNames,
        breakdown: turn.breakdown,
        deviceId: turn.deviceId,
        stages: turn.stages
            .map(
              (stage) => stage.key == key
                  ? CockpitTurnStage(
                      key: stage.key,
                      label: stage.label,
                      status: status,
                      latencyMs: latencyMs ?? stage.latencyMs,
                    )
                  : stage,
            )
            .toList(growable: false),
      );
    }).toList(growable: false);

    final hopLabel = switch (key) {
      'input' => '语音通道',
      'memory_recall' => '记忆服务',
      'agent_turn' => '智能体引擎',
      'tts' => '语音通道',
      'memory_write' => '记忆服务',
      _ => key,
    };
    final nodeType = switch (key) {
      'memory_recall' || 'memory_write' => 'memory',
      _ => 'service',
    };
    _activities = _activities.map((activity) {
      if (activity.activityId != _voiceActivityId) return activity;
      final route = [...activity.route];
      final index = route.indexWhere((hop) => hop.stage == key);
      final hop = CockpitHop(
        hopId: 'hop-$key',
        label: hopLabel,
        stage: key,
        status: status,
        nodeType: nodeType,
        latencyMs: latencyMs,
      );
      if (index >= 0) {
        route[index] = hop;
      } else {
        route.add(hop);
      }
      // Whatever came before the newly-running hop has, by construction, been
      // passed. Marking it done is what makes the route read as a wavefront
      // rather than a list of independent lamps.
      for (var i = 0; i < route.length - 1; i += 1) {
        if (route[i].status == 'running') {
          route[i] = CockpitHop(
            hopId: route[i].hopId,
            label: route[i].label,
            stage: route[i].stage,
            status: 'done',
            nodeType: route[i].nodeType,
            latencyMs: route[i].latencyMs,
          );
        }
      }
      return CockpitActivity(
        activityId: activity.activityId,
        kind: activity.kind,
        companionId: activity.companionId,
        status: activity.status,
        outcome: activity.outcome,
        summary: activity.summary,
        turnId: activity.turnId,
        originDeviceId: activity.originDeviceId,
        targetDeviceIds: activity.targetDeviceIds,
        route: route,
        currentHopId: status == 'running' ? hop.hopId : activity.currentHopId,
        startedAt: activity.startedAt,
        updatedAt: DateTime.now(),
      );
    }).toList(growable: false);
  }

  void setRecall(String companionId, int hits) {
    _companions = _companions
        .map(
          (companion) => companion.companionId == companionId
              ? CockpitCompanion(
                  companionId: companion.companionId,
                  displayName: companion.displayName,
                  status: companion.status,
                  kind: companion.kind,
                  genomeId: companion.genomeId,
                  realmId: companion.realmId,
                  recallHits: hits,
                  runners: companion.runners,
                  writeDisposition: companion.writeDisposition,
                )
              : companion,
        )
        .toList(growable: false);
    _turns = _turns
        .map(
          (turn) => turn.turnId == _voiceTurnId
              ? CockpitTurn(
                  turnId: turn.turnId,
                  companionId: turn.companionId,
                  status: turn.status,
                  trigger: turn.trigger,
                  latencyMs: turn.latencyMs,
                  memoryHits: hits,
                  toolNames: turn.toolNames,
                  deviceId: turn.deviceId,
                  stages: turn.stages,
                )
              : turn,
        )
        .toList(growable: false);
    _memory = CockpitMemory(
      realmsTotal: _memory.realmsTotal,
      activeRealmId: _memory.activeRealmId,
      runnersOnline: _memory.runnersOnline,
      runnersTotal: _memory.runnersTotal,
      lastRecallHits: hits,
      lastWriteDisposition: _memory.lastWriteDisposition,
    );
  }

  void _closeVoiceActivity(String status, String outcome, String summary) {
    if (_voiceActivityId.isEmpty) return;
    _activities = _activities
        .map(
          (activity) => activity.activityId == _voiceActivityId
              ? CockpitActivity(
                  activityId: activity.activityId,
                  kind: activity.kind,
                  companionId: activity.companionId,
                  status: status,
                  outcome: outcome,
                  summary: summary,
                  turnId: activity.turnId,
                  originDeviceId: activity.originDeviceId,
                  targetDeviceIds: activity.targetDeviceIds,
                  route: activity.route
                      .map(
                        (hop) => hop.status == 'running'
                            ? CockpitHop(
                                hopId: hop.hopId,
                                label: hop.label,
                                stage: hop.stage,
                                status:
                                    outcome == 'success' ? 'done' : 'degraded',
                                nodeType: hop.nodeType,
                                latencyMs: hop.latencyMs,
                              )
                            : hop,
                      )
                      .toList(growable: false),
                  currentHopId: '',
                  startedAt: activity.startedAt,
                  updatedAt: DateTime.now(),
                )
              : activity,
        )
        .toList(growable: false);
    _turns = _turns
        .map(
          (turn) => turn.turnId == _voiceTurnId
              ? CockpitTurn(
                  turnId: turn.turnId,
                  companionId: turn.companionId,
                  status: status,
                  trigger: turn.trigger,
                  latencyMs: turn.latencyMs ?? 1180,
                  memoryHits: turn.memoryHits,
                  toolNames: turn.toolNames,
                  deviceId: turn.deviceId,
                  stages: turn.stages,
                )
              : turn,
        )
        .toList(growable: false);
    _voiceActivityId = '';
  }

  void finishVoiceTurn() =>
      _closeVoiceActivity('completed', 'success', '一次语音对话已完成');

  void interruptVoiceTurn() =>
      _closeVoiceActivity('interrupted', 'deferred', '这一轮被主人打断');

  void startBackgroundJob(String companionId) {
    final id = _id('job');
    _jobs = <CockpitJob>[
      CockpitJob(
        jobId: id,
        companionId: companionId,
        kind: 'memory_consolidation',
        status: 'running',
        summary: '整理最近的对话，写回摘要',
      ),
      ..._jobs,
    ].take(6).toList(growable: false);
    final now = DateTime.now();
    _activities = <CockpitActivity>[
      CockpitActivity(
        activityId: _id('activity'),
        kind: 'background_job',
        companionId: companionId,
        status: 'running',
        outcome: 'deferred',
        summary: '后台整理 2026-08 的对话摘要',
        startedAt: now,
        updatedAt: now,
        currentHopId: 'hop-job-runner',
        route: const [
          CockpitHop(
            hopId: 'hop-job-accept',
            label: '智能体引擎',
            stage: 'commit',
            status: 'done',
            nodeType: 'service',
            latencyMs: 24,
          ),
          CockpitHop(
            hopId: 'hop-job-runner',
            label: '记忆服务',
            stage: 'memory_write',
            status: 'running',
            nodeType: 'memory',
          ),
        ],
      ),
      ..._activities,
    ].take(8).toList(growable: false);
  }

  void finishBackgroundJob(String companionId) {
    _jobs = _jobs
        .where(
            (job) => job.companionId != companionId || job.status != 'running')
        .toList(growable: false);
    _activities = _activities
        .map(
          (activity) => activity.kind == 'background_job' &&
                  activity.companionId == companionId &&
                  isActiveActivity(activity)
              ? CockpitActivity(
                  activityId: activity.activityId,
                  kind: activity.kind,
                  companionId: activity.companionId,
                  status: 'completed',
                  outcome: 'success',
                  summary: '后台整理完成，写回 3 条摘要',
                  route: activity.route
                      .map(
                        (hop) => CockpitHop(
                          hopId: hop.hopId,
                          label: hop.label,
                          stage: hop.stage,
                          status: 'done',
                          nodeType: hop.nodeType,
                          latencyMs: hop.latencyMs ?? 910,
                        ),
                      )
                      .toList(growable: false),
                  currentHopId: '',
                  startedAt: activity.startedAt,
                  updatedAt: DateTime.now(),
                )
              : activity,
        )
        .toList(growable: false);
  }

  void denyGuardEvent(String companionId) {
    final now = DateTime.now();
    _activities = <CockpitActivity>[
      CockpitActivity(
        activityId: _id('activity'),
        kind: 'guard_event',
        companionId: companionId,
        status: 'rejected',
        outcome: 'denied',
        summary: '摄像头请求未获授权',
        startedAt: now,
        updatedAt: now,
        route: const [
          CockpitHop(
            hopId: 'hop-guard-ask',
            label: '设备中枢',
            stage: 'commit',
            status: 'done',
            nodeType: 'service',
            latencyMs: 12,
          ),
          CockpitHop(
            hopId: 'hop-guard-deny',
            label: '授权边界',
            stage: 'commit',
            status: 'failed',
            nodeType: 'service',
          ),
        ],
      ),
      ..._activities,
    ].take(8).toList(growable: false);
  }

  void failDeviceCommand(String companionId, String deviceId) {
    final now = DateTime.now();
    _activities = <CockpitActivity>[
      CockpitActivity(
        activityId: _id('activity'),
        kind: 'device_command',
        companionId: companionId,
        status: 'failed',
        outcome: 'failure',
        summary: '${_deviceName(deviceId)} 不在线，指令没有送到',
        targetDeviceIds: [deviceId],
        startedAt: now,
        updatedAt: now,
        route: [
          const CockpitHop(
            hopId: 'hop-cmd-send',
            label: '设备中枢',
            stage: 'commit',
            status: 'done',
            nodeType: 'service',
            latencyMs: 9,
          ),
          CockpitHop(
            hopId: 'hop-cmd-deliver',
            label: _deviceName(deviceId),
            stage: 'playback',
            status: 'failed',
            nodeType: 'device',
          ),
        ],
      ),
      ..._activities,
    ].take(8).toList(growable: false);
  }

  static String _deviceName(String deviceId) => switch (deviceId) {
        _living => '客厅音箱',
        _study => '书房屏',
        _car => '车机',
        _ => deviceId,
      };

  /// Whether the staged memory service is answering. One beat of the script
  /// takes it away, so the degraded-lane path is something you can watch rather
  /// than only assert.
  var memoryReadable = true;

  CockpitSnapshot snapshot(StreamState state) => CockpitSnapshot(
        provenance: CockpitProvenance.staged,
        generatedAt: DateTime.now(),
        ownerLane: const CockpitLane<CockpitOwner?>.ok(
          CockpitOwner(ownerId: 'owner-shenyi', displayName: '沈亦'),
        ),
        companionsLane: CockpitLane<List<CockpitCompanion>>.ok(_companions),
        devicesLane: CockpitLane<List<CockpitDevice>>.ok(_devices),
        servicesLane: CockpitLane<List<CockpitService>>.ok(_services),
        activitiesLane: CockpitLane<List<CockpitActivity>>.ok(_activities),
        turnsLane: CockpitLane<List<CockpitTurn>>.ok(_turns),
        jobsLane: CockpitLane<List<CockpitJob>>.ok(_jobs),
        eventsLane: CockpitLane<List<CockpitEvent>>.ok(_events),
        memoryLane: memoryReadable
            ? CockpitLane<CockpitMemory?>.ok(_memory)
            : const CockpitLane<CockpitMemory?>.missing(
                null,
                '记忆服务没有回应（连接超时 2s）',
              ),
        streamState: state,
        traceId: _voiceTurnId.isEmpty ? '—' : compactId(_voiceTurnId),
        cursor: _seq,
        defaultCompanionId: _master,
      );
}

/// The runtime substrate, as the console's cockpit lists it. Client products
/// (web body, this app) are bodies, not services, and Admin is the console you
/// look through — neither belongs on this rail.
const List<CockpitService> _services = <CockpitService>[
  CockpitService(
    serviceId: 'hub',
    name: '设备中枢',
    code: 'eidolon_hub',
    role: '管理身体的接入、发现与指令下发，签发语音房间令牌。',
    mode: '代理',
    tier: ServiceTier.service,
    glyph: '⎔',
    online: true,
    checked: true,
    latencyMs: 12,
    detail: '7 个身体注册在册',
  ),
  CockpitService(
    serviceId: 'channel',
    name: '语音通道',
    code: 'eidolon_channel',
    role: '语音转文字、文字转语音，作为语音房间里的 worker 调用智能体。',
    mode: '托管',
    tier: ServiceTier.service,
    glyph: '◍',
    online: true,
    checked: true,
    latencyMs: 26,
    detail: '1 个房间在跑',
  ),
  CockpitService(
    serviceId: 'agent',
    name: '智能体引擎',
    code: 'eidolon_agent',
    role: '理解、规划、调用工具、生成回应；运行每个伙伴的人格。',
    mode: '代理',
    tier: ServiceTier.service,
    glyph: '◊',
    online: true,
    checked: true,
    latencyMs: 41,
    detail: '3 个人格已装载',
  ),
  CockpitService(
    serviceId: 'memory',
    name: '记忆服务',
    code: 'eidolon_memory',
    role: '保存与召回长期记忆，经消息总线消费对话轮次。',
    mode: '内建',
    tier: ServiceTier.service,
    glyph: '◈',
    online: true,
    checked: true,
    latencyMs: 18,
    detail: '2 个记忆空间',
  ),
  CockpitService(
    serviceId: 'livekit',
    name: 'LiveKit',
    code: 'livekit-server',
    role: '实时音视频服务器 —— 承载语音房间。',
    mode: '基础',
    tier: ServiceTier.middleware,
    glyph: '⧉',
    online: true,
    checked: true,
    latencyMs: 8,
    detail: '1 个房间 · 2 位参与者',
  ),
  CockpitService(
    serviceId: 'nats',
    name: 'NATS',
    code: 'nats-server',
    role: '消息总线 —— 各子项目之间的事件与数据流通道。',
    mode: '基础',
    tier: ServiceTier.middleware,
    glyph: '⇄',
    online: true,
    checked: true,
    latencyMs: 4,
    detail: 'JetStream 正常',
  ),
  CockpitService(
    serviceId: 'mementos',
    name: 'Mementos',
    code: 'mementos',
    role: '后台数字员工 —— 承接长任务并产出产物（外挂扩展，非核心链路）。',
    mode: '托管',
    tier: ServiceTier.external,
    glyph: '✦',
    online: false,
    checked: true,
    detail: '进程没有回应',
  ),
];

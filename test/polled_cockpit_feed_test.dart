import 'package:eidolon_client_mobile/src/features/constellation/cockpit_feed.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/polled_cockpit_feed.dart';
import 'package:flutter_test/flutter_test.dart';

CockpitEvent _event(int seq, {String milestone = 'brain_first_delta'}) =>
    CockpitEvent(
      eventId: 'event-$seq',
      ingestSeq: seq,
      ts: DateTime.utc(2026, 8, 26, 12, 0, seq),
      source: 'channel',
      type: 'channel.turn.progress',
      milestone: milestone,
      companionId: 'companion-a',
      summary: '一件事',
    );

CockpitTurn _turn(
  String turnId, {
  String companionId = 'companion-a',
  List<(String, String)> stages = const [],
}) =>
    CockpitTurn(
      turnId: turnId,
      companionId: companionId,
      status: 'running',
      trigger: 'voice',
      memoryHits: 0,
      stages: [
        for (final (key, status) in stages)
          CockpitTurnStage(key: key, label: key, status: status),
      ],
    );

CockpitSnapshot _snapshot({
  bool memoryReadable = true,
  DateTime? at,
  List<CockpitEvent>? events,
  bool eventsReadable = true,
  List<CockpitTurn>? turns,
  List<CockpitActivity>? activities,
}) =>
    CockpitSnapshot(
      provenance: CockpitProvenance.host,
      generatedAt: at ?? DateTime.utc(2026, 8, 24, 5, 16),
      ownerLane: const CockpitLane<CockpitOwner?>.ok(
        CockpitOwner(ownerId: 'owner-1', displayName: '沈亦'),
      ),
      companionsLane: const CockpitLane<List<CockpitCompanion>>.ok(
        <CockpitCompanion>[],
      ),
      devicesLane: const CockpitLane<List<CockpitDevice>>.ok(<CockpitDevice>[]),
      servicesLane: const CockpitLane<List<CockpitService>>.ok(
        <CockpitService>[],
      ),
      memoryLane: memoryReadable
          ? const CockpitLane<CockpitMemory?>.ok(CockpitMemory())
          : const CockpitLane<CockpitMemory?>.missing(null, '记忆服务没有回应'),
      activitiesLane: CockpitLane<List<CockpitActivity>>.ok(
        activities ?? const <CockpitActivity>[],
      ),
      turnsLane:
          CockpitLane<List<CockpitTurn>>.ok(turns ?? const <CockpitTurn>[]),
      eventsLane: eventsReadable
          ? CockpitLane<List<CockpitEvent>>.ok(events ?? const <CockpitEvent>[])
          : const CockpitLane<List<CockpitEvent>>.missing(
              <CockpitEvent>[],
              '审计索引没有回应',
            ),
    );

void main() {
  test('start 才开始读；再 start 一次不会多出一个轮询', () async {
    var reads = 0;
    final feed = PolledCockpitFeed(read: () async {
      reads += 1;
      return _snapshot();
    });
    addTearDown(feed.dispose);

    // 构造只是准备好，不是开始。
    expect(reads, 0);

    feed.start();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);

    // 幂等：第二次 start 不该再排一次期，否则两条轮询会并行敲同一台主机。
    feed.start();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
  });

  test('start 的第一次读失败：报在观测通道上，不抛到 zone 里', () async {
    final feed = PolledCockpitFeed(
      read: () async => throw StateError('主机没有回应'),
      retryFloor: const Duration(milliseconds: 50),
    );
    addTearDown(feed.dispose);

    final states = <ObservationState>[];
    feed.observations.listen((observation) => states.add(observation.state));

    // 没有 caller 可以接这个异常。逃到 zone 里就是一次未捕获错误，这个测试会自己红。
    feed.start();
    await Future<void>.delayed(Duration.zero);

    expect(states, [ObservationState.lost]);
    expect(feed.observation.detail, contains('主机没有回应'));
  });

  test('没 start 过的 resume 不会偷偷开始观测', () async {
    var reads = 0;
    final feed = PolledCockpitFeed(read: () async {
      reads += 1;
      return _snapshot();
    });
    addTearDown(feed.dispose);

    // resume 是「继续」，不是「开始」：一个从未开始的 feed 没有东西可以继续。
    feed.pause();
    feed.resume();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 0);

    feed.start();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
  });

  test('第一次读到之前没有 snapshot，状态是 connecting', () {
    final feed = PolledCockpitFeed(read: () async => _snapshot());
    addTearDown(feed.dispose);
    expect(feed.snapshot, isNull);
    expect(feed.observation.state, ObservationState.connecting);
    expect(feed.observation.lastReadAt, isNull);
  });

  test('读到了就 live，并记下这次读取的时间', () async {
    final feed = PolledCockpitFeed(read: () async => _snapshot());
    addTearDown(feed.dispose);
    await feed.refresh();
    expect(feed.snapshot, isNotNull);
    expect(feed.observation.state, ObservationState.live);
    expect(feed.observation.lastReadAt, DateTime.utc(2026, 8, 24, 5, 16));
  });

  test('请求成功但有 lane 读不到，观测是 degraded 而不是 live', () async {
    final feed = PolledCockpitFeed(
      read: () async => _snapshot(memoryReadable: false),
    );
    addTearDown(feed.dispose);
    await feed.refresh();
    expect(feed.observation.state, ObservationState.degraded);
    expect(feed.observation.detail, contains('记忆'));
  });

  test('读失败：抛出去，观测变 lost，上一次的事实留在手里', () async {
    var attempt = 0;
    final feed = PolledCockpitFeed(
      read: () async {
        attempt += 1;
        if (attempt == 1) return _snapshot();
        throw StateError('pinned host 无法验证');
      },
    );
    addTearDown(feed.dispose);
    await feed.refresh();
    final remembered = feed.snapshot;

    await expectLater(feed.refresh(), throwsA(isA<StateError>()));

    expect(feed.observation.state, ObservationState.lost);
    expect(feed.observation.detail, contains('pinned host'));
    // 上一次成功读取的时间必须留着 —— 屏幕要说清它是哪一刻的样子。
    expect(feed.observation.lastReadAt, isNotNull);
    // 事实也留着：它是记忆，不是空白。
    expect(feed.snapshot, same(remembered));
  });

  test('失败重试是有界退避：先落到下限，再翻倍，最后被上限夹住', () {
    const floor = Duration(seconds: 2);
    const ceiling = Duration(seconds: 45);
    Duration next(Duration previous) =>
        nextReadBackoff(previous, floor: floor, ceiling: ceiling);

    // 第一次失败落在下限。
    expect(next(Duration.zero), floor);
    expect(next(floor), const Duration(seconds: 4));
    expect(next(const Duration(seconds: 4)), const Duration(seconds: 8));
    // 不会无限涨 —— 对一台不在的主机每两秒锤一次只是换了个说法的耗电。
    expect(next(const Duration(seconds: 30)), ceiling);
    expect(next(ceiling), ceiling);
  });

  test('读失败之后还会再试，而不是就此停住', () async {
    var reads = 0;
    final feed = PolledCockpitFeed(
      read: () async {
        reads += 1;
        throw StateError('主机不在');
      },
      retryFloor: const Duration(milliseconds: 20),
      retryCeiling: const Duration(milliseconds: 40),
    );
    addTearDown(feed.dispose);

    await expectLater(feed.refresh(), throwsA(isA<StateError>()));
    expect(reads, 1);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(reads, greaterThan(1));
    feed.pause();
  });

  test('暂停不再读，恢复立刻读 —— 不等一个间隔', () async {
    var reads = 0;
    final feed = PolledCockpitFeed(
      read: () async {
        reads += 1;
        return _snapshot();
      },
      interval: const Duration(milliseconds: 20),
    );
    addTearDown(feed.dispose);

    await feed.refresh();
    expect(reads, 1);
    feed.pause();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(reads, 1, reason: '没人看的时候不该继续读');

    feed.resume();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    // 屏幕上那份事实可能已经很旧了，所以恢复是立刻读，不是排队等。
    expect(reads, 2);
    feed.pause();
  });

  test('事件 lane 里一个瞬间都没有，就不画箭', () async {
    final feed = PolledCockpitFeed(read: () async => _snapshot());
    addTearDown(feed.dispose);
    final fired = <CockpitPulse>[];
    final sub = feed.pulses.listen(fired.add);
    addTearDown(sub.cancel);

    await feed.refresh();
    await feed.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(fired, isEmpty);
  });

  group('飞镖只对真的新到达的瞬间发', () {
    test('第一次读取只建基线：积压的历史不当作正在发生', () async {
      final feed = PolledCockpitFeed(
        read: () async => _snapshot(events: [_event(1), _event(2), _event(3)]),
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      // 一百条来自没人看的时候的瞬间，全部画出来就是在宣称它们正在发生。
      expect(fired, isEmpty);
    });

    test('第二次读取里新增的那一条，发一支', () async {
      var reads = 0;
      final feed = PolledCockpitFeed(
        read: () async {
          reads += 1;
          return _snapshot(
            events: reads == 1
                ? [_event(1), _event(2)]
                : [_event(1), _event(2), _event(3)],
          );
        },
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      expect(fired, hasLength(1));
      // 时刻是主机观测到的那个，不是这一屏听说的那个 —— 否则六秒前的事看起来
      // 像正在眼前发生。
      expect(fired.single.firedAt, DateTime.utc(2026, 8, 26, 12, 0, 3));
      expect(fired.single.id, 'event-3');
    });

    test('同一份读取再来一次，不会重放', () async {
      final feed = PolledCockpitFeed(
        read: () async => _snapshot(events: [_event(1), _event(2)]),
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await feed.refresh();
      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      // 一个瞬间只发生一次。重复的读取里它还在，但它不是新的。
      expect(fired, isEmpty);
    });

    test('事件 lane 读不到时不动水位：恢复后那段空档照样发出来', () async {
      var reads = 0;
      final feed = PolledCockpitFeed(
        read: () async {
          reads += 1;
          if (reads == 1) return _snapshot(events: [_event(1)]);
          if (reads == 2) return _snapshot(eventsReadable: false);
          return _snapshot(events: [_event(1), _event(2), _event(3)]);
        },
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await feed.refresh();
      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      // 读不到不是「没有」：水位留在 1，所以恢复之后 2 和 3 都还算新。
      expect(fired.map((pulse) => pulse.id), ['event-2', 'event-3']);
    });

    test('没有序号的事件不猜：主机不保序就无从判断新旧', () async {
      var reads = 0;
      final feed = PolledCockpitFeed(
        read: () async {
          reads += 1;
          return _snapshot(
            events: [
              CockpitEvent(
                eventId: 'event-unordered-$reads',
                ts: DateTime.utc(2026, 8, 26, 12, 5),
                source: 'channel',
                type: 'channel.turn.progress',
                milestone: 'brain_first_delta',
                companionId: 'companion-a',
                summary: '一件没有序号的事',
              ),
            ],
          );
        },
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      expect(fired, isEmpty);
    });
  });

  group('活的那张图:飞镖来自轮次阶段的跃迁', () {
    test('第一次看见一条轮次,只画它正在跑的那一段', () async {
      // 一条已经跑了一半才被看见的轮次,前面那些阶段是在没人看的时候完成的。
      // 把它们现在画出来,就是在宣称它们正在发生 —— 和事件那条的第一次读取同一条纪律。
      final feed = PolledCockpitFeed(
        read: () async => _snapshot(
          turns: [
            _turn('turn-1', stages: const [
              ('input', 'done'),
              ('memory_recall', 'done'),
              ('agent_turn', 'running'),
            ]),
          ],
        ),
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      expect(fired, hasLength(1));
      expect(fired.single.leg, MoonKind.act);
      expect(fired.single.direction, PulseDirection.outward);
    });

    test('开始跑=出去,完成=回来', () async {
      var reads = 0;
      final feed = PolledCockpitFeed(
        read: () async {
          reads += 1;
          return _snapshot(
            turns: [
              _turn('turn-1', stages: [
                ('memory_recall', reads == 1 ? 'running' : 'done'),
              ]),
            ],
          );
        },
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      // 信号去找记忆,记忆答回来。一条规则,不需要逐阶段的方向表。
      expect(fired.map((p) => (p.leg, p.direction)), [
        (MoonKind.mem, PulseDirection.outward),
        (MoonKind.mem, PulseDirection.inward),
      ]);
    });

    test('没动的阶段不重放', () async {
      final feed = PolledCockpitFeed(
        read: () async => _snapshot(
          turns: [
            _turn('turn-1', stages: const [('agent_turn', 'running')]),
          ],
        ),
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await feed.refresh();
      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      // 同一个阶段还在跑,不是又跑了一次。
      expect(fired, hasLength(1));
    });

    test('停在 pending 的阶段既不是正在跑,也不发镖', () async {
      // 真机上每条已结束的轮次都带 memory_write: pending。把 pending 当成正在跑,
      // 那些轮次会永久读成「正在写记忆」,而且每次读取都发一支镖。
      final feed = PolledCockpitFeed(
        read: () async => _snapshot(
          turns: [
            _turn('turn-1', stages: const [
              ('agent_turn', 'done'),
              ('memory_write', 'pending'),
            ]),
          ],
        ),
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      expect(fired, isEmpty);
      expect(stageIsRunning('pending'), isFalse);
      expect(
          currentStageKey(
              _turn('t', stages: const [('memory_write', 'pending')])),
          '');
    });

    test('从没跑过就结束的阶段，不画一趟归途', () async {
      // 一轮不调工具的对话（最常见的一种）结束时，tools 会从 pending 直接落到
      // done。状态确实变了，但什么都没出去过，所以也没有什么回得来 —— 画一支
      // 归来的镖等于凭状态差编一次移动。轮次都是「已完成才第一次看见」的时候
      // 这条路走不到；现在一条轮次会被跨读取地跟住，每轮对话都会走到。
      var reading = 0;
      final feed = PolledCockpitFeed(
        read: () async {
          reading += 1;
          return _snapshot(
            turns: [
              _turn('turn-1', stages: [
                ('agent_turn', reading == 1 ? 'running' : 'done'),
                ('tools', reading == 1 ? 'pending' : 'done'),
              ]),
            ],
          );
        },
      );
      addTearDown(feed.dispose);
      final fired = <CockpitPulse>[];
      final sub = feed.pulses.listen(fired.add);
      addTearDown(sub.cancel);

      await feed.refresh();
      await Future<void>.delayed(Duration.zero);
      fired.clear();
      await feed.refresh();
      await Future<void>.delayed(Duration.zero);

      // agent_turn 跑完了，回来一支；tools 没有。
      expect(fired.length, 1);
      expect(fired.single.id, 'turn-1:agent_turn:done');
    });

    test('这一屏开着的时候，按图会动的节奏读 —— 不是"看到在动才加速"', () async {
      // 那个自适应版本抓不到任何东西：要切到快档，得先有一次读取看见轮次在跑，
      // 而证明它必要的那次对话（13:03:45 → 13:03:48，整轮三秒）必须先活过一个慢档。
      // 两次六秒读取之间它开始并结束，两次都看到一台"什么都没发生"的主机。
      var reads = 0;
      final feed = PolledCockpitFeed(
        read: () async {
          reads += 1;
          // 一台完全空闲的主机 —— 正是旧逻辑会退回慢档的情形。
          return _snapshot();
        },
        interval: const Duration(milliseconds: 20),
      );
      addTearDown(feed.dispose);

      feed.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      feed.pause();

      // 空闲也照常按这个节奏读，因为下一秒可能就有人说话。
      expect(reads, greaterThan(2));
    });
  });
}

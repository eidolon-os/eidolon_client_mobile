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

CockpitSnapshot _snapshot({
  bool memoryReadable = true,
  DateTime? at,
  List<CockpitEvent>? events,
  bool eventsReadable = true,
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
}

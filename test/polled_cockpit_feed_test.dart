import 'package:eidolon_client_mobile/src/features/constellation/cockpit_feed.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/polled_cockpit_feed.dart';
import 'package:flutter_test/flutter_test.dart';

CockpitSnapshot _snapshot({
  bool memoryReadable = true,
  DateTime? at,
}) =>
    CockpitSnapshot(
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
    );

void main() {
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

  test('永远不发脉冲：没有观测到的瞬间，就不画箭', () async {
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
}
